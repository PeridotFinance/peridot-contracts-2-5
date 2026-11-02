// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";

/**
 * @notice Dedicated fork fixture for CASH-ONLY lending: controller + pUSDC + pWAVAX + guarded oracle, NO margin stack, BOTH controller
 *         margin hooks UNSET (address(0)). Exercises supply, borrowing, repayment, ordinary liquidation in both directions,
 *         stale-feed / emergency-price rejection and cash exhaustion. All parameters are placeholders (operator decision 3).
 *         Nothing here signs or broadcasts; nothing here approves unpausing borrowing in any deployment.
 *
 * Run: AVALANCHE_MAINNET_RPC_URL=<archive RPC> FOUNDRY_PROFILE=debt_accounting forge test --match-contract AvalancheCashOnlyLendingForkTest \
 *      --threads 1 -vv --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
 */
contract AvalancheCashOnlyLendingForkTest is AvalancheCashOnlyBase {
    bytes4 internal constant BORROW_REJECTION = bytes4(keccak256("BorrowPeridottrollerRejection(uint256)"));

    /// @dev Interest accrues per BLOCK (`accrualBlockNumber`); the IRM assumes 31,536,000 blocks per year, so roll one block per second.
    function _advance(uint256 seconds_) internal {
        vm.roll(block.number + seconds_);
        vm.warp(block.timestamp + seconds_);
    }

    function _usd6(uint256 wavaxAmount) internal view returns (uint256) {
        return Math.mulDiv(wavaxAmount, uint256(avaxAnswer), 1e8 * 1e12);
    }

    /// @dev Underlying value (USDC base units) of `pTokens` of market `p`.
    function _valueUsd6(PErc20Delegator p, uint256 pTokens) internal view returns (uint256) {
        uint256 underlying = Math.mulDiv(pTokens, p.exchangeRateStored(), 1e18);
        return address(p) == address(pUsdc) ? underlying : _usd6(underlying);
    }

    function _assertWithin(uint256 actual, uint256 expected, uint256 bps, string memory why) internal pure {
        uint256 diff = actual > expected ? actual - expected : expected - actual;
        assertLe(diff * 10_000, expected * bps, why);
    }

    // ================================================================= fixture state
    function testFixture_NoMarginStack_HooksUnset_BorrowingPausedAtDeploy() public {
        assertEq(controller.isolatedMarginRiskHook(), address(0), "risk hook unset");
        assertEq(controller.isolatedMarginRegistrar(), address(0), "registrar unset");
        assertTrue(controller.borrowGuardianPaused(address(pWavax)) && controller.borrowGuardianPaused(address(pUsdc)), "borrowing paused");
        assertEq(address(controller.oracle()), address(oracle), "guarded oracle");
        assertEq(pWavax.implementation(), pUsdc.implementation(), "one plain delegate implementation");
        // supply works while borrowing is paused; borrowing is rejected
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 100e6);
        assertFalse(ok, "borrow rejected while paused");
        // the controller's margin hooks being unset must not break any entry point it would consult
        (uint256 err,, uint256 shortfall) = controller.getAccountLiquidity(DAVE);
        assertEq(err, 0);
        assertEq(shortfall, 0);
        // the hooks stay unset after governance unpauses borrowing
        _unpauseBorrows();
        assertEq(controller.isolatedMarginRiskHook(), address(0));
    }

    // ================================================================= supply / borrow / repay / redeem, both directions
    function testSupplyBorrowRepayRedeem_BothDirections() public {
        _unpauseBorrows();
        // --- direction 1: WAVAX collateral, USDC debt ---
        uint256 pw = _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok, uint256 code) = _borrow(pUsdc, DAVE, 480e6); // limit = 100 x 8.55 x 0.60 = about 513 USDC
        assertTrue(ok, "borrow USDC against WAVAX");
        (ok,) = _borrow(pUsdc, DAVE, 100e6);
        assertFalse(ok, "over-borrow beyond the collateral factor is denied");
        _advance(30 days);
        _setAvaxBps(10_000); // keep the feed fresh
        uint256 owed = _debt(pUsdc, DAVE);
        assertGt(owed, 480e6, "interest accrued");
        (ok, code) = _repay(pUsdc, DAVE, type(uint256).max);
        assertTrue(ok, "repay in full");
        assertEq(_debt(pUsdc, DAVE), 0, "debt cleared");
        vm.prank(DAVE);
        assertEq(pWavax.redeem(pw), 0, "collateral redeemed after repay");
        assertGe(IERC20(WAVAX).balanceOf(DAVE), 100e18 - 1, "got the WAVAX back");

        // --- direction 2: USDC collateral, WAVAX debt ---
        uint256 pu = _mintP(pUsdc, BOB, 1_000e6);
        _enter(BOB);
        (ok,) = _borrow(pWavax, BOB, 60e18); // about 513 USD of a 750 limit
        assertTrue(ok, "borrow WAVAX against USDC");
        (ok,) = _borrow(pWavax, BOB, 40e18);
        assertFalse(ok, "over-borrow denied");
        _advance(30 days);
        _setAvaxBps(10_000);
        assertGt(_debt(pWavax, BOB), 60e18, "interest accrued");
        (ok, code) = _repay(pWavax, BOB, type(uint256).max);
        assertTrue(ok, "repay WAVAX in full");
        assertEq(_debt(pWavax, BOB), 0);
        vm.prank(BOB);
        assertEq(pUsdc.redeem(pu), 0, "USDC collateral redeemed after repay");
    }

    function testRepayOnBehalf_AndSupplierWithdrawalWithDebtLimit() public {
        _unpauseBorrows();
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 480e6);
        assertTrue(ok);
        // anyone can repay on behalf; it adds cash
        uint256 cash0 = pUsdc.getCash();
        deal(USDC, ALICE, 100e6);
        vm.prank(ALICE);
        IERC20(USDC).approve(address(pUsdc), 100e6);
        (bool rok, uint256 rc) = _try(ALICE, address(pUsdc), abi.encodeWithSelector(PErc20.repayBorrowBehalf.selector, DAVE, 100e6));
        assertTrue(rok, "repay on behalf works");
        assertEq(rc, 0);
        assertEq(pUsdc.getCash(), cash0 + 100e6, "cash increased");
        // a borrower cannot withdraw collateral that backs the debt
        (ok,) = _redeemUnderlying(pWavax, DAVE, 100e18);
        assertFalse(ok, "collateral backing debt cannot be withdrawn in full");
    }

    // ================================================================= ordinary liquidation, both directions
    function testOrdinaryLiquidation_BothDirections() public {
        _unpauseBorrows();
        // ---------------- direction 1: WAVAX collateral, USDC debt, AVAX falls ----------------
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 480e6);
        assertTrue(ok);
        (bool lok, uint256 lcode, uint256 seized) = _liquidate(pUsdc, pWavax, DAVE, 100e6);
        assertFalse(lok, "healthy account cannot be liquidated");
        assertEq(seized, 0);
        assertEq(lcode, INSUFFICIENT_SHORTFALL_CODE, "INSUFFICIENT_SHORTFALL");
        _setAvaxBps(6_600);
        (, , uint256 shortfall) = controller.getAccountLiquidity(DAVE);
        assertGt(shortfall, 0, "underwater after AVAX -34%");
        (lok, lcode,) = _liquidate(pUsdc, pWavax, DAVE, 400e6); // 400 > 50% close factor of 480
        assertFalse(lok, "over-repay beyond the close factor refused");
        assertEq(lcode, TOO_MUCH_REPAY_CODE, "TOO_MUCH_REPAY");
        uint256 debt0 = _debt(pUsdc, DAVE);
        (lok, lcode, seized) = _liquidate(pUsdc, pWavax, DAVE, 200e6);
        assertTrue(lok, "liquidation succeeds");
        assertLt(_debt(pUsdc, DAVE), debt0, "debt reduced");
        assertApproxEqAbs(debt0 - _debt(pUsdc, DAVE), 200e6, 2, "repaid amount");
        // liquidator nets repay x 1.08 x (1 - 2.8% protocol share) of collateral value
        _assertWithin(_valueUsd6(pWavax, seized), Math.mulDiv(200e6, 108 * 972, 100 * 1000), 100, "seized value = repay x 1.08 x 0.972 within 1%");

        // ---------------- direction 2: USDC collateral, WAVAX debt, AVAX rises ----------------
        _setAvaxBps(10_000);
        _mintP(pUsdc, BOB, 1_000e6);
        _enter(BOB);
        (ok,) = _borrow(pWavax, BOB, 80e18); // about 684 USD of a 750 limit
        assertTrue(ok);
        (lok,,) = _liquidate(pWavax, pUsdc, BOB, 10e18);
        assertFalse(lok, "healthy account cannot be liquidated");
        _setAvaxBps(12_000);
        (, , shortfall) = controller.getAccountLiquidity(BOB);
        assertGt(shortfall, 0, "underwater after AVAX +20%");
        (lok, lcode,) = _liquidate(pWavax, pUsdc, BOB, 60e18);
        assertFalse(lok, "over-repay beyond the close factor refused");
        assertEq(lcode, TOO_MUCH_REPAY_CODE);
        uint256 wdebt0 = _debt(pWavax, BOB);
        (lok, lcode, seized) = _liquidate(pWavax, pUsdc, BOB, 30e18);
        assertTrue(lok, "liquidation succeeds");
        assertApproxEqAbs(wdebt0 - _debt(pWavax, BOB), 30e18, 1e9, "repaid amount");
        _assertWithin(_valueUsd6(pUsdc, seized), Math.mulDiv(_usd6(30e18), 108 * 972, 100 * 1000), 100, "seized value = repay x 1.08 x 0.972 within 1%");
    }

    // ================================================================= stale feed + emergency price
    function testStaleFeed_EmergencyPrice_RejectsBorrowAndLiquidation_RepayStillWorks() public {
        _unpauseBorrows();
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 480e6);
        assertTrue(ok, "pre-stale borrow works");
        _mintP(pUsdc, ALICE, 1_000e6); // supplier that entered markets, no debt
        _enter(ALICE);
        _mintP(pWavax, BOB, 50e18);
        _enter(BOB);

        // AVAX stale (real feed, no mock; USDC feed still fresh within 90,000 s)
        vm.warp(block.timestamp + AVAX_MAX_AGE + 1);
        assertEq(oracle.getPrice(WAVAX), 0, "guarded oracle: stale AVAX -> 0");
        assertGt(oracle.getPrice(USDC), 0, "USDC feed still fresh");
        // the owner sets an emergency price on the INNER oracle that would put DAVE deeply underwater
        inner.setEmergencyPrice(WAVAX, uint192(2e18), uint64(block.timestamp + 30 minutes));
        assertEq(inner.getPrice(WAVAX), 2e18, "inner oracle would serve the emergency price");
        assertEq(oracle.getPrice(WAVAX), 0, "guarded oracle ignores it");

        // CONTROL: with the unguarded oracle the account is underwater and an ordinary liquidation would succeed
        uint256 snap = vm.snapshotState();
        require(controller._setPriceOracle(PriceOracle(address(inner))) == 0, "control oracle");
        (, , uint256 controlShortfall) = controller.getAccountLiquidity(DAVE);
        assertGt(controlShortfall, 0, "control: underwater at the emergency price");
        (bool cOk,,) = _liquidate(pUsdc, pWavax, DAVE, 100e6);
        assertTrue(cOk, "control: unguarded oracle would allow the liquidation");
        vm.revertToState(snap);

        // 1. borrowing blocked, both directions, with PRICE_ERROR
        (ok,) = _borrow(pUsdc, BOB, 1e6);
        assertFalse(ok, "borrow USDC against WAVAX blocked");
        assertEq(_selector(lastRevert), BORROW_REJECTION, "borrow rejection selector");
        assertEq(_revertCode(lastRevert), PRICE_ERROR_CODE, "PRICE_ERROR");
        (ok,) = _borrow(pWavax, ALICE, 1e18);
        assertFalse(ok, "borrow WAVAX against USDC blocked");
        assertEq(_revertCode(lastRevert), PRICE_ERROR_CODE);
        // 2. ordinary liquidation blocked: no seize, no debt change
        uint256 debt0 = _debt(pUsdc, DAVE);
        (bool lok, uint256 lcode, uint256 seized) = _liquidate(pUsdc, pWavax, DAVE, 100e6);
        assertFalse(lok, "liquidation must not run on an emergency price");
        assertEq(seized, 0, "nothing seized");
        assertEq(_debt(pUsdc, DAVE), debt0, "debt unchanged");
        assertTrue(lcode == PRICE_ERROR_CODE || _revertCode(lastRevert) == PRICE_ERROR_CODE, "PRICE_ERROR");
        // 3. an entered supplier cannot withdraw during the outage (documented availability cost); repay still works
        (ok,) = _redeemUnderlying(pUsdc, ALICE, 100e6);
        assertFalse(ok, "entered supplier cannot redeem while the feed is stale");
        (ok,) = _repay(pUsdc, DAVE, 50e6);
        assertTrue(ok, "repay always works");
        assertLt(_debt(pUsdc, DAVE), debt0, "repay reduced the debt");
        // 4. recovery: a fresh round restores everything
        _setAvaxBps(10_000);
        (ok,) = _redeemUnderlying(pUsdc, ALICE, 100e6);
        assertTrue(ok, "after a fresh round the supplier can redeem");
    }

    // ================================================================= cash exhaustion
    function _drainUsdcCash() internal returns (uint256 drained) {
        address whale = address(0xDEAD0001);
        _mintP(pWavax, whale, 80_000e18); // about 684k USD of collateral at CF 60%: enough to borrow all pUSDC cash
        _enter(whale);
        uint256 target = pUsdc.getCash() - 1;
        (bool ok,) = _borrow(pUsdc, whale, target);
        require(ok, "drain borrow failed");
        drained = target;
    }

    function testCashExhaustion_WithdrawalsLimitedByCash_RepayAndLiquidationStillWork() public {
        _unpauseBorrows();
        // positions that exist before the drain
        _mintP(pWavax, DAVE, 100e18); // USDC debt, WAVAX collateral
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 480e6);
        assertTrue(ok);
        _mintP(pUsdc, BOB, 1_000e6); // WAVAX debt, USDC collateral
        _enter(BOB);
        (ok,) = _borrow(pWavax, BOB, 80e18);
        assertTrue(ok);

        uint256 drained = _drainUsdcCash();
        assertLe(pUsdc.getCash(), 1, "pUSDC cash exhausted");
        // supplier withdrawals are limited by available cash (not by any other rule)
        (ok,) = _redeemUnderlying(pUsdc, LP, 1_000e6);
        assertFalse(ok, "supplier cannot withdraw USDC that is lent out");
        uint256 lpTokens = pUsdc.balanceOf(LP);
        (bool rok,) = _try(LP, address(pUsdc), abi.encodeWithSelector(PErc20.redeem.selector, lpTokens));
        assertFalse(rok, "full redeem fails (error code or revert), nothing moves");
        assertEq(IERC20(USDC).balanceOf(LP), 0);
        // repayment is never blocked and creates cash
        (ok,) = _repay(pUsdc, DAVE, 100e6);
        assertTrue(ok, "repay works with zero market cash");
        assertGe(pUsdc.getCash(), 100e6 - 1, "repay added cash");
        // a supplier can now withdraw exactly what is available
        (ok,) = _redeemUnderlying(pUsdc, LP, 90e6);
        assertTrue(ok, "withdrawal up to the available cash works");
        (ok,) = _redeemUnderlying(pUsdc, LP, 100e6);
        assertFalse(ok, "and not beyond it");

        // ordinary liquidation does not need market cash: direction 1 repays USDC and seizes pWAVAX
        _setAvaxBps(6_600);
        (bool lok,, uint256 seized) = _liquidate(pUsdc, pWavax, DAVE, 150e6);
        assertTrue(lok, "liquidation of the USDC borrower works with (nearly) zero pUSDC cash");
        assertGt(seized, 0);
        // direction 2 seizes pUSDC: it works, but the seized pUSDC is NOT redeemable while pUSDC cash is exhausted
        _setAvaxBps(12_000);
        uint256 cashBefore = pUsdc.getCash();
        (lok,, seized) = _liquidate(pWavax, pUsdc, BOB, 30e18);
        assertTrue(lok, "liquidation of the WAVAX borrower works");
        assertGt(seized, 0);
        uint256 want = _valueUsd6(pUsdc, seized);
        assertGt(want, cashBefore, "the liquidator's seized USDC claim exceeds the market cash: it is a claim, not cash");
        (ok,) = _redeemUnderlying(pUsdc, CAROL, want);
        assertFalse(ok, "seized pUSDC cannot be redeemed beyond market cash");
        drained;
    }
}
