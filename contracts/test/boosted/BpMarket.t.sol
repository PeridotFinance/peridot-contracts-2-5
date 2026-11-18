// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PToken} from "../../contracts/PToken.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {PeridottrollerAvalanche} from "../../contracts/PeridottrollerAvalanche.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {PharaohVaultShareOracle} from "../../contracts/PharaohVaultShareOracle.sol";
import {PErc20Delegator} from "../../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../../contracts/InterestRateModel.sol";
import {TokenErrorReporter} from "../../contracts/ErrorReporter.sol";
import {BpBase} from "./BpBase.sol";

/// @notice Tests 2, 3, 6 and 8 of the bpPHAR-USDC list: supply/redeem/borrow-against-shares, fail-closed pricing,
///         the share market is not borrowable, CF 0 -> 50% at listing. Local stack, no fork.
contract BpMarketTest is BpBase {
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

    function test_vaultReadReverts_priceIsZero_andFailsClosedForEnteredAccounts() external {
        _borrowerWithDebt();
        _supplyShares(BOB, 100e6);
        _enter(BOB, address(bp));
        vault.setConvertReverts(true); // models the DLMM vault's totalAssets() guard revert / pause
        assertEq(_price(PToken(address(bp))), 0, "reverting convertToAssets -> 0");
        assertEq(wrapper.getShareUsdPrice(address(vault)), 0);
        assertGt(_price(PToken(address(pUsdc))), 0, "USDC itself is still priced");

        (bool ok, bytes memory ret) = _borrowUsdc(BOB, 1e6);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE, "entered account: new USDC borrow blocked");
        (ok, ret) = _redeemShares(ALICE, 1);
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE, "entered account: redeem blocked");
        (ok, ret) = _liquidate(CAROL, ALICE, 10e6);
        assertFalse(ok, "liquidation blocked while the vault read reverts");
        assertEq(_errCode(ret), ERR_PRICE);

        // an account that never entered the share market is unaffected
        _mintUnderlyingP(pWavax, DAVE(), 10e18);
        _enter(DAVE(), address(pWavax));
        (ok,) = _borrowUsdc(DAVE(), 1e6);
        assertTrue(ok, "pWAVAX-only borrower still borrows USDC");
    }

    function test_vaultAssetChangeOrZeroPrice_alsoFailClosed() external {
        vault.setAssetOverride(address(wavax));
        assertEq(_price(PToken(address(bp))), 0, "vault asset() changed");
        vault.setAssetOverride(address(0));
        assertGt(_price(PToken(address(bp))), 0);
        vault.setAssetReverts(true);
        assertEq(_price(PToken(address(bp))), 0, "vault asset() reverts");
        vault.setAssetReverts(false);
        vault.setAssetsPerWholeShare(0);
        assertEq(_price(PToken(address(bp))), 0, "pps 0");
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

    // =================================================================== 8. CF 0 at listing, then 50%
    function test_cfIsZeroAtListing_thenRaisedTo50() external {
        assertEq(_cf(address(bp)), 0, "listed with CF 0");
        _raiseCf();
        assertEq(_cf(address(bp)), CF_SHARE);
    }

    function test_setCollateralFactor_refusesWhenPriceIsZero() external {
        _staleUsdcFeed();
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), ERR_PRICE, "stale feed");
        assertEq(_cf(address(bp)), 0);
        _freshUsdcFeed();
        vault.setConvertReverts(true);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), ERR_PRICE, "vault reverts");
        vault.setConvertReverts(false);
        vault.setAssetsPerWholeShare(0);
        assertEq(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE), ERR_PRICE, "pps 0");
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

    function DAVE() internal pure returns (address) {
        return address(0xDA7E);
    }
}

/// @notice Listing order: every ceremony step is its own EOA transaction, so each prefix of the sequence is tested.
contract BpListingOrderTest is BpBase {
    function _fresh() internal returns (PErc20Delegator) {
        return new PErc20Delegator(
            address(vault),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(irm)),
            SHARE_INITIAL_EXCHANGE_RATE,
            "x",
            "x",
            8,
            payable(address(this)),
            address(bpDelegate),
            abi.encode(address(vault), MIN_VAULT_SUPPLY)
        );
    }

    function test_flashLoansOfTheShareMarket_defaultOpenUntilPaused() external {
        assertFalse(bp.flashLoansPaused(), "default: flash loans NOT paused (must be paused in the ceremony)");
        assertTrue(PErc20(address(bp))._setFlashLoansPaused(true));
        assertTrue(bp.flashLoansPaused());
    }

    function test_deployedButUnlisted_cannotBeSupplied() external {
        vault.mintShares(BOB, 1e6);
        vm.startPrank(BOB);
        vault.approve(address(bp), 1e6);
        vm.expectRevert(); // MintPeridottrollerRejection(MARKET_NOT_LISTED): the seed cannot be minted before listing
        bp.mint(1e6);
        vm.stopPrank();
    }

    function test_afterSupportOnly_oldOraclePricesTheMarketAtZero_soNothingCanBeBorrowed() external {
        require(controller._supportMarket(PErc20(address(bp))) == 0);
        // borrow not paused, cap 0 (unlimited), flash loans open, OLD oracle active
        assertFalse(controller.borrowGuardianPaused(address(bp)));
        assertEq(controller.borrowCaps(address(bp)), 0);
        vault.mintShares(BOB, 100e6);
        vm.startPrank(BOB);
        vault.approve(address(bp), 100e6);
        bp.mint(100e6); // supply is open the moment the market is listed: the seed must follow immediately
        vm.stopPrank();
        _mintUnderlyingP(pWavax, ALICE, 10e18);
        _enter(ALICE, address(pWavax));
        (bool ok, bytes memory ret) = _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.borrow.selector, 1e6));
        assertFalse(ok);
        assertEq(_errCode(ret), ERR_PRICE, "old oracle: unknown pToken -> price 0 -> borrow fails closed");
    }

    function test_wrongOrder_wrapperBeforePauseAndCap_letsAPWavaxHolderBorrowShares() external {
        require(controller._supportMarket(PErc20(address(bp))) == 0);
        _supplyShares(BOB, 100e6);
        _registerVaultInWrapper();
        require(controller._setPriceOracle(PriceOracle(address(wrapper))) == 0);
        _mintUnderlyingP(pWavax, ALICE, 10e18);
        _enter(ALICE, address(pWavax));
        (bool ok,) = _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.borrow.selector, 1e6));
        assertTrue(ok, "WRONG ORDER: the wrapper must be installed AFTER pause + cap");
    }

    function test_correctOrder_everyPrefixIsClosed() external {
        // 1 support
        require(controller._supportMarket(PErc20(address(bp))) == 0);
        // 2 pause borrow, 3 cap 1, 4 pause flash loans
        controller._setBorrowPaused(PToken(address(bp)), true);
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(bp));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1;
        controller._setMarketBorrowCaps(ps, caps);
        PErc20(address(bp))._setFlashLoansPaused(true);
        // 5 seed
        _seedPermanent(SEED);
        // 6 register + 7 swap oracle: only now is the share market priced
        _registerVaultInWrapper();
        require(controller._setPriceOracle(PriceOracle(address(wrapper))) == 0);
        _supplyShares(BOB, 100e6);
        _mintUnderlyingP(pWavax, ALICE, 10e18);
        _enter(ALICE, address(pWavax));
        (bool ok, bytes memory ret) = _try(ALICE, address(bp), abi.encodeWithSelector(PErc20.borrow.selector, 1));
        assertFalse(ok);
        assertEq(_reason(ret), "borrow is paused");
        assertGt(_price(PToken(address(bp))), 0);
    }

    /// @dev Anyone can mint into the market between support and the seed. A front-runner who poisons the empty market
    ///      (mint dust, redeem all but one pToken base unit, donate) leaves totalSupply != 0 BEFORE the seed.
    ///      The ceremony must check `totalSupply == 0 && cash == 0` immediately before the seed mint; if it fails,
    ///      abandon this pToken (it stays listed but paused, nothing of anyone's is in it).
    function test_preSeedFrontRun_isDetectableByTotalSupplyAndCash() external {
        require(controller._supportMarket(PErc20(address(bp))) == 0);
        assertEq(bp.totalSupply(), 0);
        assertEq(vault.balanceOf(address(bp)), 0);
        vault.mintShares(ATTACKER, 1_000e6);
        vm.startPrank(ATTACKER);
        vault.approve(address(bp), type(uint256).max);
        bp.mint(1);
        bp.redeem(bp.balanceOf(ATTACKER) - 1); // burns 4999 pTokens for 0 shares (rounds to zero), leaves 1 base unit
        vault.transfer(address(bp), 100e6); // donate
        vm.stopPrank();
        assertEq(bp.totalSupply(), 1, "attacker left totalSupply = 1 base unit");
        assertGt(bp.exchangeRateStored(), 1e6 * 1e18, "rate is inflated");
        // the seeder's mint is now captured: 1_000_000 shares at that rate mints ~0 pTokens
        uint256 seeded = _supplyShares(SEEDER, SEED);
        assertEq(seeded, 0, "the seed is lost to the attacker -> the ceremony must check totalSupply==0 first");
    }
}
