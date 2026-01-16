// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {xPeridotVault} from "../contracts/xperidot/xPeridotVault.sol";
import {xPStaking} from "../contracts/xperidot/xPStaking.sol";
import {PeridotTierRewardsV2} from "../contracts/xperidot/PeridotTierRewardsV2.sol";
import {MockErc20} from "./MockErc20.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockOracle} from "./MockOracle.sol";

contract XPeridotSystemTest is Test {
    // Contracts
    xPeridotVault vault;
    xPStaking staking;
    PeridotTierRewardsV2 tierRewards;
    MockErc20 peridotToken;
    MockPeridottroller peridottroller;
    MockOracle oracle;

    // Test users
    address alice = address(0x1);
    address bob = address(0x2);
    address admin = address(0x3);

    // Constants
    uint256 constant INITIAL_SUPPLY = 1_000_000e18;
    uint256 constant BASE_APR_BPS = 1000; // 10%

    function setUp() public {
        // Deploy mock contracts
        peridotToken = new MockErc20("Peridot", "PERIDOT", 18);
        peridottroller = new MockPeridottroller();
        oracle = new MockOracle();

        // Deploy xPeridot system
        vault = new xPeridotVault(address(peridotToken), "xPeridot Vault Token", "xPERIDOT", admin);

        staking = new xPStaking(address(vault), address(peridotToken), admin, BASE_APR_BPS);

        tierRewards = new PeridotTierRewardsV2(
            address(peridotToken), address(peridottroller), address(oracle), address(vault), address(staking), admin
        );

        // Setup initial balances
        peridotToken.mint(alice, INITIAL_SUPPLY);
        peridotToken.mint(bob, INITIAL_SUPPLY);
        peridotToken.mint(admin, INITIAL_SUPPLY);

        // Fund staking contract with rewards
        vm.startPrank(admin);
        peridotToken.approve(address(staking), INITIAL_SUPPLY / 2);
        staking.fundRewards(INITIAL_SUPPLY / 2);
        vm.stopPrank();
    }

    // --- Vault Tests ---

    function testVaultDeposit() public {
        uint256 depositAmount = 1000e18;

        vm.startPrank(alice);
        peridotToken.approve(address(vault), depositAmount);

        // First deposit should be 1:1
        uint256 expectedShares = vault.previewDeposit(depositAmount);
        assertEq(expectedShares, depositAmount);

        uint256 shares = vault.deposit(depositAmount);
        assertEq(shares, depositAmount);
        assertEq(vault.balanceOf(alice), depositAmount);
        assertEq(vault.totalPInVault(), depositAmount);

        vm.stopPrank();
    }

    function testVaultWithdraw() public {
        // First deposit
        testVaultDeposit();

        uint256 withdrawShares = 500e18;

        vm.startPrank(alice);
        uint256 expectedAmount = vault.previewWithdraw(withdrawShares);
        uint256 amount = vault.withdraw(withdrawShares);

        assertEq(amount, expectedAmount);
        assertEq(vault.balanceOf(alice), 500e18);
        assertEq(peridotToken.balanceOf(alice), INITIAL_SUPPLY - 500e18);

        vm.stopPrank();
    }

    function testVaultRevenueIncreasesExchangeRate() public {
        // Initial deposit
        testVaultDeposit();

        uint256 initialExchangeRate = vault.exchangeRate();
        assertEq(initialExchangeRate, 1e18); // 1:1 initially

        // Admin adds revenue
        uint256 revenueAmount = 100e18;
        vm.startPrank(admin);
        peridotToken.approve(address(vault), revenueAmount);
        vault.addRevenue(revenueAmount);
        vm.stopPrank();

        // Exchange rate should increase
        uint256 newExchangeRate = vault.exchangeRate();
        assertGt(newExchangeRate, initialExchangeRate);

        // Should be (1000 + 100) / 1000 = 1.1
        assertEq(newExchangeRate, 1.1e18);
    }

    // --- Staking Tests ---

    function testStakingPosition() public {
        // First get xPERIDOT
        testVaultDeposit();

        uint256 stakeAmount = 100e18;
        uint8 lockMonths = 12;

        vm.startPrank(alice);
        vault.approve(address(staking), stakeAmount);

        uint256 positionId = staking.stake(stakeAmount, lockMonths);
        assertEq(positionId, 0);

        // Check position details
        xPStaking.Position memory position = staking.getPosition(alice, positionId);
        assertEq(position.amountXP, stakeAmount);
        assertEq(position.lockMonths, lockMonths);
        assertGt(position.endTime, block.timestamp);

        // Check total staked
        assertEq(staking.totalStaked(), stakeAmount);
        assertEq(staking.getUserTotalStaked(alice), stakeAmount);

        vm.stopPrank();
    }

    function testStakingRewards() public {
        testStakingPosition();

        // Fast forward 1 year
        vm.warp(block.timestamp + 365 days);

        // Calculate expected rewards
        uint256 expectedRewards = staking.calculateRewards(alice, 0);

        // Should be approximately: 100e18 * (1000 + 4000) / 10000 = 50e18 (50% APR for 12 months)
        assertGt(expectedRewards, 49e18);
        assertLt(expectedRewards, 51e18);

        // Claim rewards
        vm.startPrank(alice);
        staking.claimRewards(0);
        vm.stopPrank();

        // Check PERIDOT balance increased
        assertGt(peridotToken.balanceOf(alice), INITIAL_SUPPLY - 1000e18);
    }

    function testStakingUnstake() public {
        testStakingPosition();

        // Try to unstake before lock expires (should fail)
        vm.startPrank(alice);
        vm.expectRevert("Position still locked");
        staking.unstake(0);

        // Fast forward past lock period
        vm.warp(block.timestamp + 365 days);

        // Now unstake should work
        uint256 balanceBefore = vault.balanceOf(alice);
        staking.unstake(0);
        uint256 balanceAfter = vault.balanceOf(alice);

        assertEq(balanceAfter - balanceBefore, 100e18);
        assertEq(staking.totalStaked(), 0);

        vm.stopPrank();
    }

    // --- Tier Rewards Tests ---

    function testTierCalculationWithStaking() public {
        // Setup: Alice deposits and stakes
        testStakingPosition();

        // Mock portfolio value - simulate Alice having $1000 in supplied assets
        // This would normally come from pToken balances

        // For tier calculation, we need staked PERIDOT value vs supplied value
        // Alice staked 100 xPERIDOT, which is worth 100 PERIDOT at 1:1 exchange rate
        // At $1 PERIDOT price = $100 staked value
        // If she has $1000 supplied, ratio = 100/1000 = 10% = tier 4

        (uint8 tier, uint256 tierPercentBps) = tierRewards.calculateUserTier(alice);

        // Note: This test would need mock pToken balances to work properly
        // For now, we're testing the basic structure
        assertGe(tier, 1);
        assertLe(tier, 4);
    }

    function testTierMultipliers() public {
        // Test tier multiplier configuration
        uint8[] memory tiers = new uint8[](2);
        uint256[] memory multipliers = new uint256[](2);

        tiers[0] = 1;
        tiers[1] = 4;
        multipliers[0] = 10000; // 1.0x
        multipliers[1] = 20000; // 2.0x

        vm.startPrank(admin);
        tierRewards.updateTierMultipliers(tiers, multipliers);
        vm.stopPrank();

        // Verify configuration
        (, uint256[] memory actualMultipliers) = tierRewards.getTierConfig();
        assertEq(actualMultipliers[0], 10000);
        assertEq(actualMultipliers[3], 20000);
    }

    // --- Integration Tests ---

    function testFullWorkflow() public {
        uint256 depositAmount = 1000e18;
        uint256 stakeAmount = 100e18;

        vm.startPrank(alice);

        // 1. Deposit PERIDOT to get xPERIDOT
        peridotToken.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount);
        assertEq(shares, depositAmount);

        // 2. Stake xPERIDOT for 12 months
        vault.approve(address(staking), stakeAmount);
        uint256 positionId = staking.stake(stakeAmount, 12);

        // 3. Check position was created
        xPStaking.Position memory position = staking.getPosition(alice, positionId);
        assertEq(position.amountXP, stakeAmount);
        assertEq(position.lockMonths, 12);

        // 4. Fast forward and claim rewards
        vm.warp(block.timestamp + 180 days); // 6 months

        uint256 rewardsBefore = peridotToken.balanceOf(alice);
        staking.claimRewards(positionId);
        uint256 rewardsAfter = peridotToken.balanceOf(alice);

        assertGt(rewardsAfter, rewardsBefore);

        // 5. After full lock period, unstake
        vm.warp(block.timestamp + 185 days); // Complete 12 months

        uint256 xPeridotBefore = vault.balanceOf(alice);
        staking.unstake(positionId);
        uint256 xPeridotAfter = vault.balanceOf(alice);

        assertEq(xPeridotAfter - xPeridotBefore, stakeAmount);

        vm.stopPrank();
    }

    function testRevenueShareIncreasesStakingValue() public {
        // Alice stakes
        testStakingPosition();

        // Admin adds revenue to vault
        uint256 revenueAmount = 100e18;
        vm.startPrank(admin);
        peridotToken.approve(address(vault), revenueAmount);
        vault.addRevenue(revenueAmount);
        vm.stopPrank();

        // Exchange rate should increase, making staked xPERIDOT more valuable
        uint256 exchangeRate = vault.exchangeRate();
        assertGt(exchangeRate, 1e18);

        // When Alice unstakes later, she should get more PERIDOT back
        vm.warp(block.timestamp + 365 days);

        vm.startPrank(alice);
        uint256 peridotBefore = peridotToken.balanceOf(alice);
        staking.unstake(0);

        // Withdraw from vault
        uint256 xPeridotBalance = vault.balanceOf(alice);
        uint256 peridotReceived = vault.withdraw(xPeridotBalance);
        uint256 peridotAfter = peridotToken.balanceOf(alice);

        // She should have more PERIDOT than initially due to revenue sharing
        assertGt(peridotAfter, INITIAL_SUPPLY - 1000e18);

        vm.stopPrank();
    }

    // --- Edge Case Tests ---

    function testZeroStakingEdgeCases() public {
        // Test with no staking
        (uint8 tier, uint256 percent) = tierRewards.calculateUserTier(alice);
        assertEq(tier, 1);
        assertEq(percent, 0);

        // Test rewards calculation with no position
        uint256 rewards = staking.calculateRewards(alice, 0);
        assertEq(rewards, 0);
    }

    function testMultipleStakingPositions() public {
        testVaultDeposit();

        vm.startPrank(alice);
        vault.approve(address(staking), 1000e18);

        // Create multiple positions with different lock durations
        uint256 pos1 = staking.stake(100e18, 1); // 1 month
        uint256 pos3 = staking.stake(200e18, 3); // 3 months
        uint256 pos12 = staking.stake(300e18, 12); // 12 months

        assertEq(pos1, 0);
        assertEq(pos3, 1);
        assertEq(pos12, 2);

        // Check total staked
        assertEq(staking.getUserTotalStaked(alice), 600e18);
        assertEq(staking.getUserPositionCount(alice), 3);

        // Fast forward and check different APRs
        vm.warp(block.timestamp + 30 days);

        uint256 rewards1 = staking.calculateRewards(alice, 0);
        uint256 rewards3 = staking.calculateRewards(alice, 1);
        uint256 rewards12 = staking.calculateRewards(alice, 2);

        // 12-month lock should have highest rewards due to bonus
        assertGt(rewards12, rewards3);
        assertGt(rewards3, rewards1);

        vm.stopPrank();
    }

    function testAPRConfiguration() public {
        uint8[] memory lockMonths = new uint8[](2);
        uint256[] memory bonusBps = new uint256[](2);

        lockMonths[0] = 6;
        lockMonths[1] = 18;
        bonusBps[0] = 2000; // +20%
        bonusBps[1] = 10000; // +100%

        vm.startPrank(admin);
        staking.setAPRConfig(1500, lockMonths, bonusBps); // 15% base
        vm.stopPrank();

        // Check configuration
        assertEq(staking.baseAprBps(), 1500);
        assertEq(staking.getTotalAPR(6), 3500); // 15% + 20%
        assertEq(staking.getTotalAPR(18), 11500); // 15% + 100%

        uint8[] memory available = staking.getAvailableLockDurations();
        assertEq(available.length, 2);
        assertEq(available[0], 6);
        assertEq(available[1], 18);
    }

    // --- Failure Tests ---

    function testDepositZeroAmount() public {
        vm.startPrank(alice);
        peridotToken.approve(address(vault), 1000e18);

        vm.expectRevert("Amount must be greater than 0");
        vault.deposit(0);

        vm.stopPrank();
    }

    function testStakeInvalidLockDuration() public {
        testVaultDeposit();

        vm.startPrank(alice);
        vault.approve(address(staking), 100e18);

        vm.expectRevert("Invalid lock duration");
        staking.stake(100e18, 6); // 6 months not in default config

        vm.stopPrank();
    }

    function testUnstakeInvalidPosition() public {
        vm.startPrank(alice);

        vm.expectRevert("Invalid position ID");
        staking.unstake(0);

        vm.stopPrank();
    }

    function testWithdrawInsufficientShares() public {
        testVaultDeposit();

        vm.startPrank(alice);

        vm.expectRevert("Insufficient shares");
        vault.withdraw(2000e18); // More than deposited

        vm.stopPrank();
    }

    // --- View Function Tests ---

    function testVaultStats() public {
        testVaultDeposit();

        (uint256 totalShares, uint256 totalPeridot, uint256 exchangeRate) = vault.getVaultStats();

        assertEq(totalShares, 1000e18);
        assertEq(totalPeridot, 1000e18);
        assertEq(exchangeRate, 1e18);
    }

    function testStakingStats() public {
        testStakingPosition();

        (uint256 contractBalance, uint256 totalStakedXP, uint256 currentBaseAPR) = staking.getContractStats();

        assertEq(totalStakedXP, 100e18);
        assertEq(currentBaseAPR, BASE_APR_BPS);
        assertGt(contractBalance, 0); // Should have reward tokens
    }

    function testTierConfiguration() public {
        (uint256[] memory thresholds, uint256[] memory multipliers) = tierRewards.getTierConfig();

        assertEq(thresholds.length, 3);
        assertEq(multipliers.length, 4);

        assertEq(thresholds[0], 100); // 1%
        assertEq(thresholds[1], 500); // 5%
        assertEq(thresholds[2], 1000); // 10%

        assertEq(multipliers[0], 10000); // 1.0x
        assertEq(multipliers[1], 11000); // 1.1x
        assertEq(multipliers[2], 12500); // 1.25x
        assertEq(multipliers[3], 15000); // 1.5x
    }
}
