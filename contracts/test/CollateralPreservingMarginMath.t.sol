// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {CollateralPreservingMarginMath as M} from "../contracts/margin/CollateralPreservingMarginMath.sol";

/// @notice Accounting specifications only; not proof of an executable boosted lifecycle.
contract CollateralPreservingMarginMathTest is Test {
    function evaluate(M.Inputs memory input) external pure returns (M.Metrics memory) {
        return M.calculate(input);
    }

    function _entry() private pure returns (M.Inputs memory) {
        return M.Inputs(100e18, 500e18, 500e18, 0, 500e18, 2000, 1000);
    }

    function testFiveXTradeDoesNotCountCollateralAsSixXExposure() public pure {
        M.Metrics memory m = M.calculate(_entry());
        assertEq(m.equityUsd, 100e18);
        assertEq(m.tradingLeverageX100, 500);
        assertEq(m.initialRequirementUsd, 100e18);
        assertEq(m.maintenanceRequirementUsd, 50e18);
        assertEq(m.healthFactorBps, 20_000);
        assertTrue(m.meetsInitialMargin);
        assertFalse(m.liquidatable);
    }

    function testOpeningLossRequiresSizingHeadroom() public pure {
        M.Inputs memory p = _entry();
        p.tradingAssetsUsd = 495e18;
        p.tradingExposureUsd = 495e18;
        M.Metrics memory m = M.calculate(p);
        assertEq(m.equityUsd, 95e18);
        assertFalse(m.meetsInitialMargin);
        assertGt(m.tradingLeverageX100, 500);
        assertFalse(m.liquidatable);
    }

    function testBorrowInterestReducesEquity() public pure {
        M.Inputs memory p = _entry();
        p.debtUsd += 2e18;
        M.Metrics memory m = M.calculate(p);
        assertEq(m.equityUsd, 98e18);
        assertLt(m.healthFactorBps, 20_000);
    }

    function testCollateralYieldIncreasesEquityWithoutChangingTradeExposure() public pure {
        M.Inputs memory p = _entry();
        p.eligibleCollateralUsd += 2e18;
        M.Metrics memory m = M.calculate(p);
        assertEq(m.equityUsd, 102e18);
        assertEq(m.maintenanceRequirementUsd, 50e18);
        assertGt(m.healthFactorBps, 20_000);
    }

    function testExitCostsAndCollateralHaircutReduceCapacity() public pure {
        M.Inputs memory p = _entry();
        p.eligibleCollateralUsd = 90e18;
        p.reservedExitCostsUsd = 3e18;
        M.Metrics memory m = M.calculate(p);
        assertEq(m.equityUsd, 87e18);
        assertFalse(m.meetsInitialMargin);
    }

    function testLongLiquidationBoundaryWithStableCollateral() public pure {
        M.Inputs memory p = _entry();
        // At entry AVAX $10: 50 AVAX held, $500 debt, $100 stable collateral.
        // $8.90 remains healthy; $8.88 is liquidatable. No fees/interest/haircut.
        p.tradingAssetsUsd = 445e18;
        p.tradingExposureUsd = p.tradingAssetsUsd;
        assertFalse(M.calculate(p).liquidatable);
        p.tradingAssetsUsd = 444e18;
        p.tradingExposureUsd = p.tradingAssetsUsd;
        assertTrue(M.calculate(p).liquidatable);
    }

    function testShortLiquidationBoundaryWithStableCollateral() public pure {
        M.Inputs memory p = _entry();
        // 50 AVAX borrowed and sold for $500. Collateral stays $100.
        // $10.90 remains healthy; $10.92 is liquidatable.
        p.debtUsd = 545e18;
        p.tradingExposureUsd = p.debtUsd;
        assertFalse(M.calculate(p).liquidatable);
        p.debtUsd = 546e18;
        p.tradingExposureUsd = p.debtUsd;
        assertTrue(M.calculate(p).liquidatable);
    }

    function testVolatileCollateralAddsIndependentPriceRisk() public pure {
        M.Inputs memory p = _entry();
        // 10 AVAX collateral plus 50 AVAX long, all fall 10% in USD terms.
        p.eligibleCollateralUsd = 90e18;
        p.tradingAssetsUsd = 450e18;
        p.tradingExposureUsd = p.tradingAssetsUsd;
        assertTrue(M.calculate(p).liquidatable);
        // Same trade with stable collateral is still above maintenance.
        p.eligibleCollateralUsd = 100e18;
        assertFalse(M.calculate(p).liquidatable);
    }

    function testNegativeEquityIsNotClampedAway() public pure {
        M.Inputs memory p = _entry();
        p.debtUsd = 650e18;
        M.Metrics memory m = M.calculate(p);
        assertEq(m.equityUsd, -50e18);
        assertEq(m.healthFactorBps, 0);
        assertTrue(m.liquidatable);
        assertFalse(m.meetsInitialMargin);
    }

    function testFlatAccountHasNoTradingRequirement() public pure {
        M.Inputs memory p = _entry();
        p.tradingAssetsUsd = 0;
        p.debtUsd = 0;
        p.tradingExposureUsd = 0;
        M.Metrics memory m = M.calculate(p);
        assertEq(m.equityUsd, 100e18);
        assertEq(m.tradingLeverageX100, 0);
        assertFalse(m.liquidatable);
    }

    function testTinyExposureCannotRoundRequirementToZero() public pure {
        M.Inputs memory p = _entry();
        p.tradingExposureUsd = 1;
        M.Metrics memory m = M.calculate(p);
        assertEq(m.initialRequirementUsd, 1);
        assertEq(m.maintenanceRequirementUsd, 1);
    }

    function testRejectsInvalidMarginRatios() public {
        M.Inputs memory p = _entry();
        p.maintenanceMarginBps = p.initialMarginBps;
        vm.expectRevert(M.InvalidMarginRatios.selector);
        this.evaluate(p);
    }

    function testRejectsUnrepresentableEquity() public {
        M.Inputs memory p = _entry();
        p.eligibleCollateralUsd = uint256(type(int256).max) + 1;
        vm.expectRevert(M.SignedValueOverflow.selector);
        this.evaluate(p);
    }

    function testFuzzEquityConservation(uint128 collateral, uint128 assets, uint128 debt, uint128 costs) public pure {
        M.Inputs memory p = M.Inputs(collateral, assets, debt, costs, assets, 2000, 1000);
        M.Metrics memory m = M.calculate(p);
        assertEq(m.equityUsd, int256(uint256(collateral) + assets) - int256(uint256(debt) + costs));
    }

    function testFuzzIncreasingCollateralCannotWorsenHealth(uint96 collateral, uint96 extra) public pure {
        M.Inputs memory p = _entry();
        p.eligibleCollateralUsd = uint256(collateral) + 1;
        M.Metrics memory before = M.calculate(p);
        p.eligibleCollateralUsd += extra;
        M.Metrics memory after_ = M.calculate(p);
        assertGe(after_.healthFactorBps, before.healthFactorBps);
        assertLe(after_.tradingLeverageX100, before.tradingLeverageX100);
    }
}
