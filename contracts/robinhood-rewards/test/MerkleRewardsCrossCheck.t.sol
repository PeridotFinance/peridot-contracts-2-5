// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {MerkleRewardsDistributor as D} from "../src/MerkleRewardsDistributor.sol";
import {RewardsBase, MerkleBuild} from "./RewardsBase.sol";

/// @notice The JS generator's committed golden output (tools/test, fixtures under test/fixtures) against the contract.
contract MerkleRewardsCrossCheckTest is RewardsBase {
    string internal e0;
    string internal m0;
    string internal e1;
    string internal m1;

    function setUp() public override {
        super.setUp();
        e0 = vm.readFile("test/fixtures/expected.epoch0.json");
        m0 = vm.readFile("test/fixtures/expected.manifest0.json");
        e1 = vm.readFile("test/fixtures/expected.epoch1.json");
        m1 = vm.readFile("test/fixtures/expected.manifest1.json");
    }

    function _publishFromManifest(string memory m) internal returns (uint256 id) {
        bytes32 root = vm.parseJsonBytes32(m, ".publishEpochArguments.root");
        uint256 total = vm.parseUint(vm.parseJsonString(m, ".publishEpochArguments.total"));
        uint64 fromB = uint64(vm.parseJsonUint(m, ".publishEpochArguments.fromBlock"));
        uint64 toB = uint64(vm.parseJsonUint(m, ".publishEpochArguments.toBlock"));
        bytes32 dh = vm.parseJsonBytes32(m, ".publishEpochArguments.dataHash");
        // the timelock forwards exactly the held sum (forwardExternalRewardArguments.amount)
        _fund(vm.parseUint(vm.parseJsonString(m, ".forwardExternalRewardArguments.amount")));
        vm.prank(owner_);
        id = d.publishEpoch(root, total, fromB, toB, dh);
    }

    function _claimAll(string memory e, uint256 id) internal returns (uint256 paid) {
        uint256 n = vm.parseJsonUint(e, ".totals.leafCount");
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".leaves[", vm.toString(i), "]");
            address a = vm.parseJsonAddress(e, string.concat(k, ".account"));
            uint256 amt = vm.parseUint(vm.parseJsonString(e, string.concat(k, ".amount")));
            bytes32[] memory p = vm.parseJsonBytes32Array(e, string.concat(k, ".proof"));
            assertEq(d.leafOf(id, a, amt), vm.parseJsonBytes32(e, string.concat(k, ".leaf")), "leaf formula");
            uint256 before_ = ram.balanceOf(a);
            vm.prank(rando);
            d.claim(id, a, amt, p);
            assertEq(ram.balanceOf(a) - before_, amt);
            paid += amt;
        }
    }

    function test_dataHashIsTheKeccakOfTheEpochFile() public view {
        assertEq(vm.parseJsonBytes32(m0, ".dataHash"), keccak256(bytes(e0)));
        assertEq(vm.parseJsonBytes32(m1, ".dataHash"), keccak256(bytes(e1)));
    }

    function test_publishTotalEqualsTheForwardedAmount() public view {
        assertEq(
            vm.parseJsonString(m0, ".publishEpochArguments.total"),
            vm.parseJsonString(m0, ".forwardExternalRewardArguments.amount")
        );
    }

    function test_everyLeafOfBothEpochsClaimsOnChainAndNothingIsLeft() public {
        uint256 id0 = _publishFromManifest(m0);
        uint256 id1 = _publishFromManifest(m1);
        assertEq(id0, 0);
        assertEq(id1, 1);
        assertEq(d.unallocated(), 0, "publish total == forwarded amount");
        _openWindow();
        uint256 p0 = _claimAll(e0, 0);
        uint256 p1 = _claimAll(e1, 1);
        assertEq(p0, d.epochInfo(0).total);
        assertEq(p1, d.epochInfo(1).total);
        assertEq(ram.balanceOf(address(d)), 0);
        assertEq(d.reserved(), 0);
    }

    function test_theJsProofsFailUnderAnotherEpochIdAndTwice() public {
        _fund(1);
        vm.prank(owner_);
        d.publishEpoch(bytes32(uint256(1)), 1, 1, 2, bytes32(uint256(1))); // burns id 0
        uint256 id = _publishFromManifest(m0); // id 1, leaves say 0
        _openWindow();
        address a = vm.parseJsonAddress(e0, ".leaves[0].account");
        uint256 amt = vm.parseUint(vm.parseJsonString(e0, ".leaves[0].amount"));
        bytes32[] memory p = vm.parseJsonBytes32Array(e0, ".leaves[0].proof");
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(id, a, amt, p);
        assertFalse(d.verifyLeaf(id, a, amt, p));
    }

    function test_solidityRebuildsTheSameRoot() public view {
        uint256 n = vm.parseJsonUint(e0, ".totals.leafCount");
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory k = string.concat(".leaves[", vm.toString(i), "]");
            leaves[i] = MerkleBuild.leaf(
                0,
                vm.parseJsonAddress(e0, string.concat(k, ".account")),
                vm.parseUint(vm.parseJsonString(e0, string.concat(k, ".amount")))
            );
        }
        assertEq(MerkleBuild.root(leaves), vm.parseJsonBytes32(e0, ".root"));
    }
}
