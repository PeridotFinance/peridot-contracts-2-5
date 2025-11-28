// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/JumpRateModelBoosted.sol";

/// @dev Example deployment script for JumpRateModelBoosted tuned for a boosted stable market.
contract DeployJumpRateModelBoosted is Script {
    function run() external {
        // Suggested defaults for a boosted stable market (adjust as needed):
        uint256 baseRatePerYear = vm.envOr("BR_BASE_PER_YEAR", uint256(0)); // 0%
        uint256 multiplierPerYear = vm.envOr("BR_MULTIPLIER_PER_YEAR", uint256(0.08e18)); // 8%
        uint256 jumpMultiplierPerYear = vm.envOr("BR_JUMP_PER_YEAR", uint256(0.20e18)); // 20%
        uint256 kink = vm.envOr("BR_KINK", uint256(0.25e18)); // 25%

        // External yield target & safety
        uint256 targetMorphoSupplyAPY = vm.envOr("BR_TARGET_MORPHO_APY", uint256(0.05e18)); // 5%
        uint256 reserveFactor = vm.envOr("BR_RESERVE_FACTOR", uint256(0.10e18)); // 10% RF used in market
        uint256 safetyMargin = vm.envOr("BR_SAFETY_MARGIN", uint256(0.05e18)); // +5% margin over target

        vm.startBroadcast();
        JumpRateModelBoosted model = new JumpRateModelBoosted(
            baseRatePerYear,
            multiplierPerYear,
            jumpMultiplierPerYear,
            kink,
            targetMorphoSupplyAPY,
            reserveFactor,
            safetyMargin
        );
        console2.log("JumpRateModelBoosted deployed at:", address(model));
        vm.stopBroadcast();
    }
}
