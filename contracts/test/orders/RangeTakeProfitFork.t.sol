// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IsolatedMarginExecutorUpgradeable} from "../../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {RobinhoodMarginCloseAdapter, IRobinhoodOrderExecutor} from "../../contracts/margin/orders/RobinhoodMarginCloseAdapter.sol";
import {MarginOrderRegistry} from "../../contracts/margin/orders/MarginOrderRegistry.sol";
import {MarginOrderRegistryV2} from "../../contracts/margin/orders/MarginOrderRegistryV2.sol";
import {IMarginOrderRegistry, IMarginCloseAdapter} from "../../contracts/margin/orders/IMarginOrderRegistry.sol";
import {RangeTakeProfit} from "../../contracts/margin/orders/range/RangeTakeProfit.sol";
import {TickMath} from "../../contracts/margin/orders/range/vendor/TickMath.sol";

interface IRtpProxyAdmin {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external payable;
    function owner() external view returns (address);
}

interface IRtpPool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint24, bool);
    function swap(address, bool, int256, uint160, bytes calldata) external returns (int256, int256);
}

interface IRtpVault {
    function freeBalance(address, address) external view returns (uint256);
}

interface IRtpMarket {
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
}

interface IRtpLiquidator {
    struct LiquidationParams {
        uint256 positionId;
        address recipient;
        uint256 minDebtUnderlying;
        uint256 minMarginUnderlying;
        bytes collateralToDebtSwapData;
        bytes debtToMarginSwapData;
    }

    function liquidate(LiquidationParams calldata params) external;
}

interface IRtpConfig {
    function queuePairRisk(address, address, address, IsolatedMarginTypes.PairRiskConfig calldata) external returns (bytes32);
    function setPairRisk(address, address, address, IsolatedMarginTypes.PairRiskConfig calldata) external;
    function getPairRisk(address, address, address) external view returns (IsolatedMarginTypes.PairRiskConfig memory);
}

interface IRtpNfp {
    function ownerOf(uint256) external view returns (address);
}

/// @notice Moves the Ramses NVDA/USDG pool by real swaps (pays in the callback).
contract RtpTrader {
    IRtpPool immutable pool;
    IERC20 immutable t0;
    IERC20 immutable t1;

    constructor(IRtpPool p, IERC20 a, IERC20 b) {
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

/// @notice Range take-profit PROTOTYPE on the LIVE Robinhood margin stack (fork): live position 4 (a real NVDA long against
/// USDG debt), the live executor, risk engine and liquidator upgraded on the fork to the prototype hooks, the real Ramses
/// NVDA/USDG pool and position manager. Nothing is sent; live position 4 is never touched outside the fork.
contract RangeTakeProfitForkTest is Test {
    using stdStorage for StdStorage;

    address constant EXECUTOR = 0x6A45Ae86bD992d250580d08D340A06A04D478977;
    address constant RISK = 0xC8b178C3c74570472FF1eeE0DD559e61AF9f9678;
    address constant LIQUIDATOR = 0x1434CDa56d0Aeac4d5abC16F91ca76a8A989083c;
    address constant TIMELOCK = 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498;
    address constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address constant ORACLE = 0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD;
    address constant QUOTER = 0xeD3c353Ab237329BD53CC7eB24E66B370155FE6e;
    address constant CONFIG = 0x09F94fe0B79E000c8a26617c63E3427fdECB528b;
    address constant VAULT = 0x04D4A5555b7a37017A67B4D21A1Da5838de28B9e;
    address constant FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address constant POOL = 0xdac1904D823F7d6bcAaF431ceEe40c934fEd321b; // Ramses NVDA/USDG, token0 USDG, spacing 10
    address constant NFP = 0x2eBd7B85a4E08D5B508b04BA147976C94afE6590;
    address constant GAUGE = 0x93c6A733FB3165D94774B3A5Fc4319D29bd7b6ce;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    address constant PROTOCOL = address(0xBEEF01);
    address constant RESERVE = 0x806b182B050f7EcF908758dD6bBF91DB8B2212aF; // the NVDA/USDG pair's loss reserve (live)
    bytes32 constant NVDA_PAIR = 0xe2050352f4346597cc69d2776d99ae60c9440dfc28f9406ce66be0bbe3fb6b06;

    IsolatedMarginExecutorUpgradeable ex = IsolatedMarginExecutorUpgradeable(EXECUTOR);
    IsolatedMarginRiskEngineUpgradeable risk = IsolatedMarginRiskEngineUpgradeable(RISK);
    MarginOrderRegistry reg;
    RangeTakeProfit rtp;
    RobinhoodMarginCloseAdapter adapter; // v2, range-aware
    RobinhoodMarginCloseAdapter adapterV1; // the ceremony's
    RtpTrader trader;
    uint256 id; // a live long
    IsolatedMarginTypes.Position p;
    int256 answer;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ORDERS_FORK_BLOCK"));
        vm.roll(vm.envUint("ORDERS_NATIVE_BLOCK"));
        (bool okc, bytes memory r) = FEED.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(okc);
        (, answer,,,) = abi.decode(r, (uint80, int256, uint256, uint256, uint80));
        _stamp();
        for (uint256 i = 1; i < ex.nextPositionId(); i++) {
            IsolatedMarginTypes.Position memory q = IRobinhoodOrderExecutor(EXECUTOR).positions(i);
            if (q.status == IsolatedMarginTypes.Status.ACTIVE && q.side == IsolatedMarginTypes.Side.LONG) id = i;
        }
        require(id != 0, "no live long at this pin");
        p = IRobinhoodOrderExecutor(EXECUTOR).positions(id);

        // 1. The 15-17 Nov ceremony as prepared: registry V1 behind its proxy, close adapter v1 (no custodian), executor
        //    upgraded with initializeOrderExecutor(adapter v1). (On this branch adapter v1 is the 6-argument adapter with
        //    custodian 0; the ceremony artifact is the 5-argument one on feat/margin-order-interface, same behaviour.)
        uint256 n = vm.getNonce(address(this));
        address predictedV1 = vm.computeCreateAddress(address(this), n + 2);
        MarginOrderRegistry impl = new MarginOrderRegistry();
        reg = MarginOrderRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(impl), TIMELOCK, abi.encodeCall(MarginOrderRegistry.initialize, (IMarginCloseAdapter(predictedV1), TIMELOCK))
                )
            )
        );
        adapterV1 = new RobinhoodMarginCloseAdapter(EXECUTOR, address(reg), ORACLE, QUOTER, CONFIG, address(0));
        require(address(adapterV1) == predictedV1, "PREDICT");
        address execImpl = address(new IsolatedMarginExecutorUpgradeable());
        _upgrade(EXECUTOR, execImpl, abi.encodeCall(IsolatedMarginExecutorUpgradeable.initializeOrderExecutor, (address(adapterV1))));

        // 2. The range batch: custodian and range-aware adapter v2, then every upgrade in one timelocked batch.
        rtp = RangeTakeProfit(
            address(
                new TransparentUpgradeableProxy(
                    address(new RangeTakeProfit()),
                    TIMELOCK,
                    abi.encodeCall(
                        RangeTakeProfit.initialize,
                        (RangeTakeProfit.InitParams(EXECUTOR, RISK, NFP, POOL, GAUGE, ORACLE, CONFIG, address(reg), NVDA, USDG, address(this)))
                    )
                )
            )
        );
        adapter = new RobinhoodMarginCloseAdapter(EXECUTOR, address(reg), ORACLE, QUOTER, CONFIG, address(rtp));
        _upgrade(EXECUTOR, execImpl,
            abi.encodeCall(IsolatedMarginExecutorUpgradeable.initializeRange, (address(rtp), address(adapter))));
        _upgrade(address(reg), address(new MarginOrderRegistryV2()),
            abi.encodeCall(MarginOrderRegistryV2.initializeV2, (IMarginCloseAdapter(address(adapter)), address(rtp))));
        _upgrade(RISK, address(new IsolatedMarginRiskEngineUpgradeable()),
            abi.encodeCall(IsolatedMarginRiskEngineUpgradeable.initializeRangeCustodian, (address(rtp))));
        _upgrade(LIQUIDATOR, address(new IsolatedMarginLiquidatorUpgradeable()),
            abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.initializeRangeCustodian, (address(rtp))));

        // Presets and the disclosed fee split (parameters; production values undecided).
        // Pilot presets (operator 2026-11-07): 1%, 3% and 5% above the market, each 2% wide (1.0001^ticks; spacing 10).
        rtp.setPreset(1, true, 100, 200);
        rtp.setPreset(2, true, 300, 200);
        rtp.setPreset(3, true, 490, 200);
        rtp.setFeeSplit(7000, 2000, 1000, PROTOCOL, RESERVE, NVDA_PAIR); // pilot split; reserve share credited to the pair
        rtp.setUnwinders(LIQUIDATOR, address(adapter));

        trader = new RtpTrader(IRtpPool(POOL), IERC20(USDG), IERC20(NVDA));
        deal(USDG, address(trader), 10_000_000e6);
        deal(NVDA, address(trader), 100_000e18);
        _alignPoolToOracle();
    }

    // ------------------------------------------------------------------ helpers
    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))));
    }

    function _upgrade(address proxy, address impl, bytes memory data) internal {
        IRtpProxyAdmin admin = IRtpProxyAdmin(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))));
        assertEq(admin.owner(), TIMELOCK);
        vm.prank(TIMELOCK);
        admin.upgradeAndCall(proxy, impl, data);
    }

    function _stamp() internal {
        vm.mockCall(FEED, abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(9), answer, block.timestamp, block.timestamp, uint80(9)));
    }

    /// @dev sqrt price (token1 NVDA raw per token0 USDG raw) for a USD price of NVDA with 18 decimals.
    function _sqrtForPrice(uint256 priceE18) internal pure returns (uint160) {
        return uint160(Math.sqrt(Math.mulDiv(1e30, uint256(1) << 192, priceE18)));
    }

    function _oraclePrice() internal view returns (uint256) {
        (bool ok, bytes memory r) = ORACLE.staticcall(abi.encodeWithSignature("getPrice(address)", NVDA));
        require(ok);
        return abi.decode(r, (uint256));
    }

    function _alignPoolToOracle() internal {
        trader.moveTo(_sqrtForPrice(_oraclePrice()));
    }

    /// @dev Moves the pool to a tick and makes the margin oracle report the matching price (the feed's next answer).
    function _marketTo(int24 tick) internal {
        uint160 s = TickMath.getSqrtPriceAtTick(tick);
        trader.moveTo(s);
        uint256 price = Math.mulDiv(1e30, uint256(1) << 192, uint256(s) * uint256(s));
        vm.mockCall(ORACLE, abi.encodeWithSignature("getPrice(address)", NVDA), abi.encode(price));
    }

    function _reserveAvailable() internal view returns (uint256) {
        (bool ok, bytes memory r) =
            RESERVE.staticcall(abi.encodeWithSignature("available(bytes32,address)", NVDA_PAIR, USDG));
        require(ok);
        return abi.decode(r, (uint256));
    }

    function _health() internal view returns (uint256) {
        return risk.getMetrics(p.account).healthFactorBps;
    }

    function _create() internal returns (int24 lo, int24 hi) {
        vm.prank(p.owner);
        (lo, hi,) = rtp.createRangeOrder(id, 1, 0);
    }

    function _status() internal view returns (RangeTakeProfit.Status) {
        return rtp.getOrder(id).status;
    }

    // ------------------------------------------------------------------ 1. creation from a live margin position
    function testCreateFromTheLiveLongPlacesABandAboveTheMarketAndKeepsHealth() public {
        uint256 hBefore = _health();
        uint256 pBefore = IRtpMarket(p.positionPToken).balanceOf(p.account);
        (int24 lo, int24 hi) = _create();
        (, int24 tick,,,,,) = IRtpPool(POOL).slot0();
        RangeTakeProfit.Order memory o = rtp.getOrder(id);
        emit log_named_int("current tick", tick);
        emit log_named_int("band lower", lo);
        emit log_named_int("band upper", hi);
        emit log_named_uint("stock committed (raw NVDA)", o.stockCommitted);
        emit log_named_uint("health before (bps)", hBefore);
        emit log_named_uint("health after (bps)", _health());
        assertEq(uint8(o.status), uint8(RangeTakeProfit.Status.ACTIVE));
        assertGt(pBefore, 0);
        assertEq(IRtpMarket(p.positionPToken).balanceOf(p.account), 0, "all stock collateral committed");
        assertEq(IRtpNfp(NFP).ownerOf(o.tokenId), address(rtp), "band held by the custodian");
        // NVDA is token1: "above the market" means the whole band is at lower ticks, holding only NVDA.
        assertLe(hi, tick);
        assertEq(hi - lo, 200);
        (uint256 s, uint256 u) = rtp.holdings(p.account);
        assertEq(u, 0, "no USDG in the band yet");
        assertApproxEqRel(s, o.stockCommitted, 1e14);
        assertApproxEqRel(_health(), hBefore, 2e15, "health unchanged within 0.2%: the band is counted at the oracle");
        assertFalse(risk.isLiquidatable(p.account));
    }

    function testPilotPresetsSitOneThreeAndFivePercentAboveAndTwoPercentWide() public {
        (, int24 tick,,,,,) = IRtpPool(POOL).slot0();
        uint256 snap = vm.snapshotState();
        uint8[3] memory ids = [uint8(1), 2, 3];
        for (uint256 i; i < 3; i++) {
            vm.revertToState(snap);
            vm.prank(p.owner);
            (int24 lo, int24 hi,) = rtp.createRangeOrder(id, ids[i], 0);
            // NVDA is token1: price of NVDA in USD = 1e12 / (1.0001^tick); a lower tick is a higher NVDA price.
            emit log_named_int("preset distance (ticks from the current tick to the near edge)", tick - hi);
            int24[3] memory want = [int24(100), 300, 490];
            assertGe(tick - hi, want[i], "never closer than the preset");
            assertLt(tick - hi, want[i] + 10, "within one tick spacing of it");
            assertEq(hi - lo, 200, "2% wide");
        }
    }

    // ------------------------------------------------------------------ 2. partial fill and reversal
    function testPartialFillConvertsSomeAndAFallBackReversesIt() public {
        (int24 lo, int24 hi) = _create();
        (, int24 start,,,,,) = IRtpPool(POOL).slot0();
        _marketTo((lo + hi) / 2); // NVDA up into the middle of the band
        (uint256 sMid, uint256 uMid) = rtp.holdings(p.account);
        emit log_named_uint("mid-band: NVDA in band", sMid);
        emit log_named_uint("mid-band: USDG in band", uMid);
        assertGt(uMid, 0, "partly converted to USDG");
        assertLt(sMid, rtp.getOrder(id).stockCommitted);
        vm.expectRevert(RangeTakeProfit.BandNotFullyConverted.selector);
        rtp.finalize(id); // a range order is not final while partly converted
        _marketTo(start); // back below the band
        (uint256 sBack, uint256 uBack) = rtp.holdings(p.account);
        emit log_named_uint("after reversal: NVDA in band", sBack);
        assertEq(uBack, 0, "conversion fully reversed");
        assertApproxEqRel(sBack, rtp.getOrder(id).stockCommitted, 1e14);
        assertEq(uint8(_status()), uint8(RangeTakeProfit.Status.ACTIVE));
        assertEq(uint8(IRobinhoodOrderExecutor(EXECUTOR).positions(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
    }

    function testBandIsValuedAtTheOracleNotThePool() public {
        (int24 lo, int24 hi) = _create();
        uint160 mid = TickMath.getSqrtPriceAtTick((lo + hi) / 2);
        trader.moveTo(mid); // pool moved, oracle NOT moved
        (uint256 s, uint256 u) = rtp.holdings(p.account);
        assertEq(u, 0, "valued at the oracle price, still below the band");
        assertApproxEqRel(s, rtp.getOrder(id).stockCommitted, 1e14);
        vm.expectRevert(); // and nothing can be finalised against a pool that disagrees with the oracle
        rtp.finalize(id);
    }

    // ------------------------------------------------------------------ 3. keeper finalisation with repay
    function testFullFillThenKeeperFinalisesRepaysDebtAndReturnsEquity() public {
        (int24 lo,) = _create();
        uint256 freeBefore = IRtpVault(VAULT).freeBalance(p.owner, p.marginPToken);
        uint256 reserveBefore = _reserveAvailable();
        _marketTo(lo - 20); // traded through the whole band
        uint256 debtBefore = IRtpMarket(p.debtPToken).borrowBalanceStored(p.account);
        assertGt(debtBefore, 0);
        vm.prank(address(0xCAFE)); // any keeper
        rtp.finalize(id);
        assertEq(uint8(_status()), uint8(RangeTakeProfit.Status.SETTLED));
        assertEq(IRtpMarket(p.debtPToken).borrowBalanceStored(p.account), 0, "debt and accrued interest repaid");
        assertEq(uint8(IRobinhoodOrderExecutor(EXECUTOR).positions(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        uint256 credited = IRtpVault(VAULT).freeBalance(p.owner, p.marginPToken) - freeBefore;
        emit log_named_uint("equity credited to the owner (pUSDG units)", credited);
        emit log_named_uint("protocol fee share (USDG raw)", IERC20(USDG).balanceOf(PROTOCOL));
        emit log_named_uint("reserve fee share credited to the pair (USDG raw)", _reserveAvailable() - reserveBefore);
        assertGt(_reserveAvailable(), reserveBefore, "reserve share credited to the pair's loss reserve, not just sent");
        assertGt(credited, 0);
        assertEq(IERC20(USDG).balanceOf(address(rtp)), 0, "custodian keeps nothing");
        assertEq(IERC20(NVDA).balanceOf(address(rtp)), 0);
    }

    function testNothingCountsAsRepaidUntilTheRepaySucceeds() public {
        (int24 lo,) = _create();
        _marketTo(lo - 20);
        vm.mockCallRevert(EXECUTOR, abi.encodeWithSignature("rangeReturn(uint256,bool)", id, true), "REPAY_FAILED");
        vm.expectRevert(bytes("REPAY_FAILED"));
        rtp.finalize(id);
        assertEq(uint8(_status()), uint8(RangeTakeProfit.Status.ACTIVE), "still ACTIVE: conversion is not settlement");
        assertGt(IRtpMarket(p.debtPToken).borrowBalanceStored(p.account), 0);
    }

    /// @dev Committing part of the collateral: the band's proceeds repay what they can; if they do not cover the whole
    /// debt the position stays open on its remaining collateral with less debt (and better health), never closed short.
    function testPartialCommitRepaysWhatTheBandEarnedAndKeepsThePositionOpen() public {
        uint256 all = IRtpMarket(p.positionPToken).balanceOf(p.account);
        vm.prank(p.owner);
        (int24 lo,,) = rtp.createRangeOrder(id, 1, all / 2);
        assertEq(IRtpMarket(p.positionPToken).balanceOf(p.account), all - all / 2, "half stays as collateral");
        assertFalse(risk.isLiquidatable(p.account));
        _marketTo(lo - 20);
        uint256 debtBefore = IRtpMarket(p.debtPToken).borrowBalanceStored(p.account);
        uint256 hBefore = _health();
        rtp.finalize(id);
        uint256 debtAfter = IRtpMarket(p.debtPToken).borrowBalanceStored(p.account);
        emit log_named_uint("debt before (USDG raw)", debtBefore);
        emit log_named_uint("debt after (USDG raw)", debtAfter);
        assertEq(uint8(_status()), uint8(RangeTakeProfit.Status.SETTLED));
        assertLt(debtAfter, debtBefore, "the band's USDG repaid debt");
        if (debtAfter != 0) {
            assertEq(uint8(IRobinhoodOrderExecutor(EXECUTOR).positions(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
            assertGe(IRtpMarket(p.positionPToken).balanceOf(p.account), all - all / 2, "uncommitted stock kept as collateral");
            assertGt(_health(), hBefore, "health improved");
        }
    }

    // ------------------------------------------------------------------ 4. liquidation while a band is active
    function testLiquidationRemovesTheActiveBandAndProceeds() public {
        _create();
        // Make the live long liquidatable without moving any price: raise the pair's margin requirements (owner path).
        _makeLiquidatable();
        IRtpLiquidator(LIQUIDATOR).liquidate(IRtpLiquidator.LiquidationParams(id, address(this), 0, 0, "", ""));
        assertEq(uint8(_status()), uint8(RangeTakeProfit.Status.UNWOUND), "band removed by the liquidator");
        IsolatedMarginTypes.Position memory after_ = IRobinhoodOrderExecutor(EXECUTOR).positions(id);
        assertEq(uint8(after_.status), uint8(IsolatedMarginTypes.Status.LIQUIDATED), "fully liquidated");
        assertEq(IRtpMarket(p.debtPToken).borrowBalanceStored(p.account), 0);
    }

    /// @dev Counterfactual: without the liquidator's pre-hook the seizure finds no stock collateral (it is in the band),
    /// so the liquidation fails. This is why the liquidator must remove the band as part of seizure.
    function testWithoutThePreHookABandWouldBlockLiquidation() public {
        _create();
        _makeLiquidatable();
        bytes32 slot = bytes32(uint256(stdstore.target(LIQUIDATOR).sig("rangeCustodian()").find()));
        vm.store(LIQUIDATOR, slot, bytes32(0));
        // LiquidationError(12): the account holds no position collateral to seize; it is all in the band.
        vm.expectRevert(abi.encodeWithSignature("LiquidationError(uint8)", uint8(12)));
        IRtpLiquidator(LIQUIDATOR).liquidate(IRtpLiquidator.LiquidationParams(id, address(this), 0, 0, "", ""));
        assertEq(uint8(_status()), uint8(RangeTakeProfit.Status.ACTIVE));
    }

    function _makeLiquidatable() internal {
        IsolatedMarginTypes.PairRiskConfig memory c = IRtpConfig(CONFIG).getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken);
        c.initialMarginBps = 9000;
        c.maintenanceMarginBps = 8900;
        vm.prank(LEDGER);
        IRtpConfig(CONFIG).queuePairRisk(p.marginPToken, p.positionPToken, p.debtPToken, c);
        vm.warp(block.timestamp + 3601);
        _stamp();
        vm.prank(LEDGER);
        IRtpConfig(CONFIG).setPairRisk(p.marginPToken, p.positionPToken, p.debtPToken, c);
        assertTrue(risk.isLiquidatable(p.account), "liquidatable with the band counted");
    }

    // ------------------------------------------------------------------ 5. stop-loss unwinding an active band
    function testStopLossUnwindsTheBandThenClosesThroughTheNormalPath() public {
        _create();
        uint256 price = _oraclePrice();
        vm.prank(p.owner);
        uint256 sl = reg.createOrder(id, IMarginOrderRegistry.OrderKind.STOP_LOSS, false, price, 10_000, 100, uint64(block.timestamp + 1 days));
        vm.prank(address(0xCAFE));
        assertTrue(reg.executeOrder(sl, ""));
        assertEq(uint8(_status()), uint8(RangeTakeProfit.Status.UNWOUND), "band removed first");
        assertEq(uint8(IRobinhoodOrderExecutor(EXECUTOR).positions(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(uint8(reg.getOrder(sl).status), uint8(IMarginOrderRegistry.OrderStatus.EXECUTED));
    }

    // ------------------------------------------------------------------ rules
    function testOneOrderPerPositionAndExclusiveWithAConventionalTakeProfit() public {
        uint256 price = _oraclePrice();
        vm.prank(p.owner);
        uint256 tp = reg.createOrder(id, IMarginOrderRegistry.OrderKind.TAKE_PROFIT, true, price * 2, 10_000, 100, uint64(block.timestamp + 1 days));
        vm.prank(p.owner);
        vm.expectRevert(abi.encodeWithSelector(RangeTakeProfit.PositionNotEligible.selector, uint8(5)));
        rtp.createRangeOrder(id, 1, 0);
        vm.prank(p.owner);
        reg.cancelOrder(tp);
        _create();
        vm.prank(p.owner);
        vm.expectRevert(abi.encodeWithSelector(RangeTakeProfit.PositionNotEligible.selector, uint8(4)));
        rtp.createRangeOrder(id, 1, 0);
    }

    function testOnlyTheOwnerOnlyApprovedPresetsNoBandBelowTheMarket() public {
        vm.expectRevert(RangeTakeProfit.NotOwner.selector);
        rtp.createRangeOrder(id, 1, 0);
        vm.prank(p.owner);
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.createRangeOrder(id, 9, 0); // not an approved preset
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(4, true, 0, 200); // distance 0: the band would touch the market
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(4, true, -100, 200); // below the market: never a stop-loss substitute
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(4, true, 105, 200); // not a multiple of the tick spacing
        vm.prank(address(0xbad));
        vm.expectRevert(RangeTakeProfit.NotAdmin.selector);
        rtp.setPreset(4, true, 100, 200);
        vm.expectRevert(RangeTakeProfit.InvalidFeeSplit.selector);
        rtp.setFeeSplit(7000, 2000, 2000, PROTOCOL, RESERVE, NVDA_PAIR);
        vm.expectRevert(RangeTakeProfit.InvalidFeeSplit.selector);
        rtp.setFeeSplit(7000, 2000, 1000, PROTOCOL, address(0xBEEF02), NVDA_PAIR); // a deposit target must be a contract
    }

    function testStaleOracleAndIssuerPauseRefuseCreation() public {
        vm.warp(block.timestamp + 13 hours);
        vm.clearMockedCalls();
        vm.mockCall(FEED, abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(9), answer, block.timestamp - 13 hours, block.timestamp - 13 hours, uint80(9)));
        vm.prank(p.owner);
        vm.expectRevert(RangeTakeProfit.OracleUnavailable.selector);
        rtp.createRangeOrder(id, 1, 0);
        _stamp();
        vm.mockCall(NVDA, abi.encodeWithSignature("oraclePaused()"), abi.encode(true));
        vm.prank(p.owner);
        vm.expectRevert(RangeTakeProfit.OracleUnavailable.selector);
        rtp.createRangeOrder(id, 1, 0);
    }

    function testPoolFarFromTheOracleRefusesCreation() public {
        trader.moveTo(_sqrtForPrice(_oraclePrice() * 103 / 100));
        vm.prank(p.owner);
        vm.expectPartialRevert(RangeTakeProfit.PoolOracleDeviation.selector);
        rtp.createRangeOrder(id, 1, 0);
    }

    function testOwnerCancelReturnsTheStockToCollateral() public {
        _create();
        vm.prank(address(0xbad));
        vm.expectRevert(RangeTakeProfit.NotAuthorized.selector);
        rtp.unwind(id);
        vm.prank(p.owner);
        assertTrue(rtp.unwind(id));
        assertEq(uint8(_status()), uint8(RangeTakeProfit.Status.UNWOUND));
        assertGt(IRtpMarket(p.positionPToken).balanceOf(p.account), 0, "stock back as collateral");
        assertEq(uint8(IRobinhoodOrderExecutor(EXECUTOR).positions(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertFalse(risk.isLiquidatable(p.account));
    }

    function testRiskEngineCustodianChangeIsDelayedAndRefusedWhileBandsAreActive() public {
        address owner = risk.owner();
        vm.prank(address(0xbad));
        vm.expectRevert();
        risk.queueRangeCustodian(address(0));
        _create();
        vm.prank(owner);
        risk.queueRangeCustodian(address(0)); // try to switch the band valuation off
        vm.prank(owner);
        vm.expectRevert(bytes("RiskEngine: range custodian not ready"));
        risk.applyRangeCustodian();
        vm.warp(block.timestamp + 3600);
        _stamp();
        vm.prank(owner);
        vm.expectRevert(bytes("RiskEngine: active range orders"));
        risk.applyRangeCustodian();
        assertEq(risk.rangeCustodian(), address(rtp));
        vm.prank(p.owner);
        rtp.unwind(id);
        assertEq(rtp.activeOrders(), 0);
        vm.prank(owner);
        risk.applyRangeCustodian();
        assertEq(risk.rangeCustodian(), address(0));
        vm.prank(owner);
        vm.expectRevert(bytes("RiskEngine: range custodian not ready"));
        risk.applyRangeCustodian(); // consumed
    }

    /// @dev The handover: after the batch the executor accepts closes only from adapter v2, the registry uses adapter v2,
    /// and adapter v1 can no longer close for anyone. A stop-loss through the registry then works end to end.
    function testCeremonyThenRangeBatchHandsOverFromAdapterV1ToV2() public {
        assertEq(ex.orderExecutor(), address(adapter));
        assertEq(address(reg.adapter()), address(adapter));
        assertEq(MarginOrderRegistryV2(address(reg)).rangeOrders(), address(rtp));
        assertEq(ex.rangeCustodian(), address(rtp));
        assertEq(risk.rangeCustodian(), address(rtp));
        IRobinhoodOrderExecutor.CloseParams memory cp = IRobinhoodOrderExecutor.CloseParams(id, 10_000, type(uint256).max, 0, 0, "", "");
        vm.prank(address(adapterV1));
        vm.expectRevert(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.ExecutorError.selector, uint8(60)));
        IRobinhoodOrderExecutor(EXECUTOR).closePositionFor(p.owner, cp);
        _create();
        uint256 price = _oraclePrice();
        vm.prank(p.owner);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(7)));
        reg.createOrder(id, IMarginOrderRegistry.OrderKind.TAKE_PROFIT, true, price * 2, 10_000, 100, uint64(block.timestamp + 1 days));
        vm.prank(p.owner);
        uint256 sl = reg.createOrder(id, IMarginOrderRegistry.OrderKind.STOP_LOSS, false, price, 10_000, 100, uint64(block.timestamp + 1 days));
        assertTrue(reg.executeOrder(sl, ""));
        assertEq(uint8(IRobinhoodOrderExecutor(EXECUTOR).positions(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        vm.prank(TIMELOCK);
        vm.expectRevert(); // reinitializer(3) spent: the range wiring happens once
        IRtpProxyAdmin(address(uint160(uint256(vm.load(EXECUTOR, ADMIN_SLOT))))).upgradeAndCall(
            EXECUTOR, _impl(EXECUTOR), abi.encodeCall(IsolatedMarginExecutorUpgradeable.initializeRange, (address(rtp), address(adapterV1)))
        );
    }

    function testCustodianRefusesBandsUntilTheRiskEngineCountsItAndItsImplementationIsLocked() public {
        // a second custodian, not wired into the risk engine
        RangeTakeProfit other = RangeTakeProfit(
            address(
                new TransparentUpgradeableProxy(
                    address(new RangeTakeProfit()), TIMELOCK,
                    abi.encodeCall(RangeTakeProfit.initialize,
                        (RangeTakeProfit.InitParams(EXECUTOR, RISK, NFP, POOL, GAUGE, ORACLE, CONFIG, address(reg), NVDA, USDG, address(this))))
                )
            )
        );
        other.setPreset(1, true, 100, 200);
        vm.prank(p.owner);
        vm.expectRevert(RangeTakeProfit.NotWired.selector);
        other.createRangeOrder(id, 1, 0);
        RangeTakeProfit impl = new RangeTakeProfit();
        vm.expectRevert();
        impl.initialize(RangeTakeProfit.InitParams(EXECUTOR, RISK, NFP, POOL, GAUGE, ORACLE, CONFIG, address(reg), NVDA, USDG, address(this)));
    }

    function testHooksAreCustodianOnly() public {
        vm.expectRevert(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.ExecutorError.selector, uint8(61)));
        ex.rangeRelease(id, 0);
        vm.expectRevert(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.ExecutorError.selector, uint8(61)));
        ex.rangeReturn(id, true);
        vm.expectRevert();
        risk.authorizeRangeRelease(p.account, 1);
    }
}
