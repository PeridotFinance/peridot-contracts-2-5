// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MerkleRewardsDistributor} from "../src/MerkleRewardsDistributor.sol";

/// @dev block range / data hash used by the generic tests (the contract only records them). L2 heights far above block.number on
///      purpose: on Robinhood Chain block.number is the L1-derived number (~26M) while the range is in L2 heights (~116M).
uint64 constant PUB_FROM = 110_177_000;
uint64 constant PUB_TO = 115_915_867;
bytes32 constant PUB_DATA = keccak256("epoch data file");

/// @dev RAM stand-in: 18 decimals, permissionless mint.
contract RewardMock is ERC20 {
    constructor() ERC20("Ramses", "RAM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Test-side Merkle tree with the SAME rules as the off-chain generator and OpenZeppelin's MerkleProof: sorted pair
///      hashing, an unpaired node is promoted.
library MerkleBuild {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function leaf(uint256 epochId, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        require(leaves.length > 0, "empty");
        bytes32[] memory layer = leaves;
        while (layer.length > 1) {
            uint256 n = (layer.length + 1) / 2;
            bytes32[] memory next = new bytes32[](n);
            for (uint256 i = 0; i < n; ++i) {
                next[i] = 2 * i + 1 < layer.length ? hashPair(layer[2 * i], layer[2 * i + 1]) : layer[2 * i];
            }
            layer = next;
        }
        return layer[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory) {
        bytes32[] memory tmp = new bytes32[](64);
        uint256 count;
        bytes32[] memory layer = leaves;
        uint256 idx = index;
        while (layer.length > 1) {
            uint256 sib = idx ^ 1;
            if (sib < layer.length) tmp[count++] = layer[sib];
            uint256 n = (layer.length + 1) / 2;
            bytes32[] memory next = new bytes32[](n);
            for (uint256 i = 0; i < n; ++i) {
                next[i] = 2 * i + 1 < layer.length ? hashPair(layer[2 * i], layer[2 * i + 1]) : layer[2 * i];
            }
            layer = next;
            idx >>= 1;
        }
        bytes32[] memory out = new bytes32[](count);
        for (uint256 i = 0; i < count; ++i) {
            out[i] = tmp[i];
        }
        return out;
    }
}

/// @dev A built epoch: who gets what, the leaves, the root and the sum.
struct Tree {
    uint256 epochId;
    address[] accounts;
    uint256[] amounts;
    bytes32[] leaves;
    bytes32 root;
    uint256 total;
}

abstract contract RewardsBase is Test {
    uint256 internal constant DELAY = 1 days;
    uint256 internal constant DEADLINE = 180 days;
    uint256 internal constant START_TS = 1_800_000_000;

    RewardMock internal ram;
    MerkleRewardsDistributor internal d;
    address internal owner_ = makeAddr("ledger");
    address internal forwarder = makeAddr("timelock"); // stands for the timelock's forwardExternalReward
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal rando = makeAddr("rando");

    function setUp() public virtual {
        vm.warp(START_TS);
        vm.roll(26_000_000); // L1-derived block.number as on Robinhood Chain: BELOW the L2 heights of the ranges
        ram = new RewardMock();
        d = new MerkleRewardsDistributor(ram, owner_, DELAY, DEADLINE);
        ram.mint(forwarder, 1_000_000e18);
    }

    // ------------------------------------------------------------------------------------------------------- builders
    function _tree(uint256 epochId, address[] memory accounts, uint256[] memory amounts)
        internal
        pure
        returns (Tree memory t)
    {
        t.epochId = epochId;
        t.accounts = accounts;
        t.amounts = amounts;
        t.leaves = new bytes32[](accounts.length);
        for (uint256 i = 0; i < accounts.length; ++i) {
            t.leaves[i] = MerkleBuild.leaf(epochId, accounts[i], amounts[i]);
            t.total += amounts[i];
        }
        t.root = MerkleBuild.root(t.leaves);
    }

    /// @dev alice 100, bob 200, carol 300, dave 400, erin 500 (18 decimals) as epoch `epochId`.
    function _tree5(uint256 epochId) internal view returns (Tree memory) {
        address[] memory a = new address[](5);
        uint256[] memory m = new uint256[](5);
        a[0] = alice;
        a[1] = bob;
        a[2] = carol;
        a[3] = dave;
        a[4] = erin;
        for (uint256 i = 0; i < 5; ++i) {
            m[i] = (i + 1) * 100e18;
        }
        return _tree(epochId, a, m);
    }

    /// @dev the forward of the timelock: tokens arrive in the distributor before the publication
    function _fund(uint256 amount) internal {
        vm.prank(forwarder);
        ram.transfer(address(d), amount);
    }

    function _publishOnly(Tree memory t) internal returns (uint256 id) {
        vm.prank(owner_);
        id = d.publishEpoch(t.root, t.total, PUB_FROM, PUB_TO, PUB_DATA);
        assertEq(id, t.epochId, "epoch id differs from the one the tree was built for");
    }

    function _publish(Tree memory t) internal returns (uint256 id) {
        _fund(t.total);
        id = _publishOnly(t);
    }

    function _proof(Tree memory t, uint256 i) internal pure returns (bytes32[] memory) {
        return MerkleBuild.proof(t.leaves, i);
    }

    function _claim(Tree memory t, uint256 i) internal {
        d.claim(t.epochId, t.accounts[i], t.amounts[i], _proof(t, i));
    }

    function _openWindow() internal {
        vm.warp(vm.getBlockTimestamp() + DELAY);
    }
}
