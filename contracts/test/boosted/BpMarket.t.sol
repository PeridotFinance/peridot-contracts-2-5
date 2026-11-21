// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PToken} from "../../contracts/PToken.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {PeridottrollerAvalanche} from "../../contracts/PeridottrollerAvalanche.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {PharaohBoostedDelegate} from "../../contracts/boosted/PharaohBoostedDelegate.sol";
import {PErc20Delegator} from "../../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../../contracts/InterestRateModel.sol";
import {TokenErrorReporter} from "../../contracts/ErrorReporter.sol";
import {BpBase} from "./BpBase.sol";

/// @notice Tests 2, 3, 6 and 8 of the bpPHAR-USDC list: supply/redeem/borrow-against-shares, fail-closed pricing,
///         the share market is not borrowable, CF 0 -> 50% at listing. Local stack, no fork.
contract BpMarketTest is BpBase {
    address internal constant FRANK = address(0xF7A);
    address internal constant DAVE = address(0xDA7E);

    function setUp() public override {
        super.setUp();
        _listShareMarket(); // CF 0, borrow paused, cap 1, flash paused, seeded, wrapper installed
    }

    function _raiseCf() internal {
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), 0, "cf 50%");
    }

    function _cf(address m) internal view returns (uint256 cf) {
        (, cf,) = controller.markets(m);
    }

    // =================================================================== 2. supply / redeem / borrow
    function test_supplyAndRedeemShares() external {
        uint256 pTokens = _supplyShares(ALICE, 100e6);
        // 6-dec share, 2e14 initial rate: 1 share base unit = 5000 pToken base units
        assertEq(pTokens, 100e6 * 5000, "pTokens minted at the initial exchange rate");
        assertEq(vault.balanceOf(address(bp)), SEED + 100e6, "market holds the shares");
        assertEq(bp.balanceOf(DEAD), SEED * 5000, "seed pTokens sit at the dead address");

        (bool ok,) = _redeemShares(ALICE, pTokens);
        assertTrue(ok, "redeem (not entered, no debt)");
        assertEq(vault.balanceOf(ALICE), 100e6, "all shares back");
        assertEq(bp.balanceOf(ALICE), 0);
        assertEq(vault.balanceOf(address(bp)), SEED, "only the permanent seed remains");
    }

    function test_enterMarkets_isAllowedWhileCfIsZero_andBorrowPowerIsZero() external {
        _supplyShares(ALICE, 400e6);
        _enter(ALICE, address(bp));
        assertTrue(controller.checkMembership(ALICE, PToken(address(bp))));
        (uint256 err, uint256 liquidity, uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertEq(err, 0);
        assertEq(liquidity, 0, "CF 0 means zero borrow power");
        assertEq(shortfall, 0);

        (bool ok, bytes memory ret) = _borrowUsdc(ALICE, 1);
        assertFalse(ok, "CF 0: even 1 base unit of USDC cannot be borrowed");
        assertEq(_selector(ret), TokenErrorReporter.BorrowPeridottrollerRejection.selector);
        assertEq(_errCode(ret), ERR_INSUFFICIENT_LIQUIDITY);
    }

    function test_borrowUsdcAgainstShares_atCf50() external {
        _raiseCf();
        _supplyShares(ALICE, 100e6); // $100 of shares
        _enter(ALICE, address(bp));
        (uint256 err, uint256 liquidity,) = controller.getAccountLiquidity(ALICE);
        assertEq(err, 0);
        assertEq(liquidity, 50e18, "50% of $100 = $50 of borrow power (1e18 USD mantissa)");

        (bool ok, bytes memory ret) = _borrowUsdc(ALICE, 50e6 + 1);
        assertFalse(ok, "one base unit over 50% fails");
        assertEq(_errCode(ret), ERR_INSUFFICIENT_LIQUIDITY);

        (ok,) = _borrowUsdc(ALICE, 50e6);
        assertTrue(ok, "exactly 50% borrows");
        assertEq(usdc.balanceOf(ALICE), 50e6);
        assertEq(pUsdc.borrowBalanceStored(ALICE), 50e6);
        (, liquidity,) = controller.getAccountLiquidity(ALICE);
        assertEq(liquidity, 0, "fully used");
    }

    function test_borrowPowerFollowsSharePrice() external {
        _raiseCf();
        _supplyShares(ALICE, 100e6);
        _enter(ALICE, address(bp));
        vault.setAssetsPerWholeShare(1.2e6); // NAV up 20%: $120 -> $60 of power
        (, uint256 liquidity,) = controller.getAccountLiquidity(ALICE);
        assertEq(liquidity, 60e18);
        vault.setAssetsPerWholeShare(0.9e6); // NAV down 10%: $90 -> $45
        (, liquidity,) = controller.getAccountLiquidity(ALICE);
        assertEq(liquidity, 45e18);
    }

    function test_borrowCap200_isStrictlyBelow_andStillApplies() external {
        _raiseCf();
        _supplyShares(ALICE, 1_000e6); // $500 borrow power: the cap, not liquidity, must bind
        _enter(ALICE, address(bp));
        assertEq(controller.borrowCaps(address(pUsdc)), USDC_BORROW_CAP);

        (bool ok, bytes memory ret) = _borrowUsdc(ALICE, 200e6);
        assertFalse(ok, "borrowing exactly the cap reverts: nextTotalBorrows < cap");
        assertEq(_reason(ret), "market borrow cap reached");

        (ok,) = _borrowUsdc(ALICE, 200e6 - 1);
        assertTrue(ok, "cap - 1 is the largest total borrow");
        (ok, ret) = _borrowUsdc(ALICE, 1);
        assertFalse(ok);
        assertEq(_reason(ret), "market borrow cap reached");
        // a second borrower cannot use the remaining headroom either
        _supplyShares(BOB, 1_000e6);
        _enter(BOB, address(bp));
        (ok, ret) = _borrowUsdc(BOB, 1);
        assertFalse(ok);
        assertEq(_reason(ret), "market borrow cap reached");
    }

    function test_cashFloor50_stillApplies() external {
        _raiseCf();
        // lift the cap (0 = unlimited) so that only the floor binds; pUSDC cash is 300
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        controller._setMarketBorrowCaps(ps, caps);
        _supplyShares(ALICE, 2_000e6); // $1000 power
        _enter(ALICE, address(bp));
        assertEq(PeridottrollerAvalanche(address(controller)).borrowCashFloor(address(pUsdc)), USDC_CASH_FLOOR);
        assertEq(pUsdc.getCash(), 300e6);

        (bool ok, bytes memory ret) = _borrowUsdc(ALICE, 250e6 + 1);
        assertFalse(ok, "would leave less than 50 USDC cash");
        assertEq(_reason(ret), "borrow cash floor");
        (ok,) = _borrowUsdc(ALICE, 250e6);
        assertTrue(ok, "leaves exactly the floor");
        (ok, ret) = _borrowUsdc(ALICE, 1);
        assertFalse(ok);
        assertEq(_reason(ret), "borrow cash floor");
        assertEq(pUsdc.getCash(), 50e6);
    }

    function test_shareSupplierCanStillRedeemUnenteredAndWhileDebtFree() external {
        _raiseCf();
        uint256 pTokens = _supplyShares(ALICE, 100e6);
        _enter(ALICE, address(bp));
        (bool ok,) = _redeemShares(ALICE, pTokens);
        assertTrue(ok, "entered but no debt: redeem works while the price is fresh");
    }

    // =================================================================== 3. fail closed
    function _borrowerWithDebt() internal {
        _raiseCf();
        _openBorrow(ALICE, 100e6, 40e6);
    }

    function test_staleFeed_priceIsZeroAndNewBorrowFailsClosed() external {
        _borrowerWithDebt();
        _supplyShares(BOB, 100e6);
        _enter(BOB, address(bp));
        _staleUsdcFeed();
        assertEq(_price(PToken(address(bp))), 0, "share price 0");
        assertEq(_price(PToken(address(pUsdc))), 0, "USDC price 0 (guarded oracle)");

        (bool ok, bytes memory ret) = _borrowUsdc(BOB, 1e6);
        assertFalse(ok, "new borrow fails closed");
        assertEq(_selector(ret), TokenErrorReporter.BorrowPeridottrollerRejection.selector);
        assertEq(_errCode(ret), ERR_PRICE);
    }

    function test_staleFeed_redeemForEnteredAccountFailsClosed_butNotForUnentered() external {
        _borrowerWithDebt();
        uint256 aliceTokens = bp.balanceOf(ALICE);
        uint256 carolTokens = _supplyShares(CAROL, 10e6); // supplied, never entered
        _staleUsdcFeed();
        (bool ok, bytes memory ret) = _redeemShares(ALICE, aliceTokens / 10);
        assertFalse(ok, "entered + debt: redeem blocked");
        assertEq(_selector(ret), TokenErrorReporter.RedeemPeridottrollerRejection.selector);
        assertEq(_errCode(ret), ERR_PRICE);
        (ok,) = _redeemShares(CAROL, carolTokens);
        assertTrue(ok, "a supplier that never entered the market is unaffected");
    }

    function test_staleFeed_liquidationFailsClosed() external {
        _borrowerWithDebt();
        vault.setAssetsPerWholeShare(0.5e6); // genuinely underwater: $50 collateral * 0.5 = $25 < $40
        (, , uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertGt(shortfall, 0, "liquidatable at a fresh price");
        _staleUsdcFeed();
        (bool ok, bytes memory ret) = _liquidate(CAROL, ALICE, 10e6);
        assertFalse(ok, "stale feed: nobody can liquidate");
        assertEq(_selector(ret), TokenErrorReporter.LiquidatePeridottrollerRejection.selector);
        assertEq(_errCode(ret), ERR_PRICE);
        _freshUsdcFeed();
        (ok,) = _liquidate(CAROL, ALICE, 10e6);
        assertTrue(ok, "liquidation works again once the feed is fresh");
    }

    /// @dev v2 (PharaohDlmmShareOracle fallback). (a) A VAULT-side outage (convertToAssets reverts, BASE USDC feed fresh) is served by the 97%
    ///      fallback for 24 h after the last poke: the share is priced at 97% of the last good leg and entered accounts keep working (full
    ///      matrix in BpStaleFallback.t.sol). (b) A stale/zero BASE USDC feed (test_staleFeed_* above) still prices the share 0 AND pUSDC 0 in
    ///      the guarded oracle: unchanged. (c) After the window the vault outage fails closed as in v1 (next test).
    function test_vaultReadReverts_servedByFallback_at97Percent_enteredAccountsKeepWorking() external {
        _borrowerWithDebt(); // ALICE: 100 shares, 40 USDC debt, CF 50%
        _supplyShares(BOB, 100e6);
        _enter(BOB, address(bp));
        vault.setConvertReverts(true); // models the DLMM vault's totalAssets() FeedInvalid revert
        assertEq(_price(PToken(address(bp))), 0.97e30, "fallback: 97% of the last good leg (1.0) x USDC $1");
        assertEq(wrapper.getShareUsdPrice(), 0.97e18);
        assertGt(_price(PToken(address(pUsdc))), 0, "USDC itself is still priced");
        (, , , bool usingFallback,) = wrapper.shareState();
        assertTrue(usingFallback);

        // BOB (entered, 100 shares): 100 * 0.97 * 50% = $48.5 of power, one base unit more is refused
        (bool ok, bytes memory ret) = _borrowUsdc(BOB, 48.5e6 + 1);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_INSUFFICIENT_LIQUIDITY, "limit is 97% of the share value");
        (ok,) = _borrowUsdc(BOB, 48.5e6);
        assertTrue(ok, "entered account borrows during the fallback");
        // ALICE (entered, debt 40): 100 * 0.97 * 0.5 = 48.5 >= 40: healthy, small redeem works, not liquidatable
        (ok,) = _redeemShares(ALICE, 1e6 * 5000);
        assertTrue(ok, "entered account with debt redeems a little inside the 97% valuation");
        (ok, ret) = _liquidate(CAROL, ALICE, 10e6);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_INSUFFICIENT_SHORTFALL, "healthy at 97%: no liquidation");

        // an account that never entered the share market is unaffected, as before
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (ok,) = _borrowUsdc(DAVE, 1e6);
        assertTrue(ok, "pWAVAX-only borrower still borrows USDC");
    }

    /// @dev v1 behaviour kept for the EXPIRED window: a vault outage older than 24 h since the last poke prices the share 0, which fails
    ///      closed for every account that entered the share market.
    function test_vaultReadReverts_afterWindow_priceIsZero_andFailsClosedForEnteredAccounts() external {
        _borrowerWithDebt();
        _supplyShares(BOB, 100e6);
        _enter(BOB, address(bp));
        vault.setConvertReverts(true);
        uint256 tExpired = wrapper.lastGoodTime() + wrapper.FALLBACK_WINDOW() + 1;
        vm.warp(tExpired);
        _pinFeeds(tExpired, 20e8); // the base feeds are fresh: ONLY the vault is down
        assertEq(_price(PToken(address(bp))), 0, "reverting convertToAssets, window over -> 0");
        assertEq(wrapper.getShareUsdPrice(), 0);
        assertGt(_price(PToken(address(pUsdc))), 0, "USDC itself is still priced");

        (bool ok, bytes memory ret) = _borrowUsdc(BOB, 1e6);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE, "entered account: new USDC borrow blocked");
        (ok, ret) = _redeemShares(ALICE, 1);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE, "entered account: redeem blocked");
        vault.setAssetsPerWholeShare(0.5e6); // (live read is down, so this only matters once the vault answers again)
        (ok, ret) = _liquidate(CAROL, ALICE, 10e6);
        assertFalse(ok, "liquidation blocked while the vault read reverts and the window is over");
        assertEq(_errCode(ret), ERR_PRICE);

        // an account that never entered the share market is unaffected
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (ok,) = _borrowUsdc(DAVE, 1e6);
        assertTrue(ok, "pWAVAX-only borrower still borrows USDC");
    }

    /// @dev Only a vault whose asset() is unreadable or different (BROKEN) is priced 0 at once. A vault that answers asset() but returns 0
    ///      from convertToAssets is an UNAVAILABLE leg: served by the fallback in v2.
    function test_vaultAssetChange_alsoFailsClosed_zeroLegIsFallback() external {
        vault.setAssetOverride(address(wavax));
        assertEq(_price(PToken(address(bp))), 0, "vault asset() changed: BROKEN, never a fallback");
        vault.setAssetOverride(address(0));
        assertGt(_price(PToken(address(bp))), 0);
        vault.setAssetReverts(true);
        assertEq(_price(PToken(address(bp))), 0, "vault asset() reverts: BROKEN, never a fallback");
        vault.setAssetReverts(false);
        vault.setAssetsPerWholeShare(0);
        assertEq(_price(PToken(address(bp))), 0.97e30, "pps 0 = leg unavailable: 97% fallback (v1: 0)");
    }

    function test_repayStillWorks_whenPriceIsZero() external {
        _borrowerWithDebt();
        _staleUsdcFeed();
        (bool ok,) = _repayUsdc(ALICE, 10e6);
        assertTrue(ok, "partial repay with stale feed");
        assertEq(pUsdc.borrowBalanceStored(ALICE), 30e6);
        vault.setConvertReverts(true);
        (ok,) = _repayUsdc(ALICE, type(uint256).max);
        assertTrue(ok, "full repay with stale feed and reverting vault");
        assertEq(pUsdc.borrowBalanceStored(ALICE), 0);
    }

    function test_mintStillWorks_whenPriceIsZero() external {
        _staleUsdcFeed();
        vault.setConvertReverts(true);
        uint256 minted = _supplyShares(BOB, 5e6);
        assertEq(minted, 5e6 * 5000);
    }

    // =================================================================== 6. the share market is NOT borrowable
    function test_shareMarketIsNotBorrowable_pausedCapOneFlashPaused() external {
        assertTrue(controller.borrowGuardianPaused(address(bp)), "borrow paused");
        assertEq(controller.borrowCaps(address(bp)), 1, "cap 1 base unit (cap 0 would mean UNLIMITED)");
        assertTrue(bp.flashLoansPaused(), "flash loans paused");
        assertEq(bp.maxFlashLoan(address(vault)), 0, "no flash liquidity");
        assertFalse(controller.mintGuardianPaused(address(bp)), "supply stays enabled");

        // a pWAVAX holder with real collateral cannot borrow shares
        _supplyShares(BOB, 100e6); // gives the market some cash
        _mintUnderlyingP(pWavax, ALICE, 10e18); // $200, CF 30% -> $60 power
        _enter(ALICE, address(pWavax));
        (, uint256 liquidity,) = controller.getAccountLiquidity(ALICE);
        assertEq(liquidity, 60e18);
        (bool ok, bytes memory ret) =
            _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.borrow.selector, 1e6));
        assertFalse(ok);
        assertEq(_reason(ret), "borrow is paused");
        (ok, ret) = _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.borrow.selector, 1));
        assertFalse(ok);
        assertEq(_reason(ret), "borrow is paused");

        // flash loan refused
        (ok, ret) = _try(
            ALICE,
            address(bp),
            abi.encodeWithSignature("flashLoan(address,address,uint256,bytes)", address(this), address(vault), 1e6, "")
        );
        assertFalse(ok);
        assertEq(_reason(ret), "FlashLoan: flash loans are paused");
    }

    function test_capOneAloneStopsBorrowing_ifThePauseWereLifted() external {
        _supplyShares(BOB, 100e6);
        _mintUnderlyingP(pWavax, ALICE, 10e18);
        _enter(ALICE, address(pWavax));
        controller._setBorrowPaused(PToken(address(bp)), false);
        (bool ok, bytes memory ret) = _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.borrow.selector, 1));
        assertFalse(ok, "cap 1: even a 1 base-unit borrow reverts");
        assertEq(_reason(ret), "market borrow cap reached");
    }

    function test_capZeroMeansUnlimited_soThePauseIsThePrimaryGuard() external {
        _supplyShares(BOB, 100e6);
        _mintUnderlyingP(pWavax, ALICE, 10e18);
        _enter(ALICE, address(pWavax));
        controller._setBorrowPaused(PToken(address(bp)), false);
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(bp));
        uint256[] memory caps = new uint256[](1);
        controller._setMarketBorrowCaps(ps, caps); // cap 0
        (bool ok,) = _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.borrow.selector, 5e6));
        assertTrue(ok, "DOCUMENTED RISK: unpaused + cap 0 lends the shares to a pWAVAX holder");
        assertEq(vault.balanceOf(ALICE), 5e6);
    }

    /// @dev CONTAGION. Entering bp costs nothing and needs no balance. v1: while the share price was unavailable (vault read reverts) every
    ///      account that entered bp was unliquidatable in ALL markets. v2: the 97% fallback prices the share for 24 h after the last poke, so
    ///      a zero-balance entrant stays liquidatable inside the window; only after the window is the v1 freeze back.
    function test_zeroBalanceEntry_vaultReadReverts_pilotDebtorsStayLiquidatable_insideWindow() external {
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (bool ok,) = _borrowUsdc(DAVE, 10e6);
        assertTrue(ok);
        _enter(DAVE, address(bp)); // zero bp balance
        vault.setConvertReverts(true);
        avaxFeed.setRound(1e8, block.timestamp, 9, 9);
        (ok,) = _liquidateSeizing(FRANK, DAVE, 2e6, address(pWavax));
        assertTrue(ok, "liquidatable while the DLMM vault read reverts (fallback window)");
        (ok,) = _repayUsdc(DAVE, 8e6);
        assertTrue(ok, "repay works");
    }

    function test_zeroBalanceEntry_vaultReadReverts_afterWindow_makesPilotDebtorsUnliquidatable() external {
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (bool ok,) = _borrowUsdc(DAVE, 10e6);
        assertTrue(ok);
        _enter(DAVE, address(bp)); // zero bp balance
        vault.setConvertReverts(true);
        uint256 tExpired = wrapper.lastGoodTime() + wrapper.FALLBACK_WINDOW() + 1;
        vm.warp(tExpired);
        _pinFeeds(tExpired, 1e8); // AVAX $1: DAVE underwater; both base feeds fresh
        (ok,) = _liquidateSeizing(FRANK, DAVE, 2e6, address(pWavax));
        assertFalse(ok, "unliquidatable once the fallback window is over and the vault read still reverts");
        assertEq(_errCode(lastRevert), ERR_PRICE);
        (ok,) = _try(DAVE, address(pWavax), abi.encodeWithSelector(PErc20.redeem.selector, 1));
        assertFalse(ok, "and cannot redeem pWAVAX either");
        (ok,) = _repayUsdc(DAVE, 10e6);
        assertTrue(ok, "repay still works");
    }

    function test_zeroBalanceEntry_afterWindow_liquidationResumesWhenTheVaultReadRecovers() external {
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (bool ok,) = _borrowUsdc(DAVE, 10e6);
        assertTrue(ok);
        _enter(DAVE, address(bp));
        vault.setConvertReverts(true);
        uint256 tExpired = wrapper.lastGoodTime() + wrapper.FALLBACK_WINDOW() + 1;
        vm.warp(tExpired);
        _pinFeeds(tExpired, 1e8);
        (ok,) = _liquidateSeizing(FRANK, DAVE, 2e6, address(pWavax));
        assertFalse(ok);
        vault.setConvertReverts(false);
        (ok,) = _liquidateSeizing(FRANK, DAVE, 2e6, address(pWavax));
        assertTrue(ok, "recovers with the vault (the live price needs no poke)");
    }

    // =================================================================== 8. CF 0 at listing, then 50%
    function test_cfIsZeroAtListing_thenRaisedTo50() external {
        assertEq(_cf(address(bp)), 0, "listed with CF 0");
        _raiseCf();
        assertEq(_cf(address(bp)), CF_SHARE);
    }

    /// @dev v2: a price of 0 is refused; a fallback price (vault leg unavailable, window valid) is a price and is accepted.
    function test_setCollateralFactor_refusesWhenPriceIsZero() external {
        _staleUsdcFeed();
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), ERR_PRICE, "stale BASE feed: price 0");
        assertEq(_cf(address(bp)), 0);
        _freshUsdcFeed();
        vault.setAssetReverts(true);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), ERR_PRICE, "vault asset() unreadable: BROKEN, price 0");
        vault.setAssetReverts(false);
        vault.setConvertReverts(true);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), 0, "vault reverts inside the window: fallback price, accepted");
        assertEq(_cf(address(bp)), CF_SHARE);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), 0), 0);
        vault.setConvertReverts(false);
        vault.setAssetsPerWholeShare(0);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), 0, "pps 0 = unavailable leg: fallback, accepted");
        assertEq(controller._setCollateralFactor(PToken(address(bp)), 0), 0);
        vault.setAssetsPerWholeShare(1e6);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), 0, "fresh and priced");
        // lowering to 0 is always possible, even while the price is unavailable (non-zero CF is the only gated value)
        _staleUsdcFeed();
        assertEq(controller._setCollateralFactor(PToken(address(bp)), 0), 0, "CF back to 0 works with price 0");
        assertEq(_cf(address(bp)), 0);
    }

    function test_setCollateralFactor_refusesWithTheOldOracleInstalled() external {
        controller._setPriceOracle(PriceOracle(address(old)));
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), ERR_PRICE, "old oracle: price 0");
    }

    function test_setCollateralFactor_aboveNinetyPercentRejected() external {
        assertEq(controller._setCollateralFactor(PToken(address(bp)), 0.91e18), 6, "INVALID_COLLATERAL_FACTOR");
    }

}

/// @notice Listing order (tools/bp-dlmm-ceremony.sh T1..T9): every ceremony step is its own EOA transaction, so each prefix of
///         the sequence is tested.
contract BpListingOrderTest is BpBase {
    address internal constant DAVE = address(0xDA7E);
    address internal constant FRANK = address(0xF7A);

    function test_flashLoansOfTheShareMarket_pausedFromBirth() external view {
        assertTrue(bp.flashLoansPaused(), "the delegate pauses flash loans in _becomeImplementation");
        assertEq(bp.maxFlashLoan(address(vault)), 0);
    }

    function test_deployedButUnlisted_cannotBeSupplied() external {
        vault.mintShares(BOB, 1e6);
        vm.startPrank(BOB);
        vault.approve(address(bp), 1e6);
        vm.expectRevert(); // SeedPending (outsider, supply 0)
        bp.mint(1e6);
        vm.stopPrank();
    }

    /// @dev DAVE borrows USDC against pWAVAX, enters bp with a ZERO balance (allowed for anyone once bp is listed), the AVAX
    ///      price collapses, FRANK tries to liquidate DAVE (seizing pWAVAX). Returns whether the liquidation went through.
    function _zeroBalanceEntryLiquidation() internal returns (bool liquidated, uint256 code) {
        uint256 snap = vm.snapshotState();
        _mintUnderlyingP(pWavax, DAVE, 10e18);
        _enter(DAVE, address(pWavax));
        (bool ok,) = _try(DAVE, address(pUsdc), abi.encodeWithSelector(PErc20.borrow.selector, 10e6));
        require(ok, "setup borrow");
        address[] memory ms = new address[](1);
        ms[0] = address(bp);
        vm.prank(DAVE);
        controller.enterMarkets(ms); // returns MARKET_NOT_LISTED (9) when bp is not listed: then nothing is entered
        avaxFeed.setRound(1e8, block.timestamp, 9, 9); // AVAX $1: DAVE is deeply underwater
        (liquidated,) = _liquidateSeizing(FRANK, DAVE, 2e6, address(pWavax));
        code = _errCode(lastRevert);
        vm.revertToState(snap);
    }

    function _bpBorrowAttempt() internal returns (bool ok, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        _mintUnderlyingP(pWavax, ALICE, 10e18);
        _enter(ALICE, address(pWavax));
        (ok, ret) = _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.borrow.selector, 1));
        vm.revertToState(snap);
    }

    function _assertClosed(string memory step) internal {
        (bool ok,) = _bpBorrowAttempt();
        assertFalse(ok, string.concat("share borrow must fail at step ", step));
        (bool liquidated, uint256 code) = _zeroBalanceEntryLiquidation();
        assertTrue(liquidated, string.concat("zero-balance entrant must stay liquidatable at step ", step, " code ", vm.toString(code)));
    }

    /// @dev ORDER A (rejected): support first, swap last. Between `_supportMarket` and the oracle swap bp is LISTED but priced 0
    ///      by the old oracle. Any account can enter it for free; the controller then returns PRICE_ERROR for that account in
    ///      every market, so a debtor who enters bp cannot be liquidated until the wrapper is installed.
    function test_orderA_supportBeforeSwap_hasAnUnpricedWindow_zeroBalanceEntryBlocksLiquidation() external {
        require(controller._supportMarket(PErc20(address(bp))) == 0);
        controller._setBorrowPaused(PToken(address(bp)), true);
        (bool liquidated, uint256 code) = _zeroBalanceEntryLiquidation();
        assertFalse(liquidated, "WINDOW: a zero-balance entrant of the unpriced listed market is unliquidatable");
        assertEq(code, ERR_PRICE);
        require(controller._setPriceOracle(PriceOracle(address(wrapper))) == 0);
        (liquidated,) = _zeroBalanceEntryLiquidation();
        assertTrue(liquidated, "window closed after the swap");
    }

    function test_orderA_listedButUnpriced_shareBorrowFailsClosed() external {
        require(controller._supportMarket(PErc20(address(bp))) == 0);
        (bool ok, bytes memory ret) = _bpBorrowAttempt();
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE, "old oracle: unknown pToken -> price 0 -> share borrow fails closed");
    }

    /// @dev ORDER B (the ceremony): T1 swap, T2 cap 1 (accepted for an unlisted pToken), T3 support, T4 pause, T5/6 seed mint by
    ///      the admin, T7 mint pause, T8 dead transfer, T9 mint unpause. After EVERY step: (a) a pWAVAX holder cannot borrow shares,
    ///      (b) a zero-balance bp entrant is still liquidatable, and while the supply is 0 (c) an outsider cannot mint.
    function test_closedOrder_swapFirst_capThenSupportPauseSeed_everyPrefixIsClosed() external {
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(bp));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1;

        _assertClosed("0 start (unlisted)");
        require(controller._setPriceOracle(PriceOracle(address(wrapper))) == 0); // T1
        assertGt(_price(PToken(address(bp))), 0, "priced while still unlisted");
        _assertClosed("T1 swapped");
        controller._setMarketBorrowCaps(ps, caps); // T2
        assertEq(controller.borrowCaps(address(bp)), 1);
        _assertClosed("T2 cap 1");
        require(controller._supportMarket(PErc20(address(bp))) == 0); // T3
        (bool ok, bytes memory ret) = _bpBorrowAttempt();
        assertFalse(ok);
        assertEq(_reason(ret), "market borrow cap reached", "listed, not yet paused: cap 1 alone stops share borrowing");
        _assertOutsiderCannotMint("T3 listed");
        _assertClosed("T3 supported");
        controller._setBorrowPaused(PToken(address(bp)), true); // T4
        (ok, ret) = _bpBorrowAttempt();
        assertEq(_reason(ret), "borrow is paused");
        _assertOutsiderCannotMint("T4 paused");
        _assertClosed("T4 paused");
        vault.mintShares(address(this), SEED); // T5 approve, T6 seed mint (admin)
        vault.approve(address(bp), SEED);
        assertEq(bp.mint(SEED), 0);
        assertEq(bp.balanceOf(address(this)), SEED * 5000);
        _assertClosed("T6 seeded");
        controller._setMintPaused(PToken(address(bp)), true); // T7
        vault.mintShares(BOB, 1e6);
        vm.startPrank(BOB);
        vault.approve(address(bp), 1e6);
        (ok, ret) = address(bp).call(abi.encodeWithSelector(PErc20.mint.selector, 1e6));
        vm.stopPrank();
        assertFalse(ok);
        assertEq(_reason(ret), "mint is paused", "T7: supply closed right after the seed");
        assertTrue(bp.transfer(DEAD, SEED * 5000)); // T8
        assertEq(bp.balanceOf(address(this)), 0, "admin keeps 0 pTokens");
        assertEq(bp.balanceOf(DEAD), SEED * 5000);
        _assertClosed("T8 dead");
        controller._setMintPaused(PToken(address(bp)), false); // T9
        _assertClosed("T9 activation");
    }

    function _assertOutsiderCannotMint(string memory step) internal {
        uint256 snap = vm.snapshotState();
        vault.mintShares(ATTACKER, 1_000e6);
        vm.startPrank(ATTACKER);
        vault.approve(address(bp), type(uint256).max);
        (bool ok, bytes memory ret) = address(bp).call(abi.encodeWithSelector(PErc20.mint.selector, 1));
        vm.stopPrank();
        assertFalse(ok, string.concat("outsider mint must revert at ", step));
        assertEq(_selector(ret), PharaohBoostedDelegate.PharaohBoosted__SeedPending.selector);
        vm.revertToState(snap);
    }

    /// @dev The classic pre-seed poisoning (mint 1 wei, redeem all but one pToken wei, donate) is impossible for an outsider:
    ///      `mint` reverts with SeedPending while the pToken supply is 0.
    function test_preSeedFrontRun_outsiderCannotMint() external {
        require(controller._supportMarket(PErc20(address(bp))) == 0);
        _assertOutsiderCannotMint("listed, unseeded");
        assertEq(bp.totalSupply(), 0);
    }

    /// @dev A direct share donation before the seed does not change what the seed mints (supply 0 => initial rate) but inflates
    ///      the post-seed rate, which the ceremony's read-back (exchangeRateStored == 2e14) detects; the dead seed owns the donation.
    function test_preSeedDonation_seedStillMintsAtInitialRate_andIsDetectableAfterwards() external {
        require(controller._supportMarket(PErc20(address(bp))) == 0);
        vault.mintShares(ATTACKER, 100e6);
        vm.prank(ATTACKER);
        vault.transfer(address(bp), 100e6);
        vault.mintShares(address(this), SEED);
        vault.approve(address(bp), SEED);
        assertEq(bp.mint(SEED), 0);
        assertEq(bp.balanceOf(address(this)), SEED * 5000, "seed minted at the INITIAL rate");
        assertGt(bp.exchangeRateStored(), SHARE_INITIAL_EXCHANGE_RATE, "post-seed rate inflated: detectable by the read-back");
        assertTrue(bp.transfer(DEAD, SEED * 5000));
        // the dead address owns the donation: it is worth ~ (100 + 1) shares
        assertEq((bp.balanceOf(DEAD) * bp.exchangeRateStored()) / 1e18, 101e6);
    }

    /// @dev Between T6 and T7 the seed guard is inert (supply > 0): an outsider mint is ordinary supply, harmless.
    function test_betweenSeedMintAndMintPause_outsiderMintIsOrdinarySupply() external {
        _listShareMarketNoSeed();
        vault.mintShares(address(this), SEED);
        vault.approve(address(bp), SEED);
        bp.mint(SEED);
        uint256 minted = _supplyShares(BOB, 5e6);
        assertEq(minted, 5e6 * 5000, "mints at the initial rate; no inflation possible");
    }

    function test_adminIsTheOnlyMinterWhileSupplyIsZero() external {
        _listShareMarketNoSeed();
        vault.mintShares(address(this), 10);
        vault.approve(address(bp), 10);
        assertEq(bp.mint(10), 0, "admin can mint first");
    }
}
