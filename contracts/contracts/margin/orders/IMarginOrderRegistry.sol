// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Chain-agnostic take-profit / stop-loss order registry for isolated margin positions.
/// @notice One interface for every chain (Robinhood, Avalanche, and the Stellar port by analogy) so the frontend has one
/// component. The registry stores and authorizes orders; a chain-specific IMarginCloseAdapter closes through that chain's
/// existing margin close path. Spec: docs/margin-orders/SPEC.md.
///
/// Invariants every implementation must keep:
///  1. LIQUIDATION INDEPENDENCE: no order, no registry state and no adapter call can delay, block or front-run a liquidation.
///     The registry never holds the position, its margin or its debt, and liquidation never calls the registry.
///  2. MUTUAL CANCELLATION: a close through ANY path (an order, the owner closing directly, a liquidation) that leaves the
///     position inactive makes every remaining order on it unexecutable; `execute` then cancels instead of reverting.
///     Executing a full-size order cancels every other open order on the same position in the same transaction.
///  3. OWNER AUTHORIZATION: only the current position owner creates, modifies or cancels an order. Execution is
///     permissionless, but proceeds go only where the close path already sends them (the owner); the executor gets nothing.
///  4. BOUNDED EXECUTION: execution requires a fresh oracle price that crosses the trigger, enforces `maxSlippageBps`
///     against that oracle price, includes accrued interest (the close path accrues before repaying), and enforces expiry.
interface IMarginOrderRegistry {
    enum OrderKind {
        TAKE_PROFIT, // close when the price moves in the position's favour past the trigger
        STOP_LOSS // close when the price moves against the position past the trigger
    }

    enum OrderStatus {
        NONE,
        OPEN,
        EXECUTED,
        CANCELLED, // by the owner, by mutual cancellation, or because the position is no longer active
        EXPIRED
    }

    /// @dev Field names and units are shared across chains. Prices are USD with 18 decimals, as the margin oracles report.
    struct Order {
        uint256 positionId; // the margin engine's position id on this chain
        address owner; // position owner at creation; re-checked on every execution
        OrderKind kind;
        bool triggerAbove; // true: execute when oracle price >= triggerPriceE18; false: when <=
        uint256 triggerPriceE18; // stock price in USD, 18 decimals
        uint16 closeBps; // share of the position to close, 1..10_000; partial only where the close path supports it
        uint16 maxSlippageBps; // max execution shortfall against the oracle price at execution
        uint64 expiry; // unix seconds; 0 is not allowed (every order expires)
        uint64 createdAt;
        uint64 updatedAt;
        OrderStatus status;
    }

    event OrderCreated(uint256 indexed orderId, uint256 indexed positionId, address indexed owner, Order order);
    event OrderModified(uint256 indexed orderId, uint256 indexed positionId, Order order);
    event OrderCancelled(uint256 indexed orderId, uint256 indexed positionId, uint8 reason); // see CancelReason in the spec
    event OrderExpired(uint256 indexed orderId, uint256 indexed positionId);
    event OrderExecuted(
        uint256 indexed orderId,
        uint256 indexed positionId,
        address indexed executor,
        uint256 oraclePriceE18,
        uint16 closeBps,
        uint256 returnedMargin // in the close path's own unit (margin pTokens on Robinhood); 0 if not reported
    );

    error NotPositionOwner();
    error PositionNotActive();
    error InvalidOrder(uint8 code); // codes in the spec
    error OrderNotOpen();
    error TriggerNotReached(uint256 oraclePriceE18, uint256 triggerPriceE18);
    error OracleUnavailable(); // stale, paused or invalid price: the order waits, nothing is cancelled

    /// @notice Owner only. Reverts InvalidOrder if any field is out of range or the expiry is in the past.
    function createOrder(
        uint256 positionId,
        OrderKind kind,
        bool triggerAbove,
        uint256 triggerPriceE18,
        uint16 closeBps,
        uint16 maxSlippageBps,
        uint64 expiry
    ) external returns (uint256 orderId);

    /// @notice Owner only, open orders only. Replaces the price, size, slippage and expiry; kind and position are fixed.
    function modifyOrder(uint256 orderId, uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry) external;

    /// @notice Owner only, open orders only.
    function cancelOrder(uint256 orderId) external;

    /// @notice Permissionless. Closes `closeBps` of the position through the adapter if the order is open, unexpired, the
    /// position is active and still owned by `order.owner`, and a fresh oracle price crosses the trigger. An expired order
    /// becomes EXPIRED and an order on an inactive or transferred position becomes CANCELLED (no revert) so keepers can
    /// sweep. `adapterData` carries chain-specific swap routing; it can never move value away from the owner.
    function executeOrder(uint256 orderId, bytes calldata adapterData) external returns (bool executed);

    /// @notice Whether `executeOrder` would close right now, and the oracle price it would use. Never reverts.
    function canExecute(uint256 orderId) external view returns (bool executable, uint256 oraclePriceE18, uint8 reason);

    function getOrder(uint256 orderId) external view returns (Order memory);

    /// @notice Open orders on a position (bounded by MAX_ORDERS_PER_POSITION in the spec).
    function openOrdersOf(uint256 positionId) external view returns (uint256[] memory orderIds);

    function adapter() external view returns (IMarginCloseAdapter);
}

/// @title Chain-specific bridge from the registry to one chain's existing margin close path.
interface IMarginCloseAdapter {
    /// @dev Direction of the exposure, so the registry can check that TAKE_PROFIT and STOP_LOSS triggers sit on the
    /// correct side of the entry (long: TP above, SL below; short: the reverse).
    function positionOwner(uint256 positionId) external view returns (address);
    function isActive(uint256 positionId) external view returns (bool);
    function isLong(uint256 positionId) external view returns (bool);

    /// @notice Fresh oracle price of the position's stock in USD 1e18; `ok` false when stale, paused or invalid.
    function oraclePriceE18(uint256 positionId) external view returns (uint256 priceE18, bool ok);

    /// @notice Closes `closeBps` of the position for its owner through the chain's existing close path, with minimum outputs
    /// derived from `oraclePriceE18` and `maxSlippageBps`. Callable only by the registry. Proceeds follow the close path
    /// to the owner. Reverts if the close path does not support `closeBps` (for example a partial where only full closes
    /// exist) so the order stays open.
    function closeFor(
        uint256 positionId,
        address owner,
        uint16 closeBps,
        uint256 oraclePriceE18,
        uint16 maxSlippageBps,
        bytes calldata adapterData
    ) external returns (uint256 returnedMargin);
}
