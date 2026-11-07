// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IMarginOrderRegistry, IMarginCloseAdapter} from "./IMarginOrderRegistry.sol";

/// @title Take-profit / stop-loss order registry (one per chain, behind an OZ 5 transparent proxy).
/// @notice Stores and authorizes orders; the chain's IMarginCloseAdapter closes through the chain's existing close path.
/// Rules, reason codes and the deployment convention: docs/margin-orders/SPEC.md.
/// The registry never holds the position, its margin or its debt, and nothing in a liquidation path reads it.
/// STORAGE IS APPEND-ONLY: OZ 5 keeps Initializable and ReentrancyGuard in namespaced slots, so this contract's own
/// variables start at slot 0 in declaration order. Add new variables only above `__gap` and shrink the gap to match;
/// `tools/orders/check_registry_layout.py` fails on any other change.
contract MarginOrderRegistry is IMarginOrderRegistry, Initializable, ReentrancyGuardUpgradeable {
    uint16 public constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 300;
    uint64 public constant MAX_ORDER_LIFETIME = 30 days;
    uint256 public constant MAX_ORDERS_PER_POSITION = 4;

    // canExecute reasons (SPEC "Reason codes"); 7 is this implementation's pause.
    uint8 internal constant R_OK = 0;
    uint8 internal constant R_NOT_OPEN = 1;
    uint8 internal constant R_EXPIRED = 2;
    uint8 internal constant R_INACTIVE = 3;
    uint8 internal constant R_OWNER_CHANGED = 4;
    uint8 internal constant R_ORACLE = 5;
    uint8 internal constant R_TRIGGER = 6;
    uint8 internal constant R_PAUSED = 7;

    // OrderCancelled reasons.
    uint8 internal constant C_OWNER = 0;
    uint8 internal constant C_SIBLING = 1;
    uint8 internal constant C_INACTIVE = 2;
    uint8 internal constant C_OWNER_CHANGED = 3;

    // ------------------------------------------------------------------ storage (append-only)
    IMarginCloseAdapter public adapter; // slot 0
    address public admin; // slot 1: the timelock
    bool public paused; // slot 1 (packed): stops execution only
    uint256 public nextOrderId; // slot 2: ids start at 1
    mapping(uint256 => Order) internal _orders; // slot 3
    mapping(uint256 => uint256[]) internal _openOrders; // slot 4: positionId => open order ids
    mapping(uint256 => uint256) internal _openIndex; // slot 5: orderId => index + 1 in _openOrders
    uint256[44] private __gap; // slots 6..49

    event PausedSet(bool paused);

    error NotAdmin();
    error ExecutionPaused();

    constructor() {
        _disableInitializers();
    }

    function initialize(IMarginCloseAdapter adapter_, address admin_) external initializer {
        require(address(adapter_) != address(0) && admin_ != address(0), "REGISTRY_CONFIG");
        __ReentrancyGuard_init();
        adapter = adapter_;
        admin = admin_;
        nextOrderId = 1;
    }

    // ------------------------------------------------------------------ admin
    /// @notice Stops order execution only. Owners can still create, modify and cancel; owner closes and liquidations
    /// never touch the registry.
    function setPaused(bool paused_) external {
        if (msg.sender != admin) revert NotAdmin();
        paused = paused_;
        emit PausedSet(paused_);
    }

    // ------------------------------------------------------------------ owner actions
    function createOrder(
        uint256 positionId,
        OrderKind kind,
        bool triggerAbove,
        uint256 triggerPriceE18,
        uint16 closeBps,
        uint16 maxSlippageBps,
        uint64 expiry
    ) external nonReentrant returns (uint256 orderId) {
        IMarginCloseAdapter a = adapter;
        if (msg.sender != a.positionOwner(positionId)) revert NotPositionOwner();
        if (!a.isActive(positionId)) revert PositionNotActive();
        // Long: TP above, SL below. Short: the reverse.
        if (triggerAbove != ((kind == OrderKind.TAKE_PROFIT) == a.isLong(positionId))) revert InvalidOrder(1);
        _checkFields(triggerPriceE18, closeBps, maxSlippageBps, expiry);
        uint256[] storage open = _openOrders[positionId];
        if (open.length >= MAX_ORDERS_PER_POSITION) revert InvalidOrder(6);

        orderId = nextOrderId++;
        Order storage o = _orders[orderId];
        o.positionId = positionId;
        o.owner = msg.sender;
        o.kind = kind;
        o.triggerAbove = triggerAbove;
        o.triggerPriceE18 = triggerPriceE18;
        o.closeBps = closeBps;
        o.maxSlippageBps = maxSlippageBps;
        o.expiry = expiry;
        o.createdAt = uint64(block.timestamp);
        o.updatedAt = uint64(block.timestamp);
        o.status = OrderStatus.OPEN;
        open.push(orderId);
        _openIndex[orderId] = open.length;
        emit OrderCreated(orderId, positionId, msg.sender, o);
    }

    function modifyOrder(uint256 orderId, uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry)
        external
        nonReentrant
    {
        Order storage o = _orders[orderId];
        if (o.status != OrderStatus.OPEN || block.timestamp > o.expiry) revert OrderNotOpen();
        IMarginCloseAdapter a = adapter;
        if (msg.sender != o.owner || msg.sender != a.positionOwner(o.positionId)) revert NotPositionOwner();
        if (!a.isActive(o.positionId)) revert PositionNotActive();
        _checkFields(triggerPriceE18, closeBps, maxSlippageBps, expiry);
        o.triggerPriceE18 = triggerPriceE18;
        o.closeBps = closeBps;
        o.maxSlippageBps = maxSlippageBps;
        o.expiry = expiry;
        o.updatedAt = uint64(block.timestamp);
        emit OrderModified(orderId, o.positionId, o);
    }

    /// @notice The order's owner can always withdraw it, even after the position closed. An order already past its
    /// expiry becomes EXPIRED instead (SPEC: an expired order can only become EXPIRED).
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = _orders[orderId];
        if (o.status != OrderStatus.OPEN) revert OrderNotOpen();
        if (msg.sender != o.owner) revert NotPositionOwner();
        if (block.timestamp > o.expiry) _expire(orderId, o);
        else _cancel(orderId, o, C_OWNER);
    }

    // ------------------------------------------------------------------ execution
    function executeOrder(uint256 orderId, bytes calldata adapterData) external nonReentrant returns (bool executed) {
        if (paused) revert ExecutionPaused();
        Order storage o = _orders[orderId];
        // 1. open
        if (o.status != OrderStatus.OPEN) revert OrderNotOpen();
        // 2. expiry first
        if (block.timestamp > o.expiry) {
            _expire(orderId, o);
            return false;
        }
        IMarginCloseAdapter a = adapter;
        uint256 positionId = o.positionId;
        // 3. position still active and still the order owner's
        if (!a.isActive(positionId)) {
            _cancel(orderId, o, C_INACTIVE);
            return false;
        }
        if (a.positionOwner(positionId) != o.owner) {
            _cancel(orderId, o, C_OWNER_CHANGED);
            return false;
        }
        // 4. fresh oracle price
        (uint256 price, bool ok) = a.oraclePriceE18(positionId);
        if (!ok || price == 0) revert OracleUnavailable();
        // 5. trigger
        if (!_crossed(o, price)) revert TriggerNotReached(price, o.triggerPriceE18);
        // 6. close; a revert leaves the order open
        uint16 closeBps = o.closeBps;
        address owner = o.owner;
        o.status = OrderStatus.EXECUTED; // before the external call
        o.updatedAt = uint64(block.timestamp);
        _removeOpen(positionId, orderId);
        uint256 returned = a.closeFor(positionId, owner, closeBps, price, o.maxSlippageBps, adapterData);
        // 7. record, then mutual cancellation if the position ended
        emit OrderExecuted(orderId, positionId, msg.sender, price, closeBps, returned);
        if (!a.isActive(positionId)) _cancelAllOpen(positionId, C_SIBLING);
        return true;
    }

    function canExecute(uint256 orderId) external view returns (bool executable, uint256 oraclePriceE18, uint8 reason) {
        Order storage o = _orders[orderId];
        if (o.status != OrderStatus.OPEN) return (false, 0, R_NOT_OPEN);
        if (block.timestamp > o.expiry) return (false, 0, R_EXPIRED);
        IMarginCloseAdapter a = adapter;
        try a.isActive(o.positionId) returns (bool active) {
            if (!active) return (false, 0, R_INACTIVE);
        } catch {
            return (false, 0, R_INACTIVE);
        }
        try a.positionOwner(o.positionId) returns (address current) {
            if (current != o.owner) return (false, 0, R_OWNER_CHANGED);
        } catch {
            return (false, 0, R_OWNER_CHANGED);
        }
        try a.oraclePriceE18(o.positionId) returns (uint256 price, bool ok) {
            if (!ok || price == 0) return (false, 0, R_ORACLE);
            oraclePriceE18 = price;
        } catch {
            return (false, 0, R_ORACLE);
        }
        if (!_crossed(o, oraclePriceE18)) return (false, oraclePriceE18, R_TRIGGER);
        if (paused) return (false, oraclePriceE18, R_PAUSED);
        return (true, oraclePriceE18, R_OK);
    }

    // ------------------------------------------------------------------ views
    function getOrder(uint256 orderId) external view returns (Order memory) {
        return _orders[orderId];
    }

    function openOrdersOf(uint256 positionId) external view returns (uint256[] memory) {
        return _openOrders[positionId];
    }

    // ------------------------------------------------------------------ internals
    function _checkFields(uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry) private view {
        if (closeBps == 0 || closeBps > BPS) revert InvalidOrder(2);
        if (maxSlippageBps == 0 || maxSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidOrder(3);
        if (expiry <= block.timestamp || expiry > block.timestamp + MAX_ORDER_LIFETIME) revert InvalidOrder(4);
        if (triggerPriceE18 == 0) revert InvalidOrder(5);
    }

    function _crossed(Order storage o, uint256 price) private view returns (bool) {
        return o.triggerAbove ? price >= o.triggerPriceE18 : price <= o.triggerPriceE18;
    }

    function _expire(uint256 orderId, Order storage o) private {
        o.status = OrderStatus.EXPIRED;
        o.updatedAt = uint64(block.timestamp);
        _removeOpen(o.positionId, orderId);
        emit OrderExpired(orderId, o.positionId);
    }

    function _cancel(uint256 orderId, Order storage o, uint8 reason) private {
        o.status = OrderStatus.CANCELLED;
        o.updatedAt = uint64(block.timestamp);
        _removeOpen(o.positionId, orderId);
        emit OrderCancelled(orderId, o.positionId, reason);
    }

    function _cancelAllOpen(uint256 positionId, uint8 reason) private {
        uint256[] storage open = _openOrders[positionId];
        while (open.length != 0) {
            uint256 id = open[open.length - 1];
            _cancel(id, _orders[id], reason); // removes the last element
        }
    }

    function _removeOpen(uint256 positionId, uint256 orderId) private {
        uint256 slot = _openIndex[orderId];
        if (slot == 0) return;
        uint256[] storage open = _openOrders[positionId];
        uint256 last = open[open.length - 1];
        open[slot - 1] = last;
        _openIndex[last] = slot;
        open.pop();
        delete _openIndex[orderId];
    }
}
