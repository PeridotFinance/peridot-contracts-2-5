// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IsolatedMarginTypes} from "@peridot/margin/IsolatedMarginTypes.sol";
import {IMarginOrderRegistry} from "@peridot/margin/orders/IMarginOrderRegistry.sol";
import {RangeFixture, INfpView} from "./RangeFixture.sol";
import {RangeTakeProfit} from "../src/RangeTakeProfit.sol";
import {IsolatedMarginLiquidatorUpgradeable as RLiquidator} from "../src/engine/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable as RExecutor} from "../src/engine/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable as RRiskEngine} from "../src/engine/IsolatedMarginRiskEngineUpgradeable.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Failure modes, rules, the engine hooks and the risk paths of the range take-profit (fork, pinned block).
contract RangeRiskForkTest is RangeFixture {
    uint256 internal constant MARGIN = 90e6;

    function _create(uint256 id, uint8 preset) internal returns (RangeTakeProfit.Order memory) {
        vm.prank(ALICE);
        rtp.createRangeOrder(id, preset, 0);
        return rtp.getOrder(id);
    }

    function _setAvaxBps(uint256 bps) internal {
        _setPrices(int256((uint256(realAvax) * bps) / 10_000), usdcAnswer);
    }

    function _fundedCall(uint256 id, address op, uint256 maxRepay, uint256 minValueBps) internal returns (bool ok, bytes memory ret) {
        vm.prank(op);
        (ok, ret) = address(liquidator).call(
            abi.encodeWithSelector(
                RLiquidator.liquidateFunded.selector, RLiquidator.FundedLiquidationParams(id, op, maxRepay, 0, 0, minValueBps)
            )
        );
    }

    function _fundOperator(address op, uint256 usdc) internal {
        deal(USDC, op, usdc);
        vm.prank(op);
        IERC20(USDC).approve(address(liquidator), usdc);
    }

    function _nftExists(uint256 tokenId) internal view returns (bool ok) {
        (ok,) = PHARAOH_NFPM.staticcall(abi.encodeWithSelector(INfpView.ownerOf.selector, tokenId));
    }

    // ----------------------------------------------------------------- creation rules
    function test_20_rules_creation() public {
        uint256 id = _open(ALICE, MARGIN);
        // not the owner
        vm.prank(STRANGER);
        vm.expectRevert(RangeTakeProfit.NotOwner.selector);
        rtp.createRangeOrder(id, 1, 0);
        // a preset that does not exist / is disabled
        vm.prank(ALICE);
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.createRangeOrder(id, 9, 0);
        // more collateral than the position has
        vm.prank(ALICE);
        vm.expectRevert(); // executor error 63
        rtp.createRangeOrder(id, 1, type(uint128).max);
        // a position that does not exist
        vm.prank(ALICE);
        vm.expectRevert();
        rtp.createRangeOrder(777, 1, 0);
        // good, then a second order on the same position is refused
        _create(id, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RangeTakeProfit.PositionNotEligible.selector, uint8(4)));
        rtp.createRangeOrder(id, 2, 0);
    }

    function test_21_rules_openTakeProfitInTheRegistry_refuses() public {
        uint256 id = _open(ALICE, MARGIN);
        (uint256 price, bool ok) = _adapterV1Price(id);
        assertTrue(ok);
        vm.prank(ALICE);
        uint256 oid = registry.createOrder(
            id, IMarginOrderRegistry.OrderKind.TAKE_PROFIT, true, price * 130 / 100, 10_000, 100, uint64(block.timestamp + 7 days)
        );
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RangeTakeProfit.PositionNotEligible.selector, uint8(5)));
        rtp.createRangeOrder(id, 1, 0);
        // a STOP-LOSS in the registry does not block it
        vm.prank(ALICE);
        registry.cancelOrder(oid);
        vm.prank(ALICE);
        registry.createOrder(id, IMarginOrderRegistry.OrderKind.STOP_LOSS, false, price * 70 / 100, 10_000, 100, uint64(block.timestamp + 7 days));
        _create(id, 1);
    }

    function _adapterV1Price(uint256 id) internal view returns (uint256 price, bool ok) {
        (bool s, bytes memory r) = md.closeAdapter.staticcall(abi.encodeWithSignature("oraclePriceE18(uint256)", id));
        require(s, "adapter price");
        (price, ok) = abi.decode(r, (uint256, bool));
    }

    function test_22_notWired_refusesUntilTheRiskEngineCountsBands() public {
        uint256 id = _open(ALICE, MARGIN);
        // a second custodian that the risk engine does NOT know
        RangeTakeProfit impl = new RangeTakeProfit();
        address[] memory rewards = new address[](0);
        RangeTakeProfit.InitParams memory ip = RangeTakeProfit.InitParams({
            executor: md.executor,
            riskEngine: md.riskEngine,
            positionManager: PHARAOH_NFPM,
            pool: PHARAOH_POOL,
            oracle: md.oracle,
            config: md.config,
            registry: address(0),
            collateral: WAVAX,
            quote: USDC,
            admin: LEDGER,
            rewardTokens: rewards,
            xPhar: address(0)
        });
        RangeTakeProfit other = RangeTakeProfit(address(new TransparentUpgradeableProxy(address(impl), LEDGER, abi.encodeCall(RangeTakeProfit.initialize, (ip)))));
        vm.prank(ALICE);
        vm.expectRevert(RangeTakeProfit.NotWired.selector);
        other.createRangeOrder(id, 1, 0);
    }

    function test_23_initialize_refusesAWrongPool() public {
        RangeTakeProfit impl = new RangeTakeProfit();
        address[] memory rewards = new address[](0);
        RangeTakeProfit.InitParams memory ip = RangeTakeProfit.InitParams({
            executor: md.executor,
            riskEngine: md.riskEngine,
            positionManager: PHARAOH_NFPM,
            pool: PHARAOH_POOL,
            oracle: md.oracle,
            config: md.config,
            registry: address(0),
            collateral: USDC, // the stock must be token0
            quote: WAVAX,
            admin: LEDGER,
            rewardTokens: rewards,
            xPhar: address(0)
        });
        vm.expectRevert(bytes("RANGE_POOL"));
        new TransparentUpgradeableProxy(address(impl), LEDGER, abi.encodeCall(RangeTakeProfit.initialize, (ip)));
    }

    function test_24_presets_adminOnly_andValidated() public {
        int24[3] memory d = [int24(100), 0, 0];
        int24[3] memory w = [int24(200), 0, 0];
        uint16[3] memory wt = [uint16(10_000), 0, 0];
        vm.prank(STRANGER);
        vm.expectRevert(RangeTakeProfit.NotAdmin.selector);
        rtp.setPreset(7, true, 1, d, w, wt);
        vm.startPrank(LEDGER);
        // distance not above the market
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(7, true, 1, [int24(0), 0, 0], w, wt);
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(7, true, 1, [int24(-100), 0, 0], w, wt);
        // not a multiple of the tick spacing (10)
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(7, true, 1, [int24(105), 0, 0], w, wt);
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(7, true, 1, d, [int24(205), 0, 0], wt);
        // weights not 100 %
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(7, true, 2, [int24(100), 300, 0], [int24(200), 200, 0], [uint16(7_000), 2_000, 0]);
        // more than three levels / zero levels
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(7, true, 4, d, w, wt);
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.setPreset(7, true, 0, d, w, wt);
        // a valid change works and can be used
        rtp.setPreset(7, true, 2, [int24(50), 150, 0], [int24(100), 100, 0], [uint16(5_000), 5_000, 0]);
        vm.stopPrank();
        uint256 id = _open(ALICE, MARGIN);
        vm.prank(ALICE);
        rtp.createRangeOrder(id, 7, 0);
        assertEq(rtp.getOrder(id).rungCount, 2);
        // disabling it refuses new orders
        vm.prank(LEDGER);
        rtp.setPreset(7, false, 0, d, w, wt);
        uint256 id2 = _open(address(0xB0B), MARGIN);
        vm.prank(address(0xB0B));
        vm.expectRevert(RangeTakeProfit.InvalidPreset.selector);
        rtp.createRangeOrder(id2, 7, 0);
    }

    // ----------------------------------------------------------------- price conditions
    function test_25_oracleStale_refusesCreateAndFinalise() public {
        uint256 id = _open(ALICE, MARGIN);
        vm.warp(block.timestamp + 1_300); // the AVAX feed's maximum age is 1,200 s; the mock is not refreshed
        vm.prank(ALICE);
        vm.expectRevert(RangeTakeProfit.OracleUnavailable.selector);
        rtp.createRangeOrder(id, 1, 0);

        _refreshFeeds();
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickUpper + 5);
        vm.warp(vm.getBlockTimestamp() + 1_300); // (via-IR caches block.timestamp within a function: read it through the cheatcode)
        vm.prank(KEEPER);
        vm.expectRevert(RangeTakeProfit.OracleUnavailable.selector);
        rtp.finalize(id);
        // the risk path does not read a price: the owner can still cancel
        vm.prank(ALICE);
        assertTrue(rtp.unwind(id));
    }

    function test_26_poolAwayFromOracle_refusesCreate_andFinalise() public {
        uint256 id = _open(ALICE, MARGIN);
        // pool +3 %, oracle not moved: beyond the pair's 100 bp bound
        (, int24 tick) = _slot0();
        _moveTo(tick + 300);
        vm.prank(ALICE);
        vm.expectRevert(); // PoolOracleDeviation(poolPrice, oraclePrice)
        rtp.createRangeOrder(id, 1, 0);
        _syncOracleToPool();
        RangeTakeProfit.Order memory o = _create(id, 1);
        // the market trades through the band but the oracle does not follow: finalisation refuses (a pushed pool cannot finalise)
        _moveTo(o.rungs[0].tickUpper + 5);
        vm.prank(KEEPER);
        vm.expectRevert();
        rtp.finalize(id);
        // the oracle follows: finalisation goes through
        _syncOracleToPool();
        vm.prank(KEEPER);
        rtp.finalize(id);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
    }

    /// A pool pushed through a band while the ORACLE stays put cannot change a position's health: the band is valued at the oracle.
    function test_27_bandIsValuedAtTheOracle_notThePool() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        uint256 h0 = _health(id);
        (uint256 hc0, uint256 hq0) = rtp.holdings(_pos(id).account);
        _moveTo(o.rungs[0].tickUpper + 5); // pool through the band, oracle unchanged
        assertEq(_health(id), h0, "health unchanged by pushing the pool");
        (uint256 hc1, uint256 hq1) = rtp.holdings(_pos(id).account);
        assertEq(hc1, hc0);
        assertEq(hq1, hq0);
    }

    // ----------------------------------------------------------------- finalisation failure modes
    function test_30_slippageFloor_refusesAShortfall() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickUpper + 5);
        // the position manager reports 2 % less USDC principal than the liquidity maths of a crossed band
        uint256 low = o.rungs[0].quoteExpected * 98 / 100;
        vm.mockCall(PHARAOH_NFPM, abi.encodeWithSignature("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))"), abi.encode(uint256(0), low));
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(RangeTakeProfit.SlippageFloor.selector, uint8(0), low, o.rungs[0].quoteExpected * 99 / 100));
        rtp.finalize(id);
        // 0.5 % less is inside the pair's 100 bp
        vm.clearMockedCalls();
        _refreshFeeds();
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.ACTIVE));
        assertTrue(_nftExists(o.rungs[0].tokenId), "NFT untouched after the refusal");
    }

    function test_31_repayFails_orderStaysActive_nothingMoves() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickUpper + 5);
        vm.mockCallRevert(md.executor, abi.encodeWithSelector(RExecutor.rangeReturn.selector), "repay failed");
        vm.prank(KEEPER);
        vm.expectRevert();
        rtp.finalize(id);
        vm.clearMockedCalls();
        _refreshFeeds();
        // the whole finalisation reverted: order ACTIVE, rung ACTIVE, NFT still in the custodian, debt unchanged
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.ACTIVE));
        assertEq(uint8(rtp.getOrder(id).rungs[0].status), uint8(RangeTakeProfit.Status.ACTIVE));
        assertEq(INfpView(PHARAOH_NFPM).ownerOf(o.rungs[0].tokenId), address(rtp));
        assertGt(_debt(id), 0);
        // and it still finalises when the repay works
        vm.prank(KEEPER);
        rtp.finalize(id);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
    }

    function test_32_finalise_nothingActive_refuses() public {
        uint256 id = _open(ALICE, MARGIN);
        vm.prank(KEEPER);
        vm.expectRevert(RangeTakeProfit.NoActiveOrder.selector);
        rtp.finalize(id);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickUpper + 5);
        vm.prank(KEEPER);
        rtp.finalize(id);
        vm.prank(KEEPER);
        vm.expectRevert(RangeTakeProfit.NoActiveOrder.selector);
        rtp.finalize(id); // a second call
    }

    /// There is no minimum size: even one pWAVAX wei (2e8 WAVAX wei here) mints liquidity in every rung and cancels cleanly. (RangeTooSmall
    /// only fires when a rung would mint ZERO liquidity.)
    function test_33_dustPosition_worksAndCancels() public {
        uint256 id = _open(ALICE, MARGIN);
        vm.prank(ALICE);
        rtp.createRangeOrder(id, 4, 1);
        RangeTakeProfit.Order memory o = rtp.getOrder(id);
        assertEq(o.rungs[0].collateralCommitted + o.rungs[1].collateralCommitted + o.rungs[2].collateralCommitted, 200_000_000);
        assertGt(o.rungs[2].liquidity, 0);
        vm.prank(ALICE);
        assertTrue(rtp.unwind(id));
        assertEq(IERC20(WAVAX).balanceOf(address(rtp)), 0);
    }

    // ----------------------------------------------------------------- the engine hooks are custodian-only and one-shot
    function test_40_hooks_custodianOnly_oneShot() public {
        uint256 id = _open(ALICE, MARGIN);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RExecutor.ExecutorError.selector, uint8(61)));
        executor.rangeRelease(id, 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RExecutor.ExecutorError.selector, uint8(61)));
        executor.rangeReturn(id, true);
        address acct = _pos(id).account; // (precomputed: an external call in the argument list would consume the prank / expectRevert)
        vm.prank(STRANGER);
        vm.expectRevert();
        riskEngine.authorizeRangeRelease(acct, 1);
        // a second initialisation (reinitializer) by the ProxyAdmin is refused
        address admin = address(uint160(uint256(vm.load(md.executor, ADMIN_SLOT))));
        vm.prank(LEDGER);
        (bool ok,) = admin.call(
            abi.encodeWithSignature(
                "upgradeAndCall(address,address,bytes)",
                md.executor,
                _impl(md.executor),
                abi.encodeCall(RExecutor.initializeRange, (address(0xBEEF), address(0xBEEF)))
            )
        );
        assertFalse(ok);
        vm.prank(STRANGER);
        vm.expectRevert();
        executor.initializeRange(address(rtp), address(adapter2));
        assertEq(executor.rangeCustodian(), address(rtp));
        assertEq(riskEngine.rangeCustodian(), address(rtp));
        assertEq(liquidator.rangeCustodian(), address(rtp));
        assertEq(executor.orderExecutor(), address(adapter2));
    }

    function _impl(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc))));
    }

    /// The custodian the risk engine counts cannot be changed while bands are active (it would drop them from every health figure).
    function test_41_riskEngine_custodianChange_refusedWhileBandsActive() public {
        uint256 id = _open(ALICE, MARGIN);
        _create(id, 1);
        vm.startPrank(LEDGER);
        riskEngine.queueRangeCustodian(address(0));
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 24 hours + 1); // the margin config's action delay
        _refreshFeeds();
        vm.prank(LEDGER);
        vm.expectRevert(bytes("RiskEngine: active range orders"));
        riskEngine.applyRangeCustodian();
        vm.prank(ALICE);
        rtp.unwind(id);
        vm.prank(LEDGER);
        riskEngine.applyRangeCustodian();
        assertEq(riskEngine.rangeCustodian(), address(0));
    }

    // ----------------------------------------------------------------- risk paths
    /// Funded liquidation of a position whose WAVAX is in three bands: the liquidator unwinds first, so seizure finds the collateral.
    function test_50_liquidation_unwindsTheBandsFirst() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 4);
        address acct = _pos(id).account;
        assertFalse(riskEngine.isLiquidatable(acct));
        _setAvaxBps(6_400); // -36 %: the band's WAVAX is valued at the oracle and the position is below maintenance
        assertTrue(riskEngine.isLiquidatable(acct), "the bands count at the oracle: liquidatable");
        _fundOperator(OP1, 200e6);
        uint256 gas0 = gasleft();
        (bool ok, bytes memory ret) = _fundedCall(id, OP1, 200e6, 0);
        emit log_named_uint("gas liquidateFunded with a 3-rung band", gas0 - gasleft());
        assertTrue(ok, string(abi.encodePacked("funded liquidation: ", vm.toString(ret))));
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.UNWOUND), "order unwound by the liquidator");
        for (uint256 i; i < 3; ++i) {
            assertFalse(_nftExists(o.rungs[i].tokenId), "rung NFT burned");
        }
        assertEq(rtp.activeOrders(), 0);
        assertEq(IERC20(WAVAX).balanceOf(address(rtp)), 0);
        assertEq(IERC20(USDC).balanceOf(address(rtp)), 0);
        IsolatedMarginTypes.Position memory p = _pos(id);
        emit log_named_uint("position status after (2 ACTIVE, 6 LIQUIDATED)", uint8(p.status));
        assertGt(pWavax.balanceOf(OP1), 0, "the operator seized collateral");
    }

    /// The liquidator's hook cannot be used to cancel a HEALTHY position's bands: the call reverts as a whole, the band stays.
    function test_51_liquidatorCannotCancelAHealthyBand() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _fundOperator(OP1, 200e6);
        (bool ok,) = _fundedCall(id, OP1, 200e6, 0);
        assertFalse(ok, "a healthy position is not liquidated");
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.ACTIVE), "band untouched");
        assertTrue(_nftExists(o.rungs[0].tokenId));
        // and a stranger cannot call unwind directly
        vm.prank(OP1);
        vm.expectRevert(RangeTakeProfit.NotAuthorized.selector);
        rtp.unwind(id);
    }

    /// A stop-loss (an order through the close adapter) first removes the band; the normal close path then sees all the collateral.
    function test_52_stopLossThroughTheAdapter_unwindsFirst() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 4);
        (uint256 price, bool ok) = adapter2.oraclePriceE18(id);
        assertTrue(ok);
        // adapter2's "registry" is this test contract: it plays the registry's executeOrder
        uint256 gas0 = gasleft();
        adapter2.closeFor(id, ALICE, 10_000, price, 100, "");
        emit log_named_uint("gas stop-loss close with a 3-rung band", gas0 - gasleft());
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.UNWOUND));
        assertFalse(_nftExists(o.rungs[0].tokenId));
        assertEq(pUsdc.borrowBalanceCurrent(_pos(id).account), 0);
        assertEq(rtp.activeOrders(), 0);
    }

    /// Without the adapter hook the close would see no collateral: shown by closing through a plain adapter (v1, no custodian).
    function test_53_counterfactual_closeWithoutTheUnwindHook() public {
        uint256 id = _open(ALICE, MARGIN);
        _create(id, 1);
        // the owner's own close (no hook in that path): the account holds no WAVAX, so the close cannot sell it
        vm.prank(ALICE);
        (bool ok,) = address(executor).call(
            abi.encodeWithSelector(RExecutor.closePosition.selector, RExecutor.CloseParams(id, 10_000, type(uint256).max, 0, 0, "", ""))
        );
        assertFalse(ok, "an owner close while the collateral sits in a band fails (cancel the order first)");
        vm.prank(ALICE);
        rtp.unwind(id);
        vm.prank(ALICE);
        (ok,) = address(executor).call(
            abi.encodeWithSelector(RExecutor.closePosition.selector, RExecutor.CloseParams(id, 10_000, type(uint256).max, 0, 0, "", ""))
        );
        assertTrue(ok, "after the cancel the normal close works");
    }

    // ----------------------------------------------------------------- rewards (Pharaoh: PHAR + transfer-restricted xPHAR)
    /// Probe: leave a band partly in range for days and cancel it. Whatever the gauge paid is forwarded (PHAR) or recorded (xPHAR); the
    /// removal never reverts because of a reward. The amounts are LOGGED, not asserted: they depend on the gauge's emissions at the pin.
    function test_60_rewards_neverBlockTheRemoval() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 1);
        _market(o.rungs[0].tickLower + 100); // in range: the only way a band earns gauge rewards
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _refreshFeeds();
        uint256 phar0 = IERC20(PHAR).balanceOf(ALICE);
        vm.prank(ALICE);
        assertTrue(rtp.unwind(id));
        emit log_named_uint("PHAR forwarded to the owner", IERC20(PHAR).balanceOf(ALICE) - phar0);
        emit log_named_uint("xPHAR claimable by the owner", rtp.rewardClaimable(ALICE, XPHAR));
        emit log_named_uint("PHAR claimable by the owner", rtp.rewardClaimable(ALICE, PHAR));
        assertEq(IERC20(PHAR).balanceOf(address(rtp)), rtp.rewardClaimable(ALICE, PHAR));
        assertEq(IERC20(XPHAR).balanceOf(address(rtp)), rtp.rewardClaimable(ALICE, XPHAR));
        // xPHAR cannot be sent to an ordinary wallet (transfer-restricted): claiming reverts, the amount stays recorded
        if (rtp.rewardClaimable(ALICE, XPHAR) != 0) {
            vm.prank(ALICE);
            vm.expectRevert();
            rtp.claimRewards(XPHAR, ALICE);
            assertGt(rtp.rewardClaimable(ALICE, XPHAR), 0, "still recorded after the failed claim");
        }
        vm.prank(ALICE);
        vm.expectRevert(RangeTakeProfit.NothingClaimable.selector);
        rtp.claimRewards(address(0xDEAD), ALICE);
    }

    /// A reward step that reverts (the position manager's getReward) must not block the removal.
    function test_61_rewardClaimReverts_removalStillWorks() public {
        uint256 id = _open(ALICE, MARGIN);
        _create(id, 1);
        vm.mockCallRevert(PHARAOH_NFPM, abi.encodeWithSignature("getReward(uint256,address[])"), "gauge down");
        vm.prank(ALICE);
        assertTrue(rtp.unwind(id));
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.UNWOUND));
    }

    /// The xPHAR / failed-transfer ledger, exercised with stubbed balances (the live gauge paid only PHAR at the pin, test_60): the custodian's
    /// reward-token balance is mocked to rise by 5 xPHAR and 7 PHAR during the removal. xPHAR is never sent (it is transfer-restricted) and is
    /// recorded as claimable; PHAR is sent to the owner, and where that transfer fails (the custodian does not really hold it) it is recorded too.
    function test_62_rewardLedger_xPharAndFailedTransfer_recordedNotLost() public {
        uint256 id = _open(ALICE, MARGIN);
        _create(id, 1);
        uint256[] memory x = new uint256[](2);
        x[0] = 0;
        x[1] = 5e18;
        vm.mockCalls(XPHAR, abi.encodeWithSelector(IERC20.balanceOf.selector, address(rtp)), _enc(x));
        uint256[] memory p = new uint256[](2);
        p[0] = 0;
        p[1] = 7e18;
        vm.mockCalls(PHAR, abi.encodeWithSelector(IERC20.balanceOf.selector, address(rtp)), _enc(p));
        vm.prank(ALICE);
        assertTrue(rtp.unwind(id));
        vm.clearMockedCalls();
        _refreshFeeds();
        assertEq(rtp.rewardClaimable(ALICE, XPHAR), 5e18, "xPHAR recorded, never sent");
        assertEq(rtp.rewardClaimable(ALICE, PHAR), 7e18, "the PHAR transfer failed (not held): recorded, not lost");
        // the owner claims PHAR once the custodian really holds it; xPHAR cannot leave (transfer-restricted)
        deal(PHAR, address(rtp), 7e18);
        vm.prank(ALICE);
        rtp.claimRewards(PHAR, ALICE);
        assertEq(rtp.rewardClaimable(ALICE, PHAR), 0);
        assertEq(IERC20(PHAR).balanceOf(ALICE), 7e18);
        deal(XPHAR, address(rtp), 5e18);
        vm.prank(ALICE);
        vm.expectRevert();
        rtp.claimRewards(XPHAR, ALICE);
        assertEq(rtp.rewardClaimable(ALICE, XPHAR), 5e18, "a reverted claim leaves the record intact");
        // another owner cannot take it
        vm.prank(STRANGER);
        vm.expectRevert(RangeTakeProfit.NothingClaimable.selector);
        rtp.claimRewards(XPHAR, STRANGER);
    }

    function _enc(uint256[] memory v) internal pure returns (bytes[] memory out) {
        out = new bytes[](v.length);
        for (uint256 i; i < v.length; ++i) out[i] = abi.encode(v[i]);
    }

    /// DEFECT FOUND IN REVIEW (specific to the ladder; PR #7's single band always settles with `settle = true`): after rung 1 repays the
    /// debt, the position is ACTIVE and debt-FREE while rungs 2 and 3 still hold its WAVAX in the pool. Nothing in the executor's debt-free exit
    /// or full close consults the custodian, so the owner could close the position, after which `finalize` and `unwind` both revert in the
    /// executor (ExecutorError(47): the position is not ACTIVE) and the rungs' WAVAX is unreachable. Fixed in the risk-engine copy: a full
    /// close or debt-free exit is refused while any band has holdings. This test failed (the exit succeeded and `unwind` then reverted) before
    /// the guard was added.
    function test_54_ladder_afterRung1_ownerCannotExitWhileRungsRemain() public {
        uint256 id = _open(ALICE, MARGIN);
        RangeTakeProfit.Order memory o = _create(id, 4);
        _market(o.rungs[0].tickUpper + 5);
        vm.prank(KEEPER);
        rtp.finalize(id);
        assertEq(_debt(id), 0, "rung 1 repaid the debt");
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertEq(uint8(rtp.getOrder(id).status), uint8(RangeTakeProfit.Status.ACTIVE));

        vm.prank(ALICE);
        (bool ok,) = address(executor).call(abi.encodeWithSelector(RExecutor.exitDebtFreeToPTokens.selector, id, uint16(100)));
        emit log_named_uint("debt-free exit with rungs 2 and 3 active succeeded (1 = DEFECT)", ok ? 1 : 0);
        assertFalse(ok, "a debt-free exit is refused while rungs hold the position's WAVAX");
        vm.prank(ALICE);
        (ok,) = address(executor).call(
            abi.encodeWithSelector(RExecutor.closePosition.selector, RExecutor.CloseParams(id, 10_000, type(uint256).max, 0, 0, "", ""))
        );
        assertFalse(ok, "a full close is refused too");
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));

        // the rungs are reachable: cancel returns their WAVAX, and then the exit works and pays the owner
        vm.prank(ALICE);
        assertTrue(rtp.unwind(id));
        vm.prank(ALICE);
        (ok,) = address(executor).call(abi.encodeWithSelector(RExecutor.exitDebtFreeToPTokens.selector, id, uint16(100)));
        assertTrue(ok, "after the cancel the debt-free exit works");
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(IERC20(WAVAX).balanceOf(address(rtp)), 0);
    }

    /// A position that is ALREADY liquidatable cannot place bands (the check after placement, which also covers any valuation shortfall).
    function test_28_alreadyLiquidatable_createRefused() public {
        uint256 id = _open(ALICE, MARGIN);
        (, int24 tick) = _slot0();
        _market(tick - 4_470); // the market falls about 36 %: pool and oracle together, so the deviation check passes
        assertTrue(riskEngine.isLiquidatable(_pos(id).account));
        vm.prank(ALICE);
        vm.expectRevert(RangeTakeProfit.WouldBeLiquidatable.selector);
        rtp.createRangeOrder(id, 1, 0);
    }
}
