// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PharRewardsDistributor as D} from "../../src/rewards/PharRewardsDistributor.sol";
import {RewardsBase, Tree, MerkleBuild, PharMock, PUB_FROM, PUB_TO, PUB_DATA} from "./RewardsBase.sol";

contract PharRewardsDistributorTest is RewardsBase {
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
    event EpochCancelled(uint256 indexed epochId, address indexed to, uint256 refunded);
    event Claimed(uint256 indexed epochId, address indexed account, uint256 amount);
    event EpochSwept(uint256 indexed epochId, address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ================================================================================================================ constructor
    function test_constructorSetsEverything() public view {
        assertEq(address(d.PHAR()), address(phar));
        assertEq(d.owner(), safe);
        assertEq(d.pendingOwner(), address(0));
        assertEq(d.CLAIM_DELAY(), DELAY);
        assertEq(d.CLAIM_DEADLINE(), DEADLINE);
        assertEq(d.epochCount(), 0);
        assertEq(d.MIN_CLAIM_WINDOW(), 7 days);
    }

    function test_constructorRefusesBadInputs() public {
        vm.expectRevert(D.ZeroAddress.selector);
        new D(IERC20(address(0)), safe, DELAY, DEADLINE);
        vm.expectRevert(D.NotAContract.selector);
        new D(IERC20(alice), safe, DELAY, DEADLINE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new D(phar, address(0), DELAY, DEADLINE);
        vm.expectRevert(D.BadWindow.selector);
        new D(phar, safe, 0, DEADLINE);
        // deadline must leave at least MIN_CLAIM_WINDOW after the delay
        vm.expectRevert(D.BadWindow.selector);
        new D(phar, safe, DELAY, DELAY);
        vm.expectRevert(D.BadWindow.selector);
        new D(phar, safe, DELAY, DELAY + 7 days - 1);
        new D(phar, safe, DELAY, DELAY + 7 days); // exactly the minimum is fine
        vm.expectRevert(D.BadWindow.selector);
        new D(phar, safe, DELAY, 10 * 365 days + 1);
        new D(phar, safe, DELAY, 10 * 365 days);
    }

    // ================================================================================================================ happy path
    function test_happyPath_publishWaitClaimAll() public {
        Tree memory t = _tree5(0);
        uint256 safeBefore = phar.balanceOf(safe);

        vm.expectEmit(true, false, false, true, address(d));
        emit EpochPublished(
            0, t.root, t.total, PUB_FROM, PUB_TO, PUB_DATA, vm.getBlockTimestamp(), vm.getBlockTimestamp() + DELAY, vm.getBlockTimestamp() + DEADLINE
        );
        _publish(t);
        assertEq(phar.balanceOf(address(d)), t.total);
        assertEq(phar.balanceOf(safe), safeBefore - t.total);
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
            vm.prank(rando); // anyone may submit; the PHAR goes to the account
            _claim(t, i);
            paid += t.amounts[i];
            assertEq(phar.balanceOf(t.accounts[i]), t.amounts[i]);
            assertTrue(d.isClaimed(0, t.accounts[i]));
            assertEq(d.epochInfo(0).claimed, paid);
        }
        assertEq(phar.balanceOf(rando), 0, "the submitter never gets anything");
        assertEq(phar.balanceOf(address(d)), 0);
        assertEq(d.epochInfo(0).claimed, d.epochInfo(0).total);
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
        assertEq(phar.balanceOf(alice), 7e18);
    }

    function test_oddSizedTreesAllLeavesClaim() public {
        for (uint256 n = 2; n <= 9; ++n) {
            Tree memory t = _manyLeaves(d.epochCount(), n);
            _publish(t);
            vm.warp(vm.getBlockTimestamp() + DELAY);
            for (uint256 i = 0; i < n; ++i) _claim(t, i);
            assertEq(d.epochInfo(t.epochId).claimed, t.total);
        }
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
        // epoch 0 is open (3 days in), epoch 1 still in its window
        _claim(t0, 0);
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, vm.getBlockTimestamp() + DELAY));
        _claim(t1, 0);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        _claim(t1, 0); // same account, other epoch: allowed
        assertEq(phar.balanceOf(alice), 200e18);
        assertTrue(d.isClaimed(0, alice));
        assertTrue(d.isClaimed(1, alice));
        assertFalse(d.isClaimed(1, bob));
    }

    // ================================================================================================================ claim: double / wrong
    function test_doubleClaimReverts() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        _claim(t, 2);
        vm.expectRevert(D.AlreadyClaimed.selector);
        _claim(t, 2);
        assertEq(phar.balanceOf(carol), 300e18);
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
        d.claim(0, bob, 300e18, p); // another leaf's amount
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, alice, 200e18, p); // another account, bob's amount and proof
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, rando, 200e18, p); // an account that is not in the tree
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, _proof(t, 3)); // someone else's proof
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, new bytes32[](0)); // empty proof
        bytes32[] memory flipped = _proof(t, 1);
        flipped[0] = bytes32(uint256(flipped[0]) ^ 1);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, flipped);
        bytes32[] memory longer = new bytes32[](p.length + 1);
        for (uint256 i = 0; i < p.length; ++i) longer[i] = p[i];
        longer[p.length] = bytes32(uint256(42));
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, longer);
        bytes32[] memory shorter = new bytes32[](p.length - 1);
        for (uint256 i = 0; i < shorter.length; ++i) shorter[i] = p[i];
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, bob, 200e18, shorter);
        // the right claim still works (nothing above changed state)
        d.claim(0, bob, 200e18, p);
        assertEq(phar.balanceOf(bob), 200e18);
    }

    function test_zeroAccountAndZeroAmountAreRefused() public {
        address[] memory a = new address[](2);
        uint256[] memory m = new uint256[](2);
        a[0] = alice;
        m[0] = 0; // a (bad) leaf with amount 0
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
        // the operator generated the root for epoch id 0 but the next id is 1: every claim must fail, nothing leaks
        Tree memory t0 = _tree5(0);
        vm.prank(safe);
        d.publishEpoch(bytes32(uint256(0xdead)), 1, PUB_FROM, PUB_TO, PUB_DATA); // burns id 0 with an unrelated root
        vm.prank(safe);
        d.publishEpoch(t0.root, t0.total, PUB_FROM, PUB_TO, PUB_DATA); // this is id 1, but the leaves say id 0
        _openWindow();
        for (uint256 i = 0; i < 5; ++i) {
            vm.expectRevert(D.InvalidProof.selector);
            d.claim(1, t0.accounts[i], t0.amounts[i], _proof(t0, i));
            vm.expectRevert(D.InvalidProof.selector);
            d.claim(0, t0.accounts[i], t0.amounts[i], _proof(t0, i));
        }
        // the owner can cancel only inside the window: here the window is over, so this epoch is a dead end, which is why the procedure checks the id BEFORE publishing
        vm.prank(safe);
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

    // ================================================================================================================ claimMany
    function test_claimManySkipsAlreadyClaimedAndPaysEveryone() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        _claim(t, 1); // front-run: bob is already paid
        D.Claim[] memory cs = new D.Claim[](5);
        for (uint256 i = 0; i < 5; ++i) cs[i] = D.Claim(0, t.accounts[i], t.amounts[i], _proof(t, i));
        vm.recordLogs();
        vm.prank(rando);
        d.claimMany(cs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fromDistributor;
        for (uint256 i = 0; i < logs.length; ++i) if (logs[i].emitter == address(d)) ++fromDistributor;
        assertEq(fromDistributor, 4, "4 Claimed events, bob skipped");
        for (uint256 i = 0; i < 5; ++i) assertEq(phar.balanceOf(t.accounts[i]), t.amounts[i], "each paid exactly once");
        assertEq(d.epochInfo(0).claimed, t.total);
    }

    function test_claimManyRevertsWholeBatchOnABadEntry() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        D.Claim[] memory cs = new D.Claim[](3);
        cs[0] = D.Claim(0, alice, 100e18, _proof(t, 0));
        cs[1] = D.Claim(0, bob, 200e18 + 1, _proof(t, 1)); // wrong amount
        cs[2] = D.Claim(0, carol, 300e18, _proof(t, 2));
        vm.expectRevert(D.InvalidProof.selector);
        d.claimMany(cs);
        assertEq(phar.balanceOf(alice), 0, "atomic");
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
        assertEq(phar.balanceOf(alice), 200e18);
        d.claimMany(new D.Claim[](0)); // no-op
    }

    function test_claimManyEnforcesTheWindowPerEntry() public {
        Tree memory t0 = _tree5(0);
        _publish(t0);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        Tree memory t1 = _tree5(1);
        _publish(t1); // still in its challenge window
        D.Claim[] memory cs = new D.Claim[](2);
        cs[0] = D.Claim(0, alice, 100e18, _proof(t0, 0));
        cs[1] = D.Claim(1, alice, 100e18, _proof(t1, 0));
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, vm.getBlockTimestamp() + DELAY));
        d.claimMany(cs);
    }

    // ================================================================================================================ timing: claim before / after the window
    function test_claimBeforeWindowRevertsAtEveryTimeUpToTheBoundary() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        uint256 opens = t0 + DELAY;
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, opens));
        _claim(t, 0); // same block as the publication
        vm.warp(t0 + 1);
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, opens));
        _claim(t, 0);
        vm.warp(opens - 1);
        assertFalse(d.isClaimWindowOpen(0));
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsNotOpen.selector, opens));
        _claim(t, 0);
        vm.warp(opens); // exactly at the end of the window: open
        assertTrue(d.isClaimWindowOpen(0));
        _claim(t, 0);
        assertEq(phar.balanceOf(alice), 100e18);
    }

    function test_claimDeadlineBoundary() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        vm.warp(t0 + DEADLINE - 1); // last second
        assertTrue(d.isClaimWindowOpen(0));
        _claim(t, 0);
        vm.warp(t0 + DEADLINE); // closed at the deadline itself
        assertFalse(d.isClaimWindowOpen(0));
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsClosed.selector, t0 + DEADLINE));
        _claim(t, 1);
        vm.warp(t0 + DEADLINE + 365 days);
        vm.expectRevert(abi.encodeWithSelector(D.ClaimsClosed.selector, t0 + DEADLINE));
        _claim(t, 1);
    }

    // ================================================================================================================ cancel
    function test_cancelInsideWindowRefundsEverything() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        uint256 safeBefore = phar.balanceOf(safe);
        _publish(t);
        vm.warp(t0 + DELAY - 1); // the very last second of the window
        vm.expectEmit(true, true, false, true, address(d));
        emit EpochCancelled(0, safe, t.total);
        vm.prank(safe);
        d.cancelEpoch(0);
        assertEq(phar.balanceOf(safe), safeBefore);
        assertEq(phar.balanceOf(address(d)), 0);
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.Cancelled));
        assertEq(d.epochCount(), 1, "the id stays burnt");
        // dead: no claims, no second cancel, no sweep, even much later
        vm.warp(t0 + DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Cancelled));
        _claim(t, 0);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Cancelled));
        d.cancelEpoch(0);
        vm.warp(t0 + DEADLINE);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Cancelled));
        d.sweepUnclaimed(0);
    }

    function test_cancelAtTheSameBlockAsPublish() public {
        Tree memory t = _tree5(0);
        _publish(t);
        vm.prank(safe);
        d.cancelEpoch(0);
        assertEq(phar.balanceOf(address(d)), 0);
    }

    function test_cancelAtOrAfterTheWindowReverts() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        vm.warp(t0 + DELAY); // claims open at this very second, so cancel is closed
        vm.prank(safe);
        vm.expectRevert(D.WindowOver.selector);
        d.cancelEpoch(0);
        vm.warp(t0 + DELAY + 1 days);
        vm.prank(safe);
        vm.expectRevert(D.WindowOver.selector);
        d.cancelEpoch(0);
        // the epoch is untouched and immutable: claims work
        _claim(t, 0);
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.Open));
    }

    function test_cancelAfterAClaimIsImpossible() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        _claim(t, 0);
        vm.prank(safe);
        vm.expectRevert(D.WindowOver.selector);
        d.cancelEpoch(0);
    }

    function test_cancelUnknownEpoch() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.None));
        d.cancelEpoch(0);
    }

    function test_cancelThenRepublishGetsANewId() public {
        Tree memory bad = _tree5(0);
        _publish(bad);
        vm.prank(safe);
        d.cancelEpoch(0);
        Tree memory good = _tree5(1); // regenerated for the new id
        _publish(good);
        _openWindow();
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Cancelled));
        _claim(bad, 0);
        _claim(good, 0);
        assertEq(phar.balanceOf(alice), 100e18);
    }

    // ================================================================================================================ sweep
    function test_sweepBeforeDeadlineReverts() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.DeadlineNotReached.selector, t0 + DEADLINE));
        d.sweepUnclaimed(0);
        vm.warp(t0 + DELAY + 5 days);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.DeadlineNotReached.selector, t0 + DEADLINE));
        d.sweepUnclaimed(0);
        vm.warp(t0 + DEADLINE - 1);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.DeadlineNotReached.selector, t0 + DEADLINE));
        d.sweepUnclaimed(0);
    }

    function test_sweepAfterDeadlinePaysExactlyTheUnclaimedOnce() public {
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        _openWindow();
        _claim(t, 0);
        _claim(t, 4); // 100 + 500 claimed, 900 left
        uint256 safeBefore = phar.balanceOf(safe);
        vm.warp(t0 + DEADLINE);
        vm.expectEmit(true, true, false, true, address(d));
        emit EpochSwept(0, safe, 900e18);
        vm.prank(safe);
        d.sweepUnclaimed(0);
        assertEq(phar.balanceOf(safe), safeBefore + 900e18);
        assertEq(phar.balanceOf(address(d)), 0);
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.Swept));
        assertEq(d.epochInfo(0).claimed, 600e18, "claimed is not rewritten by the sweep");
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Swept));
        d.sweepUnclaimed(0);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.Swept));
        _claim(t, 1);
    }

    function test_sweepWhenEverythingWasClaimedPaysNothing() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        for (uint256 i = 0; i < 5; ++i) _claim(t, i);
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        uint256 safeBefore = phar.balanceOf(safe);
        vm.expectEmit(true, true, false, true, address(d));
        emit EpochSwept(0, safe, 0);
        vm.prank(safe);
        d.sweepUnclaimed(0);
        assertEq(phar.balanceOf(safe), safeBefore);
    }

    function test_sweepOfOneEpochDoesNotTouchAnother() public {
        Tree memory t0 = _tree5(0);
        _publish(t0);
        vm.warp(vm.getBlockTimestamp() + 100 days);
        Tree memory t1 = _tree5(1);
        _publish(t1);
        vm.warp(vm.getBlockTimestamp() + 80 days); // epoch 0 is 180 days old, epoch 1 is 80
        vm.prank(safe);
        d.sweepUnclaimed(0);
        assertEq(phar.balanceOf(address(d)), t1.total, "epoch 1 funds intact");
        _claim(t1, 0);
        assertEq(phar.balanceOf(alice), 100e18);
        uint256 dl1 = d.epochInfo(1).claimDeadline;
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.DeadlineNotReached.selector, dl1));
        d.sweepUnclaimed(1);
    }

    function test_sweepUnknownEpoch() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.None));
        d.sweepUnclaimed(7);
    }

    // ================================================================================================================ over-commit
    function test_leavesAddingUpToMoreThanTotalCannotOverdraw() public {
        // the owner funds 450 but the leaves add up to 1500: the claims stop at 450, the rest of the contract's PHAR (epoch 1) is out of reach
        Tree memory over = _tree5(0);
        vm.prank(safe);
        d.publishEpoch(over.root, 450e18, PUB_FROM, PUB_TO, PUB_DATA);
        Tree memory other = _tree5(1);
        _publish(other);
        _openWindow();
        _claim(over, 0); // 100
        _claim(over, 1); // +200 = 300
        vm.expectRevert(abi.encodeWithSelector(D.ExceedsEpochTotal.selector, 600e18, 450e18));
        _claim(over, 2); // +300 would be 600 > 450
        assertEq(d.epochInfo(0).claimed, 300e18);
        // another leaf of epoch 0 that does still fit
        address[] memory a = new address[](2);
        uint256[] memory m = new uint256[](2);
        a[0] = alice;
        m[0] = 100e18;
        a[1] = bob;
        m[1] = 351e18;
        Tree memory o2 = _tree(2, a, m);
        vm.prank(safe);
        d.publishEpoch(o2.root, 450e18, PUB_FROM, PUB_TO, PUB_DATA); // epoch 2: 451 of leaves for 450 funded
        vm.warp(vm.getBlockTimestamp() + DELAY);
        _claim(o2, 0);
        vm.expectRevert(abi.encodeWithSelector(D.ExceedsEpochTotal.selector, 451e18, 450e18));
        _claim(o2, 1);
        // epoch 1 is whole
        for (uint256 i = 0; i < 5; ++i) _claim(other, i);
        assertEq(phar.balanceOf(address(d)), (450e18 - 300e18) + (450e18 - 100e18), "only the over-committed epochs' own money is left");
    }

    function test_publishRefusesBadInputs() public {
        vm.startPrank(safe);
        vm.expectRevert(D.ZeroRoot.selector);
        d.publishEpoch(bytes32(0), 1, PUB_FROM, PUB_TO, PUB_DATA);
        vm.expectRevert(D.ZeroTotal.selector);
        d.publishEpoch(bytes32(uint256(1)), 0, PUB_FROM, PUB_TO, PUB_DATA);
        vm.expectRevert(D.TotalTooLarge.selector);
        d.publishEpoch(bytes32(uint256(1)), uint256(type(uint128).max) + 1, PUB_FROM, PUB_TO, PUB_DATA);
        vm.stopPrank();
        assertEq(d.epochCount(), 0);
    }

    function test_publishRecordsAndRefusesBadBlockRangeAndDataHash() public {
        bytes32 r = bytes32(uint256(1));
        vm.startPrank(safe);
        vm.expectRevert(D.ZeroDataHash.selector);
        d.publishEpoch(r, 1, PUB_FROM, PUB_TO, bytes32(0));
        vm.expectRevert(D.BadBlockRange.selector);
        d.publishEpoch(r, 1, 200, 200, PUB_DATA); // empty range
        vm.expectRevert(D.BadBlockRange.selector);
        d.publishEpoch(r, 1, 300, 200, PUB_DATA); // reversed
        vm.expectRevert(D.BadBlockRange.selector);
        d.publishEpoch(r, 1, 100, uint64(block.number) + 1, PUB_DATA); // a block in the future
        uint256 id = d.publishEpoch(r, 1, 0, uint64(block.number), PUB_DATA); // up to the current block is fine
        vm.stopPrank();
        assertEq(d.epochInfo(id).toBlock, block.number);
        // the range is NOT chained on chain: the same range can be published again (a cancelled epoch must be republishable)
        vm.prank(safe);
        d.publishEpoch(r, 1, 0, uint64(block.number), PUB_DATA);
    }

    function test_publishNeedsAllowanceAndBalance() public {
        vm.startPrank(safe);
        phar.approve(address(d), 99e18);
        vm.expectRevert(); // ERC20InsufficientAllowance
        d.publishEpoch(bytes32(uint256(1)), 100e18, PUB_FROM, PUB_TO, PUB_DATA);
        phar.approve(address(d), type(uint256).max);
        vm.expectRevert(); // ERC20InsufficientBalance
        d.publishEpoch(bytes32(uint256(1)), 2_000_000e18, PUB_FROM, PUB_TO, PUB_DATA);
        vm.stopPrank();
        assertEq(d.epochCount(), 0, "a failed publish leaves no epoch behind");
        assertEq(uint8(d.epochInfo(0).status), uint8(D.Status.None));
    }

    function test_donatedPharIsNotClaimableNorSweepable() public {
        Tree memory t = _tree5(0);
        _publish(t);
        phar.mint(address(d), 77e18); // sent by mistake
        _openWindow();
        for (uint256 i = 0; i < 5; ++i) _claim(t, i);
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        uint256 safeBefore = phar.balanceOf(safe);
        vm.prank(safe);
        d.sweepUnclaimed(0);
        assertEq(phar.balanceOf(safe), safeBefore, "nothing swept: all was claimed");
        assertEq(phar.balanceOf(address(d)), 77e18, "the donation is stuck (documented)");
    }

    // ================================================================================================================ unprivileged
    function test_onlyOwnerFunctionsRevertForEveryoneElse() public {
        Tree memory t = _tree5(0);
        _publish(t);
        address[3] memory who = [rando, alice, address(this)];
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

    function test_publishPullsFromTheOwnerNeverFromAnotherAccount() public {
        phar.mint(rando, 1000e18);
        vm.prank(rando);
        phar.approve(address(d), type(uint256).max); // even a fully approved, funded stranger cannot be the source
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        d.publishEpoch(bytes32(uint256(1)), 10e18, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(phar.balanceOf(rando), 1000e18);
    }

    function test_noWayToTakePharOutExceptTheThreeDoors() public {
        // there is no other external state-changing function: the ABI is the whole story. Check the selectors a rescue/pause would have.
        string[8] memory names = [
            "pause()", "unpause()", "rescue(address,uint256)", "rescueTokens(address,address,uint256)", "withdraw(uint256)", "setRoot(uint256,bytes32)",
            "recover(address)", "emergencyWithdraw()"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            (bool ok,) = address(d).call(abi.encodeWithSignature(names[i], 1, 1, 1));
            assertFalse(ok, names[i]);
        }
        (bool okEth,) = address(d).call{value: 0}(""); // no receive/fallback
        assertFalse(okEth);
    }

    function test_claimPaysTheAccountNotTheCaller() public {
        Tree memory t = _tree5(0);
        _publish(t);
        _openWindow();
        vm.prank(bob); // bob submits alice's claim
        _claim(t, 0);
        assertEq(phar.balanceOf(alice), 100e18);
        assertEq(phar.balanceOf(bob), 0);
    }

    // ================================================================================================================ ownership
    function test_renounceIsDisabledForEveryone() public {
        vm.prank(safe);
        vm.expectRevert(D.RenounceDisabled.selector);
        d.renounceOwnership();
        vm.prank(rando);
        vm.expectRevert(D.RenounceDisabled.selector);
        d.renounceOwnership();
        assertEq(d.owner(), safe);
    }

    function test_twoStepOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.expectEmit(true, true, false, false, address(d));
        emit OwnershipTransferStarted(safe, newOwner);
        vm.prank(safe);
        d.transferOwnership(newOwner);
        assertEq(d.owner(), safe, "not yet");
        assertEq(d.pendingOwner(), newOwner);

        // the pending owner has no power before accepting; the old owner still has
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        d.publishEpoch(bytes32(uint256(1)), 1, PUB_FROM, PUB_TO, PUB_DATA);
        // someone else cannot accept
        vm.prank(rando);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, rando));
        d.acceptOwnership();
        Tree memory t = _tree5(0);
        _publish(t); // still works for the Safe

        vm.expectEmit(true, true, false, false, address(d));
        emit OwnershipTransferred(safe, newOwner);
        vm.prank(newOwner);
        d.acceptOwnership();
        assertEq(d.owner(), newOwner);
        assertEq(d.pendingOwner(), address(0));

        // the Safe lost its rights; the new owner receives the refund of a cancel and pays for the next epoch
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        d.cancelEpoch(0);
        vm.prank(newOwner);
        d.cancelEpoch(0);
        assertEq(phar.balanceOf(newOwner), t.total, "refund goes to the CURRENT owner");

        vm.prank(newOwner);
        phar.approve(address(d), type(uint256).max);
        Tree memory t1 = _tree5(1);
        vm.prank(newOwner);
        d.publishEpoch(t1.root, t1.total, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(phar.balanceOf(newOwner), 0, "pulled from the new owner");
    }

    function test_ownershipTransferCanBeReplacedBeforeAcceptance() public {
        address a = makeAddr("a");
        address b = makeAddr("b");
        vm.startPrank(safe);
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

    // ================================================================================================================ views
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
        vm.prank(safe);
        d.cancelEpoch(0);
        vm.warp(vm.getBlockTimestamp() + DELAY + 1); // inside [claimOpensAt, claimDeadline) by time, but the epoch is Cancelled
        assertFalse(d.isClaimWindowOpen(0));
        Tree memory t1 = _tree5(1);
        _publish(t1);
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        vm.prank(safe);
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

    // ================================================================================================================ gas
    function test_gasNumbers() public {
        // epochs of 1, 100 and 1000 leaves (first and a middle claim); numbers are printed, run with -vv
        uint256[3] memory sizes = [uint256(1), 100, 1000];
        for (uint256 s = 0; s < 3; ++s) {
            uint256 n = sizes[s];
            Tree memory t = _manyLeaves(d.epochCount(), n);
            vm.prank(safe);
            d.publishEpoch(t.root, t.total, PUB_FROM, PUB_TO, PUB_DATA);
            uint256 pubGas = vm.lastCallGas().gasTotalUsed;
            vm.warp(vm.getBlockTimestamp() + DELAY);
            bytes32[] memory p = _proof(t, n / 2);
            d.claim(t.epochId, t.accounts[n / 2], t.amounts[n / 2], p);
            uint256 claimGas = vm.lastCallGas().gasTotalUsed;
            console2.log("leaves / proof length / publishEpoch gas / first claim gas:", n, p.length);
            console2.log("  publishEpoch", pubGas);
            console2.log("  claim", claimGas);
        }
        // cancel and sweep
        Tree memory t5 = _tree5(d.epochCount());
        _publish(t5);
        vm.prank(safe);
        d.cancelEpoch(t5.epochId);
        console2.log("  cancelEpoch", vm.lastCallGas().gasTotalUsed);
        Tree memory t6 = _tree5(d.epochCount());
        _publish(t6);
        vm.warp(vm.getBlockTimestamp() + DEADLINE);
        vm.prank(safe);
        d.sweepUnclaimed(t6.epochId);
        console2.log("  sweepUnclaimed", vm.lastCallGas().gasTotalUsed);
        // claimMany of 5 in one transaction (fresh epoch)
        Tree memory t7 = _tree5(d.epochCount());
        _publish(t7);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        D.Claim[] memory cs = new D.Claim[](5);
        for (uint256 i = 0; i < 5; ++i) cs[i] = D.Claim(t7.epochId, t7.accounts[i], t7.amounts[i], _proof(t7, i));
        d.claimMany(cs);
        console2.log("  claimMany(5), 5-leaf tree", vm.lastCallGas().gasTotalUsed);
    }
}
