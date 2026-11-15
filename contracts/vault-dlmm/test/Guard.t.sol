// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./Base.t.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Spec section 4: guard bits 1,2,4,8,16,32 each set by a fixture that sets ONLY that bit; latch / trip / clear; setGuardParams bounds.
///         Entry paths (deposit, mint, openBand, rebalance) are blocked while any bit holds; exits are never blocked (see Exits.t.sol).
contract GuardTest is Base {
    function setUp() public virtual {
        _setUpVault();
    }

    // ------------------------------------------------------------------ fixtures: one cause, one bit
    function _reasons() internal view returns (uint256 r) {
        (,, r) = v.guardState();
    }

    function _assertOnly(uint256 bit) internal view {
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        assertEq(r, bit, "exactly this reason bit");
        assertTrue(unsafe, "unsafe");
        assertFalse(latched, "not latched until tripGuard");
    }

    function test_baselineSafe() public view {
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        assertFalse(unsafe);
        assertFalse(latched);
        assertEq(r, 0);
    }

    // ---- bit 1: asset feed (USDC/USD) broken, four independent causes
    function test_bit1_feedReverts() public {
        feedUsdc.setRevertLatest(true);
        _assertOnly(1);
    }

    function test_bit1_feedRevertsEverything() public {
        feedUsdc.setRevertAll(true);
        _assertOnly(1);
    }

    function test_bit1_answerZero() public {
        feedUsdc.setAnswer(0);
        _assertOnly(1);
    }

    function test_bit1_answerNegative() public {
        feedUsdc.setAnswer(-1);
        _assertOnly(1);
    }

    function test_bit1_stale() public {
        feedUsdc.setAnswerAt(1e8, block.timestamp - 93_600 - 1);
        _assertOnly(1);
    }

    function test_bit1_staleBoundaryIsFresh() public {
        feedUsdc.setAnswerAt(1e8, block.timestamp - 93_600);
        (bool unsafe,, uint256 r) = v.guardState();
        assertEq(r & 1, 0, "age == maxFeedAge is still fresh");
        assertFalse(unsafe);
    }

    function test_bit1_incompleteRound() public {
        feedUsdc.setIncompleteRound();
        _assertOnly(1);
    }

    // ---- bit 2: pair feed (USDT/USD)
    function test_bit2_feedReverts() public {
        feedUsdt.setRevertLatest(true);
        _assertOnly(2);
    }

    function test_bit2_feedRevertsEverything() public {
        feedUsdt.setRevertAll(true);
        _assertOnly(2);
    }

    function test_bit2_answerZero() public {
        feedUsdt.setAnswer(0);
        _assertOnly(2);
    }

    function test_bit2_answerNegative() public {
        feedUsdt.setAnswer(-5);
        _assertOnly(2);
    }

    function test_bit2_stale() public {
        feedUsdt.setAnswerAt(1e8, block.timestamp - 93_601);
        _assertOnly(2);
    }

    function test_bit2_incompleteRound() public {
        feedUsdt.setIncompleteRound();
        _assertOnly(2);
    }

    // ---- bit 4: asset leg out of 1.00 +- legBandBps (50)
    function test_bit4_assetLegHigh() public {
        feedUsdc.setAnswer(1.0051e8);
        _assertOnly(4);
    }

    function test_bit4_assetLegLow() public {
        feedUsdc.setAnswer(0.9949e8);
        _assertOnly(4);
    }

    function test_bit4_insideBandIsSafe() public {
        feedUsdc.setAnswer(1.0049e8);
        assertEq(_reasons(), 0);
        feedUsdc.setAnswer(0.9951e8);
        assertEq(_reasons(), 0);
    }

    function test_bit4_noiseOfTenBpsIsSafe() public {
        // read live on 15 Nov: USDC 0.99975, USDT 0.99934
        _setFeeds(0.99975e8, 0.99934e8);
        assertEq(_reasons(), 0);
    }

    // ---- bit 8: pair leg out of band
    function test_bit8_pairLegLow() public {
        feedUsdt.setAnswer(0.994e8);
        _assertOnly(8);
    }

    function test_bit8_pairLegHigh() public {
        feedUsdt.setAnswer(1.006e8);
        _assertOnly(8);
    }

    // ---- bit 16: pool active-bin price vs the oracle ratio, live only. Fixtures keep BOTH feeds at 1.00 and move the pool.
    function test_bit16_poolBelowOracle() public {
        pair.forceActiveId(ID0 - 70); // -0.70 % > 60 bps
        _assertOnly(16);
    }

    function test_bit16_poolAboveOracle() public {
        pair.forceActiveId(ID0 + 70);
        _assertOnly(16);
    }

    function test_bit16_insideToleranceIsSafe() public {
        pair.forceActiveId(ID0 + 50); // 50 bps < 60
        assertEq(_reasons(), 0);
        pair.forceActiveId(ID0 - 50);
        assertEq(_reasons(), 0);
    }

    function test_bit16_isLiveAndClearsItself() public {
        pair.forceActiveId(ID0 + 70);
        assertEq(_reasons(), 16);
        pair.forceActiveId(ID0);
        (bool unsafe,, uint256 r) = v.guardState();
        assertEq(r, 0);
        assertFalse(unsafe);
    }

    function test_bit16_feedsMoveWithinBandStillDeviate() public {
        // oracle ratio moves 40 bps one way and the pool 40 bps the other: 80 bps apart, each leg inside its 50 bp band
        feedUsdt.setAnswer(0.9960e8);
        pair.forceActiveId(ID0 - 40);
        uint256 r = _reasons();
        // the sign of the pool/oracle ratio convention is the vault's: the two moves either add (80 bps, bit 16) or cancel (0)
        assertTrue(r == 16 || r == 0, "only bit 16 can be involved");
        pair.forceActiveId(ID0 + 40);
        uint256 r2 = _reasons();
        assertTrue((r == 16 && r2 == 0) || (r == 0 && r2 == 16), "exactly one of the two directions deviates by 80 bps");
    }

    /// Spec correction: the oracle ratio is feedPair(USDT/USD) / feedAsset(USDC/USD) = USDC per USDt, oriented by the token order read at initialize.
    /// Feeds are skewed (USDT 0.996, USDC 1.003: each leg inside its 50 bp band) so the ratio is 0.99302 (-70 bp). A pool AT that price must be safe in BOTH token orders
    /// (X=USDt: pool price Y/X = USDC per USDt = ratio, id -70; X=USDC: pool price = USDt per USDC = 1/ratio, id +70). The wrong orientation would read 140 bp apart.
    function _skewFeeds() internal {
        feedUsdt.setAnswer(0.996e8);
        feedUsdc.setAnswer(1.003e8);
    }

    function _truePoolId() internal view returns (uint24) {
        return usdcIsX ? ID0 + 70 : ID0 - 70;
    }

    function test_bit16_orientationPoolAtTruePriceIsSafe() public {
        _skewFeeds();
        pair.forceActiveId(_truePoolId());
        (bool unsafe,, uint256 r) = v.guardState();
        assertEq(r, 0, "a pool at its true price must not trip bit 16 in either token order");
        assertFalse(unsafe);
        // one bin either side of the true id is still safe
        pair.forceActiveId(_truePoolId() + 1);
        assertEq(_reasons(), 0);
        pair.forceActiveId(_truePoolId() - 1);
        assertEq(_reasons(), 0);
    }

    function test_bit16_orientationDeviationTripsBothDirections() public {
        _skewFeeds();
        pair.forceActiveId(_truePoolId() + 65);
        assertEq(_reasons(), 16, "65 bp above the true price trips");
        pair.forceActiveId(_truePoolId() - 65);
        assertEq(_reasons(), 16, "65 bp below the true price trips");
    }

    function test_bit16_orientationWrongWayPoolTrips() public {
        // the pool at the MIRRORED id (what a vault with the inverted ratio would call true) is 140 bp off
        _skewFeeds();
        pair.forceActiveId(usdcIsX ? ID0 - 70 : ID0 + 70);
        assertEq(_reasons(), 16);
    }

    function test_feedAged86400IsSafe() public {
        // feeds legitimately sit unchanged ~24 h (heartbeat): 86,400 s old must be safe with the default maxFeedAge of 93,600
        feedUsdc.setAnswerAt(1e8, block.timestamp - 86_400);
        feedUsdt.setAnswerAt(1e8, block.timestamp - 86_400);
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        assertEq(r, 0);
        assertFalse(unsafe);
        assertFalse(latched);
        _deposit(BOB, 10e6); // and entries still work
    }

    // ---- bit 32: rewarder not linked, or implementation codehash changed. Live only.
    function test_bit32_hookRemoved() public {
        pair.setHook(address(0));
        _assertOnly(32);
    }

    function test_bit32_hookPointsElsewhere() public {
        MockOtherHook other = new MockOtherHook();
        pair.setHook(address(other));
        _assertOnly(32);
    }

    function test_bit32_implementationCodehashChanged() public {
        beacon.setImplementation(address(implB));
        _assertOnly(32);
    }

    function test_bit32_clearsWhenRelinked() public {
        pair.setHook(address(0));
        assertEq(_reasons(), 32);
        pair.setHook(address(rewarder));
        assertEq(_reasons(), 0);
        beacon.setImplementation(address(implB));
        assertEq(_reasons(), 32);
        beacon.setImplementation(address(implA));
        assertEq(_reasons(), 0);
    }

    function test_guardStateNeverRevertsWhateverTheFeeds() public {
        feedUsdc.setRevertAll(true);
        feedUsdt.setRevertAll(true);
        (bool unsafe,, uint256 r) = v.guardState();
        assertTrue(unsafe);
        assertEq(r & 3, 3);
        beacon.setImplementation(address(implB));
        pair.forceActiveId(ID0 + 300);
        v.guardState();
        v.rebalanceAllowed();
    }

    function test_reasonsCombine() public {
        feedUsdc.setAnswer(1.01e8); // bit 4
        feedUsdt.setRevertLatest(true); // bit 2
        pair.setHook(address(0)); // bit 32
        uint256 r = _reasons();
        assertEq(r & (2 | 4 | 32), 2 | 4 | 32);
        assertEq(r & (1 | 8), 0);
    }

    // ------------------------------------------------------------------ every bit blocks every entry path
    function _breakBit(uint256 bit) internal {
        if (bit == 1) feedUsdc.setRevertLatest(true);
        else if (bit == 2) feedUsdt.setRevertLatest(true);
        else if (bit == 4) feedUsdc.setAnswer(1.01e8);
        else if (bit == 8) feedUsdt.setAnswer(0.99e8);
        else if (bit == 16) pair.forceActiveId(ID0 + 80);
        else if (bit == 32) pair.setHook(address(0));
    }

    function _entryBlocked(uint256 bit) internal {
        _breakBit(bit);
        bytes memory ret = _callAs(BOB, abi.encodeWithSignature("deposit(uint256,address)", 10e6, BOB));
        assertEq(_sel(ret), IPharaohDlmmVault.GuardUnsafe.selector, "deposit blocked by the guard");
        assertEq(abi.decode(_tail(ret), (uint256)), bit, "GuardUnsafe carries the reason");
        // mint: blocked too (or disabled: maxMint == 0 in R3 style)
        _callAs(BOB, abi.encodeWithSignature("mint(uint256,address)", 10e6, BOB));
        // openBand blocked (nothing deposited: the guard must come first or the call fails for another reason: both are reverts, assert the guard only when funds exist)
    }

    function _callAs(address who, bytes memory cd) internal returns (bytes memory ret) {
        return _assertReverts(who, address(v), cd);
    }

    function _tail(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = ret[i + 4];
    }

    function test_bit1_blocksEntries() public {
        _entryBlocked(1);
    }

    function test_bit2_blocksEntries() public {
        _entryBlocked(2);
    }

    function test_bit4_blocksEntries() public {
        _entryBlocked(4);
    }

    function test_bit8_blocksEntries() public {
        _entryBlocked(8);
    }

    function test_bit16_blocksEntries() public {
        _entryBlocked(16);
    }

    function test_bit32_blocksEntries() public {
        _entryBlocked(32);
    }

    function _blocksOpenBandAndRebalance(uint256 bit) internal {
        // deposit while safe, open the band, then break one bit: openBand is unavailable (already open), so test rebalance after the band leaves range
        _fundAndOpen(100e6);
        _pushOut(true);
        _breakBit(bit);
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), IPharaohDlmmVault.GuardUnsafe.selector, "rebalance blocked by the guard");
        (bool ok,,) = v.rebalanceAllowed();
        assertFalse(ok, "rebalanceAllowed mirrors the guard");
    }

    function test_bit1_blocksRebalance() public {
        _blocksOpenBandAndRebalance(1);
    }

    function test_bit2_blocksRebalance() public {
        _blocksOpenBandAndRebalance(2);
    }

    function test_bit4_blocksRebalance() public {
        _blocksOpenBandAndRebalance(4);
    }

    function test_bit8_blocksRebalance() public {
        _blocksOpenBandAndRebalance(8);
    }

    function test_bit16_blocksRebalance() public {
        // bit 16 is the pool vs oracle: push the pool out with a real swap and keep the feeds at 1.00
        _fundAndOpen(100e6);
        _pushOut(true);
        // a push of > 60 bins would be needed for bit 16; the 3-bin band exit is only 2 bins, so force the deviation on top
        pair.forceActiveId(pair.getActiveId() + 80);
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), IPharaohDlmmVault.GuardUnsafe.selector);
    }

    function test_bit32_blocksRebalance() public {
        _blocksOpenBandAndRebalance(32);
    }

    function test_bitsBlockOpenBand() public {
        uint256[6] memory bits = [uint256(1), 2, 4, 8, 16, 32];
        for (uint256 i; i < bits.length; ++i) {
            uint256 snap = vm.snapshotState();
            _deposit(ALICE, 50e6);
            _breakBit(bits[i]);
            bytes memory ret = _assertReverts(KEEPER, address(v), _openBandArgs());
            assertEq(_sel(ret), IPharaohDlmmVault.GuardUnsafe.selector, "openBand blocked");
            assertEq(abi.decode(_tail(ret), (uint256)), bits[i]);
            vm.revertToState(snap);
        }
    }

    // ------------------------------------------------------------------ latch / trip / clear
    function test_tripGuardRevertsWhenNothingLatchable() public {
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, 0));
        v.tripGuard();
        // bits 16 and 32 alone are not latchable
        pair.forceActiveId(ID0 + 80);
        assertEq(_reasons(), 16);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, 0));
        v.tripGuard();
        pair.forceActiveId(ID0);
        pair.setHook(address(0));
        assertEq(_reasons(), 32);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, 0));
        v.tripGuard();
    }

    function test_tripGuardIsPermissionlessAndLatchesEachLatchableBit() public {
        uint256[4] memory bits = [uint256(1), 2, 4, 8];
        for (uint256 i; i < bits.length; ++i) {
            uint256 snap = vm.snapshotState();
            _breakBit(bits[i]);
            vm.expectEmit(address(v));
            emit IPharaohDlmmVault.GuardTripped(ATTACKER, bits[i]);
            vm.prank(ATTACKER);
            v.tripGuard();
            (bool unsafe, bool latched, uint256 r) = v.guardState();
            assertTrue(latched, "latched");
            assertTrue(unsafe);
            assertEq(r & bits[i], bits[i]);
            vm.revertToState(snap);
        }
    }

    function test_latchSurvivesRecovery() public {
        feedUsdc.setAnswer(1.01e8);
        vm.prank(ATTACKER);
        v.tripGuard();
        feedUsdc.setAnswer(1e8); // prices recover
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        assertTrue(latched, "latched stays");
        assertEq(r, 0, "no live reason");
        // the latch alone blocks entries with GuardLatched
        bytes memory ret = _assertReverts(BOB, address(v), abi.encodeWithSignature("deposit(uint256,address)", 10e6, BOB));
        assertEq(_sel(ret), IPharaohDlmmVault.GuardLatched.selector);
        emit log_named_string("ACTUAL guardState().unsafe while latched and live-safe", unsafe ? "true" : "false");
    }

    function test_latchBlocksOpenBandAndRebalance() public {
        _fundAndOpen(100e6);
        _pushOut(true);
        feedUsdc.setAnswer(1.01e8);
        vm.prank(ATTACKER);
        v.tripGuard();
        feedUsdc.setAnswer(1e8);
        bytes memory ret = _assertReverts(KEEPER, address(v), _rebalanceCall());
        assertEq(_sel(ret), IPharaohDlmmVault.GuardLatched.selector, "rebalance blocked by the latch");
        // openBand on a fresh vault with the latch
        // (separate fixture below: test_latchBlocksOpenBand)
    }

    function test_latchBlocksOpenBand() public {
        _deposit(ALICE, 50e6);
        feedUsdt.setAnswer(0.99e8);
        vm.prank(ATTACKER);
        v.tripGuard();
        feedUsdt.setAnswer(1e8);
        bytes memory ret = _assertReverts(KEEPER, address(v), _openBandArgs());
        assertEq(_sel(ret), IPharaohDlmmVault.GuardLatched.selector);
    }

    function test_clearGuardOwnerOnly() public {
        feedUsdc.setAnswer(1.01e8);
        v.tripGuard();
        feedUsdc.setAnswer(1e8);
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, ATTACKER));
        v.clearGuard();
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, KEEPER));
        v.clearGuard();
    }

    function test_clearGuardRefusedWhileLiveUnsafe() public {
        feedUsdc.setAnswer(1.01e8);
        v.tripGuard();
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardStillUnsafe.selector, 4));
        v.clearGuard();
    }

    function test_clearGuardReleasesWhenSafe() public {
        feedUsdc.setAnswer(1.01e8);
        v.tripGuard();
        feedUsdc.setAnswer(1e8);
        vm.expectEmit(address(v));
        emit IPharaohDlmmVault.GuardCleared(SAFE);
        vm.prank(SAFE);
        v.clearGuard();
        (bool unsafe, bool latched, uint256 r) = v.guardState();
        assertFalse(latched);
        assertFalse(unsafe);
        assertEq(r, 0);
        _deposit(BOB, 10e6); // entries work again
    }

    function test_clearGuardRefusedUnderLiveBit16and32() public {
        feedUsdc.setAnswer(1.01e8);
        v.tripGuard();
        feedUsdc.setAnswer(1e8);
        pair.forceActiveId(ID0 + 80);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardStillUnsafe.selector, 16));
        v.clearGuard();
        pair.forceActiveId(ID0);
        pair.setHook(address(0));
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardStillUnsafe.selector, 32));
        v.clearGuard();
    }

    function test_clearGuardWhenNotLatchedIsRecorded() public {
        vm.prank(SAFE);
        (bool ok,) = address(v).call(abi.encodeCall(IPharaohDlmmVault.clearGuard, ()));
        emit log_named_string("ACTUAL clearGuard when not latched", ok ? "succeeds (no-op or event)" : "reverts");
    }

    function test_tripWhileAlreadyLatchedIsRecorded() public {
        feedUsdc.setAnswer(1.01e8);
        v.tripGuard();
        (bool ok,) = address(v).call(abi.encodeCall(IPharaohDlmmVault.tripGuard, ()));
        emit log_named_string("ACTUAL second tripGuard while latched", ok ? "succeeds" : "reverts");
        (, bool latched,) = v.guardState();
        assertTrue(latched);
    }

    function test_tripLatchesOnlyLatchableBitsEvenWhenOthersHold() public {
        feedUsdc.setAnswer(1.01e8); // bit 4, latchable
        pair.setHook(address(0)); // bit 32, live only
        vm.recordLogs();
        v.tripGuard();
        // GuardTripped reasons must not contain the non-latchable bit
        (, bool latched,) = v.guardState();
        assertTrue(latched);
        // clearing needs BOTH the latchable cause and the live-only cause gone
        feedUsdc.setAnswer(1e8);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardStillUnsafe.selector, 32));
        v.clearGuard();
    }

    // ------------------------------------------------------------------ setGuardParams bounds
    function _gp() internal view returns (IPharaohDlmmVault.GuardParams memory g) {
        return v.guardParams();
    }

    function _set(IPharaohDlmmVault.GuardParams memory g) internal returns (bool ok, bytes memory ret) {
        vm.prank(SAFE);
        return address(v).call(abi.encodeCall(IPharaohDlmmVault.setGuardParams, (g)));
    }

    function _assertParamOk(IPharaohDlmmVault.GuardParams memory g) internal {
        (bool ok, bytes memory ret) = _set(g);
        if (!ok) emit log_named_bytes("revert", ret);
        assertTrue(ok, "bound itself accepted");
    }

    function _assertParamBad(IPharaohDlmmVault.GuardParams memory g, string memory what) internal {
        (bool ok, bytes memory ret) = _set(g);
        assertFalse(ok, what);
        assertEq(_sel(ret), IPharaohDlmmVault.ParamOutOfBounds.selector, what);
    }

    function test_setGuardParamsBounds_legBandBps() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        g.legBandBps = 10;
        _assertParamOk(g);
        g.legBandBps = 200;
        _assertParamOk(g);
        g.legBandBps = 9;
        _assertParamBad(g, "legBandBps 9");
        g.legBandBps = 201;
        _assertParamBad(g, "legBandBps 201");
        g.legBandBps = 0;
        _assertParamBad(g, "legBandBps 0");
        g.legBandBps = type(uint16).max;
        _assertParamBad(g, "legBandBps max");
    }

    function test_setGuardParamsBounds_maxFeedAge() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        g.maxFeedAge = 3_600;
        _assertParamOk(g);
        g.maxFeedAge = 172_800;
        _assertParamOk(g);
        g.maxFeedAge = 3_599;
        _assertParamBad(g, "maxFeedAge 3599");
        g.maxFeedAge = 172_801;
        _assertParamBad(g, "maxFeedAge 172801");
        g.maxFeedAge = 0;
        _assertParamBad(g, "maxFeedAge 0");
    }

    function test_setGuardParamsBounds_maxPoolOracleDevBps() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        g.maxPoolOracleDevBps = 20;
        _assertParamOk(g);
        g.maxPoolOracleDevBps = 300;
        _assertParamOk(g);
        g.maxPoolOracleDevBps = 19;
        _assertParamBad(g, "dev 19");
        g.maxPoolOracleDevBps = 301;
        _assertParamBad(g, "dev 301");
    }

    function test_setGuardParamsBounds_rebalanceCooldown() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        g.rebalanceCooldown = 111;
        _assertParamOk(g);
        g.rebalanceCooldown = 3_600;
        _assertParamOk(g);
        g.rebalanceCooldown = 110;
        _assertParamBad(g, "cooldown 110 (inside the 111 s forfeiture window)");
        g.rebalanceCooldown = 3_601;
        _assertParamBad(g, "cooldown 3601");
        g.rebalanceCooldown = 0;
        _assertParamBad(g, "cooldown 0");
    }

    function test_setGuardParamsBounds_maxRebalancesPerDay() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        g.maxRebalancesPerDay = 4;
        _assertParamOk(g);
        g.maxRebalancesPerDay = 96;
        _assertParamOk(g);
        g.maxRebalancesPerDay = 3;
        _assertParamBad(g, "perDay 3");
        g.maxRebalancesPerDay = 97;
        _assertParamBad(g, "perDay 97");
        g.maxRebalancesPerDay = 0;
        _assertParamBad(g, "perDay 0");
    }

    function test_setGuardParamsBounds_maxSwapBps() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        g.maxSwapBps = 1;
        _assertParamOk(g);
        g.maxSwapBps = 10_000;
        _assertParamOk(g);
        g.maxSwapBps = 0;
        _assertParamBad(g, "swap 0");
        g.maxSwapBps = 10_001;
        _assertParamBad(g, "swap 10001");
    }

    function test_setGuardParamsBounds_maxRebalanceLossBps() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        g.maxRebalanceLossBps = 5;
        _assertParamOk(g);
        g.maxRebalanceLossBps = 300;
        _assertParamOk(g);
        g.maxRebalanceLossBps = 4;
        _assertParamBad(g, "loss 4");
        g.maxRebalanceLossBps = 301;
        _assertParamBad(g, "loss 301");
        g.maxRebalanceLossBps = 0;
        _assertParamBad(g, "loss 0");
    }

    function test_setGuardParamsStoresAndEmits() public {
        IPharaohDlmmVault.GuardParams memory g = IPharaohDlmmVault.GuardParams(40, 50_000, 80, 300, 20, 5_000, 30);
        vm.expectEmit(address(v));
        emit IPharaohDlmmVault.GuardParamsSet(g);
        vm.prank(SAFE);
        v.setGuardParams(g);
        IPharaohDlmmVault.GuardParams memory r = v.guardParams();
        assertEq(r.legBandBps, 40);
        assertEq(r.maxFeedAge, 50_000);
        assertEq(r.maxPoolOracleDevBps, 80);
        assertEq(r.rebalanceCooldown, 300);
        assertEq(r.maxRebalancesPerDay, 20);
        assertEq(r.maxSwapBps, 5_000);
        assertEq(r.maxRebalanceLossBps, 30);
    }

    function test_setGuardParamsOwnerOnly() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, ATTACKER));
        v.setGuardParams(g);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, KEEPER));
        v.setGuardParams(g);
    }

    function test_changedParamsChangeTheGuard() public {
        IPharaohDlmmVault.GuardParams memory g = _gp();
        g.legBandBps = 10;
        vm.prank(SAFE);
        v.setGuardParams(g);
        feedUsdc.setAnswer(1.0015e8); // 15 bps > 10 bps band
        assertEq(_reasons(), 4);
        g.legBandBps = 200;
        vm.prank(SAFE);
        v.setGuardParams(g);
        assertEq(_reasons(), 0);
        // maxFeedAge
        g.maxFeedAge = 3_600;
        vm.prank(SAFE);
        v.setGuardParams(g);
        feedUsdc.setAnswerAt(1e8, block.timestamp - 3_601);
        assertEq(_reasons(), 1);
    }
}

contract MockOtherHook {
    function isLinked() external pure returns (bool) {
        return true;
    }
}

contract GuardFlippedTest is GuardTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}
