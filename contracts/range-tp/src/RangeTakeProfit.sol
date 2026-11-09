// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IsolatedMarginTypes} from "@peridot/margin/IsolatedMarginTypes.sol";
import {IMarginOrderRegistry} from "@peridot/margin/orders/IMarginOrderRegistry.sol";
import {TickMath} from "./vendor/TickMath.sol";
import {FullMath} from "./vendor/FullMath.sol";
import {FixedPoint96} from "./vendor/FixedPoint96.sol";

/// @dev The three hooks the margin executor needs (PR #7 `rangeRelease` / `rangeReturn`; see src/engine/ for the patched copy).
interface IRangeExecutor {
    function positions(uint256 positionId) external view returns (IsolatedMarginTypes.Position memory);
    function rangeRelease(uint256 positionId, uint256 positionPTokens) external returns (uint256 collateralReleased);
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

/// @dev Pharaoh's position manager is `RamsesV3PositionManager` (the same code family as PR #7's Ramses): mint takes `tickSpacing`.
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
    function getReward(uint256, address[] calldata) external payable;
}

/// @title Range take-profit for a 2x WAVAX long on the Pharaoh WAVAX/USDC pool (port of PR #7's `RangeTakeProfit`, NVDA / Ramses).
/// @notice PROTOTYPE. FORK-TESTED, NOT DEPLOYED. The position's WAVAX collateral is placed into concentrated-liquidity bands
/// ("rungs") entirely above the market, split across the levels of an admin preset (the ladder preset splits 70 / 20 / 10 across
/// +1 % / +3 % / +5 %). As the market trades up through a rung its WAVAX becomes USDC; a fall back reverses that. Nothing is
/// final until a keeper `finalize`s: remove the converted rungs, collect, repay the current debt (with interest) through the
/// executor FIRST, and, when no rung remains, return the equity to the owner. The order is settled only after the repay returned.
///
/// Trust model = PR #7's: a custodian behind a transparent proxy whose admin is the timelock (presets, fee split, unwinders), and
/// the three engine hooks (executor `rangeRelease` / `rangeReturn`, risk engine `holdings` valuation at the ORACLE price, liquidator /
/// order adapter `unwind` before seizure / close). `finalize` is permissionless and pays the caller nothing; `unwind` is for the owner
/// (cancel), the liquidator and the order adapter only, reads no price and waits for nothing.
contract RangeTakeProfit is Initializable, ReentrancyGuardUpgradeable, IERC721Receiver {
    using SafeERC20 for IERC20;

    enum Status {
        NONE,
        ACTIVE,
        SETTLED,
        UNWOUND
    }

    uint256 internal constant BPS = 10_000;
    uint8 internal constant MAX_LEVELS = 3;

    /// @dev A preset is up to three levels; each level is a band `distanceTicks` above the current tick (near edge), `widthTicks` wide,
    /// carrying `weightBps` of the committed collateral. Weights sum to 10,000.
    struct Preset {
        bool enabled;
        uint8 levels;
        int24[3] distanceTicks;
        int24[3] widthTicks;
        uint16[3] weightBps;
    }

    struct Rung {
        Status status;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 tokenId;
        uint256 collateralCommitted;
        uint256 collateralIdle; // mint rounding left over, held here and returned with the rung
        uint256 quoteExpected; // USDC principal of the rung once fully converted (liquidity math)
    }

    struct Order {
        address owner;
        address account;
        Status status;
        uint8 preset;
        uint8 rungCount;
        uint16 userFeeBps;
        uint16 protocolFeeBps;
        uint16 reserveFeeBps;
        uint64 createdAt;
        uint256 entryPriceX96; // oracle price (USDC raw per WAVAX raw, Q96) at creation: the anchor of the slippage floor
        Rung[3] rungs;
    }

    // ------------------------------------------------------------------ storage (append-only, slot 0 onwards)
    IRangeExecutor public executor;
    IRangeRiskEngine public riskEngine;
    IRangeNfp public positionManager;
    IRangePool public pool;
    IRangeOracle public oracle;
    IRangeConfig public config;
    IMarginOrderRegistry public registry; // optional: TP exclusivity check; address(0) = none
    address public collateral; // WAVAX, token0 of the pool
    address public quote; // USDC, token1 of the pool
    int24 public tickSpacing;
    address public admin;
    address public liquidator;
    address public orderAdapter;
    uint16 public userFeeBps;
    uint16 public protocolFeeBps;
    uint16 public reserveFeeBps;
    address public protocolRecipient;
    address public reserveRecipient;
    mapping(uint8 => Preset) internal _presets;
    mapping(uint256 => Order) internal _orders;
    mapping(address => uint256) public positionOfAccount;
    /// @notice Orders currently active. The risk engine refuses to drop this custodian while any exist.
    uint256 public activeOrders;
    address[] internal _rewardTokens; // PHAR, xPHAR (the tokens the position manager's `getReward` pays)
    address public xPhar;
    /// @notice Rewards the custodian could not forward (xPHAR is transfer-restricted): claimable by the order owner.
    mapping(address => mapping(address => uint256)) public rewardClaimable;
    uint256[28] private __gap;

    struct InitParams {
        address executor;
        address riskEngine;
        address positionManager;
        address pool;
        address oracle;
        address config;
        address registry;
        address collateral;
        address quote;
        address admin;
        address[] rewardTokens;
        address xPhar;
    }

    event PresetSet(uint8 indexed id, bool enabled, uint8 levels);
    event FeeSplitSet(uint16 userBps, uint16 protocolBps, uint16 reserveBps, address protocolRecipient, address reserveRecipient);
    event UnwindersSet(address liquidator, address orderAdapter);
    event RangeOrderCreated(
        uint256 indexed positionId,
        address indexed owner,
        uint8 preset,
        uint8 rungCount,
        uint256 collateralCommitted,
        uint16 userFeeBps,
        uint16 protocolFeeBps,
        uint16 reserveFeeBps
    );
    event RungPlaced(
        uint256 indexed positionId, uint8 indexed rung, int24 tickLower, int24 tickUpper, uint256 collateralCommitted, uint128 liquidity, uint256 tokenId
    );
    event RungRemoved(
        uint256 indexed positionId, uint8 indexed rung, uint256 collateralOut, uint256 quoteOut, uint256 collateralFees, uint256 quoteFees
    );
    event RangeOrderSettled(uint256 indexed positionId, uint256 repaid, uint256 remainingDebt, bool positionClosed);
    event RangeOrderUnwound(uint256 indexed positionId, address indexed by, uint256 repaid);
    event FeeShareKept(address indexed token, address indexed to, uint256 amount);
    event RewardForwarded(uint256 indexed positionId, address indexed token, address indexed to, uint256 amount, bool claimable);
    event RewardClaimed(address indexed owner, address indexed token, address indexed to, uint256 amount);

    error NotAdmin();
    error NotOwner();
    error NotAuthorized();
    error InvalidPreset();
    error InvalidFeeSplit();
    error PositionNotEligible(uint8 code); // 1 inactive, 2 not long, 3 wrong markets, 4 order already active, 5 open take-profit
    error OracleUnavailable();
    error PoolOracleDeviation(uint256 poolPriceX96, uint256 oraclePriceX96);
    error BandNotFullyConverted();
    error SlippageFloor(uint8 rung, uint256 quoteGot, uint256 quoteMin);
    error RangeTooSmall(uint8 rung);
    error WouldBeLiquidatable();
    error NoActiveOrder();
    error NotWired();
    error NothingClaimable();

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata a) external initializer {
        __ReentrancyGuard_init();
        require(
            a.executor.code.length != 0 && a.riskEngine.code.length != 0 && a.positionManager.code.length != 0
                && a.oracle.code.length != 0 && a.config.code.length != 0 && a.admin != address(0),
            "RANGE_CONFIG"
        );
        executor = IRangeExecutor(a.executor);
        riskEngine = IRangeRiskEngine(a.riskEngine);
        positionManager = IRangeNfp(a.positionManager);
        pool = IRangePool(a.pool);
        oracle = IRangeOracle(a.oracle);
        config = IRangeConfig(a.config);
        registry = IMarginOrderRegistry(a.registry);
        collateral = a.collateral;
        quote = a.quote;
        // Pharaoh difference: the long's stock (WAVAX) must be token0, so every band sits ABOVE the tick and holds only token0.
        require(IRangePool(a.pool).token0() == a.collateral && IRangePool(a.pool).token1() == a.quote, "RANGE_POOL");
        tickSpacing = IRangePool(a.pool).tickSpacing();
        admin = a.admin;
        userFeeBps = uint16(BPS);
        for (uint256 i; i < a.rewardTokens.length; ++i) {
            _rewardTokens.push(a.rewardTokens[i]);
        }
        xPhar = a.xPhar;
        // The ported table: 1, 2, 3 = single level at +1 %, +3 %, +5 % (100 / 300 / 490 ticks, 200 wide); 4 = the 70 / 20 / 10 ladder.
        _setPreset(1, true, 1, [int24(100), 0, 0], [int24(200), 0, 0], [uint16(10_000), 0, 0]);
        _setPreset(2, true, 1, [int24(300), 0, 0], [int24(200), 0, 0], [uint16(10_000), 0, 0]);
        _setPreset(3, true, 1, [int24(490), 0, 0], [int24(200), 0, 0], [uint16(10_000), 0, 0]);
        _setPreset(4, true, 3, [int24(100), 300, 490], [int24(200), 200, 200], [uint16(7_000), 2_000, 1_000]);
    }

    // ------------------------------------------------------------------ admin
    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function setPreset(
        uint8 id,
        bool enabled,
        uint8 levels,
        int24[3] calldata distanceTicks,
        int24[3] calldata widthTicks,
        uint16[3] calldata weightBps
    ) external onlyAdmin {
        _setPreset(id, enabled, levels, distanceTicks, widthTicks, weightBps);
    }

    function _setPreset(
        uint8 id,
        bool enabled,
        uint8 levels,
        int24[3] memory distanceTicks,
        int24[3] memory widthTicks,
        uint16[3] memory weightBps
    ) private {
        if (enabled) {
            if (levels == 0 || levels > MAX_LEVELS) revert InvalidPreset();
            uint256 sum;
            for (uint256 i; i < levels; ++i) {
                if (
                    distanceTicks[i] <= 0 || widthTicks[i] <= 0 || distanceTicks[i] % tickSpacing != 0
                        || widthTicks[i] % tickSpacing != 0 || weightBps[i] == 0
                ) revert InvalidPreset();
                sum += weightBps[i];
            }
            if (sum != BPS) revert InvalidPreset();
        }
        _presets[id] = Preset(enabled, levels, distanceTicks, widthTicks, weightBps);
        emit PresetSet(id, enabled, levels);
    }

    /// @notice Fee split of the swap fees a band earns (collected minus principal). Snapshotted into each order at creation.
    function setFeeSplit(uint16 userBps, uint16 protocolBps, uint16 reserveBps, address protocolTo, address reserveTo)
        external
        onlyAdmin
    {
        if (uint256(userBps) + protocolBps + reserveBps != BPS) revert InvalidFeeSplit();
        if ((protocolBps != 0 && protocolTo == address(0)) || (reserveBps != 0 && reserveTo == address(0))) {
            revert InvalidFeeSplit();
        }
        (userFeeBps, protocolFeeBps, reserveFeeBps, protocolRecipient, reserveRecipient) =
            (userBps, protocolBps, reserveBps, protocolTo, reserveTo);
        emit FeeSplitSet(userBps, protocolBps, reserveBps, protocolTo, reserveTo);
    }

    function setUnwinders(address liquidator_, address orderAdapter_) external onlyAdmin {
        (liquidator, orderAdapter) = (liquidator_, orderAdapter_);
        emit UnwindersSet(liquidator_, orderAdapter_);
    }

    // ------------------------------------------------------------------ owner: create
    /// @param positionPTokens how much of the position's WAVAX collateral (in pWAVAX) to commit; 0 = all.
    function createRangeOrder(uint256 positionId, uint8 presetId, uint256 positionPTokens)
        external
        nonReentrant
        returns (uint256 collateralCommitted)
    {
        IsolatedMarginTypes.Position memory p = executor.positions(positionId);
        if (riskEngine.rangeCustodian() != address(this)) revert NotWired(); // bands must be counted before any is placed
        if (msg.sender != p.owner) revert NotOwner();
        if (p.status != IsolatedMarginTypes.Status.ACTIVE) revert PositionNotEligible(1);
        if (p.side != IsolatedMarginTypes.Side.LONG) revert PositionNotEligible(2);
        if (IRangeMarket(p.positionPToken).underlying() != collateral || IRangeMarket(p.debtPToken).underlying() != quote) {
            revert PositionNotEligible(3);
        }
        if (_orders[positionId].status == Status.ACTIVE) revert PositionNotEligible(4);
        _requireNoOpenTakeProfit(positionId);
        Preset memory preset = _presets[presetId];
        if (!preset.enabled) revert InvalidPreset();

        (uint160 spot, uint160 ref) = _checkPoolAgainstOracle(p);

        Order storage o = _orders[positionId];
        delete _orders[positionId];
        o.owner = p.owner;
        o.account = p.account;
        o.status = Status.ACTIVE;
        o.preset = presetId;
        o.rungCount = preset.levels;
        o.userFeeBps = userFeeBps;
        o.protocolFeeBps = protocolFeeBps;
        o.reserveFeeBps = reserveFeeBps;
        o.createdAt = uint64(block.timestamp);
        o.entryPriceX96 = Math.mulDiv(ref, ref, 1 << 96);
        positionOfAccount[p.account] = positionId;
        ++activeOrders;

        collateralCommitted = executor.rangeRelease(positionId, positionPTokens);
        int24 tick = TickMath.getTickAtSqrtPrice(spot);
        uint256 remaining = collateralCommitted;
        for (uint8 i; i < preset.levels; ++i) {
            // the last rung takes the remainder, so nothing is left over from the split
            uint256 amount = i + 1 == preset.levels ? remaining : Math.mulDiv(collateralCommitted, preset.weightBps[i], BPS);
            remaining -= amount;
            _place(positionId, o, i, tick, preset.distanceTicks[i], preset.widthTicks[i], amount);
        }
        // The bands are valued at the oracle; committing them must not by itself make the position liquidatable.
        if (riskEngine.isLiquidatable(p.account)) revert WouldBeLiquidatable();
        emit RangeOrderCreated(
            positionId, p.owner, presetId, preset.levels, collateralCommitted, o.userFeeBps, o.protocolFeeBps, o.reserveFeeBps
        );
    }

    function _place(uint256 positionId, Order storage o, uint8 i, int24 tick, int24 distance, int24 width, uint256 amount) private {
        // Snapped to the tick spacing AWAY from the market: the near edge is never closer than the preset's distance.
        int24 lower = _ceil(tick + distance);
        int24 upper = lower + width;
        require(lower >= TickMath.MIN_TICK && upper <= TickMath.MAX_TICK, "RANGE_TICKS");
        IERC20(collateral).forceApprove(address(positionManager), amount);
        (uint256 tokenId, uint128 l, uint256 a0, uint256 a1) = positionManager.mint(
            IRangeNfp.MintParams({
                token0: collateral,
                token1: quote,
                tickSpacing: tickSpacing,
                tickLower: lower,
                tickUpper: upper,
                amount0Desired: amount,
                amount1Desired: 0,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        IERC20(collateral).forceApprove(address(positionManager), 0);
        require(a1 == 0, "RANGE_NOT_SINGLE_SIDED");
        if (l == 0) revert RangeTooSmall(i);
        Rung storage r = o.rungs[i];
        r.status = Status.ACTIVE;
        r.tickLower = lower;
        r.tickUpper = upper;
        r.liquidity = l;
        r.tokenId = tokenId;
        r.collateralCommitted = amount;
        r.collateralIdle = amount - a0;
        r.quoteExpected = _amount1(TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(upper), l);
        emit RungPlaced(positionId, i, lower, upper, amount, l, tokenId);
    }

    // ------------------------------------------------------------------ keeper: finalise
    /// @notice Permissionless; pays the caller nothing. Finalises every rung the market has traded fully through: removes the
    /// liquidity, collects, checks the slippage floor, pays the fee shares, sends the proceeds to the position's account and repays
    /// the CURRENT debt (with accrued interest) through the executor. When no rung remains active the equity goes to the owner.
    /// Reverts with `BandNotFullyConverted` when no rung is fully converted (not reached, partly filled, or reversed).
    function finalize(uint256 positionId) external nonReentrant {
        Order storage o = _orders[positionId];
        if (o.status != Status.ACTIVE) revert NoActiveOrder();
        IsolatedMarginTypes.Position memory p = executor.positions(positionId);
        (, int24 tick,,,,,) = pool.slot0();
        // Fully converted: WAVAX is token0, so the tick is at or above the rung's upper tick.
        bool any;
        for (uint8 i; i < o.rungCount; ++i) {
            Rung storage r = o.rungs[i];
            if (r.status == Status.ACTIVE && tick >= r.tickUpper) {
                any = true;
                break;
            }
        }
        if (!any) revert BandNotFullyConverted();
        _checkPoolAgainstOracle(p);
        uint16 slip = config.getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken).maxSlippageBps;
        for (uint8 i; i < o.rungCount; ++i) {
            Rung storage r = o.rungs[i];
            if (r.status == Status.ACTIVE && tick >= r.tickUpper) {
                _removeRung(positionId, o, i, slip, true);
                r.status = Status.SETTLED;
            }
        }
        bool last = !_hasActiveRung(o);
        (uint256 repaid, uint256 remaining, bool closed) = executor.rangeReturn(positionId, last);
        if (last) {
            o.status = Status.SETTLED;
            delete positionOfAccount[o.account];
            --activeOrders;
        }
        emit RangeOrderSettled(positionId, repaid, remaining, closed);
    }

    // ------------------------------------------------------------------ risk paths: unwind
    /// @notice Removes every active rung and returns everything to the position: WAVAX back to collateral, USDC to the debt. Reads no
    /// price and has no floor (a risk path must never be blockable). Callable by the position owner (cancel), the liquidator (before
    /// seizure) and the order adapter (before a stop-loss close). Returns false, doing nothing, when no order is active.
    function unwind(uint256 positionId) external nonReentrant returns (bool unwound) {
        Order storage o = _orders[positionId];
        if (o.status != Status.ACTIVE) return false;
        if (msg.sender != liquidator && msg.sender != orderAdapter && msg.sender != o.owner) revert NotAuthorized();
        for (uint8 i; i < o.rungCount; ++i) {
            if (o.rungs[i].status == Status.ACTIVE) {
                _removeRung(positionId, o, i, 0, false);
                o.rungs[i].status = Status.UNWOUND;
            }
        }
        (uint256 repaid,,) = executor.rangeReturn(positionId, false);
        o.status = Status.UNWOUND;
        delete positionOfAccount[o.account];
        --activeOrders;
        emit RangeOrderUnwound(positionId, msg.sender, repaid);
        return true;
    }

    // ------------------------------------------------------------------ rewards the custodian could not forward
    /// @notice Claims the owner's stuck rewards (a transfer-restricted xPHAR share is recorded here, not sent). `to` should be a
    /// wallet xPHAR may be sent to; the exit to PHAR is then done there, by the holder.
    function claimRewards(address token, address to) external nonReentrant {
        uint256 amount = rewardClaimable[msg.sender][token];
        if (amount == 0) revert NothingClaimable();
        rewardClaimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(to, amount);
        emit RewardClaimed(msg.sender, token, to, amount);
    }

    // ------------------------------------------------------------------ views
    /// @notice The bands' holdings at the ORACLE price, for the risk engine: (WAVAX, USDC). Reverts when the oracle has no price,
    /// exactly as the risk engine's own valuation does.
    function holdings(address account) external view returns (uint256 collateralAmount, uint256 quoteAmount) {
        uint256 positionId = positionOfAccount[account];
        if (positionId == 0) return (0, 0);
        Order storage o = _orders[positionId];
        if (o.status != Status.ACTIVE) return (0, 0);
        uint160 ref = _oracleSqrtPriceX96();
        for (uint8 i; i < o.rungCount; ++i) {
            Rung storage r = o.rungs[i];
            if (r.status != Status.ACTIVE) continue;
            (uint256 a0, uint256 a1) =
                _amounts(ref, TickMath.getSqrtPriceAtTick(r.tickLower), TickMath.getSqrtPriceAtTick(r.tickUpper), r.liquidity);
            collateralAmount += a0 + r.collateralIdle;
            quoteAmount += a1;
        }
    }

    function getOrder(uint256 positionId) external view returns (Order memory) {
        return _orders[positionId];
    }

    function getPreset(uint8 id) external view returns (Preset memory) {
        return _presets[id];
    }

    /// @notice What a keeper needs in one call: the number of active rungs and how many of them the pool has fully crossed.
    function finalizable(uint256 positionId) external view returns (uint8 activeRungs, uint8 readyRungs) {
        Order storage o = _orders[positionId];
        if (o.status != Status.ACTIVE) return (0, 0);
        (, int24 tick,,,,,) = pool.slot0();
        for (uint8 i; i < o.rungCount; ++i) {
            Rung storage r = o.rungs[i];
            if (r.status != Status.ACTIVE) continue;
            ++activeRungs;
            if (tick >= r.tickUpper) ++readyRungs;
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    // ------------------------------------------------------------------ internals
    function _hasActiveRung(Order storage o) private view returns (bool) {
        for (uint8 i; i < o.rungCount; ++i) {
            if (o.rungs[i].status == Status.ACTIVE) return true;
        }
        return false;
    }

    function _requireNoOpenTakeProfit(uint256 positionId) private view {
        if (address(registry) == address(0)) return;
        uint256[] memory open = registry.openOrdersOf(positionId);
        for (uint256 i; i < open.length; ++i) {
            if (registry.getOrder(open[i]).kind == IMarginOrderRegistry.OrderKind.TAKE_PROFIT) {
                revert PositionNotEligible(5);
            }
        }
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

    struct Removal {
        uint256 p0;
        uint256 p1;
        uint256 c0;
        uint256 c1;
    }

    /// @dev Removes one rung and sends its proceeds (net of the protocol and reserve fee shares) to the position's account.
    /// `slip` and `enforceFloor` apply to finalisation only; the risk path (`unwind`) has no floor.
    function _removeRung(uint256 positionId, Order storage o, uint8 idx, uint16 slip, bool enforceFloor) private {
        Rung storage r = o.rungs[idx];
        uint256 tokenId = r.tokenId;
        // Rewards: the removal is itself a position change for the gauge. Claim first; every reward step is non-blocking.
        uint256[] memory before = _rewardBalances();
        try positionManager.getReward(tokenId, _rewardTokens) {} catch {}
        Removal memory x;
        (x.p0, x.p1) = positionManager.decreaseLiquidity(IRangeNfp.DecreaseLiquidityParams(tokenId, r.liquidity, 0, 0, block.timestamp));
        // the floor is checked on the principal alone, before anything else moves (a refusal reverts the whole finalisation)
        if (enforceFloor) _checkFloor(idx, o, r, x.p1, slip);
        (x.c0, x.c1) =
            positionManager.collect(IRangeNfp.CollectParams(tokenId, address(this), type(uint128).max, type(uint128).max));
        positionManager.burn(tokenId);
        // Swap fees (collected minus principal) are split; the user's share stays in the proceeds.
        uint256 collateralOut = x.c0 - _payFeeShares(o, collateral, x.c0 - x.p0);
        uint256 quoteOut = x.c1 - _payFeeShares(o, quote, x.c1 - x.p1);
        collateralOut += r.collateralIdle;
        emit RungRemoved(positionId, idx, collateralOut, quoteOut, x.c0 - x.p0, x.c1 - x.p1);
        r.collateralIdle = 0;
        r.liquidity = 0;
        if (collateralOut != 0) IERC20(collateral).safeTransfer(o.account, collateralOut);
        if (quoteOut != 0) IERC20(quote).safeTransfer(o.account, quoteOut);
        _forwardRewards(positionId, o.owner, before);
    }

    /// @dev The two anchors of the floor: the liquidity maths of a fully converted rung, and the oracle price at creation. Both at the
    /// pair's own `maxSlippageBps` (100). The principal of a rung the market crossed is deterministic; this refuses anything else.
    function _checkFloor(uint8 idx, Order storage o, Rung storage r, uint256 quoteGot, uint16 slip) private view {
        uint256 min1 = Math.mulDiv(r.quoteExpected, BPS - slip, BPS);
        uint256 min2 = Math.mulDiv(Math.mulDiv(r.collateralCommitted - r.collateralIdle, o.entryPriceX96, 1 << 96), BPS - slip, BPS);
        uint256 min = min1 > min2 ? min1 : min2;
        if (quoteGot < min) revert SlippageFloor(idx, quoteGot, min);
    }

    /// @dev Pays the protocol and reserve shares; the user's share stays in the proceeds. A transfer that fails (USDC can blacklist a
    /// recipient) must never block a risk path: the share then stays in the owner's proceeds and the event records it.
    function _payFeeShares(Order storage o, address token, uint256 fees) private returns (uint256 paid) {
        if (fees == 0) return 0;
        uint256 toProtocol = Math.mulDiv(fees, o.protocolFeeBps, BPS);
        uint256 toReserve = Math.mulDiv(fees, o.reserveFeeBps, BPS);
        if (toProtocol != 0 && _tryTransfer(token, protocolRecipient, toProtocol)) paid += toProtocol;
        if (toReserve != 0 && _tryTransfer(token, reserveRecipient, toReserve)) paid += toReserve;
    }

    function _tryTransfer(address token, address to, uint256 amount) private returns (bool ok) {
        if (to == address(0)) {
            emit FeeShareKept(token, to, amount);
            return false;
        }
        bytes memory ret;
        (ok, ret) = token.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        ok = ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
        if (!ok) emit FeeShareKept(token, to, amount);
    }

    function _rewardBalances() private view returns (uint256[] memory b) {
        b = new uint256[](_rewardTokens.length);
        for (uint256 i; i < b.length; ++i) {
            b[i] = IERC20(_rewardTokens[i]).balanceOf(address(this));
        }
    }

    /// @dev Gauge rewards (PHAR, xPHAR) on a band accrue to the custodian as NFT owner (the position manager's auto-claim on the
    /// decrease, and the explicit claim above). They go to the order owner whole, not into the fee split. PHAR is transferred; the
    /// transfer-restricted xPHAR (or any transfer that fails) is recorded as claimable by the owner. This step never reverts.
    function _forwardRewards(uint256 positionId, address owner, uint256[] memory before) private {
        for (uint256 i; i < before.length; ++i) {
            address token = _rewardTokens[i];
            uint256 got = IERC20(token).balanceOf(address(this)) - before[i];
            if (got == 0) continue;
            bool sent;
            if (token != xPhar) {
                (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20.transfer, (owner, got)));
                sent = ok && (ret.length == 0 || (ret.length == 32 && abi.decode(ret, (bool))));
            }
            if (!sent) rewardClaimable[owner][token] += got;
            emit RewardForwarded(positionId, token, owner, got, !sent);
        }
    }

    function _oracleSqrtPriceX96() private view returns (uint160) {
        uint256 pc = oracle.getPrice(collateral);
        uint256 pq = oracle.getPrice(quote);
        if (pc == 0 || pq == 0) revert OracleUnavailable();
        // raw USDC per raw WAVAX = (price WAVAX / price USDC) x 10^(dec1 - dec0), as a Q192 ratio (both prices are USD at 18 decimals)
        (uint8 d0, uint8 d1) = (_decimals(collateral), _decimals(quote));
        uint256 num = pc;
        uint256 den = pq;
        if (d1 >= d0) num *= 10 ** (d1 - d0);
        else den *= 10 ** (d0 - d1);
        return uint160(Math.sqrt(Math.mulDiv(num, 1 << 192, den)));
    }

    /// @dev Returns the pool's spot sqrt price and the oracle's, after checking they are within the pair's oracle-deviation bound.
    function _checkPoolAgainstOracle(IsolatedMarginTypes.Position memory p) private view returns (uint160 spot, uint160 ref) {
        ref = _oracleSqrtPriceX96();
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
