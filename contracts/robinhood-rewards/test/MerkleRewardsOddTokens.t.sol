// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test} from "forge-std/Test.sol";
import {MerkleRewardsDistributor as D} from "../src/MerkleRewardsDistributor.sol";
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

/// @notice The distributor against tokens that do not behave like a plain ERC-20 (RAM is plain; these are "what if" cases).
contract MerkleRewardsOddTokensTest is Test {
    uint256 internal constant DELAY = 1 days;
    uint256 internal constant DEADLINE = 180 days;
    address internal owner_ = makeAddr("ledger");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(26_000_000);
    }

    function _two(address a, address b, uint256 epochId)
        internal
        pure
        returns (bytes32 root, bytes32[] memory pa, bytes32[] memory pb)
    {
        bytes32[] memory l = new bytes32[](2);
        l[0] = MerkleBuild.leaf(epochId, a, 100e18);
        l[1] = MerkleBuild.leaf(epochId, b, 200e18);
        root = MerkleBuild.root(l);
        pa = MerkleBuild.proof(l, 0);
        pb = MerkleBuild.proof(l, 1);
    }

    // ------------------------------------------------------------------------------------- fee on transfer / bonus
    function test_feeOnTransferFundingCommitsOnlyWhatArrived() public {
        FeeToken t = new FeeToken(); // 1% fee
        D d = new D(IERC20(address(t)), owner_, DELAY, DEADLINE);
        t.mint(address(this), 1000e18);
        t.transfer(address(d), 300e18); // 297 arrive
        assertEq(d.unallocated(), 297e18);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.InsufficientUnallocated.selector, 297e18, 300e18));
        d.publishEpoch(bytes32(uint256(1)), 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(d.epochCount(), 0);
    }

    function test_overDeliveringTokenOnlyAddsUnallocated() public {
        BonusToken t = new BonusToken();
        D d = new D(IERC20(address(t)), owner_, DELAY, DEADLINE);
        t.mint(address(this), 1000e18);
        t.transfer(address(d), 300e18);
        assertEq(d.unallocated(), 303e18);
        (bytes32 root,,) = _two(alice, bob, 0);
        vm.prank(owner_);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(d.unallocated(), 3e18);
    }

    // ------------------------------------------------------------------------------------- false / no return
    function test_falseReturningTokenRevertsOnClaim() public {
        FalseReturnToken t = new FalseReturnToken();
        D d = new D(IERC20(address(t)), owner_, DELAY, DEADLINE);
        t.mint(address(d), 300e18);
        (bytes32 root, bytes32[] memory pa,) = _two(alice, bob, 0);
        vm.prank(owner_);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        t.setBroken(true);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(t)));
        d.claim(0, alice, 100e18, pa);
        assertFalse(d.isClaimed(0, alice), "a failed transfer leaves no claimed flag");
        assertEq(d.reserved(), 300e18);
        t.setBroken(false);
        d.claim(0, alice, 100e18, pa);
        assertEq(t.balanceOf(alice), 100e18);
    }

    function test_noReturnValueTokenWorksEndToEnd() public {
        NoReturnToken t = new NoReturnToken();
        D d = new D(IERC20(address(t)), owner_, DELAY, DEADLINE);
        t.mint(address(d), 300e18);
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _two(alice, bob, 0);
        vm.prank(owner_);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        d.claim(0, alice, 100e18, pa);
        d.claim(0, bob, 200e18, pb);
        assertEq(t.balanceOf(alice), 100e18);
        assertEq(t.balanceOf(bob), 200e18);
        assertEq(d.reserved(), 0);
    }

    // ------------------------------------------------------------------------------------- blocked account
    function test_blockedAccountOnlyBlocksItself() public {
        BlacklistToken t = new BlacklistToken();
        D d = new D(IERC20(address(t)), owner_, DELAY, DEADLINE);
        t.mint(address(d), 300e18);
        (bytes32 root, bytes32[] memory pa, bytes32[] memory pb) = _two(alice, bob, 0);
        vm.prank(owner_);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        t.setBlocked(alice, true);
        vm.expectRevert(bytes("blocked"));
        d.claim(0, alice, 100e18, pa);
        d.claim(0, bob, 200e18, pb);
        assertEq(t.balanceOf(bob), 200e18);
        D.Claim[] memory cs = new D.Claim[](2);
        cs[0] = D.Claim(0, bob, 200e18, pb); // skipped (already claimed)
        cs[1] = D.Claim(0, alice, 100e18, pa); // blocked: the whole batch reverts
        vm.expectRevert(bytes("blocked"));
        d.claimMany(cs);
    }

    // ------------------------------------------------------------------------------------- re-entrancy through a hook
    function test_recipientHookCannotClaimAgainOrClaimTheOtherLeaf() public {
        HookToken t = new HookToken();
        D d = new D(IERC20(address(t)), owner_, DELAY, DEADLINE);
        t.setExempt(address(d));
        Reenterer r = new Reenterer();
        t.mint(address(d), 300e18);
        (bytes32 root, bytes32[] memory pr, bytes32[] memory pb) = _two(address(r), bob, 0);
        vm.prank(owner_);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);

        r.arm(address(d), abi.encodeCall(D.claim, (0, address(r), 100e18, pr)));
        d.claim(0, address(r), 100e18, pr);
        assertEq(r.hits(), 1);
        assertFalse(r.lastSucceeded(), "re-entrant claim refused");
        assertEq(bytes4(r.lastReturn()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(t.balanceOf(address(r)), 100e18);

        // a second leaf of epoch 1 for r; inside its hook r tries to claim bob's leaf of epoch 0 (pays bob anyway) via claimMany
        t.mint(address(d), 100e18);
        bytes32 leaf1 = MerkleBuild.leaf(1, address(r), 100e18);
        vm.prank(owner_);
        d.publishEpoch(leaf1, 100e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        D.Claim[] memory cs = new D.Claim[](1);
        cs[0] = D.Claim(0, bob, 200e18, pb);
        r.arm(address(d), abi.encodeCall(D.claimMany, (cs)));
        d.claim(1, address(r), 100e18, new bytes32[](0));
        assertFalse(r.lastSucceeded());
        assertEq(t.balanceOf(bob), 0);
        d.claim(0, bob, 200e18, pb);
        assertEq(t.balanceOf(bob), 200e18);
        assertEq(d.reserved(), 0);
    }

    function test_recipientHookReentrancyBubblingUpRevertsTheWholeClaim() public {
        HookToken t = new HookToken();
        D d = new D(IERC20(address(t)), owner_, DELAY, DEADLINE);
        t.setExempt(address(d));
        BubblingReenterer r = new BubblingReenterer();
        t.mint(address(d), 300e18);
        (bytes32 root, bytes32[] memory pr,) = _two(address(r), bob, 0);
        vm.prank(owner_);
        d.publishEpoch(root, 300e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        r.arm(address(d), abi.encodeCall(D.claim, (0, address(r), 100e18, pr)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        d.claim(0, address(r), 100e18, pr);
        assertFalse(d.isClaimed(0, address(r)));
        assertEq(d.reserved(), 300e18);
    }

    function test_ownerContractCannotReenterPublishFromAClaimHook() public {
        // the owner is a contract that also holds a leaf; inside its claim hook it tries to publish a new epoch
        HookToken t = new HookToken();
        Reenterer ownerC = new Reenterer();
        D d = new D(IERC20(address(t)), address(ownerC), DELAY, DEADLINE);
        t.setExempt(address(d));
        t.mint(address(d), 400e18);
        (bytes32 root, bytes32[] memory po,) = _two(address(ownerC), bob, 0);
        ownerC.exec(address(d), abi.encodeCall(D.publishEpoch, (root, 300e18, PUB_FROM, PUB_TO, PUB_DATA)));
        vm.warp(vm.getBlockTimestamp() + DELAY);
        ownerC.arm(address(d), abi.encodeCall(D.publishEpoch, (bytes32(uint256(7)), 100e18, PUB_FROM, PUB_TO, PUB_DATA)));
        d.claim(0, address(ownerC), 100e18, po);
        assertFalse(ownerC.lastSucceeded(), "re-entrant publish refused");
        assertEq(d.epochCount(), 1);
        // outside of a claim the same publish works
        ownerC.exec(address(d), abi.encodeCall(D.publishEpoch, (bytes32(uint256(7)), 100e18, PUB_FROM, PUB_TO, PUB_DATA)));
        assertEq(d.epochCount(), 2);
    }
}
