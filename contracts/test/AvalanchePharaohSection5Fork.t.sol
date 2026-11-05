// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheSection5Base.sol";

/**
 * @notice Handoff 09 section 5 checkpoint tests. Deployment, helpers and the pool mover live in
 *         `helpers/AvalancheSection5Base.sol` (the full run instructions and parameter notes are in its header).
 */
contract AvalanchePharaohSection5ForkTest is AvalancheSection5Base {
    // ================================================================= 0. deployment state
    function testDeploymentStateIsPausedAndWired() public view {
        assertTrue(controller.borrowGuardianPaused(address(pWavax)) && controller.borrowGuardianPaused(address(pUsdc)));
        assertTrue(mConfig.opensPaused());
        assertTrue(pWavax.flashLoansPaused() && pUsdc.flashLoansPaused());
        assertEq(address(controller.oracle()), address(oracle));
        assertEq(address(riskEngine.oracle()), address(oracle));
        assertEq(address(quoter.oracle()), address(oracle));
        assertEq(controller.isolatedMarginRiskHook(), address(riskEngine));
        assertEq(mConfig.routerAdapter(), address(clAdapter));
        // Plain delegates: no strategy delegate, one implementation, cash only.
        assertEq(pWavax.implementation(), pUsdc.implementation());
        assertEq(PErc20(address(pUsdc)).underlying(), USDC);
        assertEq(PErc20(address(pWavax)).underlying(), WAVAX);
    }

    function testPinnedPoolAndFeedFacts() public {
        IPharaohPoolState pool = IPharaohPoolState(PHARAOH_POOL);
        (uint160 sqrtP, int24 tick,,,, uint24 feeProtocol,) = pool.slot0();
        emit log_named_uint("pin block", block.number);
        emit log_named_uint("pool fee ppm", pool.fee());
        emit log_named_uint("pool feeProtocol", feeProtocol);
        emit log_named_int("pool tick", tick);
        emit log_named_uint("pool active liquidity", pool.liquidity());
        emit log_named_uint("pool sqrtPriceX96", sqrtP);
        emit log_named_int("pool-implied USD/AVAX (e8)", _poolAnswer8());
        emit log_named_int("Chainlink AVAX/USD (e8)", realAvaxAnswer);
        emit log_named_int("Chainlink USDC/USD (e8)", usdcAnswer);
        emit log_named_uint("WAVAX in pool (1e18)", IERC20(WAVAX).balanceOf(PHARAOH_POOL));
        emit log_named_uint("USDC in pool (1e6)", IERC20(USDC).balanceOf(PHARAOH_POOL));
        int256 dev = (_poolAnswer8() - realAvaxAnswer) * 10_000 / realAvaxAnswer;
        emit log_named_int("pool vs oracle deviation (bps)", dev);
        assertEq(pool.fee(), 490, "fee tier at pin (handoff 09 s2 says 490 ppm now)");
    }

    // ================================================================= 1. ordinary lending, both directions
    function testSupplyAndBorrowBothDirectionsAndRepay() public {
        _activateLendingBorrows();
        // Borrowing is paused until activation (checked in the deployment test); here it is live.
        // USDC against WAVAX (ALICE)
        _mintP(pWavax, ALICE, 100e18);
        _enter(ALICE);
        (uint256 err, uint256 liq,) = controller.getAccountLiquidity(ALICE);
        assertEq(err, 0);
        uint256 borrowUsdc = liq / 1e12 * 9 / 10; // 90% of capacity (liq is 1e18-scaled USD)
        (bool ok, uint256 code) = _borrow(pUsdc, ALICE, borrowUsdc);
        assertTrue(ok, "USDC against WAVAX");
        emit log_named_uint("ALICE borrowed USDC (1e6) against 100 WAVAX", borrowUsdc);
        // WAVAX against USDC (BOB)
        _mintP(pUsdc, BOB, 10_000e6);
        _enter(BOB);
        (, liq,) = controller.getAccountLiquidity(BOB);
        uint256 borrowAvax = Math.mulDiv(liq, 9, 10) * 1e8 / uint256(avaxAnswer) / 1e10 * 1e10 / 1; // ~90% of capacity
        borrowAvax = Math.mulDiv(liq * 9 / 10, 1e8, uint256(avaxAnswer)); // liq is USD1e18; AVAX 1e18 = usd*1e8/price8
        (ok, code) = _borrow(pWavax, BOB, borrowAvax);
        assertTrue(ok, "WAVAX against USDC");
        emit log_named_uint("BOB borrowed WAVAX (1e18) against 10k USDC", borrowAvax);
        // Over-borrow is refused (code != 0) and no tokens move.
        (ok, code) = _borrow(pUsdc, ALICE, borrowUsdc);
        assertFalse(ok, "second borrow must exceed capacity (market reverts or returns a controller error code)");
        emit log_named_uint("over-borrow error code (0 = market reverted)", code);
        // Interest accrues, then repay in full (repay always allowed).
        vm.roll(block.number + 100_000);
        vm.warp(block.timestamp + 100_000);
        _refreshFeeds();
        uint256 owed = pUsdc.borrowBalanceCurrent(ALICE);
        assertGt(owed, borrowUsdc, "interest accrued");
        deal(USDC, ALICE, owed);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(pUsdc), owed);
        assertEq(pUsdc.repayBorrow(type(uint256).max), 0);
        vm.stopPrank();
        assertEq(pUsdc.borrowBalanceStored(ALICE), 0);
    }

    function testBorrowIsRejectedWhilePausedAndAfterCap() public {
        _mintP(pWavax, ALICE, 100e18);
        _enter(ALICE);
        (bool ok,) = _borrow(pUsdc, ALICE, 100e6);
        assertFalse(ok, "borrow paused at deploy");
        _activateLendingBorrows();
        (ok,) = _borrow(pUsdc, ALICE, 100e6);
        assertTrue(ok);
        // borrow cap: a second borrower asks for more than the (lowered) cap allows
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 150e6; // total borrows incl. ALICE's 100e6
        controller._setMarketBorrowCaps(ps, caps);
        _mintP(pWavax, BOB, 100e18);
        _enter(BOB);
        (ok,) = _borrow(pUsdc, BOB, 100e6);
        assertFalse(ok, "borrow above the cap is rejected");
        (ok,) = _borrow(pUsdc, BOB, 40e6);
        assertTrue(ok, "borrow within the cap works");
    }

    function testOrdinaryLiquidationBothDirections() public {
        _activateLendingBorrows();
        // ALICE: WAVAX collateral, USDC debt  -> liquidatable when AVAX falls.
        _mintP(pWavax, ALICE, 100e18);
        _enter(ALICE);
        (, uint256 liq,) = controller.getAccountLiquidity(ALICE);
        uint256 aliceDebt = liq / 1e12 * 97 / 100;
        (bool ok,) = _borrow(pUsdc, ALICE, aliceDebt);
        assertTrue(ok);
        // BOB: USDC collateral, WAVAX debt -> liquidatable when AVAX rises.
        _mintP(pUsdc, BOB, 20_000e6);
        _enter(BOB);
        (, liq,) = controller.getAccountLiquidity(BOB);
        uint256 bobDebt = Math.mulDiv(liq * 97 / 100, 1e8, uint256(avaxAnswer));
        (ok,) = _borrow(pWavax, BOB, bobDebt);
        assertTrue(ok);

        // healthy: not liquidatable
        (bool lok, uint256 lcode,) = _liquidateOrdinary(pUsdc, pWavax, ALICE, aliceDebt / 4);
        assertFalse(lok, "healthy account must not be liquidatable (market reverts LiquidatePeridottrollerRejection)");

        // AVAX -15%: ALICE underwater (close factor 50%, incentive 8%)
        _setAvaxBps(8_500);
        (uint256 e1,, uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertEq(e1, 0);
        assertGt(shortfall, 0, "ALICE shortfall");
        uint256 repay = aliceDebt / 2;
        uint256 debtBefore = pUsdc.borrowBalanceCurrent(ALICE);
        // close factor 50%: repaying the whole debt in one call while underwater is refused and changes nothing
        (lok, lcode,) = _liquidateOrdinary(pUsdc, pWavax, ALICE, debtBefore);
        assertFalse(lok, "repay above close factor refused");
        _assertRejection(lastRevert, "LiquidatePeridottrollerRejection(uint256)", 17, "close factor"); // TOO_MUCH_REPAY
        assertEq(pUsdc.borrowBalanceStored(ALICE), debtBefore, "debt unchanged by the refused liquidation");
        uint256 seizedP;
        (lok, lcode, seizedP) = _liquidateOrdinary(pUsdc, pWavax, ALICE, repay);
        assertTrue(lok, "liquidate USDC debt, seize pWAVAX");
        assertLt(pUsdc.borrowBalanceStored(ALICE), debtBefore);
        // incentive: liquidator receives repay * 1.08 of collateral minus the 2.8% protocol seize share (within 0.5%)
        uint256 seizedWavax = Math.mulDiv(seizedP, pWavax.exchangeRateStored(), 1e18);
        uint256 seizedUsd6 = _wavaxUsd(seizedWavax);
        assertApproxEqRel(seizedUsd6, repay * 108 / 100 * (1e18 - 2.8e16) / 1e18, 0.005e18, "seize value = repay * 1.08 * (1 - 2.8%)");
        // AVAX +25% from pin: BOB underwater
        _setAvaxBps(12_500);
        (, , shortfall) = controller.getAccountLiquidity(BOB);
        assertGt(shortfall, 0, "BOB shortfall");
        uint256 bobRepay = pWavax.borrowBalanceCurrent(BOB) / 2;
        (lok, lcode, ) = _liquidateOrdinary(pWavax, pUsdc, BOB, bobRepay);
        assertTrue(lok, "liquidate WAVAX debt, seize pUSDC");
    }

    // ================================================================= 2. margin lifecycle through PharaohCLRouterAdapter
    function testMarginLongOpenPartialCloseFullClose() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        emit log_named_uint("LONG flash USDC (1e6)", r.flashAmount);
        emit log_named_uint("LONG open gas", r.gas);
        emit log_named_uint("LONG gross USD (1e18)", r.m.grossAssetValueUsd);
        emit log_named_uint("LONG debt USD (1e18)", r.m.debtValueUsd);
        emit log_named_uint("LONG leverageX100", r.m.leverageX100);
        emit log_named_uint("LONG healthBps", r.m.healthFactorBps);
        assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertLe(r.m.leverageX100, MAX_LEV_X100);
        assertGt(r.m.healthFactorBps, 10_000);
        // Margin account is registered in the controller: ordinary CF liquidation/seizure refused.
        assertTrue(controller.isolatedMarginAccounts(p.account));

        uint256 freeBefore = mVault.freeBalance(ALICE, address(pUsdc));
        (bool ok, bytes memory ret) = _close(ALICE, r.id, 5_000);
        assertTrue(ok, "50% close");
        ret;
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        (ok, ret) = _close(ALICE, r.id, 10_000);
        assertTrue(ok, "full close");
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(pUsdc.borrowBalanceStored(p.account), 0);
        uint256 freeAfter = mVault.freeBalance(ALICE, address(pUsdc));
        // round trip returns margin minus swap costs; report cost in bps of margin
        uint256 marginShares = p.lockedMarginPTokens;
        uint256 returned = freeAfter - freeBefore;
        emit log_named_uint("LONG margin shares locked", marginShares);
        emit log_named_uint("LONG margin shares returned", returned);
        emit log_named_uint("LONG round-trip cost bps of margin", (marginShares - Math.min(returned, marginShares)) * 10_000 / marginShares);
        assertGe(returned, marginShares * 95 / 100, "round trip costs more than 5% of margin");
    }

    function testMarginShortOpenPartialCloseFullClose() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        emit log_named_uint("SHORT flash WAVAX (1e18)", r.flashAmount);
        emit log_named_uint("SHORT open gas", r.gas);
        emit log_named_uint("SHORT gross USD (1e18)", r.m.grossAssetValueUsd);
        emit log_named_uint("SHORT debt USD (1e18)", r.m.debtValueUsd);
        emit log_named_uint("SHORT leverageX100", r.m.leverageX100);
        emit log_named_uint("SHORT healthBps", r.m.healthFactorBps);
        assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertEq(p.debtPToken, address(pWavax));
        assertLe(r.m.leverageX100, MAX_LEV_X100);
        assertGt(r.m.healthFactorBps, 10_000);

        uint256 freeBefore = mVault.freeBalance(BOB, address(pUsdc));
        (bool ok,) = _close(BOB, r.id, 5_000);
        assertTrue(ok, "50% close");
        (ok,) = _close(BOB, r.id, 10_000);
        assertTrue(ok, "full close");
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(pWavax.borrowBalanceStored(p.account), 0);
        uint256 returned = mVault.freeBalance(BOB, address(pUsdc)) - freeBefore;
        emit log_named_uint("SHORT margin shares locked", p.lockedMarginPTokens);
        emit log_named_uint("SHORT margin shares returned", returned);
        assertGe(returned, p.lockedMarginPTokens * 95 / 100, "round trip costs more than 5% of margin");
    }

    function testMarginAccountCannotBeLiquidatedThroughOrdinaryPath() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _thresholdBps(account, false);
        assertTrue(riskEngine.isLiquidatable(account));
        // precondition: by ordinary collateral-factor accounting the account IS in shortfall, so only the
        // margin flag can explain the denial
        (uint256 lerr,, uint256 shortfall) = controller.getAccountLiquidity(account);
        assertEq(lerr, 0);
        assertGt(shortfall, 0, "ordinary shortfall exists");
        (bool ok,,) = _liquidateOrdinary(pUsdc, pWavax, account, 10e6);
        assertFalse(ok, "ordinary liquidateBorrow on a margin account");
        _assertRejection(lastRevert, "LiquidatePeridottrollerRejection(uint256)", 3, "margin account"); // INSUFFICIENT_SHORTFALL
        // the dedicated liquidator still works
        uint256 debtBefore = pUsdc.borrowBalanceCurrent(account);
        liquidator.liquidate(_liqParams(r.id));
        assertLt(pUsdc.borrowBalanceStored(account), debtBefore, "dedicated liquidation repaid debt");
    }

    function testMarginLongPartialAndFullLiquidation() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        uint256 threshold = _thresholdBps(account, false);
        emit log_named_uint("LONG liquidatable once AVAX <= % of pin (bps)", threshold);
        uint256 healthBefore = riskEngine.getMetrics(account).healthFactorBps;
        uint256 rewardBefore = IERC20(USDC).balanceOf(KEEPER_RECIPIENT);
        uint256 g = gasleft();
        liquidator.liquidate(_liqParams(r.id));
        emit log_named_uint("LONG liquidation gas", g - gasleft());
        emit log_named_uint("LONG keeper reward USDC (1e6)", IERC20(USDC).balanceOf(KEEPER_RECIPIENT) - rewardBefore);
        IsolatedMarginTypes.Status st = _position(r.id).status;
        emit log_named_uint("status after first liquidation (2=ACTIVE,6=LIQUIDATED)", uint8(st));
        assertEq(uint8(st), uint8(IsolatedMarginTypes.Status.ACTIVE), "first liquidation just past threshold is partial");
        assertGt(riskEngine.getMetrics(account).healthFactorBps, healthBefore, "partial liquidation improves health");
        // push deeper (oracle-only) -> full liquidation
        _setAvaxBps(threshold > 3_000 ? threshold - 3_000 : 500);
        assertTrue(riskEngine.isLiquidatable(account));
        liquidator.liquidate(_liqParams(r.id));
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.LIQUIDATED), "fully liquidated");
        assertEq(pUsdc.borrowBalanceStored(account), 0, "no debt left");
    }

    /// @dev FINDING test. The pool's buy side is also a wall: ~USD 4.9M of USDC buys the pool's WAVAX up to about
    ///      +50%, then the price jumps (to ~+115%) because no liquidity remains (see testPoolDepthCurve). The 2x/25%
    ///      short becomes liquidatable at about +51%, just beyond that wall. With the pool pumped past it and the
    ///      oracle following the pool, the liquidation swap reverts at the router. Asserts CURRENT behaviour.
    function testFinding_ShortLiquidationFailsWhenPoolBuySideIsExhausted() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        (uint256 usd, uint256 n) = _movePoolTo(15_250, 0, 25_000e6, 400);
        emit log_named_uint("USDC spent to pump the pool (1e6)", usd);
        emit log_named_uint("pump chunks (USD 25k each)", n);
        emit log_named_int("pool-implied USD/AVAX e8 after pump", _poolAnswer8());
        emit log_named_uint("pool WAVAX left (1e18)", IERC20(WAVAX).balanceOf(PHARAOH_POOL));
        _setPrices(_poolAnswer8(), usdcAnswer);
        assertTrue(riskEngine.isLiquidatable(account), "squeeze makes the short liquidatable");
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        emit log_named_uint("short liquidation succeeded against exhausted pool (0/1)", ok ? 1 : 0);
        _logSel("revert", _selector(ret));
        assertFalse(ok, "FINDING: no buy-side liquidity left for the liquidation swap");
        assertTrue(_reasonContains(ret, "Too little received"), "cause is the router minimum-output check");
    }

    /// @dev With maintenance 40% (initial 50%) the long becomes liquidatable at about -17% and the short at about
    ///      +20%. The short threshold lies inside the pool's buy wall and its liquidation EXECUTES against the moved
    ///      pool (next test). The long threshold lies where the sell side holds only a few thousand USD, so even this
    ///      earlier trigger cannot sell a USD 10k position (FINDING, asserts current behaviour).
    function testFinding_LongLiquidationFailsAtMinus17PercentEvenWithMaint4000() public {
        maintenanceBps = 4000;
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        (uint256 usd,) = _movePoolTo(8_250, 25e18, 0, 2_000);
        _setPrices(_poolAnswer8(), usdcAnswer);
        emit log_named_uint("USD sold into the pool, valued at pin price (1e6)", usd);
        emit log_named_uint("pool price (bps of pin)", uint256(_poolAnswer8() * 10_000 / realAvaxAnswer));
        emit log_named_uint("pool USDC left (1e6)", IERC20(USDC).balanceOf(PHARAOH_POOL));
        assertTrue(riskEngine.isLiquidatable(account), "liquidatable at about -17%");
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(ok, "FINDING: the sell side cannot absorb a USD 10k long liquidation");
        assertTrue(_reasonContains(ret, "Too little received"), "cause is the router minimum-output check");
    }

    function testMovedPool_ShortLiquidation_Maint4000() public {
        maintenanceBps = 4000;
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        (uint256 usd,) = _movePoolTo(12_200, 0, 25_000e6, 400);
        _setPrices(_poolAnswer8(), usdcAnswer);
        emit log_named_uint("USDC spent pumping the pool (1e6)", usd);
        emit log_named_uint("pool price (bps of pin)", uint256(_poolAnswer8() * 10_000 / realAvaxAnswer));
        assertTrue(riskEngine.isLiquidatable(account), "liquidatable at about +20%");
        uint256 debtBefore = pWavax.borrowBalanceCurrent(account);
        uint256 g = gasleft();
        liquidator.liquidate(_liqParams(r.id));
        emit log_named_uint("liquidation gas against moved pool", g - gasleft());
        emit log_named_uint("status (2=ACTIVE,6=LIQUIDATED)", uint8(_position(r.id).status));
        assertLt(pWavax.borrowBalanceStored(account), debtBefore, "debt repaid from the moved pool");
    }

    /// @dev Oracle-only +70% shock with the real pool unchanged: the debt->margin leg would sell surplus WAVAX at the
    ///      pool's old price, below the oracle floor, so the liquidation reverts. Documented as an observation: an
    ///      oracle that LEADS the pool blocks short liquidations until the pool catches up.
    function testObservation_ShortLiquidationRevertsWhenOracleLeadsPool() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _setAvaxBps(17_000);
        assertTrue(riskEngine.isLiquidatable(account));
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        emit log_named_uint("short liquidation succeeded with oracle +70% vs unchanged pool (0/1)", ok ? 1 : 0);
        assertFalse(ok);
        assertTrue(_reasonContains(ret, "Too little received"), "oracle-leads-pool: router minimum-output check");
    }

    /// @dev Gap crash (oracle only, pool unchanged): liquidation is profitable-looking against the stale pool.
    ///      A REAL crash moves the pool too -- see testFinding_LongLiquidationFailsWhenPoolSellSideIsExhausted and the _Maint4000 moved-pool tests.
    function testGapShocksAndInsuranceDraw() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        uint256 insBefore = pUsdc.balanceOf(address(insuranceFund));
        _setAvaxBps(4_000); // -60% gap: equity gone
        assertTrue(riskEngine.isLiquidatable(account));
        IsolatedMarginTypes.AccountMetrics memory m = riskEngine.getMetrics(account);
        emit log_named_int("LONG equity USD (1e18) at -60% gap", m.equityUsd);
        liquidator.liquidate(_liqParams(r.id));
        emit log_named_uint("status (6=LIQUIDATED)", uint8(_position(r.id).status));
        emit log_named_uint("insurance pUSDC drawn", insBefore - pUsdc.balanceOf(address(insuranceFund)));
        assertEq(pUsdc.borrowBalanceStored(account), 0);
    }

    /// @dev FINDING test. The pool's sell side is a wall: ~USD 98.5k of USDC in total, price -10% after ~USD 90k and
    ///      -20% after ~USD 97k, then no liquidity (see testPoolDepthCurve). The 2x/25% long only becomes liquidatable
    ///      at about -34%, which the pool cannot reach without being emptied. Here the pool is sold to its floor, the
    ///      oracle follows, and the liquidation of a USD 10k long cannot sell its collateral. Asserts the CURRENT
    ///      behaviour so a change in depth, caps or contracts shows up as a failing test to re-evaluate.
    function testFinding_LongLiquidationFailsWhenPoolSellSideIsExhausted() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        (uint256 usd, uint256 n) = _movePoolTo(6_000, 100e18, 0, 400);
        int256 pool8 = _poolAnswer8();
        emit log_named_uint("USD of WAVAX sold into the pool (1e6)", usd);
        emit log_named_uint("sell chunks (100 WAVAX each)", n);
        emit log_named_int("pool-implied USD/AVAX e8 after crash", pool8);
        emit log_named_uint("pool USDC left (1e6)", IERC20(USDC).balanceOf(PHARAOH_POOL));
        _setPrices(pool8, usdcAnswer);
        assertTrue(riskEngine.isLiquidatable(account), "crash makes the long liquidatable");
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        emit log_named_uint("long liquidation succeeded against exhausted pool (0/1)", ok ? 1 : 0);
        _logSel("revert", _selector(ret));
        assertFalse(ok, "FINDING: no sell-side liquidity left for the liquidation swap");
        assertTrue(_reasonContains(ret, "Too little received"), "cause is the router minimum-output check");
    }

    /// @dev Depth curve of the real pool: cumulative USD traded to move the price by X, both directions.
    function testPoolDepthCurve() public {
        uint256[7] memory down = [uint256(9_900), 9_800, 9_500, 9_000, 8_000, 6_500, 5_000];
        uint256[7] memory up = [uint256(10_100), 10_200, 10_500, 11_000, 12_000, 15_000, 20_000];
        uint256 snap = vm.snapshotState();
        uint256 cumulative;
        for (uint256 i; i < down.length; ++i) {
            (uint256 usd,) = _movePoolTo(down[i], 25e18, 0, 2_000);
            cumulative += usd;
            emit log_named_uint("SELL WAVAX: price at (bps of pin)", uint256(_poolAnswer8() * 10_000 / realAvaxAnswer));
            emit log_named_uint("   cumulative USD sold (1e6)", cumulative);
        }
        emit log_named_uint("pool USDC left after sells (1e6)", IERC20(USDC).balanceOf(PHARAOH_POOL));
        vm.revertToState(snap);
        cumulative = 0;
        for (uint256 i; i < up.length; ++i) {
            (uint256 usd,) = _movePoolTo(up[i], 0, 2_500e6, 4_000);
            cumulative += usd;
            emit log_named_uint("BUY WAVAX: price at (bps of pin)", uint256(_poolAnswer8() * 10_000 / realAvaxAnswer));
            emit log_named_uint("   cumulative USD bought (1e6)", cumulative);
        }
    }

    // ================================================================= 3. stale feed + emergency price
    function testStaleFeedWithEmergencyPriceStillBlocksRiskIncreaseAndLiquidation() public {
        _activate();
        // --- state built while feeds are fresh ---
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100); // margin long, healthy
        IsolatedMarginTypes.Position memory p = _position(r.id);
        // positive control for the margin open: the same kind of open works while the feed is fresh
        _open(BOB, false, 1_000e6, MAX_LEV_X100);
        // DAVE borrows close to the limit so that the emergency price below puts DAVE deep underwater
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 480e6);
        assertTrue(ok, "pre-stale borrow works");
        uint256 daveShares = _marginPTokens(CAROL, 1_000e6); // margin for the stale open attempt below

        // --- AVAX stale (mocked feed keeps its old updatedAt), USDC still fresh (90_000 s) ---
        vm.warp(block.timestamp + AVAX_MAX_AGE + 1);
        assertEq(oracle.getPrice(WAVAX), 0, "guarded: stale AVAX -> 0");
        assertGt(oracle.getPrice(USDC), 0, "USDC feed still fresh");

        // --- owner sets an emergency price on the INNER oracle: USD 2 makes DAVE and ALICE deeply underwater ---
        inner.setEmergencyPrice(WAVAX, uint192(2e18), uint64(block.timestamp + 30 minutes));
        assertEq(inner.getPrice(WAVAX), 2e18, "inner oracle would serve the emergency price");
        assertEq(oracle.getPrice(WAVAX), 0, "guarded oracle ignores the emergency price");
        assertEq(oracle.getUnderlyingPrice(PToken(address(pWavax))), 0);

        // CONTROL: if the controller used the unguarded oracle, DAVE would be liquidatable right now and the
        // liquidation would succeed. This proves the blocks below are caused by the guard, not by account health.
        uint256 snap = vm.snapshotState();
        require(controller._setPriceOracle(PriceOracle(address(inner))) == 0, "control oracle");
        (, , uint256 controlShortfall) = controller.getAccountLiquidity(DAVE);
        assertGt(controlShortfall, 0, "control: DAVE underwater at the emergency price");
        (bool cOk,,) = _liquidateOrdinary(pUsdc, pWavax, DAVE, 100e6);
        assertTrue(cOk, "control: unguarded oracle would allow the liquidation");
        vm.revertToState(snap);

        // 1. ordinary borrows blocked, with the controller's PRICE_ERROR
        (ok,) = _borrow(pUsdc, DAVE, 1e6);
        assertFalse(ok, "stale + emergency: borrow USDC against WAVAX blocked");
        _assertRejection(lastRevert, "BorrowPeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "borrow USDC");
        (ok,) = _borrow(pWavax, DAVE, 1e18);
        assertFalse(ok, "stale + emergency: borrow WAVAX blocked");
        _assertRejection(lastRevert, "BorrowPeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "borrow WAVAX");

        // 2. margin open blocked by the missing price, not by another parameter (control above)
        (IsolatedMarginExecutorUpgradeable.OpenParams memory op,) = _openParamsFixedMin(daveShares);
        vm.prank(CAROL);
        (bool openOk, bytes memory openRet) =
            address(executor).call(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.openPosition.selector, op));
        assertFalse(openOk, "margin open blocked");
        _logSel("margin open revert", _selector(openRet));
        assertTrue(
            _selector(openRet) == IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector
                || _reasonContains(openRet, "price unavailable"),
            "margin open reverts for the missing price"
        );

        // 3. margin liquidation blocked with PriceUnavailable (ALICE's long is deeply underwater at USD 2)
        (bool lok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(lok, "margin liquidation must not run on an emergency price");
        assertEq(_selector(ret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "PriceUnavailable");

        // 4. ordinary liquidation blocked with PRICE_ERROR (DAVE is liquidatable under the control)
        (bool oOk,,) = _liquidateOrdinary(pUsdc, pWavax, DAVE, 100e6);
        assertFalse(oOk, "ordinary liquidation blocked");
        _assertRejection(lastRevert, "LiquidatePeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "ordinary liquidation");

        // 5. margin close needs prices: blocked
        (bool cok, bytes memory cret) = _close(ALICE, r.id, 10_000);
        assertFalse(cok, "close needs a trustworthy price");
        assertEq(_selector(cret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "close: PriceUnavailable");

        // --- paths that MUST keep working ---
        deal(USDC, DAVE, 600e6);
        vm.startPrank(DAVE);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        assertEq(pUsdc.repayBorrow(type(uint256).max), 0, "ordinary repay works while stale");
        vm.stopPrank();
        assertEq(pUsdc.borrowBalanceStored(DAVE), 0);
        uint256 owed = pUsdc.borrowBalanceCurrent(p.account);
        deal(USDC, ALICE, owed + 10e6);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(executor), type(uint256).max);
        executor.repayWithUnderlying(r.id, type(uint256).max);
        (uint256 retMargin, uint256 retPos,) = executor.exitDebtFreeToPTokens(r.id, 0);
        vm.stopPrank();
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertGt(retMargin + retPos, 0, "pTokens returned without a price");
        assertEq(pUsdc.borrowBalanceStored(p.account), 0);
    }

    /// @dev Open params that do not need a price to build (min output fixed), so a stale price is the only
    ///      thing that can make the open fail.
    function _openParamsFixedMin(uint256 shares)
        internal
        view
        returns (IsolatedMarginExecutorUpgradeable.OpenParams memory, uint256)
    {
        return (_paramsWithoutQuote(shares), 0);
    }

    /// @dev Guarded oracle returns 0 (never reverts, never the emergency price) for every bad round shape.
    function testGuardedOracleFailsClosedOnBadRounds() public {
        assertGt(oracle.getPrice(WAVAX), 0);
        bytes4 sel = AggregatorV3Interface.latestRoundData.selector;
        uint256 t = block.timestamp;
        // zero answer, negative answer, future updatedAt, answeredInRound < roundId, roundId 0, updatedAt 0
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(0), t, t, uint80(5)));
        assertEq(oracle.getPrice(WAVAX), 0, "zero answer");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(-1), t, t, uint80(5)));
        assertEq(oracle.getPrice(WAVAX), 0, "negative answer");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(8e8), t, t + 1, uint80(5)));
        assertEq(oracle.getPrice(WAVAX), 0, "future updatedAt");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(8e8), t, t, uint80(4)));
        assertEq(oracle.getPrice(WAVAX), 0, "answeredInRound < roundId");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(0), int256(8e8), t, t, uint80(0)));
        assertEq(oracle.getPrice(WAVAX), 0, "roundId 0");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(8e8), t, uint256(0), uint80(5)));
        assertEq(oracle.getPrice(WAVAX), 0, "updatedAt 0");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), hex"1234"); // short returndata
        assertEq(oracle.getPrice(WAVAX), 0, "malformed returndata");
        vm.mockCallRevert(AVAX_FEED, abi.encodeWithSelector(sel), "boom");
        assertEq(oracle.getPrice(WAVAX), 0, "reverting feed");
        // the emergency price never leaks through, even when the inner oracle has one
        inner.setEmergencyPrice(WAVAX, uint192(9e18), uint64(block.timestamp + 10 minutes));
        assertEq(inner.getPrice(WAVAX), 9e18);
        assertEq(oracle.getPrice(WAVAX), 0, "emergency price ignored");
        // disabled feed and unregistered asset
        inner.disableFeed(WAVAX);
        assertEq(oracle.getPrice(WAVAX), 0, "disabled feed (inner still serves the emergency price)");
        assertEq(inner.getPrice(WAVAX), 9e18);
        assertEq(oracle.getPrice(address(0x1234)), 0, "unknown asset");
        assertEq(oracle.getUnderlyingPrice(PToken(address(0x1234))), 0, "unknown market");
        // a good round is returned with the same scaling as the inner oracle
        vm.clearMockedCalls();
        inner.configureFeed(WAVAX, AVAX_FEED, 1_000_000_000);
        inner.clearEmergencyPrice(WAVAX);
        assertEq(oracle.getPrice(WAVAX), inner.getPrice(WAVAX), "same scaling as the inner oracle");
        assertEq(
            oracle.getUnderlyingPrice(PToken(address(pWavax))), inner.getUnderlyingPrice(PToken(address(pWavax)))
        );
    }

    /// @dev Mainnet controller wrapper: chain-id gate, token-with-code requirement, delegatecall through Unitroller,
    ///      and reward flywheel inert with zero speeds. NOT a deployment-script rehearsal (see the review doc).
    function testMainnetControllerWrapper_chainIdTokenAndProxy() public {
        vm.chainId(43_113);
        vm.expectRevert("AvalancheController: Avalanche only");
        new PeridottrollerAvalanche(address(peridot), false);
        vm.chainId(43_114);
        vm.expectRevert("AvalancheController: token not contract");
        new PeridottrollerAvalanche(address(0xdead), false);
        assertEq(controller.getPeridotAddress(), address(peridot), "token visible through the Unitroller proxy");
        assertEq(unitroller.admin(), address(this));
        // zero speeds: claiming is a no-op and moves nothing
        uint256 before = peridot.balanceOf(ALICE);
        _mintP(pWavax, ALICE, 1e18);
        controller.claimPeridot(ALICE);
        assertEq(peridot.balanceOf(ALICE), before, "no PERIDOT moves with zero speeds");
    }

    /// @dev Stale-feed behaviour by account class. The controller values every ENTERED market of an account when it
    ///      redeems or borrows, so a missing AVAX price blocks entered accounts (with or without debt) and never lets an
    ///      indebted account bypass its collateral check; accounts that never entered a market only hold plain supply.
    function testStaleFeed_accountClassMatrix() public {
        _activate();
        // N: supplier that never entered markets, no debt.
        uint256 nShares = _mintP(pWavax, ALICE, 10e18);
        // Z: entered both markets, zero debt.
        uint256 zShares = _mintP(pUsdc, BOB, 1_000e6);
        _enter(BOB);
        // D: entered, collateral in WAVAX AND USDC, debt in USDC only (debt in one market, collateral in both).
        _mintP(pWavax, DAVE, 100e18);
        uint256 dUsdcShares = _mintP(pUsdc, DAVE, 500e6);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 100e6);
        assertTrue(ok);
        // control while fresh: everything works
        // (redeem of a tiny amount by D must be allowed before the feed goes stale)
        vm.prank(DAVE);
        assertEq(pUsdc.redeem(dUsdcShares / 100), 0, "control: D redeem works while fresh");

        vm.warp(block.timestamp + AVAX_MAX_AGE + 1);
        inner.setEmergencyPrice(WAVAX, uint192(30e18), uint64(block.timestamp + 30 minutes));
        assertEq(oracle.getPrice(WAVAX), 0);

        // N: plain supply can leave
        vm.prank(ALICE);
        assertEq(pWavax.redeem(nShares), 0, "never-entered supplier can redeem");
        // Z: entered, zero debt: still blocked because liquidity is computed over all entered markets
        vm.prank(BOB);
        (bool zOk, bytes memory zRet) = address(pUsdc).call(abi.encodeWithSelector(PErc20.redeem.selector, zShares));
        assertFalse(zOk, "entered zero-debt account is blocked");
        _assertRejection(zRet, "RedeemPeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "Z redeem");
        // D: entered with debt: cannot redeem from either market, and cannot borrow
        vm.prank(DAVE);
        (bool dOk, bytes memory dRet) = address(pUsdc).call(abi.encodeWithSelector(PErc20.redeem.selector, dUsdcShares / 10));
        assertFalse(dOk, "indebted account must not bypass the collateral check");
        _assertRejection(dRet, "RedeemPeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "D redeem USDC");
        vm.prank(DAVE);
        (dOk, dRet) = address(pWavax).call(abi.encodeWithSelector(PErc20.redeem.selector, uint256(1e8)));
        assertFalse(dOk);
        _assertRejection(dRet, "RedeemPeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "D redeem WAVAX");
        (ok,) = _borrow(pUsdc, DAVE, 1e6);
        assertFalse(ok);
        // pToken transfers by entered accounts are blocked too
        vm.prank(DAVE);
        (bool tOk, bytes memory tRet) =
            address(pUsdc).call(abi.encodeWithSelector(PToken.transfer.selector, address(0xCAFE), uint256(1e6)));
        assertFalse(tOk, "entered account cannot transfer pTokens without a price");
        _assertRejection(tRet, "TransferPeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "D transfer");
        // repay always works
        deal(USDC, DAVE, 200e6);
        vm.startPrank(DAVE);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        assertEq(pUsdc.repayBorrow(type(uint256).max), 0, "repay works");
        vm.stopPrank();
        // after full repay D is the same as Z: still blocked while entered (exit_market needs the same valuation)
        vm.prank(DAVE);
        (dOk,) = address(pUsdc).call(abi.encodeWithSelector(PErc20.redeem.selector, dUsdcShares / 10));
        assertFalse(dOk, "debt-free but entered: still blocked");
    }

    /// @dev Every consumer of the oracle must treat 0 as 'unavailable'. Covers AVAX and USDC feed failure, scaling,
    ///      and USDC depegs. Reads each consumer (controller liquidity, borrow, liquidation maths, seize maths,
    ///      quoter, risk engine metrics, swap module) with a dead feed and checks fail-closed behaviour.
    function testOracleZeroSentinel_allConsumers() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 100e6);
        assertTrue(ok);
        for (uint256 feed; feed < 2; ++feed) {
            uint256 snap = vm.snapshotState();
            // kill ONE feed: AVAX (feed 0) or USDC (feed 1)
            vm.mockCallRevert(feed == 0 ? AVAX_FEED : USDC_FEED, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), "dead");
            assertEq(oracle.getPrice(feed == 0 ? WAVAX : USDC), 0, "guarded oracle returns the sentinel");
            // controller: liquidity query reports PRICE_ERROR instead of a number
            (uint256 err,,) = controller.getAccountLiquidity(DAVE);
            assertEq(err, PRICE_ERROR_CODE, "getAccountLiquidity price error");
            // controller seize maths refuses a zero price
            (uint256 serr,) = controller.liquidateCalculateSeizeTokens(address(pUsdc), address(pWavax), 10e6);
            assertEq(serr, PRICE_ERROR_CODE, "liquidateCalculateSeizeTokens price error");
            // borrow / liquidation / transfer blocked
            (ok,) = _borrow(pUsdc, DAVE, 1e6);
            assertFalse(ok, "borrow blocked");
            (bool lok,,) = _liquidateOrdinary(pUsdc, pWavax, DAVE, 10e6);
            assertFalse(lok, "ordinary liquidation blocked");
            // margin: metrics, quoter, liquidation, swap module all reject
            vm.expectRevert();
            riskEngine.getMetrics(account);
            vm.expectRevert();
            quoter.expectedOut(USDC, WAVAX, 1e6);
            (bool mok,) = address(liquidator)
                .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
            assertFalse(mok, "margin liquidation blocked");
            deal(USDC, address(this), 100e6);
            IERC20(USDC).approve(address(swapModule), 100e6);
            vm.expectRevert();
            swapModule.executeSwap(USDC, WAVAX, 100e6, 0, 100, 100, "");
            vm.revertToState(snap);
            _refreshFeeds();
        }
    }

    /// @dev USDC at 0.98 and 0.90: the stack must value USDC debt and collateral at the feed price, not at 1.
    function testUsdcDepeg_valuationFollowsFeed() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        IsolatedMarginTypes.AccountMetrics memory m1 = riskEngine.getMetrics(account);
        uint256 price1 = oracle.getPrice(USDC);
        _setPrices(avaxAnswer, 98_000_000);
        IsolatedMarginTypes.AccountMetrics memory m2 = riskEngine.getMetrics(account);
        assertEq(oracle.getPrice(USDC), 0.98e18, "scaled feed price");
        // USDC debt shrinks in USD terms, so a long (USDC debt, WAVAX position) gets healthier, never reverts
        assertLt(m2.debtValueUsd, m1.debtValueUsd);
        _setPrices(avaxAnswer, 90_000_000);
        IsolatedMarginTypes.AccountMetrics memory m3 = riskEngine.getMetrics(account);
        assertLt(m3.debtValueUsd, m2.debtValueUsd);
        emit log_named_uint("USDC price e18 at feed 0.9996", price1);
        emit log_named_uint("debt USD e18 at 0.9996 / 0.98 / 0.90", m1.debtValueUsd);
        emit log_named_uint("   0.98", m2.debtValueUsd);
        emit log_named_uint("   0.90", m3.debtValueUsd);
        // Decimals: controller price is 10^(36-dec): USDC (6) 1e30 scale, WAVAX (18) 1e18 scale.
        assertApproxEqRel(oracle.getUnderlyingPrice(PToken(address(pUsdc))), 0.90e30, 0.001e18);
        assertApproxEqRel(oracle.getUnderlyingPrice(PToken(address(pWavax))), uint256(avaxAnswer) * 1e10, 1e12);
    }

    function _paramsWithoutQuote(uint256 shares) internal view returns (IsolatedMarginExecutorUpgradeable.OpenParams memory) {
        return IsolatedMarginExecutorUpgradeable.OpenParams(
            address(pUsdc), address(pWavax), address(pUsdc), shares, MAX_LEV_X100, 0, 1, IsolatedMarginTypes.Side.LONG, ""
        );
    }

    // ================================================================= 4. recovery paths
    /// @dev Plain delegates have no strategy and therefore no "local borrowing reserve" (handoff 09 s3b). The
    ///      reserve-consumption property reduces to: closes and liquidations redeem from market cash and keep
    ///      working while cash is nearly exhausted by ordinary borrowers, as long as the unwind itself returns cash.
    function testLongCloseWorksWhenDebtMarketCashIsExhausted() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        _drainCash(pUsdc, pWavax);
        emit log_named_uint("pUSDC cash after drain (1e6)", pUsdc.getCash());
        (bool ok, bytes memory ret) = _close(ALICE, r.id, 10_000);
        emit log_named_uint("LONG close with exhausted pUSDC cash succeeded (0/1)", ok ? 1 : 0);
        _logSel("revert selector", _selector(ret));
        assertTrue(ok, "long close: repayment adds cash first, redeems pWAVAX");
    }

    function testShortCloseAgainstExhaustedCashAndVoluntaryEmergencyExit() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        _drainCash(pUsdc, pWavax);
        assertLe(pUsdc.getCash(), 1, "pUSDC cash exhausted");
        (bool ok, bytes memory ret) = _close(BOB, r.id, 10_000);
        assertFalse(ok, "short close needs pUSDC cash to redeem the position");
        assertEq(_selector(ret), bytes4(0x91240a1b), "cause: RedeemTransferOutNotPossible (market cash)");
        // Voluntary emergency close (handoff 09 s3b table): owner supplies the debt asset, repays all, takes pTokens.
        uint256 owed = pWavax.borrowBalanceCurrent(p.account);
        deal(WAVAX, BOB, owed + 1e18);
        vm.startPrank(BOB);
        IERC20(WAVAX).approve(address(executor), type(uint256).max);
        executor.repayWithUnderlying(r.id, type(uint256).max);
        (uint256 a, uint256 b,) = executor.exitDebtFreeToPTokens(r.id, 0);
        vm.stopPrank();
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertGt(a + b, 0, "pTokens released although the market has no cash");
        emit log_named_uint("pTokens released via debt-free exit (margin)", a);
    }

    function testShortLiquidationWithExhaustedCash() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _drainCash(pUsdc, pWavax);
        // oracle-only shock; the pool is untouched, so any revert is attributable to market cash
        _thresholdBps(account, true);
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(ok, "FINDING: short liquidation cannot redeem collateral from an empty pUSDC market");
        _logSel("revert", _selector(ret));
        // The selector is the finding; if a different cause appears (oracle floor etc.) re-evaluate.
        emit log_named_uint("selector==RedeemTransferOutNotPossible (0/1)", _selector(ret) == bytes4(0x91240a1b) ? 1 : 0);
    }

    // ================================================================= funded in-kind fallback: ACCEPTANCE (replaces the UNMET placeholder)
    // Mechanism depth (40 tests, mutation table, budgets) lives in AvalancheFundedFallbackFork.t.sol and
    // docs/deployment-handoffs/avalanche-funded-fallback.md; finite-funding stress is in AvalancheFallbackMatrixFork.t.sol.
    // These tests are the section 5 gate's acceptance checks for the route.
    address internal constant FUNDER = address(0xF00D);

    function _allowFunder(address who) internal {
        mConfig.queueFundedLiquidator(who);
        vm.warp(block.timestamp + mConfig.actionDelay());
        _refreshFeeds();
        mConfig.addFundedLiquidator(who);
    }

    function _fundFunder(address asset, uint256 amount) internal {
        deal(asset, FUNDER, amount);
        vm.prank(FUNDER);
        IERC20(asset).approve(address(liquidator), amount);
    }

    function _funded(uint256 id, uint256 maxRepay, uint256 minValueBps, address caller)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(caller);
        (ok, ret) = address(liquidator)
            .call(
                abi.encodeWithSelector(
                    IsolatedMarginLiquidatorUpgradeable.liquidateFunded.selector,
                    IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, FUNDER, maxRepay, 0, 0, minValueBps)
                )
            );
    }

    function _liqCode(bytes memory ret) internal pure returns (uint256 c) {
        require(ret.length == 36 && _selectorOf(ret) == bytes4(keccak256("LiquidationError(uint8)")), "not a LiquidationError");
        assembly { c := mload(add(ret, 36)) }
    }

    /// @dev Zero cash in the collateral market: the normal flash route cannot redeem, the funded route settles
    ///      without redemption, a swap or a flash loan; market cash is untouched.
    function testAcceptance_fallback_zeroCash_long() public {
        _activate();
        _allowFunder(FUNDER);
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _drainCash(pWavax, pUsdc); // the long's collateral market (pWAVAX) has no cash to redeem
        _thresholdBps(account, false); // oracle-only shock: the pool is unchanged
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(ok, "flash route cannot redeem from an empty market");
        assertEq(_selectorOf(ret), bytes4(0x91240a1b), "RedeemTransferOutNotPossible");
        uint256 cashBefore = pWavax.getCash();
        uint256 debtBefore = pUsdc.borrowBalanceCurrent(account);
        uint256 insBefore = pUsdc.balanceOf(address(insuranceFund)) + pWavax.balanceOf(address(insuranceFund));
        _fundFunder(USDC, 10_000e6);
        (ok, ret) = _funded(r.id, 10_000e6, 10_000, FUNDER);
        assertTrue(ok, "funded route settles with zero market cash");
        assertLt(pUsdc.borrowBalanceStored(account), debtBefore, "debt repaid with the funder's USDC");
        assertGt(pWavax.balanceOf(FUNDER), 0, "funder received position pTokens in kind");
        assertEq(pWavax.getCash(), cashBefore, "no redemption happened");
        assertEq(pUsdc.balanceOf(address(insuranceFund)) + pWavax.balanceOf(address(insuranceFund)), insBefore, "no insurance draw");
        assertEq(IERC20(USDC).balanceOf(FUNDER), 10_000e6 - (debtBefore - pUsdc.borrowBalanceStored(account)), "funder paid exactly the repay");
    }

    function testAcceptance_fallback_zeroCash_short() public {
        _activate();
        _allowFunder(FUNDER);
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _drainCash(pUsdc, pWavax);
        _thresholdBps(account, true);
        (bool ok,) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(ok, "flash route fails");
        uint256 debtBefore = pWavax.borrowBalanceCurrent(account);
        _fundFunder(WAVAX, 1_000e18);
        bytes memory ret;
        (ok, ret) = _funded(r.id, 1_000e18, 0, FUNDER);
        assertTrue(ok, "funded route settles with zero market cash");
        assertLt(pWavax.borrowBalanceStored(account), debtBefore);
        assertGt(pUsdc.balanceOf(FUNDER), 0, "funder received pUSDC in kind");
        ret;
    }

    /// @dev The sell-side wall: the flash route's swap fails at the router, the funded route does not swap.
    function testAcceptance_fallback_poolWall_long() public {
        maintenanceBps = 4000;
        _activate();
        _allowFunder(FUNDER);
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _movePoolTo(8_250, 25e18, 0, 2_000);
        _setPrices(_poolAnswer8(), usdcAnswer);
        assertTrue(riskEngine.isLiquidatable(account));
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(ok);
        assertTrue(_reasonContains(ret, "Too little received"), "normal route fails at the router");
        uint256 debtBefore = pUsdc.borrowBalanceCurrent(account);
        _fundFunder(USDC, 10_000e6);
        (ok, ret) = _funded(r.id, 10_000e6, 10_000, FUNDER); // break-even floor: position is solvent here
        assertTrue(ok, "funded route does not need the pool");
        assertLt(pUsdc.borrowBalanceStored(account), debtBefore);
    }

    /// @dev Exhausted funding reverts atomically: debt, position tokens, vault accounting and balances unchanged.
    function testAcceptance_fallback_exhaustedFunding_revertsAtomically() public {
        _activate();
        _allowFunder(FUNDER);
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        _thresholdBps(p.account, false);
        _fundFunder(USDC, 100e6); // far below the required repay
        uint256 debt = pUsdc.borrowBalanceCurrent(p.account);
        uint256 posTok = pWavax.balanceOf(p.account);
        uint256 locked = mVault.lockedBalance(ALICE, address(pUsdc));
        (bool ok,) = _funded(r.id, 100e6, 0, FUNDER);
        assertFalse(ok, "reverts when the budget cannot cover the repay");
        assertEq(pUsdc.borrowBalanceStored(p.account), debt, "debt unchanged");
        assertEq(pWavax.balanceOf(p.account), posTok, "position pTokens unchanged");
        assertEq(mVault.lockedBalance(ALICE, address(pUsdc)), locked, "vault locked margin unchanged");
        assertEq(IERC20(USDC).balanceOf(FUNDER), 100e6, "funder balance unchanged");
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        // approval smaller than the balance also reverts atomically
        deal(USDC, FUNDER, 10_000e6);
        (ok,) = _funded(r.id, 10_000e6, 0, FUNDER);
        assertFalse(ok, "allowance exhausted");
        assertEq(pUsdc.borrowBalanceStored(p.account), debt);
    }

    /// @dev Invalid prices (stale AVAX with an emergency price set on the inner oracle) revert; no caller price exists.
    function testAcceptance_fallback_invalidPrice_reverts() public {
        _activate();
        _allowFunder(FUNDER);
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        _thresholdBps(p.account, false);
        _fundFunder(USDC, 10_000e6);
        vm.warp(block.timestamp + AVAX_MAX_AGE + 1); // mocked answers are now stale
        inner.setEmergencyPrice(WAVAX, uint192(2e18), uint64(block.timestamp + 30 minutes));
        uint256 debt = pUsdc.borrowBalanceStored(p.account);
        (bool ok, bytes memory ret) = _funded(r.id, 10_000e6, 0, FUNDER);
        assertFalse(ok);
        assertEq(_selectorOf(ret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "PriceUnavailable");
        assertEq(pUsdc.borrowBalanceStored(p.account), debt);
    }

    /// @dev Authorization, repeated calls and ownership after a full funded liquidation.
    function testAcceptance_fallback_authorization_repeat_ownership() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        _setAvaxBps(5_500); // -45%: below the full-liquidation health, still solvent
        assertTrue(riskEngine.isLiquidatable(p.account));
        _fundFunder(USDC, 10_000e6);
        (bool ok, bytes memory ret) = _funded(r.id, 10_000e6, 0, FUNDER); // not allowlisted yet
        assertFalse(ok, "unauthorized caller");
        assertEq(_liqCode(ret), 27);
        _allowFunder(FUNDER);
        _setAvaxBps(5_500);
        uint256 debt = pUsdc.borrowBalanceCurrent(p.account);
        (ok, ret) = _funded(r.id, 10_000e6, 10_000, FUNDER);
        assertTrue(ok, "full funded liquidation");
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.LIQUIDATED));
        assertEq(pUsdc.borrowBalanceStored(p.account), 0, "debt fully repaid");
        assertEq(mVault.lockedBalance(ALICE, address(pUsdc)), 0, "locked margin released");
        // the funder paid exactly the debt and received at most debt x (1 + 5% bonus) of value; the borrower keeps the rest
        assertEq(IERC20(USDC).balanceOf(FUNDER), 10_000e6 - debt);
        uint256 seizedUsdc = _wavaxUsd(Math.mulDiv(pWavax.balanceOf(FUNDER), pWavax.exchangeRateStored(), 1e18));
        assertLe(seizedUsdc, debt * 10_500 / 10_000 + 2, "seizure bounded by repay x (1 + bonus)");
        assertGt(pWavax.balanceOf(ALICE), 0, "borrower surplus returned to the owner");
        // repeated call on a closed position
        (ok, ret) = _funded(r.id, 10_000e6, 0, FUNDER);
        assertFalse(ok, "repeat call reverts");
        assertEq(_liqCode(ret), 8, "position not ACTIVE");
    }

    /// @dev FINDING (independent review, corrected by test): the controller's transfer guardian pause blocks pToken
    ///      transfers, which BOTH liquidation routes rely on (the funded route transfers the seized pTokens; the flash
    ///      route returns the borrower's margin pTokens to the vault). A transfer pause therefore stops all margin
    ///      liquidations, not only the fallback. Asserts current behaviour.
    function testFinding_transferPauseStopsAllMarginLiquidations() public {
        _activate();
        _allowFunder(FUNDER);
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        _thresholdBps(p.account, false);
        _fundFunder(USDC, 10_000e6);
        controller._setTransferPaused(true);
        (bool ok, bytes memory ret) = _funded(r.id, 10_000e6, 0, FUNDER);
        assertFalse(ok, "transfer pause blocks the funded route");
        assertTrue(_reasonContains(ret, "transfer is paused"));
        (ok, ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(ok, "transfer pause also blocks the flash route");
        controller._setTransferPaused(false);
        // and both work again once unpaused
        (ok,) = _funded(r.id, 10_000e6, 0, FUNDER);
        assertTrue(ok);
    }

    // ================================================================= 5. funding and capacity measurements
    function testFundingAtCapsFlashVaultAndOpenCosts() public {
        _activate();
        // Open as large as the pair caps allow: position cap 50k USD, debt cap 25k USD -> margin ~25k USD at 2x.
        uint256 marginUsd = 24_000e6;
        OpenReport memory l = _open(ALICE, false, marginUsd, MAX_LEV_X100);
        OpenReport memory s = _open(BOB, true, marginUsd, MAX_LEV_X100);
        emit log_named_uint("margin USDC per position (1e6)", marginUsd);
        emit log_named_uint("LONG flash need (USDC 1e6)", l.flashAmount);
        emit log_named_uint("SHORT flash need (WAVAX 1e18)", s.flashAmount);
        emit log_named_uint("LONG gross USD 1e18", l.m.grossAssetValueUsd);
        emit log_named_uint("SHORT gross USD 1e18", s.m.grossAssetValueUsd);
        emit log_named_uint("LONG health bps", l.m.healthFactorBps);
        emit log_named_uint("SHORT health bps", s.m.healthFactorBps);
        emit log_named_uint("LONG leverageX100", l.m.leverageX100);
        emit log_named_uint("SHORT leverageX100", s.m.leverageX100);
        emit log_named_uint("pUSDC cash after both opens (1e6)", pUsdc.getCash());
        emit log_named_uint("pWAVAX cash after both opens (1e18)", pWavax.getCash());
        // Peak flash need must fit the funded vault, and health must hold at the caps.
        assertLe(l.flashAmount, 200_000e6, "USDC flash need within vault funding");
        assertLe(s.flashAmount, 5_000e18, "WAVAX flash need within vault funding");
        assertGt(l.m.healthFactorBps, 10_000);
        assertGt(s.m.healthFactorBps, 10_000);
        // The debt cap binds: a 26k-margin open at 2x exceeds the 25k debt cap and is refused.
        uint256 shares = _marginPTokens(CAROL, 26_000e6);
        (IsolatedMarginExecutorUpgradeable.OpenParams memory big,) = _openParams(false, shares, MAX_LEV_X100);
        vm.prank(CAROL);
        (bool capOk,) = address(executor).call(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.openPosition.selector, big));
        assertFalse(capOk, "open above the pair cap is refused");
    }

    function testFlashFeeSensitivity() public {
        _activate();
        lender.setFeeBps(9);
        OpenReport memory l = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        emit log_named_uint("LONG leverageX100 with 9 bps flash fee", l.m.leverageX100);
        emit log_named_uint("LONG health bps with 9 bps flash fee", l.m.healthFactorBps);
        assertGt(l.m.healthFactorBps, 10_000);
    }

    function _trySwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (bool ok, uint256 out)
    {
        deal(tokenIn, address(this), amountIn);
        IERC20(tokenIn).approve(address(clAdapter), amountIn);
        try clAdapter.swap(address(this), tokenIn, tokenOut, amountIn, minOut, "") returns (uint256 o) {
            return (true, o);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Capacity ladder (both directions, one-way and round trip) through the production adapter into the
    ///      REAL pool at the pin. A size that reverts is a measured limit, not a test failure.
    function testCapacityLadderAdapterBothDirections() public {
        uint256[7] memory sizes =
            [uint256(1_000e6), 5_000e6, 25_000e6, 50_000e6, 100_000e6, 250_000e6, 500_000e6];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 usd = sizes[i];
            emit log_named_uint("== ladder notional USD (1e6)", usd);
            // buy WAVAX with USDC
            uint256 oracleAvax = Math.mulDiv(usd * 1e12, 1e8, uint256(avaxAnswer));
            (bool okBuy, uint256 avaxOut) = _trySwap(USDC, WAVAX, usd, 1);
            if (okBuy) {
                uint256 buyLoss = oracleAvax > avaxOut ? (oracleAvax - avaxOut) * 10_000 / oracleAvax : 0;
                emit log_named_uint("   buy  WAVAX loss vs oracle (bps)", buyLoss);
                // sell it straight back from the post-trade pool state
                (bool okBack, uint256 usdBack) = _trySwap(WAVAX, USDC, avaxOut, 1);
                if (okBack) {
                    emit log_named_uint("   round-trip loss (bps)", usd > usdBack ? (usd - usdBack) * 10_000 / usd : 0);
                } else {
                    emit log_string("   round-trip sell leg REVERTED");
                }
            } else {
                emit log_string("   buy  WAVAX REVERTED (beyond pool depth/price limit)");
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
            // sell WAVAX for USDC (fresh pool state)
            uint256 avaxIn = Math.mulDiv(usd * 1e12, 1e8, uint256(avaxAnswer));
            uint256 oracleUsdc = Math.mulDiv(avaxIn, uint256(avaxAnswer), 1e8 * 1e12);
            (bool okSell, uint256 usdcOut) = _trySwap(WAVAX, USDC, avaxIn, 1);
            if (okSell) {
                emit log_named_uint("   sell WAVAX loss vs oracle (bps)", oracleUsdc > usdcOut ? (oracleUsdc - usdcOut) * 10_000 / oracleUsdc : 0);
            } else {
                emit log_string("   sell WAVAX REVERTED (beyond pool depth/price limit)");
            }
            vm.revertToState(snap);
        }
    }
}
