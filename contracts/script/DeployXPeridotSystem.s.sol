// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {xPeridotVault} from "../contracts/xperidot/xPeridotVault.sol";
import {xPStaking} from "../contracts/xperidot/xPStaking.sol";
import {PeridotTierRewardsV2} from "../contracts/xperidot/PeridotTierRewardsV2.sol";
import "forge-std/console.sol";

/**
 * @title DeployXPeridotSystem
 * @notice Deploys the complete xPeridot ecosystem: vault, staking, and tier rewards
 * @dev Requires PERIDOT token and Peridottroller to be already deployed
 */
contract DeployXPeridotSystem is Script {
    
    // --- Configuration ---
    // Update these addresses based on your deployment environment
    
    address constant PERIDOT_TOKEN = 0x507f0F5E58d21f07d133722e038067248fe4ecBE; // From PeridottrollerG7
    address constant PERIDOTTROLLER = 0xa41D586530BC7BC872095950aE03a780d5114445; // Update with actual address
    address constant PRICE_ORACLE = 0xBfEaDDA58d0583f33309AdE83F35A680824E397f; // Update with actual address
    
    // Default configuration
    uint256 constant BASE_APR_BPS = 1000; // 10% base APR
    uint256 constant INITIAL_PERIDOT_PRICE_USD = 1e18; // $1.00

    function run() external {
        vm.startBroadcast();
        
        address deployer = msg.sender;
        console.log("=== Deploying xPeridot System ===");
        console.log("Deployer:", deployer);
        console.log("PERIDOT Token:", PERIDOT_TOKEN);
        console.log("Peridottroller:", PERIDOTTROLLER);
        console.log("Price Oracle:", PRICE_ORACLE);
        
        // 1. Deploy xPeridotVault
        console.log("\n=== Deploying xPeridotVault ===");
        xPeridotVault vault = new xPeridotVault(
            PERIDOT_TOKEN,
            "xPeridot Vault Token",
            "xPERIDOT",
            deployer
        );
        console.log("xPeridotVault deployed at:", address(vault));
        
        // Verify vault setup
        require(address(vault.peridotToken()) == PERIDOT_TOKEN, "Vault token mismatch");
        require(vault.owner() == deployer, "Vault owner mismatch");
        console.log("Vault verification passed");
        
        // 2. Deploy xPStaking
        console.log("\n=== Deploying xPStaking ===");
        xPStaking staking = new xPStaking(
            address(vault), // xPERIDOT token
            PERIDOT_TOKEN,  // Reward token
            deployer,       // Owner
            BASE_APR_BPS    // Base APR
        );
        console.log("xPStaking deployed at:", address(staking));
        
        // Verify staking setup
        require(address(staking.xPeridotToken()) == address(vault), "Staking token mismatch");
        require(address(staking.rewardToken()) == PERIDOT_TOKEN, "Reward token mismatch");
        require(staking.owner() == deployer, "Staking owner mismatch");
        require(staking.baseAprBps() == BASE_APR_BPS, "Base APR mismatch");
        console.log("Staking verification passed");
        
        // 3. Deploy PeridotTierRewardsV2
        console.log("\n=== Deploying PeridotTierRewardsV2 ===");
        PeridotTierRewardsV2 tierRewards = new PeridotTierRewardsV2(
            PERIDOT_TOKEN,
            PERIDOTTROLLER,
            PRICE_ORACLE,
            address(vault),
            address(staking),
            deployer
        );
        console.log("PeridotTierRewardsV2 deployed at:", address(tierRewards));
        
        // Verify tier rewards setup
        require(address(tierRewards.peridotToken()) == PERIDOT_TOKEN, "TierRewards token mismatch");
        require(address(tierRewards.peridottroller()) == PERIDOTTROLLER, "TierRewards controller mismatch");
        require(address(tierRewards.vault()) == address(vault), "TierRewards vault mismatch");
        require(address(tierRewards.stakingContract()) == address(staking), "TierRewards staking mismatch");
        require(tierRewards.owner() == deployer, "TierRewards owner mismatch");
        console.log("TierRewards verification passed");
        
        // 4. Display configuration
        console.log("\n=== Configuration Summary ===");
        console.log("Base APR:", BASE_APR_BPS, "bps (", BASE_APR_BPS / 100, "%)");
        
        uint8[] memory lockDurations = staking.getAvailableLockDurations();
        console.log("Available lock durations:");
        for (uint256 i = 0; i < lockDurations.length; i++) {
            uint256 totalAPR = staking.getTotalAPR(lockDurations[i]);
            console.log("  ", lockDurations[i], "months:", totalAPR, "bps (", totalAPR / 100, "%)");
        }
        
        vm.stopBroadcast();
        
        console.log("\n=== Deployment Summary ===");
        console.log("xPeridotVault:", address(vault));
        console.log("xPStaking:", address(staking));
        console.log("PeridotTierRewardsV2:", address(tierRewards));
        
        console.log("\n=== Next Steps ===");
        console.log("1. Fund staking contract with PERIDOT rewards:");
        console.log("   - Call staking.fundRewards(amount)");
        console.log("2. Configure PERIDOT price in tier rewards:");
        console.log("   - Call tierRewards.setPeridotPrice(priceInUSD)");
        console.log("3. Optionally adjust APR configurations:");
        console.log("   - Call staking.setAPRConfig(baseAPR, lockMonths[], bonusBps[])");
        console.log("4. Test the system:");
        console.log("   - Deposit PERIDOT into vault to get xPERIDOT");
        console.log("   - Stake xPERIDOT in staking contract");
        console.log("   - Check tier calculations via tierRewards.calculateUserTier()");
    }
}
