// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/PeridotStaking.sol";
import "./MockErc20.sol";

contract PeridotStakingTest is Test {
    PeridotStaking internal staking;
    MockErc20 internal stakeToken;
    MockErc20 internal rewardTokenA;
    MockErc20 internal rewardTokenB;

    address internal owner = address(this);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    uint256 internal rewardDuration = 7 days;

    function setUp() public {
        stakeToken = new MockErc20("Peridot", "P", 18);
        rewardTokenA = new MockErc20("RewardA", "RA", 18);
        rewardTokenB = new MockErc20("RewardB", "RB", 18);

        staking = new PeridotStaking();
        staking.initialize(address(stakeToken), address(rewardTokenA), owner, rewardDuration);

        stakeToken.mint(alice, 1000e18);
        stakeToken.mint(bob, 1000e18);
    }

    function testRewardsStreamOverTime() public {
        _stake(alice, 100e18);

        uint256 nowTs = 1000;
        vm.warp(nowTs);

        uint256 rewardAmount = rewardDuration * 1e18;
        rewardTokenA.mint(bob, rewardAmount);
        vm.startPrank(bob);
        rewardTokenA.approve(address(staking), rewardAmount);
        staking.addReward(address(rewardTokenA), rewardAmount);
        vm.stopPrank();

        nowTs += 1 days;
        vm.warp(nowTs);

        vm.prank(alice);
        staking.claimAll();
        assertEq(rewardTokenA.balanceOf(alice), 1 days * 1e18);

        nowTs += 6 days;
        vm.warp(nowTs);
        vm.prank(alice);
        staking.claimAll();
        assertEq(rewardTokenA.balanceOf(alice), rewardDuration * 1e18);
    }

    function testSwitchTokenKeepsOldStream() public {
        _stake(alice, 100e18);

        uint256 nowTs = 1000;
        vm.warp(nowTs);

        uint256 rewardAmountA = rewardDuration * 1e18;
        rewardTokenA.mint(bob, rewardAmountA);
        vm.startPrank(bob);
        rewardTokenA.approve(address(staking), rewardAmountA);
        staking.addReward(address(rewardTokenA), rewardAmountA);
        vm.stopPrank();

        nowTs += 1 days;
        vm.warp(nowTs);

        uint256 rewardDurationB = 3 days;
        staking.setRewardToken(address(rewardTokenB), rewardDurationB);

        uint256 rewardAmountB = rewardDurationB * 1e18;
        rewardTokenB.mint(bob, rewardAmountB);
        vm.startPrank(bob);
        rewardTokenB.approve(address(staking), rewardAmountB);
        staking.addReward(address(rewardTokenB), rewardAmountB);
        vm.stopPrank();

        nowTs += 1 days;
        vm.warp(nowTs);

        vm.prank(alice);
        staking.claimAll();
        assertEq(rewardTokenA.balanceOf(alice), 2 days * 1e18);
        assertEq(rewardTokenB.balanceOf(alice), 1 days * 1e18);
    }

    function testAddRewardOnlyCurrentToken() public {
        _stake(alice, 100e18);

        staking.setRewardToken(address(rewardTokenB), 3 days);

        uint256 rewardAmount = 1e18;
        rewardTokenA.mint(bob, rewardAmount);
        vm.startPrank(bob);
        rewardTokenA.approve(address(staking), rewardAmount);
        vm.expectRevert("PeridotStaking: not current reward");
        staking.addReward(address(rewardTokenA), rewardAmount);
        vm.stopPrank();
    }

    function testEmergencyWithdrawRewardsOnly() public {
        _stake(alice, 100e18);

        uint256 rewardAmount = rewardDuration * 1e18;
        rewardTokenA.mint(bob, rewardAmount);
        vm.startPrank(bob);
        rewardTokenA.approve(address(staking), rewardAmount);
        staking.addReward(address(rewardTokenA), rewardAmount);
        vm.stopPrank();

        vm.expectRevert("PeridotStaking: cannot withdraw stake");
        staking.emergencyWithdrawReward(address(stakeToken), owner, 1e18);

        uint256 ownerBefore = rewardTokenA.balanceOf(owner);
        staking.emergencyWithdrawReward(address(rewardTokenA), owner, 5e18);
        assertEq(rewardTokenA.balanceOf(owner), ownerBefore + 5e18);

        vm.prank(alice);
        staking.unstake(100e18);
        assertEq(stakeToken.balanceOf(alice), 1000e18);
    }

    function testOnlyOwnerCanSwitchRewardToken() public {
        vm.prank(alice);
        vm.expectRevert("PeridotStaking: not owner");
        staking.setRewardToken(address(rewardTokenB), 1 days);
    }

    function testRewardTopUpMidStreamAccumulates() public {
        _stake(alice, 100e18);

        uint256 nowTs = 1000;
        vm.warp(nowTs);

        uint256 rewardAmount = rewardDuration * 1e18;
        rewardTokenA.mint(bob, rewardAmount * 2);
        vm.startPrank(bob);
        rewardTokenA.approve(address(staking), rewardAmount * 2);
        staking.addReward(address(rewardTokenA), rewardAmount);
        vm.stopPrank();

        nowTs += 1 days;
        vm.warp(nowTs);

        // top up with another full duration
        vm.startPrank(bob);
        staking.addReward(address(rewardTokenA), rewardAmount);
        vm.stopPrank();

        nowTs += 1 days;
        vm.warp(nowTs);

        vm.prank(alice);
        staking.claimAll();

        // 1 day at original rate + 1 day at topped-up rate (with leftover rolled in)
        uint256 day = 1 days;
        uint256 initialRate = rewardAmount / rewardDuration;
        uint256 leftover = (rewardDuration - day) * initialRate;
        uint256 toppedUpRate = (rewardAmount + leftover) / rewardDuration;
        uint256 expected = day * initialRate + day * toppedUpRate;
        assertEq(rewardTokenA.balanceOf(alice), expected);
    }

    function testRewardsSplitBetweenStakers() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);

        uint256 nowTs = 1000;
        vm.warp(nowTs);

        uint256 rewardAmount = rewardDuration * 1e18;
        rewardTokenA.mint(owner, rewardAmount);
        rewardTokenA.approve(address(staking), rewardAmount);
        staking.addReward(address(rewardTokenA), rewardAmount);

        nowTs += 1 days;
        vm.warp(nowTs);

        vm.prank(alice);
        staking.claimAll();
        vm.prank(bob);
        staking.claimAll();

        assertEq(rewardTokenA.balanceOf(alice), (1 days * 1e18) / 2);
        assertEq(rewardTokenA.balanceOf(bob), (1 days * 1e18) / 2);
    }

    function testUnstakeStopsFutureAccrual() public {
        _stake(alice, 100e18);

        uint256 nowTs = 1000;
        vm.warp(nowTs);

        uint256 rewardAmount = rewardDuration * 1e18;
        rewardTokenA.mint(bob, rewardAmount);
        vm.startPrank(bob);
        rewardTokenA.approve(address(staking), rewardAmount);
        staking.addReward(address(rewardTokenA), rewardAmount);
        vm.stopPrank();

        nowTs += 1 days;
        vm.warp(nowTs);

        vm.prank(alice);
        staking.unstake(100e18);

        nowTs += 1 days;
        vm.warp(nowTs);

        vm.prank(alice);
        staking.claimAll();

        // Only the first day should accrue since she unstaked before day 2.
        assertEq(rewardTokenA.balanceOf(alice), 1 days * 1e18);
    }

    function _stake(address user, uint256 amount) internal {
        vm.startPrank(user);
        stakeToken.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }
}
