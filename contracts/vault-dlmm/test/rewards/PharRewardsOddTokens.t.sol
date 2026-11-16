// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";
import {PharRewardsDistributor as D} from "../../src/rewards/PharRewardsDistributor.sol";
import {MerkleBuild, PUB_FROM, PUB_TO, PUB_DATA} from "./RewardsBase.sol";
import {
    FeeToken,
    BonusToken,
    FalseReturnToken,
    NoReturnToken,
    BlacklistToken,
    HookToken,
    Reenterer,
    BubblingReenterer
} from "./OddTokens.sol";

/// @notice The distributor against tokens that do not behave like a plain ERC-20 (PHAR is plain; these are the "what if" cases).
contract PharRewardsOddTokensTest is Test {
    uint256 internal constant DELAY = 1 days;
    uint256 internal constant DEADLINE = 180 days;
    address internal safe = makeAddr("safe");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1000);
    }

    // two-leaf tree helper for epoch 0: account a gets 100, account b gets 200
    function _two(address a, address b, uint256 epochId) internal pure returns (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) {
        bytes32[] memory l = new bytes32[](2);
        l[0] = MerkleBuild.leaf(epochId, a, 100e18);
        l[1] = MerkleBuild.leaf(epochId, b, 200e18);
        root = MerkleBuild.root(l);
        pa = MerkleBuild.proof(l, 0);
        pb = MerkleBuild.proof(l, 1);
    }

    // ------------------------------------------------------------------------------------------------------------ fee on transfer
    function test_feeOnTransferTokenCannotFundAnEpoch() public {
        FeeToken t = new FeeToken();
        D d = new D(IERC20(address(t)), safe, DELAY, DEADLINE);
        t.mint(safe, 1000e18);
        vm.startPrank(safe);
        t.approve(address(d), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(D.TransferAmountMismatch.selector, 300e18, 297e18));
        d.publishEpoch(bytes32(uint256(1)), 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.stopPrank();
        assertEq(d.epochCount(), 0);
        assertEq(t.balanceOf(address(d)), 0);
    }

    function test_overDeliveringTokenCannotFundAnEpochEither() public {
        BonusToken t = new BonusToken();
        D d = new D(IERC20(address(t)), safe, DELAY, DEADLINE);
        t.mint(safe, 1000e18);
        vm.startPrank(safe);
        t.approve(address(d), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(D.TransferAmountMismatch.selector, 300e18, 303e18));
        d.publishEpoch(bytes32(uint256(1)), 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------ false return
    function test_falseReturningTokenRevertsOnPublishAndOnClaim() public {
        FalseReturnToken t = new FalseReturnToken();
        D d = new D(IERC20(address(t)), safe, DELAY, DEADLINE);
        t.mint(safe, 1000e18);
        vm.prank(safe);
        t.approve(address(d), type(uint256).max);
        (bytes32 root, bytes32[] memory pa,) = _two(alice, bob, 0);

        t.setBroken(true);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(d.epochCount(), 0, "state rolled back");

        t.setBroken(false);
        vm.prank(safe);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        t.setBroken(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        d.claim(0, alice, 100e18, pa);
        assertFalse(d.isClaimed(0, alice), "a failed payment does not burn the claim");
        assertEq(d.epochInfo(0).claimed, 0);
        t.setBroken(false);
        d.claim(0, alice, 100e18, pa);
        assertEq(t.balanceOf(alice), 100e18);
    }

    function test_falseReturningTokenRevertsOnCancelAndSweep() public {
        FalseReturnToken t = new FalseReturnToken();
        D d = new D(IERC20(address(t)), safe, DELAY, DEADLINE);
        t.mint(safe, 1000e18);
        vm.prank(safe);
        t.approve(address(d), type(uint256).max);
        (bytes32 root,,) = _two(alice, bob, 0);
        vm.prank(safe);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        t.setBroken(true);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        d.cancelEpoch(0);
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.Open), "the cancel did not half-happen");
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        d.sweepUnclaimed(0);
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.Open));
    }

    // ------------------------------------------------------------------------------------------------------------ no return value (USDT style)
    function test_noReturnValueTokenWorksEndToEnd() public {
        NoReturnToken t = new NoReturnToken();
        D d = new D(IERC20(address(t)), safe, DELAY, DEADLINE);
        t.mint(safe, 1000e18);
        vm.prank(safe);
        t.approve(address(d), type(uint256).max);
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _two(alice, bob, 0);
        vm.prank(safe);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        d.claim(0, alice, 100e18, pa);
        d.claim(0, bob, 200e18, pb);
        assertEq(t.balanceOf(alice), 100e18);
        assertEq(t.balanceOf(bob), 200e18);
        assertEq(t.balanceOf(address(d)), 0);
    }

    // ------------------------------------------------------------------------------------------------------------ blacklisting token
    function test_blockedAccountOnlyBlocksItself() public {
        BlacklistToken t = new BlacklistToken();
        D d = new D(IERC20(address(t)), safe, DELAY, DEADLINE);
        t.mint(safe, 1000e18);
        vm.prank(safe);
        t.approve(address(d), type(uint256).max);
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _two(alice, bob, 0);
        vm.prank(safe);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        t.setBlocked(alice, true);
        vm.expectRevert(bytes("blocked"));
        d.claim(0, alice, 100e18, pa);
        d.claim(0, bob, 200e18, pb); // bob is not affected
        assertEq(t.balanceOf(bob), 200e18);
        // claimMany is atomic: a blocked entry fails the batch (documented), the others can claim singly
        D.Claim[] memory cs = new D.Claim[](1);
        cs[0] = D.Claim(0, alice, 100e18, pa);
        vm.expectRevert(bytes("blocked"));
        d.claimMany(cs);
        // alice's 100 stays in the epoch and goes back to the Safe after the deadline
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        uint256 before_ = t.balanceOf(safe);
        vm.prank(safe);
        d.sweepUnclaimed(0);
        assertEq(t.balanceOf(safe), before_ + 100e18);
    }

    // ------------------------------------------------------------------------------------------------------------ re-entrancy
    function _hookSetup() internal returns (HookToken t, D d, Reenterer atk, bytes32 root, bytes32[] memory pa, bytes32[] memory pb) {
        t = new HookToken();
        atk = new Reenterer();
        d = new D(IERC20(address(t)), safe, DELAY, DEADLINE);
        t.setExempt(address(d));
        t.mint(safe, 1000e18);
        vm.prank(safe);
        t.approve(address(d), type(uint256).max);
        (root, pa, pb) = _two(address(atk), bob, 0); // the attacker contract is account 0
        vm.prank(safe);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
    }

    function test_recipientHookCannotClaimAgainOrClaimTheOtherLeaf() public {
        (HookToken t, D d, Reenterer atk, , bytes32[] memory pa, bytes32[] memory pb) = _hookSetup();
        // inside its own payment the attacker tries to claim bob's leaf (to bob, harmless but must be blocked), then its own again
        atk.arm(address(d), abi.encodeCall(D.claim, (0, bob, 200e18, pb)));
        d.claim(0, address(atk), 100e18, pa);
        assertEq(atk.hits(), 1);
        assertFalse(atk.lastSucceeded(), "re-entrant claim must fail");
        assertEq(bytes4(atk.lastReturn()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(t.balanceOf(bob), 0, "bob was not paid by the re-entrant call");
        assertEq(t.balanceOf(address(atk)), 100e18);
        assertEq(d.epochInfo(0).claimed, 100e18);

        // claimMany: the hook of the attacker's payment tries to claim bob's (valid, unclaimed) leaf
        (t, d, atk,, pa, pb) = _hookSetup();
        atk.arm(address(d), abi.encodeCall(D.claim, (0, bob, 200e18, pb)));
        D.Claim[] memory cs = new D.Claim[](1);
        cs[0] = D.Claim(0, address(atk), 100e18, pa);
        d.claimMany(cs);
        assertEq(atk.hits(), 1);
        assertFalse(atk.lastSucceeded(), "claimMany holds the same lock");
        assertEq(t.balanceOf(address(atk)), 100e18, "paid once");
        assertEq(t.balanceOf(bob), 0);
        // and a re-entering claimMany is blocked from inside claim
        (t, d, atk,, pa, pb) = _hookSetup();
        D.Claim[] memory inner = new D.Claim[](1);
        inner[0] = D.Claim(0, bob, 200e18, pb);
        atk.arm(address(d), abi.encodeCall(D.claimMany, (inner)));
        d.claim(0, address(atk), 100e18, pa);
        assertFalse(atk.lastSucceeded());
        assertEq(t.balanceOf(bob), 0);
    }

    function test_recipientHookReentrancyBubblingUpRevertsTheWholeClaim() public {
        HookToken t = new HookToken();
        BubblingReenterer atk = new BubblingReenterer();
        D d = new D(IERC20(address(t)), safe, DELAY, DEADLINE);
        t.setExempt(address(d));
        t.mint(safe, 1000e18);
        vm.prank(safe);
        t.approve(address(d), type(uint256).max);
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _two(address(atk), bob, 0);
        vm.prank(safe);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        atk.arm(address(d), abi.encodeCall(D.claim, (0, bob, 200e18, pb)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        d.claim(0, address(atk), 100e18, pa);
        assertFalse(d.isClaimed(0, address(atk)));
        assertEq(t.balanceOf(address(d)), 300e18);
    }

    function test_ownerContractCannotReenterDuringItsRefundOrSweep() public {
        // the OWNER is a contract with a receive hook (the Safe is a contract too): during the refund of cancelEpoch / the payout of sweepUnclaimed it tries to
        // publish, cancel, sweep again
        HookToken t = new HookToken();
        Reenterer ownerC = new Reenterer();
        D d = new D(IERC20(address(t)), address(ownerC), DELAY, DEADLINE);
        t.setExempt(address(d));
        t.mint(address(ownerC), 1000e18);
        ownerC.approveToken(address(t), address(d), type(uint256).max);
        (bytes32 root,,) = _two(alice, bob, 0);

        ownerC.exec(address(d), abi.encodeCall(D.publishEpoch, (root, 300e18, PUB_FROM, PUB_TO, PUB_DATA)));
        // cancel: inside the refund callback the owner re-enters cancelEpoch(0)
        ownerC.arm(address(d), abi.encodeCall(D.cancelEpoch, (0)));
        ownerC.exec(address(d), abi.encodeCall(D.cancelEpoch, (0)));
        assertEq(ownerC.hits(), 1);
        assertFalse(ownerC.lastSucceeded());
        assertEq(bytes4(ownerC.lastReturn()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(t.balanceOf(address(ownerC)), 1000e18, "refunded once");

        // sweep: the owner re-enters publishEpoch (to pull more) and sweep
        ownerC.exec(address(d), abi.encodeCall(D.publishEpoch, (root, 300e18, PUB_FROM, PUB_TO, PUB_DATA))); // id 1
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        ownerC.arm(address(d), abi.encodeCall(D.sweepUnclaimed, (1)));
        ownerC.exec(address(d), abi.encodeCall(D.sweepUnclaimed, (1)));
        assertFalse(ownerC.lastSucceeded());
        assertEq(t.balanceOf(address(ownerC)), 1000e18);
        assertEq(t.balanceOf(address(d)), 0);
    }
}
