// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {PharRewardsDistributor as D} from "../../src/rewards/PharRewardsDistributor.sol";
import {RewardsBase, MerkleBuild, PUB_FROM, PUB_TO, PUB_DATA} from "./RewardsBase.sol";

/// @notice Cross-check of the OFF-CHAIN generator against the ON-CHAIN verifier. `tools/dlmm-rewards-root.mjs` produced fixtures/expected.epoch.json (the data
///         file whose keccak256 is the on-chain dataHash) and expected.manifest.json from the synthetic event fixture (node --test tools/rewards-test/ keeps them
///         byte-identical to what the tool generates now). Here every leaf of the data file is claimed for real through `claim()` with OpenZeppelin's MerkleProof, so a disagreement in leaf encoding, pair order,
///         odd-node handling or epoch-id binding between JS and Solidity fails this test.
contract PharRewardsCrossCheckTest is RewardsBase {
    string internal proofsJson; // the data file (epoch.json): leaves with proofs
    string internal manifestJson;

    function setUp() public override {
        super.setUp();
        proofsJson = vm.readFile("test/rewards/fixtures/expected.epoch.json");
        manifestJson = vm.readFile("test/rewards/fixtures/expected.manifest.json");
    }

    function _p(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".leaves[", vm.toString(i), "].", field);
    }

    function _proofAt(uint256 i) internal view returns (bytes32[] memory) {
        return vm.parseJsonBytes32Array(proofsJson, _p(i, "proof"));
    }

    function _pub() internal view returns (bytes32 root, uint256 total, uint64 fromBlock, uint64 toBlock, bytes32 dataHash) {
        root = vm.parseJsonBytes32(manifestJson, ".publishEpochArguments.root");
        total = vm.parseJsonUint(manifestJson, ".publishEpochArguments.total");
        fromBlock = uint64(vm.parseJsonUint(manifestJson, ".publishEpochArguments.fromBlock"));
        toBlock = uint64(vm.parseJsonUint(manifestJson, ".publishEpochArguments.toBlock"));
        dataHash = vm.parseJsonBytes32(manifestJson, ".publishEpochArguments.dataHash");
    }

    /// the manifest's dataHash is the keccak256 of the data file's bytes, and its publishEpoch arguments agree with the data file
    function test_manifestDataHashIsTheHashOfTheDataFile() public view {
        (bytes32 root, uint256 total, uint64 fromBlock, uint64 toBlock, bytes32 dataHash) = _pub();
        assertEq(dataHash, keccak256(bytes(proofsJson)), "dataHash = keccak256(epoch.json)");
        assertEq(dataHash, vm.parseJsonBytes32(manifestJson, ".dataHash"));
        assertEq(root, vm.parseJsonBytes32(proofsJson, ".root"));
        assertEq(total, vm.parseJsonUint(proofsJson, ".totals.publishTotal"));
        assertEq(fromBlock, vm.parseJsonUint(proofsJson, ".inputs.startBlock"));
        assertEq(toBlock, vm.parseJsonUint(proofsJson, ".inputs.endBlock"));
    }

    /// publish the JS root as epoch id `epochId` (earlier ids are filled with unrelated epochs) with the manifest's arguments and claim every leaf with the JS proofs
    function test_everyLeafOfTheJsRootClaimsOnChain() public {
        uint256 epochId = vm.parseJsonUint(proofsJson, ".inputs.epochId");
        (bytes32 root, uint256 total, uint64 fromBlock, uint64 toBlock, bytes32 dataHash) = _pub();
        uint256 count = vm.parseJsonUint(proofsJson, ".totals.leafCount");
        assertGt(count, 1);
        vm.roll(uint256(toBlock) + 10); // the contract only accepts a toBlock that is not in the future

        for (uint256 k = 0; k < epochId; ++k) {
            vm.prank(safe);
            d.publishEpoch(keccak256(abi.encode("filler", k)), 1, PUB_FROM, PUB_TO, PUB_DATA);
        }
        vm.prank(safe);
        uint256 id = d.publishEpoch(root, total, fromBlock, toBlock, dataHash);
        assertEq(id, epochId, "the epoch id the tool was told is the id the contract hands out");
        D.EpochView memory v = d.epochInfo(id);
        assertEq(v.fromBlock, vm.parseJsonUint(manifestJson, ".startBlock"));
        assertEq(v.toBlock, vm.parseJsonUint(manifestJson, ".endBlock"));
        assertEq(v.dataHash, vm.parseJsonBytes32(manifestJson, ".dataHash"));
        _openWindow();

        uint256 paid;
        for (uint256 i = 0; i < count; ++i) {
            address account = vm.parseJsonAddress(proofsJson, _p(i, "account"));
            uint256 amount = vm.parseJsonUint(proofsJson, _p(i, "amount"));
            bytes32 leaf = vm.parseJsonBytes32(proofsJson, _p(i, "leaf"));
            bytes32[] memory proof = _proofAt(i);

            assertEq(d.leafOf(epochId, account, amount), leaf, "leaf encoding JS == Solidity");
            assertTrue(d.verifyLeaf(epochId, account, amount, proof), "the contract verifies the JS proof");
            assertFalse(d.verifyLeaf(epochId, account, amount + 1, proof));
            vm.prank(rando);
            d.claim(epochId, account, amount, proof);
            assertEq(phar.balanceOf(account), amount);
            paid += amount;
        }
        assertEq(paid, total, "the leaves add up to the published total");
        assertEq(d.epochInfo(epochId).claimed, total);
        assertEq(phar.balanceOf(address(d)), epochId, "nothing left over of this epoch (only the 1 wei of each filler epoch)");
    }

    /// no excluded holder (dead seed, vault, contracts) has a leaf, and the excluded slices are not claimable
    function test_excludedHoldersHaveNoLeaf() public view {
        uint256 count = vm.parseJsonUint(proofsJson, ".totals.leafCount");
        uint256 nEx;
        for (uint256 e = 0; e < 16; ++e) {
            try this.exclusionAt(e) returns (address x) {
                ++nEx;
                for (uint256 i = 0; i < count; ++i) assertTrue(vm.parseJsonAddress(proofsJson, _p(i, "account")) != x, "an excluded holder has a leaf");
            } catch {
                break;
            }
        }
        assertEq(nEx, 3, "dead seed, vault and one contract in the fixture");
    }

    function exclusionAt(uint256 e) external view returns (address) {
        return vm.parseJsonAddress(proofsJson, string.concat(".exclusions.list[", vm.toString(e), "].address"));
    }

    /// the JS proofs are bound to the epoch id on chain as well
    function test_theJsProofsFailUnderAnotherEpochId() public {
        uint256 epochId = vm.parseJsonUint(proofsJson, ".inputs.epochId");
        (bytes32 root, uint256 total,,,) = _pub();
        for (uint256 k = 0; k < epochId + 2; ++k) {
            vm.prank(safe);
            d.publishEpoch(root, total, PUB_FROM, PUB_TO, PUB_DATA); // the same root under ids 0..epochId+1
        }
        _openWindow();
        address account = vm.parseJsonAddress(proofsJson, _p(0, "account"));
        uint256 amount = vm.parseJsonUint(proofsJson, _p(0, "amount"));
        for (uint256 k = 0; k < epochId + 2; ++k) {
            if (k == epochId) continue;
            vm.expectRevert(D.InvalidProof.selector);
            d.claim(k, account, amount, _proofAt(0));
        }
        d.claim(epochId, account, amount, _proofAt(0)); // only the right id works
    }

    /// rebuild the root from the claims' leaves with the Solidity-side tree builder: the same root as the JS one (sorted leaves, sorted pairs, promoted odd node)
    function test_solidityRebuildsTheSameRoot() public view {
        uint256 count = vm.parseJsonUint(proofsJson, ".totals.leafCount");
        bytes32[] memory leaves = new bytes32[](count);
        for (uint256 i = 0; i < count; ++i) leaves[i] = vm.parseJsonBytes32(proofsJson, _p(i, "leaf"));
        assertEq(MerkleBuild.root(leaves), vm.parseJsonBytes32(proofsJson, ".root"));
        for (uint256 i = 0; i < count; ++i) {
            bytes32[] memory mine = MerkleBuild.proof(leaves, i);
            bytes32[] memory js = _proofAt(i);
            assertEq(mine.length, js.length);
            for (uint256 k = 0; k < mine.length; ++k) assertEq(mine[k], js[k]);
        }
    }
}
