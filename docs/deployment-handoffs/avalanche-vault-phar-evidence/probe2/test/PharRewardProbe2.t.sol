// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";

// READ-ONLY fork probe, second set (Q1..Q10). Local VM only: vm.prank / deal / vm.warp / vm.mockCallRevert are cheatcodes
// on a forked copy of state. Nothing is signed, nothing is broadcast, no key is used. Governance actions (threshold change,
// blacklist) are LOCAL SIMULATIONS by pranking the real governance address inside the local VM.
// NOTE: vm.getBlockTimestamp()/getBlockNumber() are used instead of block.* because the via-IR optimizer caches block.timestamp within a function.
// Pin: block 99216397 (pass --fork-block-number 99216397 with --rpc-url).

interface IPM2 {
    struct MintParams {
        address token0; address token1; int24 tickSpacing; int24 tickLower; int24 tickUpper;
        uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min;
        address recipient; uint256 deadline;
    }
    struct IncParams { uint256 tokenId; uint256 amount0Desired; uint256 amount1Desired; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    struct DecParams { uint256 tokenId; uint128 liquidity; uint256 amount0Min; uint256 amount1Min; uint256 deadline; }
    struct CollectParams { uint256 tokenId; address recipient; uint128 amount0Max; uint128 amount1Max; }
    function mint(MintParams calldata p) external payable returns (uint256, uint128, uint256, uint256);
    function increaseLiquidity(IncParams calldata p) external payable returns (uint128, uint256, uint256);
    function decreaseLiquidity(DecParams calldata p) external payable returns (uint256, uint256);
    function collect(CollectParams calldata p) external payable returns (uint256, uint256);
    function getReward(uint256 tokenId, address[] calldata tokens) external payable;
    function getPeriodReward(uint256 period, uint256 tokenId, address[] calldata tokens, address receiver) external payable;
    function positions(uint256) external view returns (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function positionLastModified(uint256) external view returns (uint32);
    function ownerOf(uint256) external view returns (address);
    function transferFrom(address, address, uint256) external;
}

interface IGauge2 {
    function earned(address token, uint256 tokenId) external view returns (uint256);
    function periodEarned(uint256 period, address token, uint256 tokenId) external view returns (uint256);
    function notifyRewardAmount(address token, uint256 amount) external;
    function forfeitedRewards(bytes32, address) external view returns (uint256 period, uint256 amount);
    function lastClaimByToken(address, bytes32) external view returns (uint256);
    function positionHash(address owner, uint256 index, int24 lo, int24 hi) external pure returns (bytes32);
}

interface IVoterGov {
    function setTimeThresholdForGauge(address gauge, uint256 t) external;
    function timeThresholdForGauge(address gauge) external view returns (uint256);
    function accessHub() external view returns (address);
}

interface IRV2 {
    function addWalletToBlacklist(address) external;
    function validateReward(address, address, bytes32, address, uint256, int24, int24, address) external view returns (bool);
}

interface IERC20b {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IPool2 {
    function positionPeriodSecondsInRange(uint256 period, address owner, uint256 index, int24 lo, int24 hi) external view returns (uint256);
}

contract PharRewardProbe2 is Test {
    address constant VAULT = 0x855bF832f26a294d28500db59eE941dE3d654129;
    address constant PMA = 0x0B4478e810D48B5882D4019D435A2f864Bab4F39;
    address constant GAUGE = 0xf51B4EB0f6801729170d18BEe67C7F5d98985572;
    address constant VOTER = 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7;
    address constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
    address constant XPHAR = 0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A;
    address constant R33 = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
    address constant POOL = 0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0;
    address constant RV = 0x065028dcF219D8622Dd50231f188f2B315349AEF;
    address constant ACCESS_HUB = 0x3176f6E4Be2448C53EDD59C27651EDFaA74bf483;
    address constant TIMELOCK = 0x12d54Ad6dAF65d55B029Df1b34B260C68fc0dDCF;
    uint256 constant A = 485334; // the vault's existing NFT
    uint256 constant WEEK = 604800;
    address constant ALICE = address(0xA11CE);

    IPM2 pm = IPM2(PMA);
    IGauge2 g = IGauge2(GAUGE);

    function _toks() internal pure returns (address[] memory t) {
        t = new address[](2); t[0] = PHAR; t[1] = XPHAR;
    }

    function _hash(uint256 id) internal view returns (bytes32) {
        (,,, int24 lo, int24 hi,,,,,) = pm.positions(id);
        return g.positionHash(PMA, id, lo, hi);
    }

    function _liq(uint256 id) internal view returns (uint128 l) {
        (,,,,, l,,,,) = pm.positions(id);
    }

    function _advance(uint256 s) internal {
        vm.warp(vm.getBlockTimestamp() + s);
        vm.roll(vm.getBlockNumber() + s / 2 + 1);
    }

    function _claim(uint256 id) internal returns (uint256 got, bool ok) {
        uint256 b = IERC20b(PHAR).balanceOf(VAULT);
        vm.prank(VAULT);
        (ok,) = PMA.call(abi.encodeCall(IPM2.getReward, (id, _toks())));
        got = IERC20b(PHAR).balanceOf(VAULT) - b;
    }

    /// dust decrease (fraction of liquidity / 1e6) by the vault; returns PHAR paid by the auto-claim
    function _dust(uint256 id) internal returns (uint256 paid) {
        uint128 l = _liq(id);
        uint256 b = IERC20b(PHAR).balanceOf(VAULT);
        vm.prank(VAULT);
        pm.decreaseLiquidity(IPM2.DecParams(id, l / 1_000_000 + 1, 0, 0, vm.getBlockTimestamp() + 1));
        paid = IERC20b(PHAR).balanceOf(VAULT) - b;
    }

    function _mintB() internal returns (uint256 idB, uint128 liqB) {
        (address t0, address t1, int24 ts, int24 lo, int24 hi,,,,,) = pm.positions(A);
        deal(t0, VAULT, 5_000e6);
        deal(t1, VAULT, 5_000e6);
        vm.startPrank(VAULT);
        (bool o0,) = t0.call(abi.encodeWithSignature("approve(address,uint256)", PMA, type(uint256).max));
        (bool o1,) = t1.call(abi.encodeWithSignature("approve(address,uint256)", PMA, type(uint256).max));
        require(o0 && o1, "approve");
        (idB, liqB,,) = pm.mint(IPM2.MintParams(t0, t1, ts, lo, hi, 2_000e6, 2_000e6, 0, 0, VAULT, vm.getBlockTimestamp() + 1));
        vm.stopPrank();
    }

    // Q1: per-NFT windows. A second NFT of the same vault in the same pool/range has its OWN lastModified and position hash.
    // Dust-touching it any number of times never opens a window on A, and A's claim stays lossless. Rewards are additive in
    // liquidity: per-liquidity accrual of A and B match, so splitting into NFTs does not dilute.
    function test_Q1_secondNftHasIndependentWindow() public {
        uint32 lmA0 = pm.positionLastModified(A);
        uint256 gas0 = gasleft();
        (uint256 idB, uint128 liqB) = _mintB();
        console2.log("Q1 gas mint(B)                       ", gas0 - gasleft());
        assertEq(uint256(pm.positionLastModified(A)), uint256(lmA0), "minting B does not touch A.lastModified");
        assertEq(uint256(pm.positionLastModified(idB)), vm.getBlockTimestamp());
        assertTrue(_hash(idB) != _hash(A), "distinct position hash per NFT");
        // repeated dust on B (each one auto-claims B inside B's window, slashed, harmless to A)
        for (uint256 i = 0; i < 5; i++) {
            _advance(20);
            vm.startPrank(VAULT);
            uint256 g1 = gasleft();
            pm.increaseLiquidity(IPM2.IncParams(idB, 1e6, 1e6, 0, 0, vm.getBlockTimestamp() + 1));
            if (i == 0) console2.log("Q1 gas increaseLiquidity(B)          ", g1 - gasleft());
            vm.stopPrank();
        }
        assertEq(uint256(pm.positionLastModified(A)), uint256(lmA0), "A.lastModified untouched by 5 dust ops on B");
        uint256 eA = g.earned(PHAR, A);
        uint256 r0 = IERC20b(PHAR).balanceOf(R33);
        uint256 gc = gasleft();
        (uint256 got, bool ok) = _claim(A);
        console2.log("Q1 gas getReward(A, 12 periods)      ", gc - gasleft());
        assertTrue(ok);
        assertEq(got, eA, "A claim lossless while B is in its window");
        assertGt(got, 0);
        assertEq(IERC20b(PHAR).balanceOf(R33), r0, "nothing to r33 for A");
        (, uint256 fa) = g.forfeitedRewards(_hash(A), PHAR);
        assertEq(fa, 0, "no debt on A");
        // B claim inside B's window: slashed, B only
        (uint256 gotB,) = _claim(idB);
        assertEq(gotB, 0, "B claim inside B window pays zero");
        (uint256 fbp, uint256 fba) = g.forfeitedRewards(_hash(idB), PHAR);
        console2.log("Q1 B debt period/amount              ", fbp, fba);
        assertGt(fbp, 0);
        // additivity: accrual per liquidity of A and B over 1 hour
        uint256 eA0 = g.earned(PHAR, A);
        uint256 eB0 = g.earned(PHAR, idB);
        _advance(3600);
        uint256 dA = g.earned(PHAR, A) - eA0;
        uint256 dB = g.earned(PHAR, idB) - eB0;
        uint128 lA = _liq(A);
        uint128 lB = _liq(idB);
        console2.log("Q1 liquidity A / B                   ", uint256(lA), uint256(lB));
        console2.log("Q1 PHAR accrued in 1h A / B          ", dA, dB);
        uint256 rateA = dA * 1e18 / lA;
        uint256 rateB = dB * 1e18 / lB;
        console2.log("Q1 per-liquidity rate A / B (1e18)   ", rateA, rateB);
        assertApproxEqRel(rateA, rateB, 2e16, "gauge pays by liquidity-time: NFTs are additive (2%)");
        liqB;
    }

    // Q2: collect, ERC-721 transfer and a different owner/caller do not change lastModified and do not claim.
    function test_Q2_collectTransferDoNotTouchWindow() public {
        _dust(A); // clean change, pays everything, sets lastModified = t0
        uint32 lm = pm.positionLastModified(A);
        _advance(50);
        vm.prank(VAULT);
        pm.collect(IPM2.CollectParams(A, VAULT, type(uint128).max, type(uint128).max));
        assertEq(uint256(pm.positionLastModified(A)), uint256(lm), "collect does not set lastModified");
        (uint256 fp,) = g.forfeitedRewards(_hash(A), PHAR);
        assertEq(fp, 0, "collect triggered no claim, no debt");
        vm.prank(VAULT);
        pm.transferFrom(VAULT, ALICE, A);
        assertEq(uint256(pm.positionLastModified(A)), uint256(lm), "NFT transfer does not set lastModified");
        _advance(120); // now outside the 111 s window measured from lm
        uint256 e = g.earned(PHAR, A);
        uint256 a0 = IERC20b(PHAR).balanceOf(ALICE);
        uint256 r0 = IERC20b(PHAR).balanceOf(R33);
        vm.prank(ALICE);
        pm.getReward(A, _toks());
        assertGt(e, 0);
        assertEq(IERC20b(PHAR).balanceOf(ALICE) - a0, e, "reward goes to the NFT owner at claim time; claim lossless");
        assertEq(IERC20b(PHAR).balanceOf(R33), r0);
    }

    // Q3: harvest-then-change in one transaction is lossless; the SECOND change inside the window loses exactly the accrual
    // since the previous clean claim.
    function test_Q3_firstChangeLosslessSecondChangeLoses() public {
        uint256 e0 = g.earned(PHAR, A);
        (uint256 got,) = _claim(A);
        assertEq(got, e0);
        uint256 paidByDec = _dust(A); // auto-claim: old lastModified (77 days) -> clean, pays 0 because nothing is left
        assertEq(paidByDec, 0, "harvest then change: auto-claim pays zero");
        (uint256 fp,) = g.forfeitedRewards(_hash(A), PHAR);
        assertEq(fp, 0);
        _advance(50);
        uint256 e50 = g.earned(PHAR, A);
        assertGt(e50, 0);
        uint256 paid2 = _dust(A); // SECOND change inside the window: auto-claim slashed
        assertEq(paid2, 0, "second change inside window: slashed, pays zero");
        (uint256 fp2, uint256 fa2) = g.forfeitedRewards(_hash(A), PHAR);
        console2.log("Q3 accrual in the 50 s between the two changes", e50);
        console2.log("Q3 debt recorded period/amount                ", fp2, fa2);
        assertEq(fa2, e50, "debt equals the accrual since the previous clean claim");
        _advance(300);
        uint256 r0 = IERC20b(PHAR).balanceOf(R33);
        (uint256 got3,) = _claim(A);
        console2.log("Q3 r33 received (the loss)                    ", IERC20b(PHAR).balanceOf(R33) - r0);
        console2.log("Q3 vault received after window                ", got3);
        assertEq(IERC20b(PHAR).balanceOf(R33) - r0, e50);
    }

    // Q4: getPeriodReward(past period) inside the window forfeits ONLY that period and writes no debt, versus getReward which
    // writes a debt that wipes every earlier period at the next clean claim. It does not make a window claim free.
    function _setupStraddle() internal returns (uint256 p0, uint256 eOld) {
        p0 = vm.getBlockTimestamp() / WEEK;
        uint256 boundary = (p0 + 1) * WEEK;
        _claim(A);
        vm.warp(boundary - 100);
        vm.roll(vm.getBlockNumber() + 100000);
        _dust(A); // clean, pays everything, lastModified = boundary - 100
        // give the new period an emission so there is something to be forfeited there too (probe P4 technique)
        address n = address(0xB0B0);
        deal(PHAR, n, 1000 ether);
        vm.startPrank(n);
        IERC20b(PHAR).approve(GAUGE, 1000 ether);
        vm.warp(boundary + 5);
        vm.roll(vm.getBlockNumber() + 3);
        g.notifyRewardAmount(PHAR, 1000 ether);
        vm.stopPrank();
        vm.warp(boundary + 10); // 110 s after the change: still inside the 111 s window
        vm.roll(vm.getBlockNumber() + 3);
        eOld = g.periodEarned(p0, PHAR, A);
    }

    function test_Q4_getPeriodRewardScope() public {
        uint256 snap = vm.snapshotState();
        (uint256 p0, uint256 eOld) = _setupStraddle();
        uint256 eNew = g.periodEarned(p0 + 1, PHAR, A);
        console2.log("Q4 unpaid old period / new period (in window)", eOld, eNew);
        assertGt(eOld, 0);
        assertGt(eNew, 0);
        // branch A: getReward (the all-periods call) inside the window
        uint256 s2 = vm.snapshotState();
        uint256 r0 = IERC20b(PHAR).balanceOf(R33);
        (uint256 gotA,) = _claim(A);
        assertEq(gotA, 0);
        (uint256 dpA, uint256 daA) = g.forfeitedRewards(_hash(A), PHAR);
        console2.log("Q4 branch getReward: debt period/amount      ", dpA, daA);
        assertEq(dpA, p0 + 1, "debt recorded against the current period");
        _advance(400);
        uint256 eTot = g.earned(PHAR, A);
        (uint256 gotA2,) = _claim(A);
        uint256 lossA = IERC20b(PHAR).balanceOf(R33) - r0;
        console2.log("Q4 branch getReward: lost to r33 / later paid", lossA, gotA2);
        console2.log("Q4 branch getReward: earned view before late claim", eTot);
        vm.revertToState(s2);
        // branch B: getPeriodReward(old period) inside the window
        r0 = IERC20b(PHAR).balanceOf(R33);
        uint256 v0 = IERC20b(PHAR).balanceOf(VAULT);
        vm.prank(VAULT);
        pm.getPeriodReward(p0, A, _toks(), VAULT);
        assertEq(IERC20b(PHAR).balanceOf(VAULT), v0, "slashed: vault receives nothing");
        assertEq(IERC20b(PHAR).balanceOf(R33) - r0, eOld, "exactly the named period went to r33, immediately");
        (uint256 dpB,) = g.forfeitedRewards(_hash(A), PHAR);
        assertEq(dpB, 0, "no debt written by getPeriodReward");
        assertEq(g.periodEarned(p0 + 1, PHAR, A), eNew, "new period untouched");
        _advance(400);
        (uint256 gotB2,) = _claim(A);
        uint256 lossB = IERC20b(PHAR).balanceOf(R33) - r0;
        console2.log("Q4 branch getPeriodReward: lost to r33 / later paid", lossB, gotB2);
        assertGt(gotB2, 0);
        assertLt(lossB, lossA + 1, "scope is narrower or equal");
        vm.revertToState(snap);
    }

    // Q4b: getPeriodReward outside the window for ONE past period pays that period only (per-period pagination unit).
    function test_Q4b_getPeriodRewardOutsideWindowPaysOnePeriod() public {
        uint256 p = vm.getBlockTimestamp() / WEEK;
        uint256 q = p - 3;
        uint256 eq3 = g.periodEarned(q, PHAR, A);
        uint256 tot = g.earned(PHAR, A);
        uint256 v0 = IERC20b(PHAR).balanceOf(VAULT);
        uint256 gg = gasleft();
        vm.prank(VAULT);
        pm.getPeriodReward(q, A, _toks(), VAULT);
        console2.log("Q4b gas getPeriodReward(1 period)    ", gg - gasleft());
        assertGt(eq3, 0);
        assertEq(IERC20b(PHAR).balanceOf(VAULT) - v0, eq3, "pays exactly the named period");
        assertEq(g.earned(PHAR, A), tot - eq3, "other periods untouched");
        // the later getReward still pays the rest, nothing is double paid
        (uint256 rest,) = _claim(A);
        assertEq(rest, tot - eq3);
    }

    // Q5: a chain of slashed changes, 100 s apart: the debt is overwritten by the latest unpaid; the next clean claim
    // forfeits everything accrued from the chain start to the LAST slashed change. Loss grows with chain length.
    function test_Q5_slashChainLossGrowsWithLength() public {
        _claim(A);
        _advance(1000);
        _dust(A); // clean change at tc (pays accrual so far)
        uint256 tc = vm.getBlockTimestamp();
        uint256 lastDebt;
        uint256 cum;
        for (uint256 k = 1; k <= 4; k++) {
            _advance(100);
            cum += g.earned(PHAR, A); // the view already excludes the earlier debt, so this adds only the new slice
            assertEq(_dust(A), 0, "slashed");
            (, uint256 fa) = g.forfeitedRewards(_hash(A), PHAR);
            console2.log("Q5 chain step / debt after the change", k, fa);
            assertEq(fa, cum, "debt == cumulative unpaid since the chain start (overwritten each time)");
            lastDebt = fa;
        }
        assertEq(vm.getBlockTimestamp() - tc, 400);
        _advance(2000);
        uint256 r0 = IERC20b(PHAR).balanceOf(R33);
        uint256 eAfter = g.earned(PHAR, A);
        (uint256 got,) = _claim(A);
        console2.log("Q5 forfeited to r33 at the clean claim", IERC20b(PHAR).balanceOf(R33) - r0);
        console2.log("Q5 paid to vault                       ", got);
        assertEq(IERC20b(PHAR).balanceOf(R33) - r0, lastDebt, "forfeit == debt at the last slashed change");
        assertGt(lastDebt, 0);
        assertGt(eAfter, 0);
    }

    // Q6: governance changes the threshold for this gauge (LOCAL SIMULATION). The gauge/validator never block principal:
    // a decrease always succeeds; only the swallowed auto-claim slashes. The lossless time for a change is lm + threshold.
    function test_Q6_governanceRaisedThreshold() public {
        address hub = IVoterGov(VOTER).accessHub();
        assertEq(hub, ACCESS_HUB);
        uint256 t = IVoterGov(VOTER).timeThresholdForGauge(GAUGE);
        console2.log("Q6 threshold at pin (s)               ", t);
        vm.prank(hub);
        IVoterGov(VOTER).setTimeThresholdForGauge(GAUGE, 7 days);
        // first change after the long quiet span is still lossless
        uint256 e0 = g.earned(PHAR, A);
        assertEq(_dust(A), e0, "first change after quiet (77 d > 7 d) is lossless");
        _advance(1 days);
        uint256 e1 = g.earned(PHAR, A);
        assertEq(_dust(A), 0, "1 day later: second change slashed under a 7 day threshold");
        (, uint256 d1) = g.forfeitedRewards(_hash(A), PHAR);
        assertEq(d1, e1);
        _advance(1 days);
        (uint256 got,) = _claim(A);
        assertEq(got, 0, "harvest at 2 days: slashed, pays zero");
        _advance(6 days + 1); // 7 d + 1 s after the last liquidity change (day 1)
        uint256 r0 = IERC20b(PHAR).balanceOf(R33);
        (uint256 got2,) = _claim(A);
        console2.log("Q6 clean harvest after 7 d: vault / r33", got2, IERC20b(PHAR).balanceOf(R33) - r0);
        assertGt(got2, 0);
        // full principal exit is never blocked by the gauge: inside the window the decrease succeeds (rewards slashed, not principal)
        vm.prank(hub);
        IVoterGov(VOTER).setTimeThresholdForGauge(GAUGE, type(uint256).max);
        uint128 l = _liq(A);
        vm.prank(VAULT);
        pm.decreaseLiquidity(IPM2.DecParams(A, l, 0, 0, vm.getBlockTimestamp() + 1));
        assertEq(uint256(_liq(A)), 0, "principal exit succeeds under threshold = uint256.max (rewards are what is slashed)");
        _advance(365 days);
        (uint256 got3,) = _claim(A);
        assertEq(got3, 0, "threshold = uint256.max: no claim is ever clean");
    }

    // Q7: the blacklist can be read WITHOUT the time check by calling the validator with a non-position-manager owner.
    function test_Q7_walletBlacklistOracle() public {
        address bad = address(0xBAD);
        vm.prank(TIMELOCK); // LOCAL SIMULATION of Pharaoh governance
        IRV2(RV).addWalletToBlacklist(bad);
        bool badRes = IRV2(RV).validateReward(ALICE, ALICE, bytes32(0), bad, 0, 0, 0, POOL);
        bool cleanRes = IRV2(RV).validateReward(ALICE, ALICE, bytes32(0), address(0xC1EA2), 0, 0, 0, POOL);
        assertTrue(badRes, "blacklisted origin -> true");
        assertFalse(cleanRes, "clean wallet, non-NFT owner -> false (no time check)");
        // with owner == position manager the time check applies: after a fresh change it is true for a clean origin
        _dust(A);
        vm.prank(GAUGE);
        bool inWindow = IRV2(RV).validateReward(PMA, VAULT, _hash(A), address(0xC1EA2), A, -1, 1, POOL);
        console2.log("Q7 validator(owner=PM) right after a change (should be true):", inWindow ? uint256(1) : uint256(0));
        assertTrue(inWindow);
    }

    // Q8: if the pool's period-seconds view reverts, the gauge treats the period as ZERO and still advances lastClaimByToken:
    // a getReward made then HIDES the backlog from getReward/earned (no forfeit record; Q10 shows it stays recoverable per period). A direct pool read by the vault (reverts) is the detector.
    function test_Q8_poolReadFailureHidesBacklogFromGetReward() public {
        (,,, int24 lo, int24 hi,,,,,) = pm.positions(A);
        uint256 p = vm.getBlockTimestamp() / WEEK;
        uint256 eBefore = g.earned(PHAR, A);
        assertGt(eBefore, 0);
        bytes4 sel = IPool2.positionPeriodSecondsInRange.selector;
        vm.mockCallRevert(POOL, abi.encodeWithSelector(sel), "pool read broken (local mock)");
        // vault's own direct read reverts -> this is the exposure source failure signal
        bool directOk;
        try IPool2(POOL).positionPeriodSecondsInRange(p, PMA, A, lo, hi) returns (uint256) { directOk = true; } catch { directOk = false; }
        assertFalse(directOk, "direct read reverts");
        // the gauge's own views report 0 -> indistinguishable from 'nothing owed'
        assertEq(g.earned(PHAR, A), 0, "gauge view reports 0 while the pool read fails");
        (uint256 got, bool ok) = _claim(A);
        assertTrue(ok, "the claim returns normally");
        assertEq(got, 0, "pays zero");
        vm.clearMockedCalls();
        uint256 eAfter = g.earned(PHAR, A);
        console2.log("Q8 backlog before the broken-read claim", eBefore);
        console2.log("Q8 earned after the read recovers       ", eAfter);
        assertLt(eAfter, eBefore / 2, "the old periods are gone from the gauge: lastClaimByToken advanced");
        assertEq(g.lastClaimByToken(PHAR, _hash(A)), p);
    }

    // Q9: unit gas costs for the pagination bound.
    function test_Q9_gasUnits() public {
        (,,, int24 lo, int24 hi,,,,,) = pm.positions(A);
        uint256 p = vm.getBlockTimestamp() / WEEK;
        uint256 g0 = gasleft();
        IPool2(POOL).positionPeriodSecondsInRange(p, PMA, A, lo, hi);
        console2.log("Q9 gas positionPeriodSecondsInRange (cold, 1 call)", g0 - gasleft());
        g0 = gasleft();
        IPool2(POOL).positionPeriodSecondsInRange(p - 1, PMA, A, lo, hi);
        console2.log("Q9 gas positionPeriodSecondsInRange (2nd period) ", g0 - gasleft());
        g0 = gasleft();
        g.periodEarned(p - 2, PHAR, A);
        console2.log("Q9 gas gauge.periodEarned (1 period)             ", g0 - gasleft());
        g0 = gasleft();
        g.earned(PHAR, A);
        console2.log("Q9 gas gauge.earned (12 periods)                 ", g0 - gasleft());
        g0 = gasleft();
        pm.positionLastModified(A);
        console2.log("Q9 gas positionLastModified                      ", g0 - gasleft());
    }

    // Q10: the broken-read claim of Q8 is NOT permanent: getPeriodReward(period) recomputes from the pool and pays the old period
    // once the read works again (lastClaimByToken only limits getReward/earned loops, not getPeriodReward).
    function test_Q10_brokenReadLossIsRecoverableByPeriodCall() public {
        uint256 p = vm.getBlockTimestamp() / WEEK;
        uint256 q = p - 4;
        uint256 eq = g.periodEarned(q, PHAR, A);
        assertGt(eq, 0);
        vm.mockCallRevert(POOL, abi.encodeWithSelector(IPool2.positionPeriodSecondsInRange.selector), "pool read broken (local mock)");
        _claim(A);
        vm.clearMockedCalls();
        assertEq(g.lastClaimByToken(PHAR, _hash(A)), p, "getReward advanced lastClaim over the unread periods");
        uint256 v0 = IERC20b(PHAR).balanceOf(VAULT);
        vm.prank(VAULT);
        pm.getPeriodReward(q, A, _toks(), VAULT);
        console2.log("Q10 old-period pending before the broken claim", eq);
        console2.log("Q10 paid by getPeriodReward after recovery    ", IERC20b(PHAR).balanceOf(VAULT) - v0);
        assertEq(IERC20b(PHAR).balanceOf(VAULT) - v0, eq, "recovered in full by the per-period call");
    }
}
