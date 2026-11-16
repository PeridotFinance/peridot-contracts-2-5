// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MerkleRewardsDistributor as D} from "../src/MerkleRewardsDistributor.sol";
import {RewardsBase, Tree, MerkleBuild, RewardMock, PUB_FROM, PUB_TO, PUB_DATA} from "./RewardsBase.sol";

contract MerkleRewardsFuzzTest is RewardsBase {
    function setUp() public override {
        super.setUp();
        ram.mint(forwarder, type(uint128).max);
    }

    function _fuzzTree(uint256 epochId, uint256 seed, uint256 n, uint256 maxAmount) internal pure returns (Tree memory) {
        address[] memory a = new address[](n);
        uint256[] memory m = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = address(uint160(uint256(keccak256(abi.encode("acct", seed, i))) | (1 << 159)));
            m[i] = (uint256(keccak256(abi.encode("amt", seed, i))) % maxAmount) + 1;
        }
        return _tree(epochId, a, m);
    }

    function testFuzz_everyLeafClaimsExactlyItsAmount(uint256 seed, uint8 nRaw, uint256 maxAmountRaw) public {
        uint256 n = bound(nRaw, 1, 40);
        Tree memory t = _fuzzTree(0, seed, n, bound(maxAmountRaw, 1, 1e30));
        _publish(t);
        _openWindow();
        uint256 paid;
        for (uint256 k = 0; k < n; ++k) {
            uint256 i = (k * 7 + (seed % n)) % n;
            if (d.isClaimed(0, t.accounts[i])) {
                for (uint256 j = 0; j < n; ++j) {
                    if (!d.isClaimed(0, t.accounts[j])) {
                        i = j;
                        break;
                    }
                }
            }
            vm.prank(address(uint160(uint256(keccak256(abi.encode("caller", seed, k))))));
            _claim(t, i);
            paid += t.amounts[i];
            assertEq(ram.balanceOf(t.accounts[i]), t.amounts[i]);
            assertEq(d.epochInfo(0).claimed, paid);
            assertEq(d.reserved(), t.total - paid);
        }
        assertEq(paid, t.total);
        assertEq(ram.balanceOf(address(d)), 0);
    }

    function testFuzz_anyTamperingIsRejected(uint256 seed, uint8 nRaw, uint8 pick, uint256 delta, uint256 word) public {
        uint256 n = bound(nRaw, 2, 40);
        Tree memory t = _fuzzTree(0, seed, n, 1e27);
        _publish(t);
        _openWindow();
        uint256 i = bound(pick, 0, n - 1);
        bytes32[] memory p = _proof(t, i);
        address acc = t.accounts[i];
        uint256 amt = t.amounts[i];
        delta = bound(delta, 1, type(uint256).max - amt);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, acc, amt + delta, p);
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, address(uint160(uint256(uint160(acc)) ^ 1)), amt, p);
        vm.expectRevert(abi.encodeWithSelector(D.EpochNotOpen.selector, D.Status.None));
        d.claim(1, acc, amt, p);
        if (p.length != 0) {
            bytes32[] memory q = _proof(t, i);
            uint256 w = word % p.length;
            q[w] = bytes32(uint256(q[w]) ^ (delta | 1));
            vm.expectRevert(D.InvalidProof.selector);
            d.claim(0, acc, amt, q);
        }
        uint256 j = (i + 1) % n;
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, acc, amt, _proof(t, j));
        d.claim(0, acc, amt, p);
        assertEq(ram.balanceOf(acc), amt);
    }

    function testFuzz_leafOfAnotherEpochIdIsRejected(uint256 seed, uint8 nRaw, uint8 wrongId) public {
        uint256 n = bound(nRaw, 1, 20);
        uint256 id = bound(wrongId, 1, 60);
        Tree memory t = _fuzzTree(0, seed, n, 1e24);
        _publish(t);
        for (uint256 k = 1; k <= id; ++k) {
            _fund(t.total);
            vm.prank(owner_);
            d.publishEpoch(t.root, t.total, PUB_FROM, PUB_TO, PUB_DATA);
        }
        _openWindow();
        for (uint256 k = 1; k <= id; ++k) {
            vm.expectRevert(D.InvalidProof.selector);
            d.claim(k, t.accounts[0], t.amounts[0], _proof(t, 0));
        }
        _claim(t, 0);
    }

    function testFuzz_randomProofRejected(bytes32[] calldata proof, address account, uint256 amount) public {
        Tree memory t = _tree5(0);
        for (uint256 i = 0; i < 5; ++i) {
            vm.assume(account != t.accounts[i]);
        }
        vm.assume(amount != 0);
        _publish(t);
        _openWindow();
        vm.expectRevert(D.InvalidProof.selector);
        d.claim(0, account, amount, proof);
    }

    function testFuzz_timeWindows(uint256 dtRaw) public {
        uint256 dt = bound(dtRaw, 0, 400 days);
        Tree memory t = _tree5(0);
        uint256 t0 = vm.getBlockTimestamp();
        _publish(t);
        vm.warp(t0 + dt);
        uint256 snap = vm.snapshotState();
        (bool okClaim,) = address(d).call(abi.encodeCall(D.claim, (0, alice, 100e18, _proof(t, 0))));
        assertEq(okClaim, dt >= DELAY && dt < DEADLINE, "claim window");
        vm.revertToState(snap);
        vm.prank(owner_);
        (bool okCancel,) = address(d).call(abi.encodeCall(D.cancelEpoch, (0)));
        assertEq(okCancel, dt < DELAY, "cancel window");
        vm.revertToState(snap);
        vm.prank(owner_);
        (bool okSweep,) = address(d).call(abi.encodeCall(D.sweepUnclaimed, (0)));
        assertEq(okSweep, dt >= DEADLINE, "sweep window");
    }

    function testFuzz_neverPaysMoreThanCommittedAndOtherEpochsAreSafe(uint256 seed, uint8 nRaw, uint256 fundedRaw)
        public
    {
        uint256 n = bound(nRaw, 1, 30);
        Tree memory over = _fuzzTree(0, seed, n, 1e21);
        uint256 funded = bound(fundedRaw, 1, over.total + 1e21);
        _fund(funded);
        vm.prank(owner_);
        d.publishEpoch(over.root, funded, PUB_FROM, PUB_TO, PUB_DATA);
        Tree memory other = _fuzzTree(1, uint256(keccak256(abi.encode(seed))), 3, 1e21);
        _publish(other);
        _openWindow();
        uint256 paid;
        for (uint256 i = 0; i < n; ++i) {
            (bool ok,) =
                address(d).call(abi.encodeCall(D.claim, (0, over.accounts[i], over.amounts[i], _proof(over, i))));
            assertEq(ok, paid + over.amounts[i] <= funded, "a claim works iff it still fits in the committed total");
            if (ok) paid += over.amounts[i];
            assertLe(paid, funded);
        }
        assertEq(ram.balanceOf(address(d)), (funded - paid) + other.total, "epoch 1 untouched");
        for (uint256 i = 0; i < 3; ++i) {
            _claim(other, i);
        }
        assertEq(d.reserved(), funded - paid);
    }

    function testFuzz_publishCommitsAtMostTheUnallocatedBalance(uint256 fundRaw, uint256 totalRaw, uint256 donated)
        public
    {
        uint256 fund = bound(fundRaw, 0, 1e30);
        uint256 total = bound(totalRaw, 1, 1e30);
        donated = bound(donated, 0, 1e30);
        _fund(fund);
        ram.mint(address(d), donated);
        vm.prank(owner_);
        (bool ok,) = address(d).call(abi.encodeCall(D.publishEpoch, (bytes32(uint256(1)), total, PUB_FROM, PUB_TO, PUB_DATA)));
        assertEq(ok, total <= fund + donated);
        assertEq(d.reserved(), ok ? total : 0);
        assertEq(d.unallocated(), fund + donated - d.reserved());
    }

    function testFuzz_constructorWindow(uint256 delay, uint256 deadline) public {
        bool valid =
            delay != 0 && delay <= type(uint256).max - 7 days && deadline >= delay + 7 days && deadline <= 10 * 365 days;
        try new D(ram, owner_, delay, deadline) returns (D x) {
            assertTrue(valid);
            assertEq(x.CLAIM_DELAY(), delay);
            assertEq(x.CLAIM_DEADLINE(), deadline);
        } catch {
            assertFalse(valid);
        }
    }
}

/// @dev Drives random forward / publish / claim / cancel / sweep / warp calls and keeps ghost accounting.
contract RewardsHandler is RewardsBase {
    struct G {
        address[] accounts;
        uint256[] amounts;
        bytes32[] leaves;
        uint256 paid;
        uint256 committed;
    }

    mapping(uint256 => G) internal g;
    uint256 public epochs;
    uint256 public forwardedTotal; // ghost: everything that ever arrived
    uint256 public paidTotal; // ghost: everything that ever left
    mapping(uint256 => mapping(address => uint256)) public paidTo;
    bool public sawOverpay;
    bool public sawOwnerPaid;

    constructor(D dist, RewardMock p, address owner__, address forwarder_) {
        d = dist;
        ram = p;
        owner_ = owner__;
        forwarder = forwarder_;
    }

    function setUp() public override {}

    function forward(uint256 amount) external {
        amount = bound(amount, 0, 1e24);
        ram.mint(address(d), amount);
        forwardedTotal += amount;
    }

    function publish(uint256 seed, uint8 nRaw, uint8 mode) external {
        uint256 n = bound(nRaw, 1, 12);
        address[] memory a = new address[](n);
        uint256[] memory m = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = address(uint160(uint256(keccak256(abi.encode("h", seed, i)))) | (1 << 159));
            m[i] = (uint256(keccak256(abi.encode("m", seed, i))) % 1e22) + 1;
        }
        uint256 id = d.epochCount();
        Tree memory t = _tree(id, a, m);
        uint256 committed = t.total;
        if (mode % 4 == 0) committed = committed - committed / 3; // over-committed leaves
        if (mode % 3 == 0) {
            ram.mint(address(d), committed); // forward exactly what is needed
            forwardedTotal += committed;
        }
        uint256 ownerBefore = ram.balanceOf(owner_);
        vm.prank(owner_);
        try d.publishEpoch(t.root, committed, PUB_FROM, PUB_TO, PUB_DATA) {
            G storage s = g[id];
            s.accounts = a;
            s.amounts = m;
            s.leaves = t.leaves;
            s.committed = committed;
            epochs = id + 1;
        } catch {}
        if (ram.balanceOf(owner_) != ownerBefore) sawOwnerPaid = true;
    }

    function claim(uint256 epochSeed, uint256 idxSeed) external {
        if (epochs == 0) return;
        uint256 id = epochSeed % epochs;
        G storage s = g[id];
        uint256 i = idxSeed % s.accounts.length;
        bytes32[] memory p = MerkleBuild.proof(s.leaves, i);
        uint256 before_ = ram.balanceOf(s.accounts[i]);
        try d.claim(id, s.accounts[i], s.amounts[i], p) {
            uint256 got = ram.balanceOf(s.accounts[i]) - before_;
            if (got != s.amounts[i]) sawOverpay = true;
            paidTo[id][s.accounts[i]] += got;
            if (paidTo[id][s.accounts[i]] > s.amounts[i]) sawOverpay = true;
            s.paid += got;
            paidTotal += got;
        } catch {}
    }

    function wrongClaim(uint256 epochSeed, uint256 idxSeed, uint256 delta) external {
        if (epochs == 0) return;
        uint256 id = epochSeed % epochs;
        G storage s = g[id];
        uint256 i = idxSeed % s.accounts.length;
        delta = bound(delta, 1, 1e22);
        try d.claim(id, s.accounts[i], s.amounts[i] + delta, MerkleBuild.proof(s.leaves, i)) {
            sawOverpay = true;
        } catch {}
    }

    function cancel(uint256 epochSeed) external {
        if (epochs == 0) return;
        uint256 ownerBefore = ram.balanceOf(owner_);
        vm.prank(owner_);
        try d.cancelEpoch(epochSeed % epochs) {} catch {}
        if (ram.balanceOf(owner_) != ownerBefore) sawOwnerPaid = true;
    }

    function sweep(uint256 epochSeed) external {
        if (epochs == 0) return;
        uint256 ownerBefore = ram.balanceOf(owner_);
        vm.prank(owner_);
        try d.sweepUnclaimed(epochSeed % epochs) {} catch {}
        if (ram.balanceOf(owner_) != ownerBefore) sawOwnerPaid = true;
    }

    function warp(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 90 days));
    }

    function ghostPaid(uint256 id) external view returns (uint256) {
        return g[id].paid;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 150
contract MerkleRewardsInvariantTest is StdInvariant, RewardsBase {
    RewardsHandler internal h;

    function setUp() public override {
        super.setUp();
        h = new RewardsHandler(d, ram, owner_, forwarder);
        targetContract(address(h));
        bytes4[] memory sels = new bytes4[](7);
        sels[0] = RewardsHandler.forward.selector;
        sels[1] = RewardsHandler.publish.selector;
        sels[2] = RewardsHandler.claim.selector;
        sels[3] = RewardsHandler.wrongClaim.selector;
        sels[4] = RewardsHandler.cancel.selector;
        sels[5] = RewardsHandler.sweep.selector;
        sels[6] = RewardsHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
    }

    /// reserved equals what the open epochs still owe, and the balance covers it
    function invariant_reservedEqualsOpenObligationsAndIsCovered() public view {
        uint256 owed;
        for (uint256 id = 0; id < d.epochCount(); ++id) {
            D.EpochView memory v = d.epochInfo(id);
            if (v.status == D.Status.Open) owed += v.total - v.claimed;
        }
        assertEq(d.reserved(), owed);
        assertGe(ram.balanceOf(address(d)), owed);
        assertEq(d.unallocated(), ram.balanceOf(address(d)) - owed);
    }

    /// tokens only leave through claims: balance == forwarded - paid to leaf accounts
    function invariant_tokensLeaveOnlyThroughClaims() public view {
        assertEq(ram.balanceOf(address(d)), h.forwardedTotal() - h.paidTotal());
        assertFalse(h.sawOwnerPaid());
    }

    function invariant_claimedNeverExceedsTotalAndMatchesGhost() public view {
        for (uint256 id = 0; id < d.epochCount(); ++id) {
            D.EpochView memory v = d.epochInfo(id);
            assertLe(v.claimed, v.total);
            assertEq(v.claimed, h.ghostPaid(id));
            if (v.status == D.Status.Cancelled) assertEq(v.claimed, 0, "a cancelled epoch had no claims");
        }
    }

    function invariant_noOverpayNoWrongSuccess() public view {
        assertFalse(h.sawOverpay());
    }
}
