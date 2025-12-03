// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/JumpRateModelBoosted.sol";

/// @dev Example deployment script for JumpRateModelBoosted tuned for a boosted stable market.
contract DeployJumpRateModelBoosted is Script {
    function run() external {
        // Hard-coded deployment parameters (replace with your desired values)
        uint256 baseRatePerYear = 0; // 0%
        uint256 multiplierPerYear = 0.08e18; // 8%
        uint256 jumpMultiplierPerYear = 0.20e18; // 20%
        uint256 kink = 0.25e18; // 25%
        uint256 targetMorphoSupplyAPY = 0.05e18; // 5%
        uint256 reserveFactor = 0.10e18; // 10% RF used in market
        uint256 safetyMargin = 0.05e18; // +5% margin over target

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
