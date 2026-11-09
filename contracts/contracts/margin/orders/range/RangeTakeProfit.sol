// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IsolatedMarginTypes} from "../../IsolatedMarginTypes.sol";
import {IMarginOrderRegistry} from "../IMarginOrderRegistry.sol";
import {TickMath} from "./vendor/TickMath.sol";
import {FullMath} from "./vendor/FullMath.sol";
import {FixedPoint96} from "./vendor/FixedPoint96.sol";

interface IRangeExecutor {
    function positions(uint256 positionId) external view returns (IsolatedMarginTypes.Position memory);
    function rangeRelease(uint256 positionId, uint256 positionPTokens) external returns (uint256 stockReleased);
    function rangeReturn(uint256 positionId, bool settle) external returns (uint256 repaid, uint256 remainingDebt, bool closed);
}

interface IRangeRiskEngine {
    function isLiquidatable(address account) external view returns (bool);
    function rangeCustodian() external view returns (address);
}

interface IRangeOracle {
    function getPrice(address asset) external view returns (uint256);
}

interface IRangeConfig {
    function getPairRisk(address marginPToken, address positionPToken, address debtPToken)
        external
        view
        returns (IsolatedMarginTypes.PairRiskConfig memory);
}

interface IRangeMarket {
    function underlying() external view returns (address);
}

interface IRangePool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint24, bool);
}

interface IRangeNfp {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
    function burn(uint256) external payable;
    function getReward(uint256, address[] calldata) external;
}

/// @dev The pair's in-kind loss reserve (StrategyLossReserve): `deposit` credits the pair; a plain transfer would not.
interface IRangeLossReserve {
    function deposit(bytes32 pairId, address token, uint256 amount) external returns (uint256 received);
}

interface IRangeGauge {
    function getRewardTokens() external view returns (address[] memory);
}

/// @title Range take-profit for a leveraged long. Behind an OZ 5 transparent proxy whose ProxyAdmin the timelock owns;
/// admin (presets, fee split, unwinders) = the timelock. Storage append-only: tools/orders/check_registry_layout.py
/// --target <this contract> against tools/orders/range-layout.json.
/// @notice The position's stock is placed into a concentrated-liquidity band entirely above the market. As the market
/// trades up through the band, swaps convert the stock to USDG; a fall back below reverses that. Nothing is final until a
/// keeper `finalize`s: remove the liquidity, collect fees, repay the current debt with accrued interest through the
/// executor, return the equity to the owner. Conversion is not repayment: the order becomes SETTLED only after the
/// executor's repay returns.
///
/// Rules this contract enforces:
///  * one order per position at a time; refused while the registry holds an open TAKE_PROFIT for the position;
///  * only admin presets (distance above the market and width, multiples of the pool tick spacing, distance > 0): a band
///    below the market cannot be placed, so it can never stand in for a stop-loss;
///  * placement needs the margin oracle's price (stale, paused or invalid refuses) and the pool within the pair's
///    oracle-deviation bound of it; finalisation checks the same;
///  * `unwind` removes the band and returns everything to the position (stock to collateral, USDG to the debt) with no
///    price read and no fee wait. The liquidator calls it before seizure, the order adapter before a stop-loss close,
///    the owner to cancel;
///  * the band is valued for the risk engine at the ORACLE price (`holdings`), never at the pool price;
///  * the fee split (user / protocol / reserve) is snapshotted into the order at opt-in and emitted.
contract RangeTakeProfit is Initializable, ReentrancyGuardUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;

    enum Status {
        NONE,
        ACTIVE,
        SETTLED,
        UNWOUND
    }

    struct Preset {
        bool enabled;
        int24 distanceTicks; // from the current tick to the near edge of the band, in the stock's favour
        int24 widthTicks;
    }

    struct Order {
        address owner;
        address account;
        Status status;
        uint8 preset;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokenId;
        uint256 stockCommitted;
        uint256 stockIdle; // mint rounding left over, held here and returned with the band
        uint16 userFeeBps;
        uint16 protocolFeeBps;
        uint16 reserveFeeBps;
        uint64 createdAt;
    }

    uint256 internal constant BPS = 10_000;

    // ------------------------------------------------------------------ storage (append-only, slot 0 onwards)
    IRangeExecutor public executor;
    IRangeRiskEngine public riskEngine;
    IRangeNfp public positionManager;
    IRangePool public pool;
    IRangeGauge public gauge;
    IRangeOracle public oracle;
    IRangeConfig public config;
    IMarginOrderRegistry public registry;
    address public stock;
    address public usdg;
    bool public stockIsToken0;
    int24 public tickSpacing;
    address public admin;

    address public liquidator;
    address public orderAdapter;
    uint16 public userFeeBps;
    uint16 public protocolFeeBps;
    uint16 public reserveFeeBps;
    address public protocolRecipient;
    address public reserveRecipient;
    mapping(uint8 => Preset) public presets;
    mapping(uint256 => Order) internal _orders;
    mapping(address => uint256) public positionOfAccount;
    /// @notice Bands currently placed. The risk engine refuses to drop this custodian while any exist.
    uint256 public activeOrders;
    /// @notice Appended: when set, the reserve share is deposited into `reserveRecipient` (the pair's loss reserve) for
    /// this pair id, so it is credited to the pair. Zero = plain transfer to `reserveRecipient`.
    bytes32 public reservePairId;
    uint256[29] private __gap;

    struct InitParams {
        address executor;
        address riskEngine;
        address positionManager;
        address pool;
        address gauge;
        address oracle;
        address config;
        address registry;
        address stock;
        address usdg;
        address admin;
    }

    event PresetSet(uint8 indexed id, bool enabled, int24 distanceTicks, int24 widthTicks);
    event FeeSplitSet(uint16 userBps, uint16 protocolBps, uint16 reserveBps, address protocolRecipient, address reserveRecipient);
    event UnwindersSet(address liquidator, address orderAdapter);
    event RangeOrderCreated(
        uint256 indexed positionId,
        address indexed owner,
        uint8 preset,
        int24 tickLower,
        int24 tickUpper,
        uint256 stockCommitted,
        uint128 liquidity,
        uint16 userFeeBps,
        uint16 protocolFeeBps,
        uint16 reserveFeeBps
    );
    event RangeLiquidityRemoved(
        uint256 indexed positionId, uint256 stockOut, uint256 usdgOut, uint256 stockFees, uint256 usdgFees
    );
    event RangeOrderSettled(uint256 indexed positionId, uint256 repaid, uint256 remainingDebt, bool positionClosed);
    event ReserveCredited(bytes32 indexed pairId, address indexed token, uint256 amount);
    event ReserveDepositFailed(bytes32 indexed pairId, address indexed token, uint256 amount);
    event RangeOrderUnwound(uint256 indexed positionId, address indexed by, uint256 repaid);

    error NotAdmin();
    error NotOwner();
    error NotAuthorized();
    error InvalidPreset();
    error InvalidFeeSplit();
    error PositionNotEligible(uint8 code); // 1 inactive, 2 not long, 3 wrong markets, 4 order already active, 5 open take-profit
    error OracleUnavailable();
    error PoolOracleDeviation(uint256 poolPriceX96, uint256 oraclePriceX96);
    error BandNotFullyConverted();
    error WouldBeLiquidatable();
    error NoActiveOrder();
    error NotWired();

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata a) external initializer {
        __ReentrancyGuard_init();
        require(a.executor.code.length != 0 && a.riskEngine.code.length != 0 && a.positionManager.code.length != 0
            && a.oracle.code.length != 0 && a.config.code.length != 0 && a.admin != address(0), "RANGE_CONFIG");
        executor = IRangeExecutor(a.executor);
        riskEngine = IRangeRiskEngine(a.riskEngine);
        positionManager = IRangeNfp(a.positionManager);
        pool = IRangePool(a.pool);
        gauge = IRangeGauge(a.gauge);
        oracle = IRangeOracle(a.oracle);
        config = IRangeConfig(a.config);
        registry = IMarginOrderRegistry(a.registry);
        stock = a.stock;
        usdg = a.usdg;
        address t0 = IRangePool(a.pool).token0();
        address t1 = IRangePool(a.pool).token1();
        require((t0 == a.stock && t1 == a.usdg) || (t1 == a.stock && t0 == a.usdg), "RANGE_POOL");
        stockIsToken0 = t0 == a.stock;
        tickSpacing = IRangePool(a.pool).tickSpacing();
        admin = a.admin;
        userFeeBps = uint16(BPS);
    }

    // ------------------------------------------------------------------ admin
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function setPreset(uint8 id, bool enabled, int24 distanceTicks, int24 widthTicks) external onlyAdmin {
        if (
            enabled
                && (distanceTicks <= 0 || widthTicks <= 0 || distanceTicks % tickSpacing != 0 || widthTicks % tickSpacing != 0)
        ) revert InvalidPreset();
        presets[id] = Preset(enabled, distanceTicks, widthTicks);
        emit PresetSet(id, enabled, distanceTicks, widthTicks);
    }

    /// @param reserveTo the reserve share's destination; with `reservePairId_` set, a loss reserve credited via deposit.
    function setFeeSplit(
        uint16 userBps,
        uint16 protocolBps,
        uint16 reserveBps,
        address protocolTo,
        address reserveTo,
        bytes32 reservePairId_
    ) external onlyAdmin {
        if (uint256(userBps) + protocolBps + reserveBps != BPS) revert InvalidFeeSplit();
        if ((protocolBps != 0 && protocolTo == address(0)) || (reserveBps != 0 && reserveTo == address(0))) {
            revert InvalidFeeSplit();
        }
        if (reservePairId_ != bytes32(0) && reserveTo.code.length == 0) revert InvalidFeeSplit();
        (userFeeBps, protocolFeeBps, reserveFeeBps, protocolRecipient, reserveRecipient) =
            (userBps, protocolBps, reserveBps, protocolTo, reserveTo);
        reservePairId = reservePairId_;
        emit FeeSplitSet(userBps, protocolBps, reserveBps, protocolTo, reserveTo);
    }

    function setUnwinders(address liquidator_, address orderAdapter_) external onlyAdmin {
        (liquidator, orderAdapter) = (liquidator_, orderAdapter_);
        emit UnwindersSet(liquidator_, orderAdapter_);
    }

    // ------------------------------------------------------------------ owner: create
    /// @param positionPTokens how much of the position's stock collateral (in position pTokens) to commit; 0 = all.
    function createRangeOrder(uint256 positionId, uint8 presetId, uint256 positionPTokens)
        external
        nonReentrant
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        IsolatedMarginTypes.Position memory p = executor.positions(positionId);
        if (riskEngine.rangeCustodian() != address(this)) revert NotWired(); // bands must be counted before any is placed
        if (msg.sender != p.owner) revert NotOwner();
        if (p.status != IsolatedMarginTypes.Status.ACTIVE) revert PositionNotEligible(1);
        if (p.side != IsolatedMarginTypes.Side.LONG) revert PositionNotEligible(2);
        if (IRangeMarket(p.positionPToken).underlying() != stock || IRangeMarket(p.debtPToken).underlying() != usdg) {
            revert PositionNotEligible(3);
        }
        if (_orders[positionId].status == Status.ACTIVE) revert PositionNotEligible(4);
        _requireNoOpenTakeProfit(positionId);
        Preset memory preset = presets[presetId];
        if (!preset.enabled) revert InvalidPreset();

        uint160 spot = _checkPoolAgainstOracle(p);
        (tickLower, tickUpper) = _band(spot, preset);

        Order storage o = _orders[positionId];
        delete _orders[positionId];
        o.owner = p.owner;
        o.account = p.account;
        o.status = Status.ACTIVE;
        o.preset = presetId;
        o.tickLower = tickLower;
        o.tickUpper = tickUpper;
        o.userFeeBps = userFeeBps;
        o.protocolFeeBps = protocolFeeBps;
        o.reserveFeeBps = reserveFeeBps;
        o.createdAt = uint64(block.timestamp);
        positionOfAccount[p.account] = positionId;
        ++activeOrders;

        uint256 released = executor.rangeRelease(positionId, positionPTokens);
        o.stockCommitted = released;
        IERC20(stock).forceApprove(address(positionManager), released);
        (uint256 tokenId, uint128 l, uint256 a0, uint256 a1) = positionManager.mint(
            IRangeNfp.MintParams({
                token0: pool.token0(),
                token1: pool.token1(),
                tickSpacing: tickSpacing,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: stockIsToken0 ? released : 0,
                amount1Desired: stockIsToken0 ? 0 : released,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        IERC20(stock).forceApprove(address(positionManager), 0);
        uint256 used = stockIsToken0 ? a0 : a1;
        require((stockIsToken0 ? a1 : a0) == 0, "RANGE_NOT_SINGLE_SIDED");
        o.tokenId = tokenId;
        o.liquidity = l;
        o.stockIdle = released - used;
        liquidity = l;
        // The band is valued at the oracle; committing it must not by itself make the position liquidatable.
        if (riskEngine.isLiquidatable(p.account)) revert WouldBeLiquidatable();
        emit RangeOrderCreated(
            positionId, p.owner, presetId, tickLower, tickUpper, released, l, o.userFeeBps, o.protocolFeeBps, o.reserveFeeBps
        );
    }

    // ------------------------------------------------------------------ keeper: finalise
    /// @notice Permissionless once the market has traded through the whole band. Removes the liquidity, claims fees and
    /// rewards, repays the current debt with accrued interest through the executor and, if the debt is gone, returns the
    /// equity to the owner. The order is SETTLED only after the executor's repay succeeded.
    function finalize(uint256 positionId) external nonReentrant {
        Order storage o = _orders[positionId];
        if (o.status != Status.ACTIVE) revert NoActiveOrder();
        IsolatedMarginTypes.Position memory p = executor.positions(positionId);
        (, int24 tick,,,,,) = pool.slot0();
        // Fully converted: the stock is token0 and the tick is at or above the band, or token1 and at or below it.
        if (stockIsToken0 ? tick < o.tickUpper : tick >= o.tickLower) revert BandNotFullyConverted();
        _checkPoolAgainstOracle(p);
        _removeToAccount(positionId, o);
        (uint256 repaid, uint256 remaining, bool closed) = executor.rangeReturn(positionId, true);
        o.status = Status.SETTLED;
        delete positionOfAccount[o.account];
        --activeOrders;
        emit RangeOrderSettled(positionId, repaid, remaining, closed);
    }

    // ------------------------------------------------------------------ risk paths: unwind
    /// @notice Removes an active band and returns everything to the position: stock back to collateral, USDG to the debt.
    /// Reads no price and waits for nothing. Callable by the position owner (cancel), the liquidator (before seizure) and
    /// the order adapter (before a stop-loss close). Returns false, doing nothing, when no band is active.
    function unwind(uint256 positionId) external nonReentrant returns (bool unwound) {
        Order storage o = _orders[positionId];
        if (o.status != Status.ACTIVE) return false;
        if (msg.sender != liquidator && msg.sender != orderAdapter && msg.sender != o.owner) revert NotAuthorized();
        _removeToAccount(positionId, o);
        (uint256 repaid,,) = executor.rangeReturn(positionId, false);
        o.status = Status.UNWOUND;
        delete positionOfAccount[o.account];
        --activeOrders;
        emit RangeOrderUnwound(positionId, msg.sender, repaid);
        return true;
    }

    // ------------------------------------------------------------------ views
    /// @notice The band's holdings at the ORACLE price, for the risk engine: (stock, USDG). Reverts when the oracle has no
    /// price, exactly as the risk engine's own valuation does.
    function holdings(address account) external view returns (uint256 stockAmount, uint256 usdgAmount) {
        uint256 positionId = positionOfAccount[account];
        if (positionId == 0) return (0, 0);
        Order storage o = _orders[positionId];
        if (o.status != Status.ACTIVE) return (0, 0);
        uint160 ref = _oracleSqrtPriceX96();
        (uint256 a0, uint256 a1) =
            _amounts(ref, TickMath.getSqrtPriceAtTick(o.tickLower), TickMath.getSqrtPriceAtTick(o.tickUpper), o.liquidity);
        (stockAmount, usdgAmount) = stockIsToken0 ? (a0, a1) : (a1, a0);
        stockAmount += o.stockIdle;
    }

    function getOrder(uint256 positionId) external view returns (Order memory) {
        return _orders[positionId];
    }

    function isActive(uint256 positionId) external view returns (bool) {
        return _orders[positionId].status == Status.ACTIVE;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ internals
    function _requireNoOpenTakeProfit(uint256 positionId) private view {
        if (address(registry) == address(0)) return;
        uint256[] memory open = registry.openOrdersOf(positionId);
        for (uint256 i; i < open.length; ++i) {
            if (registry.getOrder(open[i]).kind == IMarginOrderRegistry.OrderKind.TAKE_PROFIT) {
                revert PositionNotEligible(5);
            }
        }
    }

    /// @dev Band strictly on the stock's favourable side of the current tick, aligned to the tick spacing.
    function _band(uint160 spot, Preset memory preset) private view returns (int24 lower, int24 upper) {
        int24 tick = TickMath.getTickAtSqrtPrice(spot);
        // Snapped to the tick spacing AWAY from the market: the near edge is never closer than the preset's distance.
        if (stockIsToken0) {
            // stock price up = tick up: the band sits above the tick and holds only token0
            lower = _ceil(tick + preset.distanceTicks);
            upper = lower + preset.widthTicks;
        } else {
            // stock price up = tick down: the band sits below the tick and holds only token1
            upper = _floor(tick - preset.distanceTicks);
            lower = upper - preset.widthTicks;
        }
        require(lower >= TickMath.MIN_TICK && upper <= TickMath.MAX_TICK, "RANGE_TICKS");
    }

    function _floor(int24 t) private view returns (int24) {
        int24 r = t / tickSpacing * tickSpacing;
        if (t < 0 && r != t) r -= tickSpacing;
        return r;
    }

    function _ceil(int24 t) private view returns (int24) {
        int24 f = _floor(t);
        return f == t ? t : f + tickSpacing;
    }

    function _removeToAccount(uint256 positionId, Order storage o) private {
        uint256 tokenId = o.tokenId;
        // Rewards first: the removal is itself a position change for the gauge.
        (uint256 rewardStock, uint256 rewardUsdg) = _claimRewards(o, tokenId);
        (uint256 p0, uint256 p1) = positionManager.decreaseLiquidity(
            IRangeNfp.DecreaseLiquidityParams(tokenId, o.liquidity, 0, 0, block.timestamp)
        );
        (uint256 c0, uint256 c1) =
            positionManager.collect(IRangeNfp.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max));
        positionManager.burn(tokenId);
        (uint256 stockOut, uint256 usdgOut, uint256 stockPrincipal, uint256 usdgPrincipal) =
            stockIsToken0 ? (c0, c1, p0, p1) : (c1, c0, p1, p0);
        // Swap fees (collected minus principal) are split; rewards paid in the pool's own tokens go to the owner whole.
        uint256 stockFees = stockOut - stockPrincipal;
        uint256 usdgFees = usdgOut - usdgPrincipal;
        stockOut += rewardStock;
        usdgOut += rewardUsdg;
        stockOut -= _payFeeShares(o, stock, stockFees);
        usdgOut -= _payFeeShares(o, usdg, usdgFees);
        stockOut += o.stockIdle;
        o.stockIdle = 0;
        o.liquidity = 0;
        if (stockOut != 0) IERC20(stock).safeTransfer(o.account, stockOut);
        if (usdgOut != 0) IERC20(usdg).safeTransfer(o.account, usdgOut);
        emit RangeLiquidityRemoved(positionId, stockOut, usdgOut, stockFees, usdgFees);
    }

    /// @dev Pays the protocol and reserve shares; the user's share stays in the proceeds. Returns what was paid out.
    function _payFeeShares(Order storage o, address token, uint256 fees) private returns (uint256 paid) {
        if (fees == 0) return 0;
        uint256 toProtocol = Math.mulDiv(fees, o.protocolFeeBps, BPS);
        uint256 toReserve = Math.mulDiv(fees, o.reserveFeeBps, BPS);
        if (toProtocol != 0) IERC20(token).safeTransfer(protocolRecipient, toProtocol);
        if (toReserve != 0) toReserve = _toReserve(o, token, toReserve);
        return toProtocol + toReserve;
    }

    /// @dev Credits the pair's loss reserve through `deposit`. A failing deposit must never block a risk path (unwind,
    /// liquidation, stop-loss): the share then stays in the owner's proceeds and the event records it. Returns what left.
    function _toReserve(Order storage, address token, uint256 amount) private returns (uint256) {
        address to = reserveRecipient;
        bytes32 pairId = reservePairId;
        if (pairId == bytes32(0)) {
            IERC20(token).safeTransfer(to, amount);
            return amount;
        }
        IERC20(token).forceApprove(to, amount);
        try IRangeLossReserve(to).deposit(pairId, token, amount) returns (uint256 received) {
            IERC20(token).forceApprove(to, 0);
            emit ReserveCredited(pairId, token, received);
            return amount;
        } catch {
            IERC20(token).forceApprove(to, 0);
            emit ReserveDepositFailed(pairId, token, amount);
            return 0;
        }
    }

    /// @dev Gauge rewards (RAM) on an active band accrue to the order owner and are paid out whole when the band is removed
    /// (operator decision 2026-11-07: not part of the fee split). Rewards paid in the pool's own tokens join the proceeds.
    /// A failing claim never blocks the removal.
    function _claimRewards(Order storage o, uint256 tokenId) private returns (uint256 rewardStock, uint256 rewardUsdg) {
        if (address(gauge) == address(0)) return (0, 0);
        address[] memory tokens = gauge.getRewardTokens();
        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) before[i] = IERC20(tokens[i]).balanceOf(address(this));
        try positionManager.getReward(tokenId, tokens) {} catch {
            return (0, 0);
        }
        for (uint256 i; i < tokens.length; ++i) {
            uint256 got = IERC20(tokens[i]).balanceOf(address(this)) - before[i];
            if (got == 0) continue;
            if (tokens[i] == stock) {
                rewardStock = got; // joins the proceeds, split with the fees
                continue;
            }
            if (tokens[i] == usdg) {
                rewardUsdg = got;
                continue;
            }
            IERC20(tokens[i]).safeTransfer(o.owner, got);
        }
    }

    function _oracleSqrtPriceX96() private view returns (uint160) {
        uint256 ps = oracle.getPrice(stock);
        uint256 pu = oracle.getPrice(usdg);
        if (ps == 0 || pu == 0) revert OracleUnavailable();
        // raw token1 per raw token0 = (price0 / price1) x 10^(dec1 - dec0), as a Q192 ratio
        (uint256 p0, uint256 p1) = stockIsToken0 ? (ps, pu) : (pu, ps);
        (uint8 d0, uint8 d1) = (_decimals(pool.token0()), _decimals(pool.token1()));
        uint256 num = p0;
        uint256 den = p1;
        if (d1 >= d0) num *= 10 ** (d1 - d0);
        else den *= 10 ** (d0 - d1);
        return uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
    }

    /// @dev Returns the pool's spot sqrt price after checking it is within the pair's oracle-deviation bound.
    function _checkPoolAgainstOracle(IsolatedMarginTypes.Position memory p) private view returns (uint160 spot) {
        uint160 ref = _oracleSqrtPriceX96();
        (spot,,,,,,) = pool.slot0();
        uint256 poolPrice = Math.mulDiv(spot, spot, 1 << 96);
        uint256 refPrice = Math.mulDiv(ref, ref, 1 << 96);
        uint16 dev = config.getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken).oracleDeviationBps;
        uint256 diff = poolPrice > refPrice ? poolPrice - refPrice : refPrice - poolPrice;
        if (diff * BPS > uint256(dev) * refPrice) revert PoolOracleDeviation(poolPrice, refPrice);
    }

    /// @dev Token amounts of `liquidity` between sqrt prices a < b at price p (the standard concentrated-liquidity formulas).
    function _amounts(uint160 p, uint160 a, uint160 b, uint128 liquidity) private pure returns (uint256 a0, uint256 a1) {
        if (p <= a) {
            a0 = _amount0(a, b, liquidity);
        } else if (p < b) {
            a0 = _amount0(p, b, liquidity);
            a1 = _amount1(a, p, liquidity);
        } else {
            a1 = _amount1(a, b, liquidity);
        }
    }

    function _amount0(uint160 a, uint160 b, uint128 liquidity) private pure returns (uint256) {
        return FullMath.mulDiv(uint256(liquidity) << FixedPoint96.RESOLUTION, b - a, b) / a;
    }

    function _amount1(uint160 a, uint160 b, uint128 liquidity) private pure returns (uint256) {
        return FullMath.mulDiv(liquidity, b - a, FixedPoint96.Q96);
    }

    function _decimals(address token) private view returns (uint8) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok && r.length == 32, "RANGE_DECIMALS");
        return abi.decode(r, (uint8));
    }
}
