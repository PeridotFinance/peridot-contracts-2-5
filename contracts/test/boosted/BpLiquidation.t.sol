// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PToken} from "../../contracts/PToken.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {TokenErrorReporter} from "../../contracts/ErrorReporter.sol";
import {BpBase} from "./BpBase.sol";

/// @notice Test 4: liquidation of USDC debt backed by bpPHAR-USDC (6-dec shares, 8-dec pTokens, incentive 108%,
///         close factor 50%, protocol seize share 2.8%). The liquidator repays USDC, receives bpPHAR pTokens and KEEPS them.
contract BpLiquidationTest is BpBase {
    function setUp() public override {
        super.setUp();
        _listShareMarket();
        require(controller._setCollateralFactor(PToken(address(bp)), CF_SHARE) == 0);
    }

    /// @dev Independent re-derivation of Peridottroller.liquidateCalculateSeizeTokens (Exp fixed-point, 1e18 scale).
    function _expectedSeize(uint256 repay, uint256 priceBorrowed, uint256 priceCollateral, uint256 rate)
        internal
        pure
        returns (uint256)
    {
        uint256 numerator = (INCENTIVE * priceBorrowed) / 1e18;
        uint256 denominator = (priceCollateral * rate) / 1e18;
        uint256 ratio = (numerator * 1e18) / denominator;
        return (ratio * repay) / 1e18;
    }

    /// @dev ALICE: 100 shares supplied, 50 USDC borrowed (the 50% maximum).
    function _aliceAtMax() internal {
        _openBorrow(ALICE, 100e6, 50e6);
    }

    function test_liquidation_exactSeizeMath_sixDecShares_eightDecPTokens() external {
        _aliceAtMax();
        assertEq(bp.balanceOf(ALICE), 100e6 * 5000, "5e11 pTokens");
        assertEq(bp.exchangeRateStored(), 2e14, "rate is exactly the initial rate (cash == supply * rate)");
        (, , uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertEq(shortfall, 0, "healthy at max borrow");
        assertEq(pUsdc.borrowBalanceStored(ALICE), 50e6);

        vault.setAssetsPerWholeShare(0.8e6); // NAV -20%: $80 * 50% = $40 < $50 debt
        uint256 priceShare = _price(PToken(address(bp)));
        uint256 priceUsdc = _price(PToken(address(pUsdc)));
        assertEq(priceShare, 0.8e30, "share price 0.8 USD, 6-dec scaling");
        assertEq(priceUsdc, 1e30);
        (, , shortfall) = controller.getAccountLiquidity(ALICE);
        assertEq(shortfall, 10e18, "shortfall $10 in 1e18 USD");

        uint256 repay = 25e6; // close factor 50% of 50e6
        uint256 expectedSeize = _expectedSeize(repay, priceUsdc, priceShare, bp.exchangeRateStored());
        assertEq(expectedSeize, 168_750_000_000, "25 USDC * 1.08 / 0.8 = 33.75 shares = 1.6875e11 pTokens");
        (uint256 err, uint256 seizeFromController) =
            controller.liquidateCalculateSeizeTokens(address(pUsdc), address(bp), repay);
        assertEq(err, 0);
        assertEq(seizeFromController, expectedSeize, "controller agrees with the independent formula");

        uint256 protocolTokens = (expectedSeize * PROTOCOL_SEIZE_SHARE) / 1e18;
        assertEq(protocolTokens, 4_725_000_000, "2.8% of the seize");
        uint256 liquidatorTokens = expectedSeize - protocolTokens;
        uint256 reservesBefore = bp.totalReserves();
        uint256 supplyBefore = bp.totalSupply();
        uint256 borrowerBefore = bp.balanceOf(ALICE);
        uint256 usdcBefore = usdc.balanceOf(CAROL);

        (bool ok, bytes memory ret) = _liquidate(CAROL, ALICE, repay);
        assertTrue(ok, string(abi.encodePacked("liquidate: ", _reason(ret))));

        assertEq(usdc.balanceOf(CAROL), usdcBefore + repay - repay, "liquidator paid exactly the repay (minted just before)");
        assertEq(pUsdc.borrowBalanceStored(ALICE), 25e6, "borrower debt down by the repay");
        assertEq(bp.balanceOf(CAROL), liquidatorTokens, "liquidator holds 97.2% of the seized pTokens");
        assertEq(bp.balanceOf(ALICE), borrowerBefore - expectedSeize, "borrower lost the full seize");
        assertEq(bp.totalSupply(), supplyBefore - protocolTokens, "protocol part of the pTokens is burned");
        uint256 protocolShares = (protocolTokens * 2e14) / 1e18;
        assertEq(protocolShares, 945_000, "0.945 share goes to reserves");
        assertEq(bp.totalReserves(), reservesBefore + protocolShares, "reserves (denominated in vault SHARES) up");
        // shares themselves did not move: seize only moves pTokens
        assertEq(vault.balanceOf(address(bp)), SEED + 100e6);

        // KEEPS: the liquidator holds pTokens and can redeem them for vault shares (no entered position -> no check)
        assertEq(vault.balanceOf(CAROL), 0);
        (ok,) = _redeemShares(CAROL, liquidatorTokens);
        assertTrue(ok, "liquidator redeems the seized pTokens");
        assertEq(vault.balanceOf(CAROL), (liquidatorTokens * 2e14) / 1e18, "32.805 shares");
        assertEq(vault.balanceOf(CAROL), 32_805_000);
        // value check: paid $25, received 32.805 shares * $0.8 = $26.244 (= 25 * 1.08 * 0.972 = 26.244)
        assertEq(vault.balanceOf(CAROL) * 0.8e6 / 1e6, 26_244_000);
    }

    function test_liquidation_borrowerHealthImprovesAndSecondLiquidationNeedsShortfall() external {
        _aliceAtMax();
        vault.setAssetsPerWholeShare(0.8e6);
        (bool ok,) = _liquidate(CAROL, ALICE, 25e6);
        assertTrue(ok);
        (, uint256 liquidity, uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        // remaining: 100 - 33.75 = 66.25 shares * 0.8 * 0.5 = 26.5 vs debt 25
        assertEq(shortfall, 0);
        assertEq(liquidity, 1.5e18, "back to healthy by $1.5");
        (ok,) = _liquidate(CAROL, ALICE, 1e6);
        assertFalse(ok, "no shortfall -> no second liquidation");
        assertEq(_errCode(lastRevert), ERR_INSUFFICIENT_SHORTFALL);
    }

    function test_liquidation_closeFactorIsEnforced() external {
        _aliceAtMax();
        vault.setAssetsPerWholeShare(0.8e6);
        (bool ok, bytes memory ret) = _liquidate(CAROL, ALICE, 25e6 + 1);
        assertFalse(ok);
        assertEq(_selector(ret), TokenErrorReporter.LiquidatePeridottrollerRejection.selector);
        assertEq(_errCode(ret), ERR_TOO_MUCH_REPAY);
        (ok,) = _liquidate(CAROL, ALICE, 25e6);
        assertTrue(ok);
    }

    function test_liquidation_tinyAmounts_noRoundingRevert() external {
        _aliceAtMax();
        vault.setAssetsPerWholeShare(0.8e6);
        uint256 before = bp.balanceOf(CAROL);
        (bool ok,) = _liquidate(CAROL, ALICE, 1); // 1 base unit of USDC
        assertTrue(ok, "1 wei repay liquidates");
        // seize = 1 * 1.08/0.8 * 5000 = 6750 pTokens; protocol floor(6750*0.028)=189
        assertEq(bp.balanceOf(CAROL) - before, 6750 - 189, "liquidator got 6561 pTokens for 1 USDC wei");
        // protocol seize amount in shares truncates to 0 (189 * 2e14 / 1e18 = 0): reserves do not move, supply drops by 189
        assertEq(bp.totalReserves(), 0, "dust reserve rounds to zero (a few pTokens of supply are burned for free)");
    }

    function test_liquidation_dustDebt() external {
        _openBorrow(BOB, 3, 1); // 3 share base units of collateral, 1 USDC base unit of debt
        _openBorrow(DAVE, 5, 2); // 2 base units of debt
        vault.setAssetsPerWholeShare(0.01e6);
        // 1 wei of debt: maxClose = floor(0.5 * 1) = 0 -> any repay > 0 is TOO_MUCH_REPAY: a 1-wei debt can never be liquidated
        (bool ok,) = _liquidate(CAROL, BOB, 1);
        assertFalse(ok);
        assertEq(_errCode(lastRevert), ERR_TOO_MUCH_REPAY, "documented: 1-wei debt is below the close factor granularity");
        // 2 wei of debt: maxClose 1; seize = 1 * 1.08 / 0.01 * 5000 = 540_000 pTokens > the 25_000 held: SEIZE_TOO_MUCH
        (ok,) = _liquidate(CAROL, DAVE, 1);
        assertFalse(ok, "dust position cannot cover the incentive at a 99% NAV drop");
        assertEq(_reason(lastRevert), "LIQUIDATE_SEIZE_TOO_MUCH");
        vault.setAssetsPerWholeShare(0.9e6);
        (ok,) = _liquidate(CAROL, DAVE, 1);
        assertFalse(ok, "at 0.9: 5 shares * 0.9 * 50% = 2.25 > 2 debt: healthy");
        assertEq(_errCode(lastRevert), ERR_INSUFFICIENT_SHORTFALL);
        vault.setAssetsPerWholeShare(0.7e6); // 1.75 < 2: liquidatable; repay 1 seizes 1*1.08/0.7*5000 = 7714 <= 25000
        (ok,) = _liquidate(CAROL, DAVE, 1);
        assertTrue(ok, "2 wei debt: a 1 wei repay liquidates without rounding revert");
        uint256 seizeDust = 7714;
        assertEq(bp.balanceOf(CAROL), seizeDust - (seizeDust * PROTOCOL_SEIZE_SHARE) / 1e18);
    }

    address internal constant DAVE = address(0xDA7E);

    function test_liquidation_deepDrop_closeFactorRepayWouldSeizeMoreThanBalance_reverts_liquidatorSizesDown() external {
        _aliceAtMax();
        vault.setAssetsPerWholeShare(0.2e6); // NAV -80%: collateral $20 vs debt $50: BAD DEBT
        (, , uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertGt(shortfall, 0);
        // 25 USDC * 1.08 / 0.2 = 135 shares > 100 held
        (bool ok, bytes memory ret) = _liquidate(CAROL, ALICE, 25e6);
        assertFalse(ok, "close-factor repay seizes more than the borrower holds");
        assertEq(_reason(ret), "LIQUIDATE_SEIZE_TOO_MUCH");
        // 18 USDC -> 97.2 shares: fits
        (ok,) = _liquidate(CAROL, ALICE, 18e6);
        assertTrue(ok, "a smaller repay works");
        assertEq(pUsdc.borrowBalanceStored(ALICE), 32e6, "residual debt");
        assertEq(bp.balanceOf(ALICE), 100e6 * 5000 - _expectedSeize(18e6, 1e30, 0.2e30, 2e14));
        // bad debt remains: 32 USDC owed against ~2.8 shares ($0.56): nothing left to seize profitably
        (, , shortfall) = controller.getAccountLiquidity(ALICE);
        assertGt(shortfall, 0);
    }

    function test_liquidation_badDebtThreshold_priceBelow54PercentOfBorrowCannotCoverIncentive() external {
        // At pps p the full-seize value is 1.08 * debt only while collateral >= 1.08 * debt: p >= 0.54 for a 50% LTV open.
        _aliceAtMax();
        vault.setAssetsPerWholeShare(0.54e6); // collateral $54 = 1.08 * $50: exactly enough to seize 100% of debt incentive
        (bool ok,) = _liquidate(CAROL, ALICE, 25e6); // seizes 25*1.08/0.54 = 50 shares
        assertTrue(ok);
        assertEq(bp.balanceOf(ALICE), 100e6 * 5000 - 250_000_000_000 , "50 shares seized");
    }

    function test_usdcDepeg_doesNotMoveHealth_shareAndDebtAreBothUsdc() external {
        _aliceAtMax();
        (, uint256 liquidityBefore, uint256 shortfallBefore) = controller.getAccountLiquidity(ALICE);
        usdcFeed.setRound(0.5e8, block.timestamp, 9, 9); // USDC at $0.50
        (, uint256 liquidity, uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertEq(shortfall, shortfallBefore);
        assertEq(liquidity * 2, liquidityBefore + 0 * liquidity, "dollar amounts halve, the ratio does not move");
        assertEq(shortfall, 0, "still healthy: the USDC feed cannot liquidate a USDC-vs-USDC-share position");
    }

    function test_liquidation_vaultPriceRise_noLiquidation_andNavDropsAre_theOnlyRisk() external {
        _aliceAtMax();
        vault.setAssetsPerWholeShare(1.3e6);
        (bool ok,) = _liquidate(CAROL, ALICE, 1e6);
        assertFalse(ok);
        assertEq(_errCode(lastRevert), ERR_INSUFFICIENT_SHORTFALL);
    }

    /// @dev Fuzz: any NAV in [0.55, 0.99] (liquidatable, no bad debt) and any repay in [1, closeFactor]. No revert,
    ///      seize equals the independent formula, liquidator nets 97.2% (floor), borrower debt falls by the repay.
    function testFuzz_liquidation_noRevertAndExactSeize(uint256 navBps, uint256 repayRaw, uint96 collateralShares) external {
        navBps = bound(navBps, 5_500, 9_900);
        uint256 shares = bound(uint256(collateralShares), 20e6, 150e6); // 20..150 shares
        uint256 borrow = shares / 2; // the 50% maximum (base units are 1:1 for USDC and 6-dec shares at NAV 1.0)
        if (borrow >= USDC_BORROW_CAP) borrow = USDC_BORROW_CAP - 1;
        _openBorrow(ALICE, shares, borrow);
        vault.setAssetsPerWholeShare((1e6 * navBps) / 10_000);
        (, , uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        vm.assume(shortfall > 0);
        uint256 maxClose = borrow / 2;
        uint256 repay = bound(repayRaw, 1, maxClose);
        vm.assume(maxClose > 0);

        uint256 pShare = _price(PToken(address(bp)));
        uint256 pUsdcP = _price(PToken(address(pUsdc)));
        uint256 expected = _expectedSeize(repay, pUsdcP, pShare, bp.exchangeRateStored());
        vm.assume(expected <= bp.balanceOf(ALICE)); // the deep-drop case is its own test
        uint256 debtBefore = pUsdc.borrowBalanceStored(ALICE);
        uint256 carolBefore = bp.balanceOf(CAROL);
        uint256 aliceBefore = bp.balanceOf(ALICE);
        uint256 reservesBefore = bp.totalReserves();
        uint256 rateBefore = bp.exchangeRateStored();

        (bool ok, bytes memory ret) = _liquidate(CAROL, ALICE, repay);
        assertTrue(ok, string(abi.encodePacked("liquidate reverted: ", _reason(ret))));
        uint256 protocolTokens = (expected * PROTOCOL_SEIZE_SHARE) / 1e18;
        assertEq(pUsdc.borrowBalanceStored(ALICE), debtBefore - repay);
        assertEq(bp.balanceOf(CAROL) - carolBefore, expected - protocolTokens);
        assertEq(aliceBefore - bp.balanceOf(ALICE), expected);
        assertEq(bp.totalReserves() - reservesBefore, (protocolTokens * rateBefore) / 1e18);
        assertGt(expected, 0, "a 1 wei repay still seizes something");
    }
}
