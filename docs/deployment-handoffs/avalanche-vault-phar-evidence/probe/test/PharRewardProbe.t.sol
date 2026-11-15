// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";

// READ-ONLY fork probe. Local VM only: vm.prank / vm.deal / deal / vm.warp are cheatcodes on a forked copy of state.
// Nothing is signed, nothing is broadcast, no key is used. Not part of the repo (lives in the scratchpad).

interface IPM {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }
    function getReward(uint256 tokenId, address[] calldata tokens) external payable;
    function decreaseLiquidity(DecreaseLiquidityParams calldata p) external payable returns (uint256, uint256);
    function positions(uint256) external view returns (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function positionLastModified(uint256) external view returns (uint32);
    function ownerOf(uint256) external view returns (address);
}

interface IGauge {
    function earned(address token, uint256 tokenId) external view returns (uint256);
    function notifyRewardAmount(address token, uint256 amount) external;
    function tokenTotalSupplyByPeriod(uint256, address) external view returns (uint256);
    function periodClaimedAmount(uint256, bytes32, address) external view returns (uint256);
    function forfeitedRewards(bytes32, address) external view returns (uint256 period, uint256 amount);
    function lastClaimByToken(address, bytes32) external view returns (uint256);
    function positionHash(address owner, uint256 index, int24 lo, int24 hi) external pure returns (bytes32);
    function getRewardForOwner(uint256 tokenId, address[] memory tokens) external;
}

interface IVoterX {
    function claimClGaugeRewards(address[] calldata g, address[][] calldata t, uint256[][] calldata ids) external;
}

interface IPool {
    function positionPeriodSecondsInRange(uint256 period, address owner, uint256 index, int24 lo, int24 hi) external view returns (uint256);
    function _advancePeriod() external;
    function lastPeriod() external view returns (uint256);
}

interface IRV {
    function addWalletToBlacklist(address) external;
}

interface IGaugeP {
    function periodEarned(uint256 period, address token, uint256 tokenId) external view returns (uint256);
}

interface IXP {
    function exit(uint256) external returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract PharRewardProbe is Test {
    address constant VAULT = 0x855bF832f26a294d28500db59eE941dE3d654129; // Pharaoh USDC vault proxy
    address constant PMA = 0x0B4478e810D48B5882D4019D435A2f864Bab4F39;
    address constant GAUGE = 0xf51B4EB0f6801729170d18BEe67C7F5d98985572;
    address constant VOTER = 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7;
    address constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
    address constant XPHAR = 0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A;
    address constant R33 = 0x26e9dbe75aed331E41272BEcE932Ff1B48926Ca9;
    uint256 constant TOKEN_ID = 485334;
    uint256 constant WEEK = 604800;
    address constant ALICE = address(0xA11CE);

    IPM pm = IPM(PMA);
    IGauge g = IGauge(GAUGE);

    function setUp() public {
        vm.createSelectFork("https://api.avax.network/ext/bc/C/rpc", 99216397);
    }

    function _toks() internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = PHAR;
        t[1] = XPHAR;
    }

    function _hash() internal view returns (bytes32) {
        (,,, int24 lo, int24 hi,,,,,) = pm.positions(TOKEN_ID);
        return g.positionHash(PMA, TOKEN_ID, lo, hi);
    }

    function _claim() internal returns (uint256 gotPhar, bool ok) {
        uint256 b = IERC20(PHAR).balanceOf(VAULT);
        vm.prank(VAULT);
        (ok,) = PMA.call(abi.encodeCall(IPM.getReward, (TOKEN_ID, _toks())));
        gotPhar = IERC20(PHAR).balanceOf(VAULT) - b;
    }

    // P1: pending view == claim at the same block; second claim pays zero without reverting; non-owner cannot claim.
    function test_P1_earnedEqualsClaim_zeroClaim_nonOwner() public {
        uint256 e = g.earned(PHAR, TOKEN_ID);
        (uint256 got, bool ok) = _claim();
        console2.log("P1 earned(view)", e);
        console2.log("P1 claimed     ", got);
        assertTrue(ok);
        assertEq(got, e, "earned == claim");
        assertEq(g.earned(PHAR, TOKEN_ID), 0, "earned after claim");
        (uint256 got2, bool ok2) = _claim();
        assertTrue(ok2, "second claim must not revert");
        assertEq(got2, 0, "second claim pays zero");
        // non-owner
        vm.prank(ALICE);
        (bool okA,) = PMA.call(abi.encodeCall(IPM.getReward, (TOKEN_ID, _toks())));
        assertFalse(okA, "PM.getReward by non-owner must revert");
        vm.prank(ALICE);
        (bool okB,) = GAUGE.call(abi.encodeCall(IGauge.getRewardForOwner, (TOKEN_ID, _toks())));
        assertFalse(okB, "gauge.getRewardForOwner by non-claimer must revert");
        address[] memory gs = new address[](1);
        gs[0] = GAUGE;
        address[][] memory ts = new address[][](1);
        ts[0] = _toks();
        uint256[][] memory ids = new uint256[][](1);
        ids[0] = new uint256[](1);
        ids[0][0] = TOKEN_ID;
        vm.prank(ALICE);
        (bool okC,) = VOTER.call(abi.encodeCall(IVoterX.claimClGaugeRewards, (gs, ts, ids)));
        assertFalse(okC, "Voter.claimClGaugeRewards by non-owner must revert");
    }

    // P2: anti-sybil window. After a liquidity change, a claim inside timeThreshold (111 s) pays ZERO, does not revert,
    // and records a forfeit; the slashed amount goes to r33 on the next successful claim.
    function test_P2_slashWindow() public {
        (,,,,, uint128 liq,,,,) = pm.positions(TOKEN_ID);
        uint256 e0 = g.earned(PHAR, TOKEN_ID);
        uint256 vb = IERC20(PHAR).balanceOf(VAULT);
        vm.prank(VAULT);
        pm.decreaseLiquidity(IPM.DecreaseLiquidityParams(TOKEN_ID, liq / 1000, 0, 0, block.timestamp + 1));
        uint256 paidByDecrease = IERC20(PHAR).balanceOf(VAULT) - vb;
        console2.log("P2 earned before decrease      ", e0);
        console2.log("P2 paid by decrease try-claim  ", paidByDecrease);
        assertEq(paidByDecrease, e0, "old lastModified -> decrease claim pays everything");
        assertEq(uint256(pm.positionLastModified(TOKEN_ID)), block.timestamp, "lastModified = now");

        // a claim in the SAME transaction/block as a liquidity change
        vm.warp(block.timestamp + 50);
        vm.roll(block.number + 25);
        uint256 e1 = g.earned(PHAR, TOKEN_ID);
        (uint256 got, bool ok) = _claim();
        console2.log("P2 earned 50s later (view)     ", e1);
        console2.log("P2 claim inside window pays    ", got);
        assertTrue(ok, "slashed claim must not revert");
        assertGt(e1, 0, "something accrued");
        assertEq(got, 0, "slashed claim pays zero");
        (uint256 fp, uint256 fa) = g.forfeitedRewards(_hash(), PHAR);
        console2.log("P2 forfeit period/amount", fp, fa);
        assertEq(fa, e1, "forfeit recorded = pending at the time");
        assertEq(g.earned(PHAR, TOKEN_ID), 0, "earned view now excludes the forfeited share");

        // after the window the claim pays only what accrued after the slash; the slashed part goes to r33
        vm.warp(block.timestamp + 300);
        vm.roll(block.number + 150);
        uint256 e2 = g.earned(PHAR, TOKEN_ID);
        uint256 r0 = IERC20(PHAR).balanceOf(R33);
        (uint256 got2,) = _claim();
        uint256 r1 = IERC20(PHAR).balanceOf(R33);
        console2.log("P2 later earned(view)          ", e2);
        console2.log("P2 later claim paid            ", got2);
        console2.log("P2 r33 received                ", r1 - r0);
        assertEq(got2, e2, "later claim == earned view");
        assertEq(r1 - r0, e1, "forfeited amount went to r33");
    }

    // P3: continuity across the weekly boundary: two claims (before, after the boundary) == one claim over the same span.
    function test_P3_boundaryContinuity() public {
        uint256 boundary = (block.timestamp / WEEK + 1) * WEEK;
        uint256 snap = vm.snapshotState();
        // path A: single claim after the boundary
        vm.warp(boundary + 300);
        vm.roll(block.number + 100000);
        (uint256 once,) = _claim();
        vm.revertToState(snap);
        // path B: claim before and after the boundary
        vm.warp(boundary - 100);
        vm.roll(block.number + 50000);
        (uint256 c1,) = _claim();
        vm.warp(boundary + 300);
        vm.roll(block.number + 50000);
        (uint256 c2,) = _claim();
        console2.log("P3 single claim", once);
        console2.log("P3 pre-boundary", c1);
        console2.log("P3 post-boundary", c2);
        console2.log("P3 sum         ", c1 + c2);
        assertApproxEqAbs(c1 + c2, once, 2, "claims are continuous across the boundary");
    }

    // P4: rewards notified late are paid for seconds BEFORE the notification (and before the vault's own last claim).
    function test_P4_lateNotifyIsRetroactive() public {
        uint256 period = block.timestamp / WEEK;
        (uint256 c0,) = _claim(); // claim at the pin
        assertGt(c0, 0);
        vm.warp(block.timestamp + 100_000);
        vm.roll(block.number + 50000);
        uint256 e0 = g.earned(PHAR, TOKEN_ID);
        uint256 S = g.tokenTotalSupplyByPeriod(period, PHAR);
        uint256 claimedP = g.periodClaimedAmount(period, _hash(), PHAR);
        uint256 X = 1000 ether;
        address notifier = address(0xB0B0);
        deal(PHAR, notifier, X);
        vm.startPrank(notifier);
        IERC20(PHAR).approve(GAUGE, X);
        g.notifyRewardAmount(PHAR, X);
        vm.stopPrank();
        uint256 e1 = g.earned(PHAR, TOKEN_ID);
        // f = share-time fraction of the whole period so far (includes seconds before the vault's last claim)
        uint256 f = (e0 + claimedP) * 1e18 / S;
        uint256 fBeforeLastClaim = claimedP * 1e18 / S;
        console2.log("P4 earned before late notify   ", e0);
        console2.log("P4 earned after  late notify   ", e1);
        console2.log("P4 delta                       ", e1 - e0);
        console2.log("P4 X*f (expected delta)        ", X * f / 1e18);
        console2.log("P4 part of delta for seconds before the vault's last claim", X * fBeforeLastClaim / 1e18);
        assertApproxEqRel(e1 - e0, X * f / 1e18, 1e12, "late notify pays for the whole period so far");
        assertGt(X * fBeforeLastClaim / 1e18, 0);
    }

    // P5: if the NFT is burned with an unclaimed (or slashed) balance, nothing can claim it afterwards.
    function test_P5_burnOrphansRewards() public {
        (,,,,, uint128 liq,,,,) = pm.positions(TOKEN_ID);
        vm.prank(VAULT);
        pm.decreaseLiquidity(IPM.DecreaseLiquidityParams(TOKEN_ID, liq / 1000, 0, 0, block.timestamp + 1)); // pays all, sets lastModified
        vm.warp(block.timestamp + 50);
        vm.roll(block.number + 25);
        (,,,,, uint128 liq2,,,,) = pm.positions(TOKEN_ID);
        uint256 e = g.earned(PHAR, TOKEN_ID);
        uint256 vb = IERC20(PHAR).balanceOf(VAULT);
        vm.prank(VAULT);
        pm.decreaseLiquidity(IPM.DecreaseLiquidityParams(TOKEN_ID, liq2, 0, 0, block.timestamp + 1)); // full exit inside window
        console2.log("P5 pending before in-window full exit", e);
        console2.log("P5 PHAR paid by it                   ", IERC20(PHAR).balanceOf(VAULT) - vb);
        assertEq(IERC20(PHAR).balanceOf(VAULT) - vb, 0, "in-window full exit pays zero");
        // collect + burn as the vault does
        vm.startPrank(VAULT);
        (bool okc,) = PMA.call(abi.encodeWithSignature(
            "collect((uint256,address,uint128,uint128))", TOKEN_ID, VAULT, type(uint128).max, type(uint128).max));
        assertTrue(okc, "collect");
        (bool okb,) = PMA.call(abi.encodeWithSignature("burn(uint256)", TOKEN_ID));
        assertTrue(okb, "burn allowed with rewards outstanding");
        vm.stopPrank();
        (bool okr,) = PMA.call(abi.encodeCall(IPM.getReward, (TOKEN_ID, _toks())));
        assertFalse(okr, "no claim possible after burn");
        vm.prank(VAULT);
        (bool okr2,) = PMA.call(abi.encodeCall(IPM.getReward, (TOKEN_ID, _toks())));
        assertFalse(okr2, "not even the former owner can claim after burn");
    }

    // P6: xPHAR is not transferable by a normal holder (the vault); exit is instant with a 50% penalty.
    function test_P6_xpharTransferExit() public {
        deal(XPHAR, VAULT, 10 ether);
        vm.prank(VAULT);
        (bool ok,) = XPHAR.call(abi.encodeCall(IXP.transfer, (ALICE, 1 ether)));
        assertFalse(ok, "xPHAR transfer from non-exempt vault reverts");
        uint256 b = IERC20(PHAR).balanceOf(VAULT);
        console2.log("P6 PHAR held by xPHAR contract", IERC20(PHAR).balanceOf(XPHAR));
        vm.prank(VAULT);
        uint256 out = IXP(XPHAR).exit(10 ether);
        console2.log("P6 exit(10 xPHAR) returned", out);
        assertEq(IERC20(PHAR).balanceOf(VAULT) - b, out);
        assertEq(out, 5 ether, "50% penalty");
    }

    // P7: the ledger's time source. S_p * T_p / (WEEK<<96) must equal the gauge's own per-period number.
    function test_P7_poolTimeSourceMatchesGauge() public {
        address pool = 0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0;
        (,,, int24 lo, int24 hi,,,,,) = pm.positions(TOKEN_ID);
        uint256 p = block.timestamp / WEEK;
        console2.log("P7 pool.lastPeriod", IPool(pool).lastPeriod());
        console2.log("P7 current period ", p);
        for (uint256 q = p - 3; q <= p; ++q) {
            uint256 T = IPool(pool).positionPeriodSecondsInRange(q, PMA, TOKEN_ID, lo, hi);
            uint256 S = g.tokenTotalSupplyByPeriod(q, PHAR);
            uint256 owedByFormula = S * T / (WEEK << 96);
            // amount the gauge would still pay for this period + what it recorded as already claimed
            uint256 claimed = g.periodClaimedAmount(q, _hash(), PHAR);
            console2.log("P7 period", q);
            console2.log("   T (X96 s)        ", T);
            console2.log("   S*T/(WEEK<<96)   ", owedByFormula);
            console2.log("   claimed so far   ", claimed);
        }
        // total check: sum over periods >= lastClaim of (formula - claimed) == earned()
        uint256 lastClaim = g.lastClaimByToken(PHAR, _hash());
        uint256 sum;
        for (uint256 q = lastClaim; q <= p; ++q) {
            uint256 T = IPool(pool).positionPeriodSecondsInRange(q, PMA, TOKEN_ID, lo, hi);
            uint256 o = g.tokenTotalSupplyByPeriod(q, PHAR) * T / (WEEK << 96);
            uint256 c = g.periodClaimedAmount(q, _hash(), PHAR);
            sum += o > c ? o - c : 0;
        }
        console2.log("P7 lastClaim period", lastClaim);
        console2.log("P7 sum(formula-claimed) over [lastClaim, now]", sum);
        console2.log("P7 gauge.earned                              ", g.earned(PHAR, TOKEN_ID));
        assertApproxEqAbs(sum, g.earned(PHAR, TOKEN_ID), 11, "formula == earned (floor per period)");
    }

    // P8: two liquidity-time events 80 s apart that straddle a weekly boundary. How much is forfeited, and for which periods?
    function test_P8_straddleBoundarySlash() public {
        uint256 period = block.timestamp / WEEK;
        uint256 boundary = (period + 1) * WEEK;
        (uint256 c0,) = _claim(); // fund the backlog at the pin so the starting point is "nothing unclaimed"
        assertGt(c0, 0);
        (,,,,, uint128 liq,,,,) = pm.positions(TOKEN_ID);
        vm.warp(boundary - 50);
        vm.roll(block.number + 100000);
        uint256 eOldBefore = IGaugeP(GAUGE).periodEarned(period, PHAR, TOKEN_ID);
        vm.prank(VAULT);
        pm.decreaseLiquidity(IPM.DecreaseLiquidityParams(TOKEN_ID, liq / 1000, 0, 0, block.timestamp + 1)); // outside window: pays everything pending
        vm.warp(boundary + 30);
        vm.roll(block.number + 40);
        uint256 eOld = IGaugeP(GAUGE).periodEarned(period, PHAR, TOKEN_ID);
        uint256 eNew = IGaugeP(GAUGE).periodEarned(period + 1, PHAR, TOKEN_ID);
        uint256 eTot = g.earned(PHAR, TOKEN_ID);
        console2.log("P8 pending in old period (last 50 s)  ", eOld);
        console2.log("P8 pending in new period (first 30 s) ", eNew);
        console2.log("P8 total earned view                  ", eTot);
        uint256 r0 = IERC20(PHAR).balanceOf(R33);
        (uint256 got,) = _claim(); // 80 s after the previous liquidity change -> inside the 111 s window
        console2.log("P8 paid inside window                 ", got);
        console2.log("P8 r33 not yet paid; earned view now  ", g.earned(PHAR, TOKEN_ID));
        (uint256 fp, uint256 fa) = g.forfeitedRewards(_hash(), PHAR);
        console2.log("P8 forfeit period/amount", fp, fa);
        assertEq(got, 0);
        assertEq(fp, period + 1, "debt is recorded against the CURRENT period");
        assertEq(g.earned(PHAR, TOKEN_ID), 0, "everything unclaimed so far is now excluded from earned");
        vm.warp(block.timestamp + 300);
        vm.roll(block.number + 150);
        (uint256 got2,) = _claim();
        uint256 r1 = IERC20(PHAR).balanceOf(R33);
        console2.log("P8 later claim pays vault             ", got2);
        console2.log("P8 r33 received (old+new period)      ", r1 - r0);
        assertEq(r1 - r0, eTot, "the whole unclaimed accrual (both periods) went to r33");
        assertGt(eOld, 0);
        assertGt(eOldBefore, 0);
    }

    // P9: a Pharaoh-blacklisted tx.origin touching the vault makes the in-tx auto-claim slash the WHOLE unclaimed backlog.
    function test_P9_blacklistedOriginForfeitsBacklog() public {
        address timelock = 0x12d54Ad6dAF65d55B029Df1b34B260C68fc0dDCF;
        address rv = 0x065028dcF219D8622Dd50231f188f2B315349AEF;
        address origin = address(0xBAD);
        vm.prank(timelock); // LOCAL VM ONLY: simulates Pharaoh governance blacklisting a wallet
        IRV(rv).addWalletToBlacklist(origin);
        uint256 backlog = g.earned(PHAR, TOKEN_ID);
        (,,,,, uint128 liq,,,,) = pm.positions(TOKEN_ID);
        uint256 vb = IERC20(PHAR).balanceOf(VAULT);
        vm.prank(VAULT, origin); // msg.sender = vault (the NFT owner), tx.origin = blacklisted user who called vault.deposit/redeem
        pm.decreaseLiquidity(IPM.DecreaseLiquidityParams(TOKEN_ID, liq / 1000, 0, 0, block.timestamp + 1));
        console2.log("P9 backlog before                 ", backlog);
        console2.log("P9 paid to vault by the auto-claim", IERC20(PHAR).balanceOf(VAULT) - vb);
        console2.log("P9 earned view afterwards         ", g.earned(PHAR, TOKEN_ID));
        assertEq(IERC20(PHAR).balanceOf(VAULT) - vb, 0);
        assertEq(g.earned(PHAR, TOKEN_ID), 0, "backlog gone from the view");
        vm.warp(block.timestamp + 300);
        vm.roll(block.number + 150);
        uint256 r0 = IERC20(PHAR).balanceOf(R33);
        _claim();
        assertEq(IERC20(PHAR).balanceOf(R33) - r0, backlog, "the entire backlog went to r33");
    }
}
