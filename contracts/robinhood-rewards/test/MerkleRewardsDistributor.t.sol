// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MerkleRewardsDistributor as D} from "../src/MerkleRewardsDistributor.sol";
import {RewardsBase, Tree, MerkleBuild, RewardMock, PUB_FROM, PUB_TO, PUB_DATA} from "./RewardsBase.sol";

contract MerkleRewardsDistributorTest is RewardsBase {
    event EpochPublished(
        uint256 indexed epochId,
        bytes32 root,
        uint256 total,
        uint64 fromBlock,
        uint64 toBlock,
        bytes32 dataHash,
        uint256 publishedAt,
        uint256 claimOpensAt,
        uint256 claimDeadline
    );
    event EpochCancelled(uint256 indexed epochId, uint256 released);
    event Claimed(uint256 indexed epochId, address indexed account, uint256 amount);
    event EpochSwept(uint256 indexed epochId, uint256 released);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ============================================================================================ constructor
    function test_constructorSetsEverything() public view {
        assertEq(address(d.REWARD_TOKEN()), address(ram));
        assertEq(d.owner(), owner_);
        assertEq(d.pendingOwner(), address(0));
        assertEq(d.CLAIM_DELAY(), DELAY);
        assertEq(d.CLAIM_DEADLINE(), DEADLINE);
        assertEq(d.epochCount(), 0);
        assertEq(d.reserved(), 0);
        assertEq(d.unallocated(), 0);
        assertEq(d.MIN_CLAIM_WINDOW(), 7 days);
    }

    function test_constructorRefusesBadInputs() public {
        vm.expectRevert(D.ZeroAddress.selector);
        new D(IERC20(address(0)), owner_, DELAY, DEADLINE);
        vm.expectRevert(D.NotAContract.selector);
        new D(IERC20(alice), owner_, DELAY, DEADLINE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new D(ram, address(0), DELAY, DEADLINE);
        vm.expectRevert(D.BadWindow.selector);
        new D(ram, owner_, 0, DEADLINE);
        vm.expectRevert(D.BadWindow.selector);
        new D(ram, owner_, DELAY, DELAY);
        vm.expectRevert(D.BadWindow.selector);
        new D(ram, owner_, DELAY, DELAY + 7 days - 1);
        new D(ram, owner_, DELAY, DELAY + 7 days); // exactly the minimum is fine
        vm.expectRevert(D.BadWindow.selector);
        new D(ram, owner_, DELAY, 10 * 365 days + 1);
        new D(ram, owner_, DELAY, 10 * 365 days);
    }

    // ============================================================================================ happy path
    function test_happyPath_forwardPublishWaitClaimAll() public {
        Tree memory t = _tree5(0);
        _fund(t.total);
        assertEq(d.unallocated(), t.total);

        vm.expectEmit(true, false, false, true, address(d));
        emit EpochPublished(
            0,
            t.root,
            t.total,
            PUB_FROM,
            PUB_TO,
            PUB_DATA,
            vm.getBlockTimestamp(),
            vm.getBlockTimestamp() + DELAY,
            vm.getBlockTimestamp() + DEADLINE
        );
        _publishOnly(t);
        assertEq(ram.balanceOf(address(d)), t.total);
        assertEq(d.reserved(), t.total);
        assertEq(d.unallocated(), 0);
        assertEq(d.epochCount(), 1);

        D.EpochView memory v = d.epochInfo(0);
        assertEq(v.root, t.root);
        assertEq(v.total, t.total);
        assertEq(v.claimed, 0);
        assertEq(v.publishedAt, vm.getBlockTimestamp());
        assertEq(v.claimOpensAt, vm.getBlockTimestamp() + DELAY);
        assertEq(v.claimDeadline, vm.getBlockTimestamp() + DEADLINE);
        assertEq(v.fromBlock, PUB_FROM);
        assertEq(v.toBlock, PUB_TO);
        assertEq(v.dataHash, PUB_DATA);
        assertEq(uint8(v.status), uint8(D.Status.Open));

        _openWindow();
        assertTrue(d.isClaimWindowOpen(0));
        uint256 paid;
        for (uint256 i = 0; i < 5; ++i) {
            assertFalse(d.isClaimed(0, t.accounts[i]));
            assertTrue(d.verifyLeaf(0, t.accounts[i], t.amounts[i], _proof(t, i)));
            vm.expectEmit(true, true, false, true, address(d));
            emit Claimed(0, t.accounts[i], t.amounts[i]);
            vm.prank(rando); // anyone may submit; the tokens go to the account
            _claim(t, i);
            paid += t.amounts[i];
            assertEq(ram.balanceOf(t.accounts[i]), t.amounts[i]);
            assertTrue(d.isClaimed(0, t.accounts[i]));
            assertEq(d.epochInfo(0).claimed, paid);
            assertEq(d.reserved(), t.total - paid);
        }
        assertEq(ram.balanceOf(rando), 0, "the submitter never gets anything");
        assertEq(ram.balanceOf(address(d)), 0);
        assertEq(d.reserved(), 0);
    }

    function test_l2BlockRangeAboveTheEvmBlockNumberIsAccepted() public {
        // Robinhood Chain (Arbitrum Orbit): block.number is the L1-derived number, the epoch range is in L2 heights.
        assertLt(block.number, PUB_FROM);
        Tree memory t = _tree5(0);
        _fund(t.total);
        vm.prank(owner_);
        d.publishEpoch(t.root, t.total, type(uint64).max - 1, type(uint64).max, PUB_DATA);
        assertEq(d.epochInfo(0).toBlock, type(uint64).max);
    }

    function test_singleLeafTreeHasAnEmptyProof() public {
        address[] memory a = new address[](1);
        uint256[] memory m = new uint256[](1);
        a[0] = alice;
        m[0] = 7e18;
        Tree memory t = _tree(0, a, m);
        assertEq(t.root, t.leaves[0]);
        _publish(t);
        _openWindow();
        assertEq(_proof(t, 0).length, 0);
        _claim(t, 0);
        assertEq(ram.balanceOf(alice), 7e18);
    }

    function test_oddSizedTreesAllLeavesClaim() public {
        for (uint256 n = 2; n <= 9; ++n) {
            Tree memory t = _manyLeaves(d.epochCount(), n);
            _publish(t);
            vm.warp(vm.getBlockTimestamp() + DELAY);
            for (uint256 i = 0; i < n; ++i) {
                _claim(t, i);
            }
            assertEq(d.epochInfo(t.epochId).claimed, t.total);
        }
        assertEq(d.reserved(), 0);
    }

    function _manyLeaves(uint256 epochId, uint256 n) internal pure returns (Tree memory) {
        address[] memory a = new address[](n);
        uint256[] memory m = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = address(uint160(0x1000 + i * 7 + epochId * 1000));
            m[i] = (i + 1) * 1e17 + epochId;
        }
        return _tree(epochId, a, m);
    }

    function test_twoEpochsAreIndependentAndSameAccountClaimsBoth() public {
        Tree memory t0 = _tree5(0);
        Tree memory t1 = _tree5(1);
        _publish(t0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _publish(t1);
        _claim(t0, 0);
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, vm.getBlockTimestamp() + DELAY));
        _claim(t1, 0);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        _claim(t1, 0);
        assertEq(ram.balanceOf(alice), 200e18);
        assertTrue(d.isClaimed(0, alice));
        assertTrue(d.isClaimed(1, alice));
        assertFalse(d.isClaimed(1, bob));
    }

    // ============================================================================================ funding
    function test_publishNeedsUnallocatedTokens() public {
        Tree memory t = _tree5(0);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.InsufficientUnallocated.selector, 0, t.total));
        d.publishEpoch(t.root, t.total, PUB_FROM, PUB_TO, PUB_DATA);
        _fund(t.total - 1);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.InsufficientUnallocated.selector, t.total - 1, t.total));
        d.publishEpoch(t.root, t.total, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(d.epochCount(), 0, "a failed publish leaves no epoch behind");
        _fund(1);
        _publishOnly(t); // exactly enough
        assertEq(d.unallocated(), 0);
    }

    function test_publishCannotCommitAnotherEpochsTokens() public {
        Tree memory t0 = _tree5(0);
        _publish(t0);
        Tree memory t1 = _tree5(1);
        // 1500 in the contract, all reserved for epoch 0: epoch 1 needs its own forward
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.InsufficientUnallocated.selector, 0, t1.total));
        d.publishEpoch(t1.root, t1.total, PUB_FROM, PUB_TO, PUB_DATA);
        // after some claims of epoch 0 the freed balance is still NOT free: claims move it out
        _openWindow();
        _claim(t0, 4);
        assertEq(d.unallocated(), 0);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.InsufficientUnallocated.selector, 0, t1.total));
        d.publishEpoch(t1.root, t1.total, PUB_FROM, PUB_TO, PUB_DATA);
    }

    function test_publishDoesNotPullFromTheOwner() public {
        ram.mint(owner_, 1000e18);
        vm.prank(owner_);
        ram.approve(address(d), type(uint256).max);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.InsufficientUnallocated.selector, 0, 10e18));
        d.publishEpoch(bytes32(uint256(1)), 10e18, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(ram.balanceOf(owner_), 1000e18);
    }

    function test_donatedTokensAreUnallocatedAndCommittable() public {
        Tree memory t = _tree5(0);
        _publish(t);
        ram.mint(address(d), 77e18); // sent directly, not through a forward
        assertEq(d.unallocated(), 77e18);
        assertEq(d.reserved(), t.total);
        address[] memory a = new address[](1);
        uint256[] memory m = new uint256[](1);
        a[0] = carol;
        m[0] = 77e18;
        Tree memory t1 = _tree(1, a, m);
        _publishOnly(t1);
        _openWindow();
        _claim(t1, 0);
        assertEq(ram.balanceOf(carol), 77e18);
    }

    // ============================================================================================ claim: double / wrong
    function test_doubleClaimReverts() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        _claim(t, 2);
        vm.expectRevert(D.AlreadyClaimed.selector);
        _claim(t, 2);
        assertEq(ram.balanceOf(carol), 300e18);
        assertEq(d.epochInfo(0).claimed, 300e18);
    }

    function test_wrongAmountAccountAndProofRevert() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        bytes32[] memory p = _proof(t, 1); // bob
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18 + 1, p);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18 - 1, p);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 300e18, p);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, alice, 200e18, p);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, rando, 200e18, p);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, _proof(t, 3));
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, new bytes32[](0));
        bytes32[] memory flipped = _proof(t, 1);
        flipped[0] = bytes32(uint256(flipped[0]) ^ 1);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, flipped);
        bytes32[] memory longer = new bytes32[](p.length + 1);
        for (uint256 i = 0; i < p.length; ++i) {
            longer[i] = p[i];
        }
        longer[p.length] = bytes32(uint256(42));
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, longer);
        bytes32[] memory shorter = new bytes32[](p.length - 1);
        for (uint256 i = 0; i < shorter.length; ++i) {
            shorter[i] = p[i];
        }
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, shorter);
        d.claim(0, bob, 200e18, p);
        assertEq(ram.balanceOf(bob), 200e18);
    }

    function test_zeroAccountAndZeroAmountAreRefused() public {
        address[] memory a = new address[](2);
        uint256[] memory m = new uint256[](2);
        a[0] = alice;
        m[0] = 0;
        a[1] = bob;
        m[1] = 5e18;
        Tree memory t = _tree(0, a, m);
        _publish(t);
        _openWindow();
        vm.expectRevert(D.ZeroAmount.selector);
        _claim(t, 0);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, address(0), 5e18, _proof(t, 1));
        _claim(t, 1);
    }

    function test_proofOfOneEpochDoesNotWorkInAnotherEpochWithTheSameRoot() public {
        Tree memory t0 = _tree5(0);
        _fund(1 + t0.total);
        vm.prank(owner_);
        d.publishEpoch(bytes32(uint256(0xdead)), 1, PUB_FROM, PUB_TO, PUB_DATA); // burns id 0
        vm.prank(owner_);
        d.publishEpoch(t0.root, t0.total, PUB_FROM, PUB_TO, PUB_DATA); // id 1, but the leaves say id 0
        _openWindow();
        for (uint256 i = 0; i < 5; ++i) {
            vm.expectRevert(D.InvalidProof.selector);
            d.claim(1, t0.accounts[i], t0.amounts[i], _proof(t0, i));
            vm.expectRevert(D.InvalidProof.selector);
            d.claim(0, t0.accounts[i], t0.amounts[i], _proof(t0, i));
        }
        vm.prank(owner_);
        vm.expectRevert(D.WindowOver.selector);
        d.cancelEpoch(1);
    }

    function test_claimOnUnknownOrDeadEpochs() public {
        bytes32[] memory p = new bytes32[](0);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.None));
        d.claim(0, alice, 1, p);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.None));
        d.claim(type(uint256).max, alice, 1, p);
    }

    // ============================================================================================ claimMany
    function test_claimManySkipsAlreadyClaimedAndPaysEveryone() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        _claim(t, 1);
        D.Claim[] memory cs = new D.Claim[](5);
        for (uint256 i = 0; i < 5; ++i) {
            cs[i] = D.Claim(0, t.accounts[i], t.amounts[i], _proof(t, i));
        }
        vm.recordLogs();
        vm.prank(rando);
        d.claimMany(cs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fromDistributor;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(d)) ++fromDistributor;
        }
        assertEq(fromDistributor, 4, "4 Claimed events, bob skipped");
        for (uint256 i = 0; i < 5; ++i) {
            assertEq(ram.balanceOf(t.accounts[i]), t.amounts[i], "each paid exactly once");
        }
        assertEq(d.epochInfo(0).claimed, t.total);
        assertEq(d.reserved(), 0);
    }

    function test_claimManyRevertsWholeBatchOnABadEntry() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        D.Claim[] memory cs = new D.Claim[](3);
        cs[0] = D.Claim(0, alice, 100e18, _proof(t, 0));
        cs[1] = D.Claim(0, bob, 200e18 + 1, _proof(t, 1));
        cs[2] = D.Claim(0, carol, 300e18, _proof(t, 2));
        vm.expectRevert(D.InvalidProof.selector);
        d.claimMany(cs);
        assertEq(ram.balanceOf(alice), 0, "atomic");
    }

    function test_claimManyAcrossEpochsAndEmpty() public {
        Tree memory t0 = _tree5(0);
        Tree memory t1 = _tree5(1);
        _publish(t0);
        _publish(t1);
        _openWindow();
        D.Claim[] memory cs = new D.Claim[](2);
        cs[0] = D.Claim(0, alice, 100e18, _proof(t0, 0));
        cs[1] = D.Claim(1, alice, 100e18, _proof(t1, 0));
        d.claimMany(cs);
        assertEq(ram.balanceOf(alice), 200e18);
        d.claimMany(new D.Claim[](0));
    }

    function test_claimManyEnforcesTheWindowPerEntry() public {
        Tree memory t0 = _tree5(0);
        _publish(t0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        Tree memory t1 = _tree5(1);
        _publish(t1);
        D.Claim[] memory cs = new D.Claim[](2);
        cs[0] = D.Claim(0, alice, 100e18, _proof(t0, 0));
        cs[1] = D.Claim(1, alice, 100e18, _proof(t1, 0));
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, vm.getBlockTimestamp() + DELAY));
        d.claimMany(cs);
    }

    // ============================================================================================ timing
    function test_claimBeforeWindowRevertsAtEveryTimeUpToTheBoundary() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        uint256 opens = t0 + DELAY;
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, opens));
        _claim(t, 0);
        vm.warp(t0 + 1);
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, opens));
        _claim(t, 0);
        vm.warp(opens - 1);
        assertFalse(d.isClaimWindowOpen(0));
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, opens));
        _claim(t, 0);
        vm.warp(opens);
        assertTrue(d.isClaimWindowOpen(0));
        _claim(t, 0);
        assertEq(ram.balanceOf(alice), 100e18);
    }

    function test_claimDeadlineBoundary() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        vm.warp(t0 + DEADLINE - 1);
        assertTrue(d.isClaimWindowOpen(0));
        _claim(t, 0);
        vm.warp(t0 + DEADLINE);
        assertFalse(d.isClaimWindowOpen(0));
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsClosed.selector, t0 + DEADLINE));
        _claim(t, 1);
        vm.warp(t0 + DEADLINE + 365 days);
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsClosed.selector, t0 + DEADLINE));
        _claim(t, 1);
    }

    // ============================================================================================ cancel
    function test_cancelInsideWindowReleasesEverythingWithoutATransfer() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        uint256 ownerBefore = ram.balanceOf(owner_);
        vm.warp(t0 + DELAY - 1); // the very last second of the window
        vm.expectEmit(true, false, false, true, address(d));
        emit EpochCancelled(0, t.total);
        vm.prank(owner_);
        d.cancelEpoch(0);
        assertEq(ram.balanceOf(owner_), ownerBefore, "no refund to the owner");
        assertEq(ram.balanceOf(address(d)), t.total, "the tokens stay");
        assertEq(d.reserved(), 0);
        assertEq(d.unallocated(), t.total);
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.Cancelled));
        assertEq(d.epochCount(), 1, "the id stays burnt");
        vm.warp(t0 + DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Cancelled));
        _claim(t, 0);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Cancelled));
        d.cancelEpoch(0);
        vm.warp(t0 + DEADLINE);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Cancelled));
        d.sweepUnclaimed(0);
    }

    function test_cancelAtTheSameBlockAsPublish() public {
        Tree memory t = _tree5(0);
        _publish(t);
        vm.prank(owner_);
        d.cancelEpoch(0);
        assertEq(d.unallocated(), t.total);
    }

    function test_cancelAtOrAfterTheWindowReverts() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        vm.warp(t0 + DELAY);
        vm.prank(owner_);
        vm.expectRevert(D.WindowOver.selector);
        d.cancelEpoch(0);
        vm.warp(t0 + DELAY + 1 days);
        vm.prank(owner_);
        vm.expectRevert(D.WindowOver.selector);
        d.cancelEpoch(0);
        _claim(t, 0);
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.Open));
    }

    function test_cancelAfterAClaimIsImpossible() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        _claim(t, 0);
        vm.prank(owner_);
        vm.expectRevert(D.WindowOver.selector);
        d.cancelEpoch(0);
    }

    function test_cancelUnknownEpoch() public {
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.None));
        d.cancelEpoch(0);
    }

    function test_cancelThenRepublishFromTheReleasedTokensWithoutANewForward() public {
        Tree memory bad = _tree5(0);
        _publish(bad);
        vm.prank(owner_);
        d.cancelEpoch(0);
        Tree memory good = _tree5(1); // regenerated for the new id
        _publishOnly(good); // no new forward needed
        _openWindow();
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Cancelled));
        _claim(bad, 0);
        _claim(good, 0);
        assertEq(ram.balanceOf(alice), 100e18);
    }

    // ============================================================================================ sweep
    function test_sweepBeforeDeadlineReverts() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.DeadlineNotReached.selector, t0 + DEADLINE));
        d.sweepUnclaimed(0);
        vm.warp(t0 + DELAY + 5 days);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.DeadlineNotReached.selector, t0 + DEADLINE));
        d.sweepUnclaimed(0);
        vm.warp(t0 + DEADLINE - 1);
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.DeadlineNotReached.selector, t0 + DEADLINE));
        d.sweepUnclaimed(0);
    }

    function test_sweepAfterDeadlineReleasesExactlyTheUnclaimedOnce() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        _openWindow();
        _claim(t, 0);
        _claim(t, 4); // 100 + 500 claimed, 900 left
        vm.warp(t0 + DEADLINE);
        vm.expectEmit(true, false, false, true, address(d));
        emit EpochSwept(0, 900e18);
        vm.prank(owner_);
        d.sweepUnclaimed(0);
        assertEq(ram.balanceOf(owner_), 0, "nothing goes to the owner");
        assertEq(ram.balanceOf(address(d)), 900e18);
        assertEq(d.reserved(), 0);
        assertEq(d.unallocated(), 900e18);
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.Swept));
        assertEq(d.epochInfo(0).claimed, 600e18, "claimed is not rewritten by the sweep");
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Swept));
        d.sweepUnclaimed(0);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Swept));
        _claim(t, 1);
        // the swept rest can only leave through a new (challengeable) epoch
        address[] memory a = new address[](1);
        uint256[] memory m = new uint256[](1);
        a[0] = makeAddr("protocol");
        m[0] = 900e18;
        Tree memory t1 = _tree(1, a, m);
        _publishOnly(t1);
        _openWindow();
        _claim(t1, 0);
        assertEq(ram.balanceOf(a[0]), 900e18);
    }

    function test_sweepWhenEverythingWasClaimedReleasesNothing() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        for (uint256 i = 0; i < 5; ++i) {
            _claim(t, i);
        }
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        vm.expectEmit(true, false, false, true, address(d));
        emit EpochSwept(0, 0);
        vm.prank(owner_);
        d.sweepUnclaimed(0);
        assertEq(d.unallocated(), 0);
    }

    function test_sweepOfOneEpochDoesNotTouchAnother() public {
        Tree memory t0 = _tree5(0);
        _publish(t0);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        Tree memory t1 = _tree5(1);
        _publish(t1);
        vm.warp(vm.getBlockTimestamp() + 80 days);
        vm.prank(owner_);
        d.sweepUnclaimed(0);
        assertEq(d.reserved(), t1.total, "epoch 1 reservation intact");
        assertEq(d.unallocated(), t0.total);
        _claim(t1, 0);
        assertEq(ram.balanceOf(alice), 100e18);
        uint256 dl1 = d.epochInfo(1).claimDeadline;
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.DeadlineNotReached.selector, dl1));
        d.sweepUnclaimed(1);
    }

    function test_sweepUnknownEpoch() public {
        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.None));
        d.sweepUnclaimed(7);
    }

    // ============================================================================================ over-commit
    function test_leavesAddingUpToMoreThanTotalCannotOverdraw() public {
        Tree memory over = _tree5(0);
        _fund(450e18);
        vm.prank(owner_);
        d.publishEpoch(over.root, 450e18, PUB_FROM, PUB_TO, PUB_DATA);
        Tree memory other = _tree5(1);
        _publish(other);
        _openWindow();
        _claim(over, 0);
        _claim(over, 1);
        vm.expectRevert(abi.encodeWithSelector(D.ExceedsEpochTotal.selector, 600e18, 450e18));
        _claim(over, 2);
        assertEq(d.epochInfo(0).claimed, 300e18);
        for (uint256 i = 0; i < 5; ++i) {
            _claim(other, i);
        }
        assertEq(ram.balanceOf(address(d)), 450e18 - 300e18, "only the over-committed epoch's own money is left");
        assertEq(d.reserved(), 150e18);
    }

    function test_publishRefusesBadInputs() public {
        _fund(10e18);
        vm.startPrank(owner_);
        vm.expectRevert(D.ZeroRoot.selector);
        d.publishEpoch(bytes32(0), 1, PUB_FROM, PUB_TO, PUB_DATA);
        vm.expectRevert(D.ZeroTotal.selector);
        d.publishEpoch(bytes32(uint256(1)), 0, PUB_FROM, PUB_TO, PUB_DATA);
        vm.expectRevert(D.TotalTooLarge.selector);
        d.publishEpoch(bytes32(uint256(1)), uint256(type(uint128).max) + 1, PUB_FROM, PUB_TO, PUB_DATA);
        vm.expectRevert(D.ZeroDataHash.selector);
        d.publishEpoch(bytes32(uint256(1)), 1, PUB_FROM, PUB_TO, bytes32(0));
        vm.expectRevert(D.BadBlockRange.selector);
        d.publishEpoch(bytes32(uint256(1)), 1, 200, 200, PUB_DATA);
        vm.expectRevert(D.BadBlockRange.selector);
        d.publishEpoch(bytes32(uint256(1)), 1, 300, 200, PUB_DATA);
        vm.stopPrank();
        assertEq(d.epochCount(), 0);
        assertEq(d.reserved(), 0);
        // the same range can be published twice (a cancelled epoch must be republishable)
        vm.startPrank(owner_);
        d.publishEpoch(bytes32(uint256(1)), 1, 199, 200, PUB_DATA);
        d.publishEpoch(bytes32(uint256(1)), 1, 199, 200, PUB_DATA);
        vm.stopPrank();
        assertEq(d.reserved(), 2);
    }

    function test_totalTooLargeIsCheckedBeforeTheBalance() public {
        // uint128 bound: a total that the uint128 slot could not hold is refused even with that much unallocated
        ram.mint(address(d), uint256(type(uint128).max) + 1);
        vm.prank(owner_);
        vm.expectRevert(D.TotalTooLarge.selector);
        d.publishEpoch(bytes32(uint256(1)), uint256(type(uint128).max) + 1, PUB_FROM, PUB_TO, PUB_DATA);
        vm.prank(owner_);
        d.publishEpoch(bytes32(uint256(1)), type(uint128).max, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(d.epochInfo(0).total, type(uint128).max);
    }

    // ============================================================================================ unprivileged
    function test_onlyOwnerFunctionsRevertForEveryoneElse() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _fund(1);
        address[4] memory who = [rando, alice, address(this), forwarder];
        for (uint256 i = 0; i < who.length; ++i) {
            vm.startPrank(who[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]));
            d.publishEpoch(bytes32(uint256(1)), 1, PUB_FROM, PUB_TO, PUB_DATA);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]));
            d.cancelEpoch(0);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]));
            d.sweepUnclaimed(0);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]));
            d.transferOwnership(who[i]);
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        d.sweepUnclaimed(0);
    }

    function test_noWayToTakeTokensOutExceptClaim() public {
        string[9] memory names = [
            "pause()",
            "unpause()",
            "rescue(address,uint256)",
            "rescueTokens(address,address,uint256)",
            "withdraw(uint256)",
            "withdrawUnallocated(address,uint256)",
            "setRoot(uint256,bytes32)",
            "recover(address)",
            "emergencyWithdraw()"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            vm.prank(owner_);
            (bool ok,) = address(d).call(abi.encodeWithSignature(names[i], 1, 1, 1));
            assertFalse(ok, names[i]);
        }
        (bool okEth,) = address(d).call{value: 0}("");
        assertFalse(okEth);
        // the owner's full life cycle (publish, cancel, publish, sweep) never moves a token to the owner
        Tree memory t = _tree5(0);
        _publish(t);
        vm.startPrank(owner_);
        d.cancelEpoch(0);
        d.publishEpoch(t.root, t.total, PUB_FROM, PUB_TO, PUB_DATA);
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        d.sweepUnclaimed(1);
        vm.stopPrank();
        assertEq(ram.balanceOf(owner_), 0);
        assertEq(ram.balanceOf(address(d)), t.total);
    }

    function test_claimPaysTheAccountNotTheCaller() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        vm.prank(bob);
        _claim(t, 0);
        assertEq(ram.balanceOf(alice), 100e18);
        assertEq(ram.balanceOf(bob), 0);
    }

    // ============================================================================================ ownership
    function test_renounceIsDisabledForEveryone() public {
        vm.prank(owner_);
        vm.expectRevert(D.RenounceDisabled.selector);
        d.renounceOwnership();
        vm.prank(rando);
        vm.expectRevert(D.RenounceDisabled.selector);
        d.renounceOwnership();
        assertEq(d.owner(), owner_);
    }

    function test_twoStepOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.expectEmit(true, true, false, false, address(d));
        emit OwnershipTransferStarted(owner_, newOwner);
        vm.prank(owner_);
        d.transferOwnership(newOwner);
        assertEq(d.owner(), owner_, "not yet");
        assertEq(d.pendingOwner(), newOwner);
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        d.publishEpoch(bytes32(uint256(1)), 1, PUB_FROM, PUB_TO, PUB_DATA);
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        d.acceptOwnership();
        Tree memory t = _tree5(0);
        _publish(t);

        vm.expectEmit(true, true, false, false, address(d));
        emit OwnershipTransferred(owner_, newOwner);
        vm.prank(newOwner);
        d.acceptOwnership();
        assertEq(d.owner(), newOwner);
        assertEq(d.pendingOwner(), address(0));

        vm.prank(owner_);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner_));
        d.cancelEpoch(0);
        vm.prank(newOwner);
        d.cancelEpoch(0);
        Tree memory t1 = _tree5(1);
        vm.prank(newOwner);
        d.publishEpoch(t1.root, t1.total, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(d.reserved(), t1.total);
    }

    function test_ownershipTransferCanBeReplacedBeforeAcceptance() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        vm.startPrank(owner_);
        d.transferOwnership(a);
        d.transferOwnership(b);
        vm.stopPrank();
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, a));
        d.acceptOwnership();
        vm.prank(b);
        d.acceptOwnership();
        assertEq(d.owner(), b);
    }

    // ============================================================================================ views
    function test_viewsOnUnknownEpoch() public view {
        D.EpochView memory v = d.epochInfo(5);
        assertEq(uint8(v.status), 0);
        assertEq(v.root, bytes32(0));
        assertEq(v.claimOpensAt, 0);
        assertEq(v.claimDeadline, 0);
        assertFalse(d.isClaimWindowOpen(5));
        assertFalse(d.isClaimed(5, alice));
        assertFalse(d.verifyLeaf(5, alice, 1, new bytes32[](0)));
    }

    function test_leafOfMatchesTheSpecFormula() public view {
        bytes32 expect = keccak256(bytes.concat(keccak256(abi.encode(uint256(3), alice, uint256(123)))));
        assertEq(d.leafOf(3, alice, 123), expect);
        assertEq(MerkleBuild.leaf(3, alice, 123), expect);
    }

    function test_isClaimWindowOpenIsFalseForCancelledAndSweptEpochsInsideTheirTimeWindow() public {
        Tree memory t = _tree5(0);
        _publish(t);
        vm.prank(owner_);
        d.cancelEpoch(0);
        vm.warp(vm.getBlockTimestamp() + DELAY + 1);
        assertFalse(d.isClaimWindowOpen(0));
        Tree memory t1 = _tree5(1);
        _publishOnly(t1);
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        vm.prank(owner_);
        d.sweepUnclaimed(1);
        assertFalse(d.isClaimWindowOpen(1));
    }

    function test_isClaimWindowOpenTracksStatus() public {
        Tree memory t = _tree5(0);
        _publish(t);
        assertFalse(d.isClaimWindowOpen(0));
        _openWindow();
        assertTrue(d.isClaimWindowOpen(0));
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        assertFalse(d.isClaimWindowOpen(0));
    }

    function test_verifyLeafWorksForCancelledEpochsButClaimDoesNot() public {
        Tree memory t = _tree5(0);
        _publish(t);
        vm.prank(owner_);
        d.cancelEpoch(0);
        assertTrue(d.verifyLeaf(0, alice, 100e18, _proof(t, 0)));
        assertFalse(d.verifyLeaf(0, alice, 100e18 + 1, _proof(t, 0)));
    }

    function test_unallocatedSaturatesWhenBalanceDropsBelowReserved() public {
        Tree memory t = _tree5(0);
        _publish(t);
        // a token that shrinks the balance (rebasing down: outside the guarantees) must not make the view revert
        vm.store(address(ram), keccak256(abi.encode(address(d), uint256(0))), bytes32(uint256(t.total - 1)));
        assertEq(ram.balanceOf(address(d)), t.total - 1);
        assertEq(d.unallocated(), 0);
    }

    // ============================================================================================ gas (run with --isolate -vv)
    function test_gasNumbers() public {
        uint256[3] memory sizes = [uint256(1), 100, 1000];
        for (uint256 s = 0; s < 3; ++s) {
            uint256 n = sizes[s];
            Tree memory t = _manyLeaves(d.epochCount(), n);
            _fund(t.total);
            vm.prank(owner_);
            d.publishEpoch(t.root, t.total, PUB_FROM, PUB_TO, PUB_DATA);
            uint256 pubGas = vm.lastCallGas().gasTotalUsed;
            vm.warp(vm.getBlockTimestamp() + DELAY);
            bytes32[] memory p = _proof(t, n / 2);
            d.claim(t.epochId, t.accounts[n / 2], t.amounts[n / 2], p);
            uint256 claimGas = vm.lastCallGas().gasTotalUsed;
            console2.log("leaves / proof length:", n, p.length);
            console2.log("  publishEpoch", pubGas);
            console2.log("  claim", claimGas);
        }
        Tree memory t5 = _tree5(d.epochCount());
        _publish(t5);
        vm.prank(owner_);
        d.cancelEpoch(t5.epochId);
        console2.log("  cancelEpoch", vm.lastCallGas().gasTotalUsed);
        Tree memory t6 = _tree5(d.epochCount());
        _publishOnly(t6);
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        vm.prank(owner_);
        d.sweepUnclaimed(t6.epochId);
        console2.log("  sweepUnclaimed", vm.lastCallGas().gasTotalUsed);
    }
}
