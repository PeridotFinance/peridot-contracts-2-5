// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/JumpRateModelBoosted.sol";

contract JumpRateModelBoostedTest is Test {
    JumpRateModelBoosted internal model;

    // Params under test (stables baseline)
    uint256 internal constant BASE = 0;
    uint256 internal constant MULT = 0.08e18; // 8%/year
    uint256 internal constant JUMP = 0.20e18; // 20%/year
    uint256 internal constant KINK = 0.25e18; // 25% util
    uint256 internal constant TARGET_MORPHO = 0.05e18; // 5% target APY
    uint256 internal constant RF = 0.10e18; // 10% reserve factor
    uint256 internal constant MARGIN = 0.05e18; // +5%

    function setUp() public {
        model = new JumpRateModelBoosted(BASE, MULT, JUMP, KINK, TARGET_MORPHO, RF, MARGIN);
    }

    function testFloorAppliedAtLowUtilization() public {
        // Very low utilization
        uint256 cash = 100e18;
        uint256 borrows = 1e18;
        uint256 reserves = 0;

        uint256 ratePerYear = model.borrowRatePerYear(cash, borrows, reserves);

        // Expected floor: target/(1-RF) * (1+margin)
        // 0.05 / 0.9 * 1.05 = 0.058333... (~5.8333%)
        uint256 expectedFloor = (TARGET_MORPHO * 1e18) / (1e18 - RF);
        expectedFloor = (expectedFloor * (1e18 + MARGIN)) / 1e18;

        assertApproxEqAbs(ratePerYear, expectedFloor, 1e9); // tolerate tiny rounding (1e-9 absolute)
    }

    function testAboveKinkUsesJumpSlope() public {
        // Utilization ~50% (cash=borrows)
        uint256 cash = 50e18;
        uint256 borrows = 50e18;
        uint256 reserves = 0;

        uint256 ratePerYear = model.borrowRatePerYear(cash, borrows, reserves);

        // Compute raw jump model without floor for comparison
        // pre-kink add: mult * kink = 0.08 * 0.25 = 0.02
        // jump part: jump * (0.5 - 0.25) = 0.20 * 0.25 = 0.05
        // base 0 => total 0.07
        uint256 raw = 0.07e18;

        // Floor is ~0.05833, so result should be raw (higher)
        assertApproxEqAbs(ratePerYear, raw, 1e14); // allow tiny rounding
    }

    function testBoostedSupplyHelperBlendsMorphoAndBorrow() public {
        // Utilization 25% (at kink)
        uint256 cash = 75e18;
        uint256 borrows = 25e18;
        uint256 reserves = 0;

        uint256 blended = model.getBoostedSupplyRate(cash, borrows, reserves, RF);

        // Expectation: floor ~5.833%, supply-from-borrows ~0.25*5.833%*0.9 ≈ 1.312%
        // blended ≈ 0.75*5% + 0.25*1.312% ≈ 4.078%
        uint256 approx = 0.04078e18;
        assertApproxEqAbs(blended, approx, 5e14); // tolerate small deviation
    }
}
