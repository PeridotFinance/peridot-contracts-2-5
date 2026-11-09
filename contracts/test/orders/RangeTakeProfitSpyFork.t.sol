// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {RangeTakeProfit} from "../../contracts/margin/orders/range/RangeTakeProfit.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TickMath} from "../../contracts/margin/orders/range/vendor/TickMath.sol";

interface ISpyPool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint24, bool);
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
    function tickSpacing() external view returns (int24);
}

contract SpyTrader {
    ISpyPool immutable pool;
    IERC20 immutable t0;
    IERC20 immutable t1;

    constructor(ISpyPool p, IERC20 a, IERC20 b) {
        (pool, t0, t1) = (p, a, b);
    }

    function moveTo(uint160 limit) external {
        (uint160 spot,,,,,,) = pool.slot0();
        if (spot == limit) return;
        pool.swap(address(this), limit < spot, type(int128).max, limit, "");
    }

    function uniswapV3SwapCallback(int256 a, int256 b, bytes calldata) external {
        require(msg.sender == address(pool));
        if (a > 0) t0.transfer(msg.sender, uint256(a));
        if (b > 0) t1.transfer(msg.sender, uint256(b));
    }
}

/// @notice TEST-ONLY price source for SPY with the guard's rules: the RHSPY feed answer, 0 when older than 12 h or when
/// the SPY token reports paused() or oraclePaused() (as RamsesOracleGuard.pricesUSD18 refuses). USDG at $1.
contract SpyGuardedPrice {
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;

    function getPrice(address asset) external view returns (uint256) {
        if (asset == USDG) return 1e18;
        if (asset != SPY) return 0;
        if (_flag("paused()") || _flag("oraclePaused()")) return 0;
        (, int256 answer,, uint256 updatedAt,) = IFeed(FEED).latestRoundData();
        if (answer <= 0 || block.timestamp - updatedAt > 12 hours) return 0;
        return uint256(answer) * 1e10;
    }

    function _flag(string memory sig) private view returns (bool) {
        (bool ok, bytes memory r) = SPY.staticcall(abi.encodeWithSignature(sig));
        return ok && r.length == 32 && abi.decode(r, (bool));
    }
}

interface IFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

contract StandInMarket {
    address public underlying;

    constructor(address u) {
        underlying = u;
    }
}

/// @notice TEST-ONLY stand-in for a margin position, because the SPY deployment has no margin engine: it holds the SPY
/// collateral, owes a USDG debt, and implements the three executor hooks with the same semantics (release stock; return:
/// repay the debt from USDG received, keep stock as collateral; settle: when debt-free, pay the equity to the owner).
contract StandInExecutor {
    IsolatedMarginTypes.Position public pos;
    address public custodian;
    uint256 public debt;
    IERC20 immutable spy;
    IERC20 immutable usdg;

    constructor(address owner_, address spy_, address usdg_, uint256 debt_) {
        spy = IERC20(spy_);
        usdg = IERC20(usdg_);
        debt = debt_;
        address m = address(new StandInMarket(usdg_));
        pos.id = 1;
        pos.owner = owner_;
        pos.account = address(this);
        pos.marginPToken = m;
        pos.debtPToken = m;
        pos.positionPToken = address(new StandInMarket(spy_));
        pos.side = IsolatedMarginTypes.Side.LONG;
        pos.status = IsolatedMarginTypes.Status.ACTIVE;
    }

    function setCustodian(address c) external {
        custodian = c;
    }

    function positions(uint256) external view returns (IsolatedMarginTypes.Position memory) {
        return pos;
    }

    function rangeRelease(uint256, uint256) external returns (uint256 amount) {
        require(msg.sender == custodian);
        amount = spy.balanceOf(address(this));
        spy.transfer(msg.sender, amount);
    }

    function rangeReturn(uint256, bool settle) external returns (uint256 repaid, uint256 remaining, bool closed) {
        require(msg.sender == custodian);
        uint256 cash = usdg.balanceOf(address(this));
        repaid = cash < debt ? cash : debt;
        debt -= repaid;
        usdg.transfer(address(0xdead), repaid); // repaid to the lender
        remaining = debt;
        if (settle && debt == 0) {
            usdg.transfer(pos.owner, usdg.balanceOf(address(this)));
            spy.transfer(pos.owner, spy.balanceOf(address(this)));
            pos.status = IsolatedMarginTypes.Status.CLOSED;
            closed = true;
        }
    }

    // risk engine and config stand-ins
    function isLiquidatable(address) external pure returns (bool) {
        return false;
    }

    function rangeCustodian() external view returns (address) {
        return custodian;
    }

    function getPairRisk(address, address, address) external pure returns (IsolatedMarginTypes.PairRiskConfig memory c) {
        c.oracleDeviationBps = 100;
    }
}

/// @notice Range take-profit band mechanics on the SPY deployment's REAL Ramses SPY/USDG pool (0x3845, SPY = token0),
/// gauge and RHSPY feed, on a fork. SPY has no margin engine, so the margin position is a labelled test-only stand-in;
/// the custodian, its band placement, valuation, finalisation and unwind are the same contract as on NVDA.
contract RangeTakeProfitSpyForkTest is Test {
    address constant POOL = 0x38453c115607463Ac284820Ce959831042f3Df4E;
    address constant GAUGE = 0x739E31798EFE8Cff3ef4c613D8ae751e179C7337;
    address constant NFP = 0x2eBd7B85a4E08D5B508b04BA147976C94afE6590;
    address constant FEED = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address constant SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant OWNER = address(0xA11CE);
    address constant PROTOCOL = address(0xBEEF01);
    address constant RESERVE = address(0xBEEF02);

    RangeTakeProfit rtp;
    StandInExecutor ex;
    SpyGuardedPrice price;
    SpyTrader trader;
    int256 answer;
    int24 spacing;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ORDERS_FORK_BLOCK"));
        (, answer,,,) = IFeed(FEED).latestRoundData();
        _stamp(answer);
        price = new SpyGuardedPrice();
        ex = new StandInExecutor(OWNER, SPY, USDG, 5e6); // 0.02 SPY collateral (~$15) against 5 USDG of debt
        deal(SPY, address(ex), 0.02e18);
        rtp = RangeTakeProfit(
            address(
                new TransparentUpgradeableProxy(
                    address(new RangeTakeProfit()), address(this),
                    abi.encodeCall(RangeTakeProfit.initialize, (RangeTakeProfit.InitParams(
                        address(ex), address(ex), NFP, POOL, GAUGE, address(price), address(ex), address(0), SPY, USDG, address(this))))
                )
            )
        );
        ex.setCustodian(address(rtp));
        spacing = ISpyPool(POOL).tickSpacing();
        // ~1% above the market and ~2% wide, rounded up to the pool's own tick spacing (read, not assumed)
        rtp.setPreset(1, true, (100 + spacing - 1) / spacing * spacing, (200 + spacing - 1) / spacing * spacing);
        rtp.setFeeSplit(7000, 2000, 1000, PROTOCOL, RESERVE, bytes32(0)); // no SPY loss reserve on the fork: plain transfer
        trader = new SpyTrader(ISpyPool(POOL), IERC20(SPY), IERC20(USDG));
        deal(SPY, address(trader), 10_000e18);
        deal(USDG, address(trader), 10_000_000e6);
        trader.moveTo(_sqrtFor(uint256(answer) * 1e10)); // pool at the oracle
    }

    function _stamp(int256 a) internal {
        vm.mockCall(FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(9), a, block.timestamp, block.timestamp, uint80(9)));
    }

    /// @dev SPY is token0 (18 decimals), USDG token1 (6): raw USDG per raw SPY = price / 1e30.
    function _sqrtFor(uint256 priceE18) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(priceE18, uint256(1) << 192, 1e30)));
    }

    function _marketTo(int24 tick) internal {
        uint160 s = TickMath.getSqrtPriceAtTick(tick);
        trader.moveTo(s);
        uint256 p = Math.mulDiv(uint256(s) * uint256(s), 1e30, uint256(1) << 192);
        _stamp(int256(p / 1e10));
    }

    function _create() internal returns (int24 lo, int24 hi) {
        vm.prank(OWNER);
        (lo, hi,) = rtp.createRangeOrder(1, 1, 0);
    }

    function testSpyBandSitsAboveTheMarketForAToken0Stock() public {
        (int24 lo, int24 hi) = _create();
        (, int24 tick,,,,,) = ISpyPool(POOL).slot0();
        emit log_named_int("SPY tick", tick);
        emit log_named_int("band lower", lo);
        emit log_named_int("band upper", hi);
        assertGt(lo, tick, "SPY is token0: price up = tick up, so the whole band is above the tick");
        (uint256 s, uint256 u) = rtp.holdings(address(ex));
        assertEq(u, 0);
        assertApproxEqRel(s, 0.02e18, 1e14);
    }

    function testSpyPartialFillReversalAndFinalisation() public {
        (int24 lo, int24 hi) = _create();
        (, int24 start,,,,,) = ISpyPool(POOL).slot0();
        _marketTo((lo + hi) / 2);
        (uint256 sMid, uint256 uMid) = rtp.holdings(address(ex));
        emit log_named_uint("mid-band SPY", sMid);
        emit log_named_uint("mid-band USDG", uMid);
        assertGt(uMid, 0);
        vm.expectRevert(RangeTakeProfit.BandNotFullyConverted.selector);
        rtp.finalize(1);
        _marketTo(start);
        (, uint256 uBack) = rtp.holdings(address(ex));
        assertEq(uBack, 0, "reversed");
        _marketTo(hi + spacing);
        uint256 ownerBefore = IERC20(USDG).balanceOf(OWNER);
        rtp.finalize(1);
        assertEq(ex.debt(), 0, "debt repaid from the conversion");
        assertEq(uint8(rtp.getOrder(1).status), uint8(RangeTakeProfit.Status.SETTLED));
        emit log_named_uint("equity paid to the owner (USDG raw)", IERC20(USDG).balanceOf(OWNER) - ownerBefore);
        emit log_named_uint("protocol fee share (USDG raw)", IERC20(USDG).balanceOf(PROTOCOL));
        assertGt(IERC20(USDG).balanceOf(OWNER) - ownerBefore, 0);
    }

    function testSpyStaleFeedAndPauseFlagsRefuse() public {
        vm.warp(block.timestamp + 13 hours);
        vm.clearMockedCalls();
        vm.mockCall(FEED, abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(9), answer, block.timestamp - 13 hours, block.timestamp - 13 hours, uint80(9)));
        vm.prank(OWNER);
        vm.expectRevert(RangeTakeProfit.OracleUnavailable.selector);
        rtp.createRangeOrder(1, 1, 0);
        _stamp(answer);
        vm.mockCall(SPY, abi.encodeWithSignature("oraclePaused()"), abi.encode(true));
        vm.prank(OWNER);
        vm.expectRevert(RangeTakeProfit.OracleUnavailable.selector);
        rtp.createRangeOrder(1, 1, 0);
    }

    function testSpyUnwindReturnsTheStock() public {
        _create();
        vm.prank(OWNER);
        assertTrue(rtp.unwind(1));
        assertApproxEqAbs(IERC20(SPY).balanceOf(address(ex)), 0.02e18, 2, "stock back with the position");
    }
}
