// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../contracts/PeridotTierRewards.sol";
import "../contracts/Governance/Peridot.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/SimplePriceOracle.sol";

/**
 * @title DeployPeridotTierRewards
 * @dev Deployment script for PeridotTierRewards contract on BNB Testnet
 */
contract DeployPeridotTierRewards is Script {
    
    // BNB Testnet addresses - Updated from addresses.MD
    address constant PERIDOT_TOKEN_ADDRESS = 0x5A5063a749fCF050CE58Cae6bB76A29bb37BA4Ed; // $P token address
    address constant PERIDOTTROLLER_ADDRESS = 0xe8F09917d56Cc5B634f4DE091A2c82189dc41b54; // Unitroller (Proxy)
    address constant ORACLE_ADDRESS = 0xBfEaDDA58d0583f33309AdE83F35A680824E397f; // SimplePriceOracle
    
    function setUp() public {
        // Validate addresses are not zero
        if (
            PERIDOT_TOKEN_ADDRESS == address(0) ||
            PERIDOTTROLLER_ADDRESS == address(0) ||
            ORACLE_ADDRESS == address(0)
        ) {
            revert("Please update the addresses in the script");
        }
    }
    
    function run() public {
        console.log("Deploying PeridotTierRewards...");
        console.log("Network: BNB Testnet");
        console.log("Peridot Token:", PERIDOT_TOKEN_ADDRESS);
        console.log("Peridottroller:", PERIDOTTROLLER_ADDRESS);
        console.log("Oracle:", ORACLE_ADDRESS);
        
        vm.startBroadcast();
        
        // Deploy the Tier Rewards contract
        PeridotTierRewards tierRewards = new PeridotTierRewards(
            PERIDOT_TOKEN_ADDRESS,
            PERIDOTTROLLER_ADDRESS,
            ORACLE_ADDRESS
        );
        
        vm.stopBroadcast();
        
        console.log("==== Deployment Complete ====");
        console.log("PeridotTierRewards deployed at:", address(tierRewards));
        
        // Log initial configuration
        console.log("Initial Tier Multipliers:");
        console.log("Tier 1:", tierRewards.tier1Multiplier());
        console.log("Tier 2:", tierRewards.tier2Multiplier());
        console.log("Tier 3:", tierRewards.tier3Multiplier());
        console.log("Tier 4:", tierRewards.tier4Multiplier());
        
        console.log("==== Next Steps ====");
        console.log("1. Update addresses.MD with new contract address");
        console.log("2. Test tier calculation with sample users");
        console.log("3. Add protocol reward multipliers as needed");
        console.log("4. Integrate with reward distribution systems");
    }
}
