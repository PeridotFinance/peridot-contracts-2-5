// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/JumpRateModelV2.sol";

/**
 * @title DeployJumpRateModelV2
 * @dev Deployment script for JumpRateModelV2 interest rate model
 * Uses default values from DeployPeridottroller.s.sol
 */
contract DeployJumpRateModelV2 is Script {
    // Default interest rate model parameters from DeployPeridottroller.s.sol
    uint baseRatePerYear = 0.03 * 1e18; // 3% APR
    uint multiplierPerYear = 0.12 * 1e18; // 12% APR slope
    uint jumpMultiplierPerYear = 2 * 1e18; // 200% APR slope after kink
    uint kink_ = 0.85 * 1e18; // 85% utilization threshold

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== JumpRateModelV2 Deployment ===");
        console.log("Deployer/Owner:", deployer);
        console.log("Interest Rate Model Parameters:");
        console.log("  Base Rate Per Year:", baseRatePerYear);
        console.log("  Multiplier Per Year:", multiplierPerYear);
        console.log("  Jump Multiplier Per Year:", jumpMultiplierPerYear);
        console.log("  Kink (Utilization Threshold):", kink_);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy JumpRateModelV2
        JumpRateModelV2 interestRateModel = new JumpRateModelV2(
            baseRatePerYear,
            multiplierPerYear,
            jumpMultiplierPerYear,
            kink_,
            deployer // Owner of the interest rate model
        );

        vm.stopBroadcast();

        console.log("==== Deployment Summary ====");
        console.log("JumpRateModelV2 deployed at:", address(interestRateModel));
        console.log("Owner:", deployer);
        console.log("\nUsage:");
        console.log("  Add this address to your PToken contracts as the interestRateModel");
        console.log("  Address:", address(interestRateModel));
    }
}
