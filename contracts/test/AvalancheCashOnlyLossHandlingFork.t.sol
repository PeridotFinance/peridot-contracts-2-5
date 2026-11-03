// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {PErc20DelegateLossPrototype, ILossPrototype} from "./prototype/PErc20DelegateLossPrototype.sol";

/**
 * @notice LOSS-HANDLING COMPARISON for the CASH-ONLY lending product (pUSDC on Avalanche C-Chain, plain `PErc20Delegate` markets, no margin).
 *
 * The SAME bad-debt event (a real liquidation shortfall: three WAVAX-collateral borrowers at 99% of borrowing power, AVAX -50% in one step,
 * liquidated by a funded liquidator until their collateral is exhausted) and the SAME supplier population are run through four handlings:
 *   S0  do nothing (first-come-first-served exit shortfall, measured in the risk study);
 *   S1  a DEDICATED TREASURY repays the unrecoverable debt with the existing `repayBorrowBehalf`;
 *   S2  the treasury calls `_addReserves` with the same amount (NOT equivalent: the debt stays recorded and keeps accruing);
 *   S3  EXPLICIT RESERVE-FIRST LOSS RECOGNITION, a TEST-ONLY prototype (`test/prototype/PErc20DelegateLossPrototype.sol`) installed with
 *       `_setImplementation`. NO production write-off power is introduced by this file: nothing under `contracts/contracts/` changed.
 *
 * SUPPLIERS (all deposit USDC into pUSDC before the borrows): EARLY 100,000, LATE 100,000, BIG 400,000 (the fixture's LP), SMALL 1,000.
 * EARLY and LATE are identical deposits; they differ only by the position in the exit queue (forward run: EARLY exits first, LATE last;
 * reverse run: LATE first, EARLY last). All parameters (60% collateral factor, 1.08 incentive, 50% close factor, 10% reserve factor, 2.8%
 * protocol seize share, mocked price feeds, one funded liquidator, 1 block = 1 second interest clock) are the fixture's PLACEHOLDERS used to
 * MEASURE, not recommendations. No fairness threshold is invented: assertions are accounting identities and the equalities that
 * distinguish the designs.
 *
 * OUTPUT: `LOSS|ROW|...` (market state after a step), `LOSS|EXIT|...` (each supplier's claim and what it actually received), `LOSS|SUM|...`.
 * Amounts are raw USDC units (6 decimals); `rate` is the pToken exchange rate (1e18 mantissa); `c_*` = pTokens x rate (claim value);
 * `w_*` = what that supplier could withdraw NOW if first in line = min(claim, market cash).
 */
contract AvalancheCashOnlyLossHandlingForkTest is AvalancheCashOnlyBase {
    uint256 internal constant N = 3; // defaulting borrowers
    uint256 internal constant COLL_USD6 = 100_000e6; // collateral per borrower at pin prices
    uint256 internal constant DUST_USD6 = 10_000; // USD 0.01
    uint256 internal constant TOL = 16; // wei of USDC (rounding only)
    uint256 internal constant BLOCKS_90D = 7_776_000; // 1 block = 1 second in the fixture's rate model
    uint256 internal constant LI = 1.08e18;

    address internal constant EARLY = address(0xEA21);
    address internal constant LATE = address(0x1A7E);
    address internal constant SMALL = address(0x5A11);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant SEEDER = address(0x5EED);
    address internal constant ADMIN_ACCT = address(0xAD31);
    address internal constant HB = address(0x4EA1);
    address internal constant LEVERED = address(0x1E7E);

    uint8 internal constant S0 = 0;
    uint8 internal constant S1 = 1;
    uint8 internal constant S2 = 2;
    uint8 internal constant S3 = 3;
    uint8 internal constant S3TOPUP = 4;

    PErc20DelegateLossPrototype internal protoStrict; // precondition on, no cap
    PErc20DelegateLossPrototype internal protoCapped; // precondition on, 10,000 USDC per call, 15,000 USDC per day
    PErc20DelegateLossPrototype internal protoOpen; // precondition OFF, no cap: an UNRESTRICTED admin
    PErc20DelegateLossPrototype internal protoCapOnly; // precondition OFF, per-call cap only

    struct Row {
        uint256 cash;
        uint256 borrows;
        uint256 defDebt;
        uint256 reserves;
        uint256 rate;
        uint256[4] claim;
        uint256[4] wd;
    }

    struct Evt {
        uint256 snap;
        uint256 b0; // total borrows right after they were opened (before any accrual)
        uint256 d0; // defaulting accounts' debt right before the gap
        uint256 collAfterUsd6; // their collateral value right after the gap, before any liquidation
        uint256 repaid; // USDC repaid by the liquidator
        uint256 wavaxResBefore;
        uint256 wavaxResAfter;
        Row pre;
        Row evt;
    }

    struct Out {
        Row act;
        uint256[4] got;
        uint256[4] claimAtExit;
        uint256 treasuryIn;
        uint256 removed;
        uint256 fromRes;
        uint256 cashLeft;
    }

    function setUp() public override {
        super.setUp();
        if (address(controller) == address(0)) return; // skipped (no RPC)
        protoStrict = new PErc20DelegateLossPrototype(true, 0, 0, 0, 1e18);
        protoCapped = new PErc20DelegateLossPrototype(true, 10_000e6, 15_000e6, 1 days, 1e18);
        protoOpen = new PErc20DelegateLossPrototype(false, 0, 0, 0, 1e18);
        protoCapOnly = new PErc20DelegateLossPrototype(false, 10_000e6, 0, 0, 1e18);
    }

    // ================================================================= helpers
    /// @dev Revert the chain AND re-mock the feeds (cheatcode mocks are not part of the snapshot).
    function _back(uint256 snap) internal {
        vm.revertToState(snap);
        _setPrices(avaxAnswer, usdcAnswer);
    }

    /// @dev One wei of USDC moves the exchange rate by 1e18 / totalSupply (about 332 mantissa units here).
    function _rateTol() internal view returns (uint256) {
        return 4 * (1e18 / pUsdc.totalSupply() + 1);
    }

    function _live() internal view returns (bool) {
        return address(controller) != address(0);
    }

    function _kv(string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat("|", k, "=", vm.toString(v));
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _max0(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _sup(uint256 i) internal pure returns (address) {
        return i == 0 ? EARLY : i == 1 ? LATE : i == 2 ? LP : SMALL;
    }

    function _supName(uint256 i) internal pure returns (string memory) {
        return i == 0 ? "early" : i == 1 ? "late" : i == 2 ? "big" : "small";
    }

    function _borrower(uint256 i) internal pure returns (address) {
        return address(uint160(0x9000 + i));
    }

    function _colUsd6(uint256 pTokens) internal view returns (uint256) {
        uint256 wavaxUnits = pTokens * pWavax.exchangeRateStored() / 1e18;
        return wavaxUnits * uint256(avaxAnswer) / 1e20;
    }

    function _usdcUsd6(uint256 units) internal view returns (uint256) {
        return units * uint256(usdcAnswer) / 1e8;
    }

    // ----------------------------------------------------------------- state rows
    function _rowNow() internal view returns (Row memory r) {
        r.cash = pUsdc.getCash();
        r.borrows = pUsdc.totalBorrows();
        r.reserves = pUsdc.totalReserves();
        r.rate = pUsdc.exchangeRateStored();
        for (uint256 i; i < N; ++i) {
            r.defDebt += pUsdc.borrowBalanceStored(_borrower(i));
        }
        for (uint256 j; j < 4; ++j) {
            r.claim[j] = pUsdc.balanceOf(_sup(j)) * r.rate / 1e18;
            r.wd[j] = _min(r.claim[j], r.cash);
        }
    }

    function _sumClaims(Row memory r) internal pure returns (uint256 s) {
        for (uint256 j; j < 4; ++j) {
            s += r.claim[j];
        }
    }

    function _logRow(string memory grp, string memory step, Row memory r) internal {
        string memory a = string.concat(
            "LOSS|ROW|", grp, "|step=", step, _kv("cash", r.cash), _kv("borrows", r.borrows), _kv("defDebt", r.defDebt)
        );
        a = string.concat(a, _kv("reserves", r.reserves), _kv("rate", r.rate));
        string memory b = string.concat(
            _kv("c_early", r.claim[0]), _kv("c_late", r.claim[1]), _kv("c_big", r.claim[2]), _kv("c_small", r.claim[3])
        );
        string memory c = string.concat(
            _kv("w_early", r.wd[0]), _kv("w_late", r.wd[1]), _kv("w_big", r.wd[2]), _kv("w_small", r.wd[3]), "|END"
        );
        emit log_string(string.concat(a, b, c));
    }

    /// @dev Accounting identities that must hold in every state (suppliers hold ALL pUSDC): value in = value claimed, no negative balance.
    function _checkIdentities(Row memory r, string memory why) internal pure {
        require(r.cash + r.borrows >= r.reserves, string.concat("negative net assets: ", why));
        uint256 assets = r.cash + r.borrows - r.reserves; // exchange-rate numerator
        uint256 claims = _sumClaims(r);
        require(_absDiff(assets, claims) <= 8, string.concat("cash + borrows - reserves != sum of claims: ", why));
        for (uint256 j; j < 4; ++j) {
            require(r.wd[j] <= r.claim[j] && r.wd[j] <= r.cash, string.concat("withdrawable exceeds claim or cash: ", why));
        }
    }

    // ----------------------------------------------------------------- actors
    function _supply() internal {
        _mintP(pUsdc, EARLY, 100_000e6);
        _mintP(pUsdc, LATE, 100_000e6);
        _mintP(pUsdc, SMALL, 1_000e6);
    }

    function _addRes(address who, uint256 amt) internal {
        if (amt == 0) return;
        deal(USDC, who, IERC20(USDC).balanceOf(who) + amt);
        vm.startPrank(who);
        IERC20(USDC).approve(address(pUsdc), amt);
        require(PErc20(address(pUsdc))._addReserves(amt) == 0, "add reserves");
        vm.stopPrank();
    }

    function _roll(uint256 blocks) internal {
        vm.roll(block.number + blocks);
        vm.warp(block.timestamp + blocks);
        _setPrices(avaxAnswer, usdcAnswer); // re-mock so the feeds are not stale
        pUsdc.accrueInterest();
        pWavax.accrueInterest();
    }

    function _openBorrows(uint256 utilPct) internal {
        for (uint256 i; i < N; ++i) {
            address b = _borrower(i);
            _mintP(pWavax, b, Math.mulDiv(COLL_USD6 * 1e12, 1e8, uint256(realAvaxAnswer)));
            _enter(b);
            (, uint256 liq,) = controller.getAccountLiquidity(b);
            (bool ok,) = _borrow(pUsdc, b, liq * utilPct / 100 / 1e12);
            require(ok, "setup borrow");
        }
    }

    function _clear(address b) internal returns (uint256 repaidTotal) {
        for (uint256 calls; calls < 60; ++calls) {
            (,, uint256 sf) = controller.getAccountLiquidity(b);
            if (sf == 0) break;
            uint256 colBal = pWavax.balanceOf(b);
            if (_colUsd6(colBal) < DUST_USD6) break;
            uint256 repay = pUsdc.borrowBalanceCurrent(b) * 0.5e18 / 1e18;
            (, uint256 seize) = controller.liquidateCalculateSeizeTokens(address(pUsdc), address(pWavax), repay);
            if (seize > colBal) repay = repay * colBal / seize;
            bool done;
            for (uint256 a; a < 8 && repay > 0; ++a) {
                if (repay < DUST_USD6) {
                    repay = 0;
                    break;
                }
                (bool ok,,) = _liquidate(pUsdc, pWavax, b, repay);
                if (ok) {
                    repaidTotal += repay;
                    done = true;
                    break;
                }
                repay = repay * 99_999 / 100_000;
            }
            if (!done) break;
        }
    }

    /// @dev Builds the event: suppliers, optional reserve seed (BEFORE the gap), borrowers, optional interest accrual, AVAX -50%,
    ///      liquidation until the collateral is exhausted. Leaves the post-event state and a snapshot of it.
    function _buildEvent(uint256 seed, uint256 utilPct, uint256 accrualBlocks) internal returns (Evt memory e) {
        _setPrices(realAvaxAnswer, usdcAnswer);
        _unpauseBorrows();
        _supply();
        _addRes(SEEDER, seed);
        _openBorrows(utilPct);
        e.b0 = pUsdc.totalBorrows();
        if (accrualBlocks > 0) _roll(accrualBlocks);
        e.pre = _rowNow();
        e.d0 = e.pre.defDebt;
        e.wavaxResBefore = pWavax.totalReserves();
        _setAvaxBps(5_000); // AVAX -50%
        for (uint256 i; i < N; ++i) {
            e.collAfterUsd6 += _colUsd6(pWavax.balanceOf(_borrower(i)));
        }
        for (uint256 i; i < N; ++i) {
            e.repaid += _clear(_borrower(i));
        }
        e.wavaxResAfter = pWavax.totalReserves();
        e.evt = _rowNow();
        e.snap = vm.snapshotState();
    }

    function _loss(Evt memory e) internal pure returns (uint256) {
        return e.evt.defDebt;
    }

    // ----------------------------------------------------------------- the four handlings
    function _repayBehalf(uint256 budget) internal returns (uint256 paid) {
        deal(USDC, TREASURY, budget);
        vm.startPrank(TREASURY);
        IERC20(USDC).approve(address(pUsdc), budget);
        uint256 left = budget;
        for (uint256 i; i < N; ++i) {
            uint256 owed = pUsdc.borrowBalanceCurrent(_borrower(i));
            uint256 amt = _min(owed, left);
            if (amt == 0) continue;
            require(pUsdc.repayBorrowBehalf(_borrower(i), amt) == 0, "repay behalf");
            paid += amt;
            left -= amt;
        }
        vm.stopPrank();
    }

    function _install(PErc20DelegateLossPrototype impl) internal {
        if (pUsdc.implementation() == address(impl)) return;
        pUsdc._setImplementation(address(impl), false, "");
    }

    function _writeOffAll(PErc20DelegateLossPrototype impl) internal returns (uint256 removed, uint256 fromRes) {
        _install(impl);
        for (uint256 i; i < N; ++i) {
            uint256 owed = pUsdc.borrowBalanceCurrent(_borrower(i));
            if (owed == 0) continue;
            (uint256 r, uint256 f) = ILossPrototype(address(pUsdc)).writeOffBadDebt(_borrower(i), owed);
            removed += r;
            fromRes += f;
        }
    }

    /// @dev One supplier tries to withdraw EVERYTHING it is owed: full redeem if the market cash covers the claim, otherwise whatever cash is left.
    function _exit(uint256 i) internal returns (uint256 claim, uint256 got) {
        address s = _sup(i);
        uint256 tok = pUsdc.balanceOf(s);
        claim = tok * pUsdc.exchangeRateStored() / 1e18;
        uint256 cash = pUsdc.getCash();
        uint256 before = IERC20(USDC).balanceOf(s);
        if (claim <= cash) {
            vm.prank(s);
            require(pUsdc.redeem(tok) == 0, "redeem");
        } else if (cash > 0) {
            vm.prank(s);
            require(pUsdc.redeemUnderlying(cash) == 0, "redeemUnderlying(cash)");
        }
        got = IERC20(USDC).balanceOf(s) - before;
    }

    /// @dev Runs one handling from the CURRENT state (the event state), then the exits. fwd: EARLY first and LATE last; reverse: LATE first, EARLY last.
    function _scenario(string memory grp, uint8 scn, uint256 amt, bool fwd) internal returns (Out memory o) {
        Row memory ev = _rowNow();
        _logRow(grp, "event", ev);
        if (scn == S1) {
            o.treasuryIn = _repayBehalf(amt);
        } else if (scn == S2) {
            _addRes(TREASURY, amt);
            o.treasuryIn = amt;
        } else if (scn == S3) {
            (o.removed, o.fromRes) = _writeOffAll(protoStrict);
        } else if (scn == S3TOPUP) {
            _addRes(TREASURY, amt);
            o.treasuryIn = amt;
            (o.removed, o.fromRes) = _writeOffAll(protoStrict);
        }
        o.act = _rowNow();
        _logRow(grp, "action", o.act);
        _checkIdentities(o.act, string.concat(grp, " after action"));
        uint8[4] memory ord = fwd ? [uint8(0), 3, 2, 1] : [uint8(1), 2, 3, 0];
        for (uint256 k; k < 4; ++k) {
            (o.claimAtExit[ord[k]], o.got[ord[k]]) = _exit(ord[k]);
            Row memory r = _rowNow();
            _logRow(grp, string.concat("exit_", _supName(ord[k])), r);
            _checkIdentities(r, string.concat(grp, " after exit"));
        }
        o.cashLeft = pUsdc.getCash();
        for (uint256 j; j < 4; ++j) {
            emit log_string(
                string.concat(
                    "LOSS|EXIT|", grp, "|who=", _supName(j), _kv("pos", _pos(ord, j)), _kv("claim", o.claimAtExit[j]), _kv("got", o.got[j]), "|END"
                )
            );
        }
        emit log_string(
            string.concat(
                "LOSS|SUM|", grp, _kv("treasuryIn", o.treasuryIn), _kv("removed", o.removed), _kv("fromReserves", o.fromRes), _kv("cashLeft", o.cashLeft), "|END"
            )
        );
    }

    function _pos(uint8[4] memory ord, uint256 who) internal pure returns (uint256) {
        for (uint256 k; k < 4; ++k) {
            if (ord[k] == who) return k + 1;
        }
        return 0;
    }

    function _sumClaim(Out memory o) internal pure returns (uint256 s) {
        for (uint256 j; j < 4; ++j) {
            s += o.claimAtExit[j];
        }
    }

    function _sumGot(Out memory o) internal pure returns (uint256 s) {
        for (uint256 j; j < 4; ++j) {
            s += o.got[j];
        }
    }

    function _lost(Out memory o, uint256 j) internal pure returns (uint256) {
        return o.claimAtExit[j] - o.got[j];
    }

    /// @dev Value conservation: every USDC the market held (plus the treasury's) went to a supplier or is still in the market.
    function _assertConserved(Evt memory e, Out memory o, string memory why) internal pure {
        assertEq(_sumGot(o) + o.cashLeft, e.evt.cash + o.treasuryIn, string.concat("value conserved: ", why));
    }

    // ================================================================= EVENT
    function testEvent_RealLiquidationShortfall_ClosedFormSeizeShareAndRates() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 loss = _loss(e);
        _logRow("t=event", "pre-loss", e.pre);
        _logRow("t=event", "post-liquidation", e.evt);
        assertGt(loss, 0, "the scenario produced bad debt (a real liquidation shortfall)");
        for (uint256 i; i < N; ++i) {
            assertLt(_colUsd6(pWavax.balanceOf(_borrower(i))), DUST_USD6 + 1, "collateral exhausted (dust only)");
            (,, uint256 sf) = controller.getAccountLiquidity(_borrower(i));
            assertGt(sf, 0, "defaulted account still in shortfall");
        }
        // the unpaid borrow stays on the books: the exchange rate does not move at the event
        assertLe(_absDiff(e.pre.rate, e.evt.rate), 2, "exchange rate unchanged by the event");
        assertEq(e.evt.reserves, e.pre.reserves, "pUSDC reserves unchanged by the event (the seize share goes to the collateral market)");
        _checkIdentities(e.pre, "pre-loss");
        _checkIdentities(e.evt, "post-event");
        // closed form of the risk study: bad debt = D - collateral_after / LI when rho < LI
        uint256 d0Usd = _usdcUsd6(e.d0);
        uint256 recoverable = e.collAfterUsd6 * 1e18 / LI;
        assertLt(recoverable, d0Usd, "rho < LI: bad debt expected");
        uint256 pred = d0Usd - recoverable;
        uint256 lossUsd = _usdcUsd6(loss);
        assertLe(_absDiff(lossUsd, pred), d0Usd / 100 + 50_000, "closed form D*(1 - rho/LI) agrees with the measurement (1% + USD 0.05)");
        // protocol seize share (2.8% of the seize) lands in the COLLATERAL market (pWAVAX), in WAVAX
        assertEq(pWavax.protocolSeizeShareMantissa(), 2.8e16, "protocol seize share as it exists");
        assertEq(pUsdc.reserveFactorMantissa(), RESERVE_FACTOR, "reserve factor as it exists");
        uint256 seizeResWavax = e.wavaxResAfter - e.wavaxResBefore;
        uint256 seizeResUsd = seizeResWavax * uint256(avaxAnswer) / 1e20;
        uint256 expectUsd = _usdcUsd6(e.repaid) * LI / 1e18 * 0.028e18 / 1e18;
        assertLe(_absDiff(seizeResUsd, expectUsd), expectUsd / 100 + DUST_USD6, "seize share = 2.8% x LI x repaid value");
        emit log_string(
            string.concat(
                "LOSS|EVENT", _kv("d0", e.d0), _kv("loss", loss), _kv("repaid", e.repaid), _kv("collAfterUsd6", e.collAfterUsd6), _kv("predLossUsd6", pred), _kv("lossUsd6", lossUsd),
                _kv("pWavaxSeizeReserveWavax", seizeResWavax), _kv("pWavaxSeizeReserveUsd6", seizeResUsd), _kv("pUsdcReserves", e.evt.reserves), "|END"
            )
        );
    }

    // ================================================================= S0
    function testS0_DoNothing_FirstComeFirstServed_EarlyVersusLate() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 loss = _loss(e);
        uint256 R = e.evt.reserves;
        Out memory f = _scenario("t=S0_fwd", S0, 0, true);
        _back(e.snap);
        Out memory r = _scenario("t=S0_rev", S0, 0, false);
        // action row: nothing moved
        assertEq(f.act.rate, e.evt.rate, "S0 exchange rate unchanged");
        assertEq(f.act.defDebt, loss, "S0 defaulted debt still recorded");
        assertEq(f.act.borrows, e.evt.borrows, "S0 total borrows unchanged");
        assertEq(f.act.reserves, R, "S0 reserves unchanged");
        // forward: the first three suppliers are paid in full, the last one carries the whole shortfall
        uint256 shortfall = _max0(loss, R);
        assertGt(shortfall, 0, "the scenario has a shortfall");
        assertEq(f.got[0], f.claimAtExit[0], "forward: EARLY paid in full");
        assertEq(f.got[3], f.claimAtExit[3], "forward: SMALL paid in full");
        assertEq(f.got[2], f.claimAtExit[2], "forward: BIG paid in full");
        assertLe(_absDiff(_lost(f, 1), shortfall), TOL, "forward: LATE (last) carries the whole shortfall = max(0, loss - reserves)");
        // reverse: positions swap, the loss moves with the queue position and not with the identity
        assertEq(r.got[1], r.claimAtExit[1], "reverse: LATE (now first) paid in full");
        assertLe(_absDiff(_lost(r, 0), shortfall), TOL, "reverse: EARLY (now last) carries the whole shortfall");
        // EARLY and LATE hold the same deposit: the difference is the queue position only
        assertEq(f.claimAtExit[0], f.claimAtExit[1], "EARLY and LATE have identical claims");
        assertEq(_sumGot(f) + f.cashLeft, e.evt.cash, "S0 value conserved (no treasury)");
        assertEq(f.cashLeft, 0, "S0 cash fully drained by the exits");
        assertLe(_absDiff(_sumClaim(f) - _sumGot(f), shortfall), TOL, "total unpaid claims = shortfall");
    }

    function testS0_ReserveExhaustionGrid() public {
        if (!_live()) return;
        uint256 base = vm.snapshotState();
        Evt memory e0 = _buildEvent(0, 99, 0);
        uint256 L = _loss(e0);
        uint256[5] memory seeds = [uint256(0), L / 2, L - 1, L, L * 3 / 2]; // loss > R, loss > R, loss > R (by 1), loss = R, loss < R
        for (uint256 k; k < seeds.length; ++k) {
            _back(base);
            Evt memory e = _buildEvent(seeds[k], 99, 0);
            assertLe(_absDiff(_loss(e), L), TOL, "same event under every reserve level");
            assertEq(e.evt.reserves, seeds[k], "reserves seeded before the gap");
            Out memory o = _scenario(string.concat("t=S0_R", vm.toString(k)), S0, 0, true);
            uint256 short = _max0(L, seeds[k]);
            assertLe(_absDiff(_lost(o, 1), short), TOL, "shortfall = max(0, loss - reserves held in the market)");
            if (seeds[k] >= L) assertEq(_lost(o, 1), 0, "reserves >= loss: the last supplier is paid in full");
            // the reserve cash is NOT protected from redemption: it was paid out to suppliers, leaving recorded reserves unbacked
            assertLe(_absDiff(o.cashLeft, _max0(seeds[k], L)), TOL, "suppliers may withdraw ALL cash including the reserve cash; only cash above the claims (reserves beyond the loss) is left");
        }
    }

    // ================================================================= S1
    function testS1_TreasuryRepayment_AllSuppliersWhole_BothOrders() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        Out memory f = _scenario("t=S1_fwd", S1, L, true);
        assertEq(f.treasuryIn, L, "treasury paid exactly the unrecoverable debt");
        assertEq(f.act.defDebt, 0, "S1 defaulted accounts' recorded debt is zero");
        assertLe(f.act.borrows, TOL, "S1 total borrows removed");
        assertEq(f.act.reserves, e.evt.reserves, "S1 reserves untouched (the debt was paid, not covered)");
        assertEq(f.act.rate, e.evt.rate, "S1 exchange rate unchanged (nothing is lost)");
        assertEq(f.act.cash, e.evt.cash + L, "S1 cash up by the repayment");
        for (uint256 j; j < 4; ++j) {
            assertEq(f.got[j], f.claimAtExit[j], "S1 every supplier paid in full");
        }
        _assertConserved(e, f, "S1 fwd");
        _back(e.snap);
        Out memory r = _scenario("t=S1_rev", S1, L, false);
        for (uint256 j; j < 4; ++j) {
            assertEq(r.got[j], r.claimAtExit[j], "S1 reverse: every supplier paid in full");
            assertEq(r.claimAtExit[j], f.claimAtExit[j], "S1 claims do not depend on the order");
        }
    }

    function testS1_RepaymentAfterEarlyExits_StillMakesEveryoneWhole_NoRaceAdvantage() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        // EARLY and SMALL leave before the treasury acts (e.g. the treasury needs time to be funded)
        (uint256 c0, uint256 g0) = _exit(0);
        (uint256 c3, uint256 g3) = _exit(3);
        assertEq(g0, c0);
        assertEq(g3, c3);
        uint256 paid = _repayBehalf(L);
        assertEq(paid, L);
        Row memory r = _rowNow();
        _logRow("t=S1_late_repay", "after_repay", r);
        (uint256 c2, uint256 g2) = _exit(2);
        (uint256 c1, uint256 g1) = _exit(1);
        assertEq(g2, c2, "BIG whole");
        assertEq(g1, c1, "LATE whole");
        assertEq(pUsdc.getCash(), 0, "market fully paid out");
        // the claims of the remaining suppliers were never reduced by the early exits
        assertEq(c1, e.evt.claim[1], "LATE's claim is the same as before anyone left");
    }

    function testS2_AddReservesAfterEarlyExits_AlsoWhole_ButSeeDrift() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        _exit(0);
        _exit(3);
        _addRes(TREASURY, L);
        (uint256 c2, uint256 g2) = _exit(2);
        (uint256 c1, uint256 g1) = _exit(1);
        assertEq(g2, c2);
        assertEq(g1, c1);
    }

    function testS1_TreasurySizes_Partial_Exact_Surplus() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        uint256[3] memory sizes = [L / 2, L, L * 3 / 2];
        for (uint256 k; k < 3; ++k) {
            _back(e.snap);
            Out memory o = _scenario(string.concat("t=S1_T", vm.toString(k)), S1, sizes[k], true);
            uint256 paid = _min(sizes[k], L);
            assertEq(o.treasuryIn, paid, "treasury pays at most the recorded debt");
            assertLe(_absDiff(o.act.defDebt, L - paid), TOL, "remaining recorded debt = loss - paid");
            uint256 short = _max0(L - paid, e.evt.reserves);
            assertLe(_absDiff(_lost(o, 1), short), TOL, "LATE shortfall = max(0, loss - paid - reserves)");
            _assertConserved(e, o, "S1 sizes");
        }
    }

    // ================================================================= S2
    function testS2_AddReserves_IsNotRepayment_PreciseDifferences() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        uint256 R = e.evt.reserves;
        Out memory s2 = _scenario("t=S2_fwd", S2, L, true);
        // what S2 does NOT change: the debt, the exchange rate, total borrows, the claims
        assertEq(s2.act.defDebt, L, "S2: the debt is still recorded on the defaulted accounts");
        assertEq(s2.act.borrows, e.evt.borrows, "S2: total borrows unchanged");
        assertEq(s2.act.rate, e.evt.rate, "S2: exchange rate unchanged (cash + borrows - reserves is invariant under _addReserves)");
        for (uint256 j; j < 4; ++j) {
            assertEq(s2.act.claim[j], e.evt.claim[j], "S2: claims unchanged (no supplier is credited or debited)");
        }
        // what S2 changes: cash and RECORDED reserves, one for one
        assertEq(s2.act.cash, e.evt.cash + L, "S2: cash +amount");
        assertEq(s2.act.reserves, R + L, "S2: recorded reserves +amount (protocol-owned, not supplier backing)");
        // and the difference to S1 on the same event
        _back(e.snap);
        Out memory s1 = _scenario("t=S1_vs_S2", S1, L, true);
        assertEq(s1.act.defDebt, 0, "S1: debt gone");
        assertEq(s1.act.reserves, R, "S1: reserves not touched");
        assertEq(s1.act.cash, s2.act.cash, "same cash in S1 and S2");
        assertEq(s1.act.rate, s2.act.rate, "same exchange rate at t0 in S1 and S2");
        assertEq(s2.act.reserves - s1.act.reserves, L, "the only recorded difference at t0: S2 books the amount as reserves, S1 removes the debt");
        // exits at t0: everybody can be paid in S2 too (the cash is there) ...
        for (uint256 j; j < 4; ++j) {
            assertEq(s2.got[j], s2.claimAtExit[j], "S2: all suppliers paid in full at t0");
        }
        // ... but after the exits the recorded reserves are backed by nothing: cash is gone, the debt (an asset that never pays) remains
        assertEq(s2.cashLeft, R, "S2: after full exit only the reserve cash that existed before is left");
        assertEq(s1.cashLeft, R, "S1: same cash left");
        _assertConserved(e, s2, "S2");
    }

    function testS2_Revocable_AdminCanReduceReservesAndBringTheShortfallBack() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        _addRes(TREASURY, L);
        Row memory a = _rowNow();
        uint256 reducible = _min(a.reserves, a.cash);
        assertEq(reducible, L, "the admin could withdraw the whole amount the treasury added (reserves are not locked)");
        uint256 adminBefore = IERC20(USDC).balanceOf(address(this));
        require(PErc20(address(pUsdc))._reduceReserves(L) == 0, "reduce");
        assertEq(IERC20(USDC).balanceOf(address(this)) - adminBefore, L, "admin received the funds");
        Row memory b = _rowNow();
        _logRow("t=S2_revoked", "after_reduceReserves", b);
        assertEq(b.cash, e.evt.cash, "cash back to the S0 level");
        assertEq(b.reserves, e.evt.reserves, "reserves back to the S0 level");
        uint256 short = b.borrows - b.reserves;
        assertLe(_absDiff(short, _max0(L, e.evt.reserves)), TOL, "the exit shortfall is back to the S0 value");
        _checkIdentities(b, "S2 revoked");
        // S1 cannot be revoked this way: the debt is gone and the treasury has no claim on the market
        _back(e.snap);
        _repayBehalf(L);
        uint256 maxReducible = _min(pUsdc.totalReserves(), pUsdc.getCash());
        assertEq(maxReducible, e.evt.reserves, "S1: nothing beyond the pre-existing reserves can be withdrawn by the admin");
    }

    function testS2_ReservesUnbackedAfterExit_ReduceReservesFails() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        _addRes(TREASURY, L);
        for (uint256 j; j < 4; ++j) {
            _exit(j);
        }
        assertEq(pUsdc.getCash(), 0, "market empty");
        assertEq(pUsdc.totalReserves(), L, "recorded reserves = L");
        assertEq(pUsdc.totalBorrows(), L, "the zombie debt is still on the books");
        vm.expectRevert();
        PErc20(address(pUsdc))._reduceReserves(1);
    }

    function testS2_SizesAndTheMinimumSufficientAmount() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        uint256 R = e.evt.reserves;
        uint256[4] memory sizes = [L / 2, L - R, L, L * 3 / 2];
        for (uint256 k; k < 4; ++k) {
            _back(e.snap);
            Out memory o = _scenario(string.concat("t=S2_T", vm.toString(k)), S2, sizes[k], true);
            uint256 short = _max0(L, R + sizes[k]);
            assertLe(_absDiff(_lost(o, 1), short), TOL, "S2 LATE shortfall at t0 = max(0, loss - reserves - amount)");
            assertEq(o.act.defDebt, L, "S2: the debt stays recorded whatever the amount");
            _assertConserved(e, o, "S2 sizes");
        }
    }

    // ================================================================= DRIFT
    function testDrift90Days_InterestOnBadDebt_S0AndS2VersusS1AndS3() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        uint256 rf = pUsdc.reserveFactorMantissa();
        // S0
        _roll(BLOCKS_90D);
        Row memory s0 = _rowNow();
        _logRow("t=drift_S0", "after_90d", s0);
        uint256 interest = s0.borrows - e.evt.borrows;
        assertGt(interest, 0, "interest accrues on the unrecoverable debt");
        assertEq(s0.defDebt > L, true, "S0: the defaulted accounts' recorded debt grows");
        assertLe(_absDiff(s0.reserves - e.evt.reserves, interest * rf / 1e18), 2, "10% of that interest is booked as reserves");
        assertEq(s0.cash, e.evt.cash, "S0: no cash comes in");
        assertGt(s0.rate, e.evt.rate, "S0: the exchange rate rises on interest nobody pays");
        uint256 s0Short = s0.borrows - s0.reserves;
        assertEq(s0Short, (L + interest) - s0.reserves, "S0 shortfall = borrows - reserves");
        assertLe(_absDiff(s0Short - L, interest - interest * rf / 1e18), 2, "S0 shortfall GROWS by interest x (1 - reserve factor)");
        _checkIdentities(s0, "S0 drift");
        // S2 (same amount as S1)
        _back(e.snap);
        _addRes(TREASURY, L);
        _roll(BLOCKS_90D);
        Row memory s2 = _rowNow();
        _logRow("t=drift_S2", "after_90d", s2);
        uint256 s2Short = s2.borrows - s2.reserves; // claims - cash with every borrow bad
        assertEq(s2.cash, e.evt.cash + L, "S2: cash is the treasury amount only");
        assertEq(s2.borrows, s0.borrows, "S2: the debt accrues exactly as in S0");
        assertLe(_absDiff(s2Short, interest - interest * rf / 1e18), 2, "S2: the exit shortfall REAPPEARS = interest x (1 - reserve factor)");
        assertGt(s2Short, 0, "S2: suppliers are short again although the treasury paid the full loss");
        assertEq(s2.claim[0] > e.evt.claim[0], true, "S2: claims are inflated by interest on unrecoverable debt");
        _checkIdentities(s2, "S2 drift");
        // S1
        _back(e.snap);
        _repayBehalf(L);
        _roll(BLOCKS_90D);
        Row memory s1 = _rowNow();
        _logRow("t=drift_S1", "after_90d", s1);
        assertEq(s1.defDebt, 0, "S1: no debt, no drift");
        assertLe(s1.borrows, TOL, "S1: no borrows");
        assertEq(s1.rate, e.evt.rate, "S1: exchange rate flat");
        assertEq(s1.cash, e.evt.cash + L, "S1: cash flat");
        _checkIdentities(s1, "S1 drift");
        // S3
        _back(e.snap);
        (uint256 removed,) = _writeOffAll(protoStrict);
        Row memory a3 = _rowNow();
        _roll(BLOCKS_90D);
        Row memory s3 = _rowNow();
        _logRow("t=drift_S3", "after_90d", s3);
        assertLe(_absDiff(removed, L), TOL, "S3 removed the whole debt");
        assertEq(s3.defDebt, 0, "S3: no debt, no drift");
        assertEq(s3.rate, a3.rate, "S3: exchange rate flat after the recognition");
        assertEq(s3.borrows, a3.borrows, "S3: borrows flat");
        _checkIdentities(s3, "S3 drift");
    }

    // ================================================================= S3
    function testS3_ReserveFirst_ExhaustionGrid_LossBelowEqualAboveReserves() public {
        if (!_live()) return;
        uint256 base = vm.snapshotState();
        Evt memory e0 = _buildEvent(0, 99, 0);
        uint256 L = _loss(e0);
        uint256[5] memory seeds = [uint256(0), L / 2, L - 1, L, L * 3 / 2];
        for (uint256 k; k < seeds.length; ++k) {
            _back(base);
            Evt memory e = _buildEvent(seeds[k], 99, 0);
            uint256 R = seeds[k];
            uint256 supply = pUsdc.totalSupply();
            uint256 rt = _rateTol();
            Out memory f = _scenario(string.concat("t=S3_R", vm.toString(k)), S3, 0, true);
            uint256 fromRes = _min(L, R);
            uint256 recognised = L - fromRes;
            assertLe(_absDiff(f.removed, L), TOL, "removed = recorded debt (share rounding only)");
            assertLe(_absDiff(f.fromRes, fromRes), TOL, "RESERVE-FIRST: reserves absorb min(loss, reserves)");
            assertLe(_absDiff(f.act.reserves, R - fromRes), TOL, "reserves reduced by exactly the absorbed part");
            assertEq(f.act.defDebt, 0, "defaulted debt removed");
            assertLe(f.act.borrows, TOL, "total borrows reduced by the loss");
            assertEq(f.act.cash, e.evt.cash, "cash unchanged");
            // exchange rate: independent expectation (cash + borrows - loss - remaining reserves) / supply
            uint256 expectRate = (e.evt.cash - (R - fromRes)) * 1e18 / supply; // all remaining borrows were the bad debt, so borrows after = 0
            assertLe(_absDiff(f.act.rate, expectRate), rt, "exchange rate = (cash + borrows - loss - remaining reserves) / supply");
            if (recognised == 0) assertLe(_absDiff(f.act.rate, e.evt.rate), rt, "loss <= reserves: suppliers recognise nothing, rate unchanged");
            else assertLt(f.act.rate, e.evt.rate, "loss > reserves: the remainder lowers the rate for everyone");
            // claims fall by exactly the recognised part, pro rata to pTokens
            assertLe(_absDiff(_sumClaims(e.evt) - _sumClaims(f.act), recognised), 8, "sum of claims falls by the recognised loss");
            for (uint256 j; j < 4; ++j) {
                uint256 expectClaim = e.evt.claim[j] - (e.evt.claim[j] * recognised / _sumClaims(e.evt));
                assertLe(_absDiff(f.act.claim[j], expectClaim), 4, "each supplier's claim falls pro rata");
            }
            // nobody is short at exit, whatever the order
            for (uint256 j; j < 4; ++j) {
                assertEq(f.got[j], f.claimAtExit[j], "S3: every supplier paid its (reduced) claim in full");
            }
            assertLe(_absDiff(f.got[0], f.got[1]), 4, "S3: EARLY and LATE receive the same amount");
            _assertConserved(e, f, "S3");
            _back(e.snap);
            Out memory r = _scenario(string.concat("t=S3_R", vm.toString(k), "_rev"), S3, 0, false);
            assertLe(_absDiff(r.got[0], f.got[0]), 4, "S3: EARLY's amount is the same in the reverse order");
            assertLe(_absDiff(r.got[1], f.got[1]), 4, "S3: LATE's amount is the same in the reverse order");
            assertLe(_absDiff(r.got[0], r.got[1]), 4, "S3 reverse: EARLY == LATE");
        }
    }

    function testS3_AccruesInterestFirst_WriteOffUsesTheCurrentDebt() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        // 30 days pass with NO interaction with the market: the stored state is stale
        vm.roll(block.number + 30 days);
        vm.warp(block.timestamp + 30 days);
        _setPrices(avaxAnswer, usdcAnswer);
        address b0 = _borrower(0);
        uint256 stale = pUsdc.borrowBalanceStored(b0);
        uint256 staleReserves = pUsdc.totalReserves();
        uint256 staleBorrows = pUsdc.totalBorrows();
        assertTrue(pUsdc.accrualBlockNumber() < block.number, "stored state is stale");
        _install(protoStrict);
        (, uint256 fromRes) = ILossPrototype(address(pUsdc)).writeOffBadDebt(b0, stale);
        assertEq(pUsdc.accrualBlockNumber(), block.number, "the write-off accrued interest first");
        assertEq(staleReserves, 0);
        assertGt(fromRes, 0, "the reserve share of the freshly accrued interest (reserves were 0 before) was absorbed first");
        uint256 left = pUsdc.borrowBalanceStored(b0);
        assertGt(left, 0, "the interest accrued since the last accrual is still recorded: the write-off used the CURRENT debt");
        assertGt(pUsdc.totalBorrows() + stale, staleBorrows, "borrows were brought up to date before the removal");
        assertGt(e.snap + 1, 0);
    }

    function testS3_EventLog_SplitMatchesAccounting() public {
        if (!_live()) return;
        uint256 base = vm.snapshotState();
        Evt memory e0 = _buildEvent(0, 99, 0);
        uint256 L = _loss(e0);
        _back(base);
        uint256 R = L / 2;
        Evt memory e = _buildEvent(R, 99, 0);
        _install(protoStrict);
        vm.recordLogs();
        _writeOffAllNoInstall();
        EvSum memory z = _sumEvents(vm.getRecordedLogs());
        uint256 n = z.n;
        uint256 sumAmt = z.amount;
        uint256 sumAbs = z.absorbed;
        uint256 sumRec = z.recognised;
        uint256 firstRateBefore = z.firstRateBefore;
        uint256 lastRateAfter = z.lastRateAfter;
        assertEq(n, N, "one event per written-off account");
        assertLe(_absDiff(sumAmt, L), TOL, "events: amounts sum to the loss");
        assertEq(sumAbs, R, "events: reserves absorbed first (all of R)");
        assertLe(_absDiff(sumRec, L - R), TOL, "events: remainder recognised by suppliers");
        assertEq(firstRateBefore, e.evt.rate, "event: rateBefore of the first write-off = event rate");
        assertEq(lastRateAfter, pUsdc.exchangeRateStored(), "event: rateAfter of the last write-off = current rate");
    }

    struct EvSum {
        uint256 n;
        uint256 amount;
        uint256 absorbed;
        uint256 recognised;
        uint256 firstRateBefore;
        uint256 lastRateAfter;
    }

    function _sumEvents(Vm.Log[] memory logs) internal view returns (EvSum memory z) {
        bytes32 sig = keccak256("BadDebtWrittenOff(address,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pUsdc) || logs[i].topics[0] != sig) continue;
            (uint256 amount, uint256 absorbed, uint256 recognised, uint256 rb, uint256 ra,,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            require(recognised == amount - absorbed, "event: recognised != amount - absorbed");
            if (z.n == 0) z.firstRateBefore = rb;
            z.lastRateAfter = ra;
            z.amount += amount;
            z.absorbed += absorbed;
            z.recognised += recognised;
            z.n++;
        }
    }

    function _writeOffAllNoInstall() internal {
        for (uint256 i; i < N; ++i) {
            uint256 owed = pUsdc.borrowBalanceCurrent(_borrower(i));
            ILossPrototype(address(pUsdc)).writeOffBadDebt(_borrower(i), owed);
        }
    }

    function testS3_TopUpReservesThenWriteOff_SameSuppliersOutcomeAsRepayment_SameNetProtocolOutlay() public {
        if (!_live()) return;
        uint256 base = vm.snapshotState();
        Evt memory e0 = _buildEvent(0, 99, 0);
        uint256 L = _loss(e0);
        _back(base);
        uint256 R = L * 3 / 10;
        Evt memory e = _buildEvent(R, 99, 0);
        Out memory s1 = _scenario("t=S1_R30", S1, L, true);
        _back(e.snap);
        uint256 tb = e.evt.borrows;
        Out memory s3 = _scenario("t=S3TOPUP_R30", S3TOPUP, tb - R, true);
        for (uint256 j; j < 4; ++j) {
            assertLe(_absDiff(s1.got[j], s3.got[j]), 1, "suppliers receive the same amounts in S1 and S3 + top-up");
            assertEq(s3.got[j], s3.claimAtExit[j], "S3 + top-up: in full");
        }
        assertEq(s3.act.rate, e.evt.rate, "no loss reaches the exchange rate");
        assertEq(s3.fromRes, tb, "reserves (pre-existing R plus the top-up) absorbed the whole loss");
        assertEq(s3.act.reserves, 0, "reserves are zero afterwards");
        assertEq(s1.act.reserves, R, "S1 leaves the reserves in place");
        assertEq(s1.treasuryIn, L, "S1 treasury outlay = loss");
        assertLe(_absDiff(s3.treasuryIn, L - R), TOL, "S3 + top-up treasury outlay = loss - reserves");
        // net cost to the protocol (treasury + reserves it no longer holds) is the same loss in both
        assertEq(s1.treasuryIn + (R - s1.act.reserves), L, "S1: net protocol outlay = loss");
        assertLe(_absDiff(s3.treasuryIn + (R - s3.act.reserves), L), TOL, "S3 + top-up: net protocol outlay = loss");
        assertLe(_absDiff(s1.act.cash - s3.act.cash, R), TOL, "S1 holds the protocol reserves R in the market, S3 consumed them: cash differs by R");
        assertLe(_absDiff(s1.act.cash - s1.act.reserves, s3.act.cash - s3.act.reserves), TOL, "cash backing suppliers (cash - reserves) is the same");
    }

    function testS3_ExitsBeforeTheWriteOff_ShiftTheWholeLossOntoTheRemainingSuppliers() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        // reference: write-off immediately
        (uint256 rem0,) = _writeOffAll(protoStrict);
        uint256 rateImmediate = pUsdc.exchangeRateStored();
        assertEq(rem0, L, "reference removal");
        // race: EARLY and SMALL leave in the gap between the event and the write-off (e.g. a timelock delay)
        _back(e.snap);
        (uint256 c0, uint256 g0) = _exit(0);
        (uint256 c3, uint256 g3) = _exit(3);
        assertEq(g0, c0, "EARLY leaves at the full unrecognised claim");
        assertEq(g3, c3, "SMALL leaves at the full unrecognised claim");
        Row memory mid = _rowNow();
        _logRow("t=S3_race", "after_early_exits", mid);
        _writeOffAll(protoStrict);
        Row memory post = _rowNow();
        _logRow("t=S3_race", "after_writeoff", post);
        uint256 rateRace = post.rate;
        assertLt(rateRace, rateImmediate, "the rate falls MORE when the early suppliers escaped first");
        // the remaining suppliers (LATE, BIG) bear the entire loss
        uint256 lostLate = e.evt.claim[1] - post.claim[1];
        uint256 lostBig = e.evt.claim[2] - post.claim[2];
        assertLe(_absDiff(lostLate + lostBig, L), 8, "remaining suppliers bear the WHOLE loss (reserves 0)");
        assertEq(e.evt.claim[0] - g0, 0, "EARLY lost nothing");
        // but the write-off itself is pro rata among those who remain
        assertLe(_absDiff(lostLate * 1e18 / e.evt.claim[1], lostBig * 1e18 / e.evt.claim[2]), 1e9, "pro rata among the remaining holders");
        _checkIdentities(post, "S3 race");
    }

    function testS3_RealReserveFactorAccrual_30Days_ReservesFirst() public {
        if (!_live()) return;
        // 90% utilisation so the accounts stay healthy through 30 days of interest; reserves come from the market's own 10% factor
        Evt memory e = _buildEvent(0, 90, 30 days);
        uint256 L = _loss(e);
        // reserves accrued are 10% of the interest charged in the 30 days
        uint256 R = e.evt.reserves;
        assertGt(R, 0, "reserves accrued from borrower interest");
        assertLe(_absDiff(e.pre.reserves, (e.pre.borrows - e.b0) * pUsdc.reserveFactorMantissa() / 1e18), 2, "reserves = reserve factor x interest charged");
        assertEq(pUsdc.reserveFactorMantissa(), 0.1e18, "reserve factor as it exists");
        assertGt(L, R, "the gap loss exceeds what 30 days of reserve-factor interest produced");
        emit log_string(string.concat("LOSS|REALRF", _kv("borrowsPreGap", e.pre.borrows), _kv("reservesPreGap", e.pre.reserves), _kv("loss", L), _kv("lossOverReservesBp", L * 10_000 / R), "|END"));
        Out memory s0 = _scenario("t=RF_S0", S0, 0, true);
        _back(e.snap);
        Out memory s3 = _scenario("t=RF_S3", S3, 0, true);
        assertLe(_absDiff(_lost(s0, 1), L - R), TOL, "S0: last supplier short by loss - reserves");
        assertEq(s3.fromRes, R, "S3: all real reserves absorbed first");
        assertEq(s3.act.reserves, 0, "S3: reserves exhausted");
        for (uint256 j; j < 4; ++j) {
            assertEq(s3.got[j], s3.claimAtExit[j], "S3: nobody short at exit");
        }
        assertLe(_absDiff(_sumClaims(e.evt) - _sumClaims(s3.act), L - R), 8, "S3: suppliers recognise loss - reserves");
    }

    function testSeizeShare_IsInTheCollateralMarket_NotInTheLossMarket() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        uint256 wavaxRes = pWavax.totalReserves();
        assertGt(wavaxRes, 0, "the liquidations booked a protocol seize share in pWAVAX");
        assertEq(pUsdc.totalReserves(), 0, "pUSDC (the loss market) received none of it");
        // S3 cannot use it: reserve-first in pUSDC only sees pUSDC reserves
        (uint256 removed, uint256 fromRes) = _writeOffAll(protoStrict);
        assertEq(removed, L);
        assertEq(fromRes, 0, "the pWAVAX seize reserve does not absorb a pUSDC loss");
        assertEq(pWavax.totalReserves(), wavaxRes, "pWAVAX reserves untouched");
        // coverage if the admin converted it (oracle value, no swap cost or slippage): _reduceReserves in pWAVAX, USDC to _addReserves in pUSDC
        uint256 usd = wavaxRes * uint256(avaxAnswer) / 1e20;
        emit log_string(string.concat("LOSS|SEIZERES", _kv("wavaxReserves", wavaxRes), _kv("usd6AtShock", usd), _kv("lossUsdc", L), _kv("coverageBp", usd * 10_000 / _usdcUsd6(L)), "|END"));
        assertLt(usd, _usdcUsd6(L), "the seize share alone is smaller than the loss in this scenario");
    }

    // ----------------------------------------------------------------- controls
    function testS3_Preconditions_NonAdmin_Amounts_Healthy_CollateralRemains() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        _install(protoStrict);
        address b0 = _borrower(0);
        uint256 owed = pUsdc.borrowBalanceCurrent(b0);
        ILossPrototype m = ILossPrototype(address(pUsdc));
        vm.prank(address(0xBAD));
        vm.expectRevert(bytes("only the admin may write off bad debt"));
        m.writeOffBadDebt(b0, owed);
        vm.expectRevert(bytes("nothing to write off"));
        m.writeOffBadDebt(b0, 0);
        vm.expectRevert(bytes("amount exceeds the recorded debt"));
        m.writeOffBadDebt(b0, owed + 1);
        vm.expectRevert(bytes("nothing to write off"));
        m.writeOffBadDebt(address(0xFEED), 1); // no debt
        // a healthy account (collateral and debt at current prices) cannot be written off
        _mintP(pWavax, HB, Math.mulDiv(60_000e6 * 1e12, 1e8, uint256(avaxAnswer)));
        _enter(HB);
        (bool ok,) = _borrow(pUsdc, HB, 10_000e6);
        require(ok, "hb borrow");
        vm.expectRevert(bytes("account is not in shortfall"));
        m.writeOffBadDebt(HB, 1_000e6);
        // an account in shortfall that still has collateral cannot be written off ("liquidate first")
        (,, uint256 sf0) = controller.getAccountLiquidity(HB);
        assertEq(sf0, 0);
        _mintP(pWavax, LEVERED, Math.mulDiv(30_000e6 * 1e12, 1e8, uint256(avaxAnswer)));
        _enter(LEVERED);
        (, uint256 liq,) = controller.getAccountLiquidity(LEVERED);
        (ok,) = _borrow(pUsdc, LEVERED, liq * 99 / 100 / 1e12);
        require(ok, "levered borrow");
        _setPrices(int256(uint256(avaxAnswer) * 9 / 10), usdcAnswer); // -10% more
        (,, uint256 sf1) = controller.getAccountLiquidity(LEVERED);
        assertGt(sf1, 0, "LEVERED in shortfall with collateral left");
        vm.expectRevert(bytes("collateral remains: liquidate first"));
        m.writeOffBadDebt(LEVERED, 1_000e6);
        // the defaulted accounts of the event are written off (exhausted collateral)
        _setPrices(avaxAnswer, usdcAnswer); // re-mock at the current stored price
        uint256 supplyBefore = pUsdc.totalSupply();
        m.writeOffBadDebt(b0, owed);
        assertEq(pUsdc.borrowBalanceStored(b0), 0, "debt gone");
        assertEq(pUsdc.totalSupply(), supplyBefore, "no pToken created or burned by a write-off");
    }

    function testS3_Caps_PerCallAndPerPeriod() public {
        if (!_live()) return;
        _buildEvent(0, 99, 0);
        _install(protoCapped); // 10,000 USDC per call, 15,000 per day
        ILossPrototype m = ILossPrototype(address(pUsdc));
        address b0 = _borrower(0);
        address b1 = _borrower(1);
        uint256 owed0 = pUsdc.borrowBalanceCurrent(b0);
        uint256 owed1 = pUsdc.borrowBalanceCurrent(b1);
        assertGt(owed0, 10_000e6, "each account's loss exceeds the per-call cap");
        vm.expectRevert(bytes("per-call cap"));
        m.writeOffBadDebt(b0, owed0); // the whole debt in one call is refused
        m.writeOffBadDebt(b0, 10_000e6);
        assertLe(_absDiff(pUsdc.borrowBalanceStored(b0), owed0 - 10_000e6), 2, "partial write-off leaves the rest recorded");
        vm.expectRevert(bytes("per-period cap"));
        m.writeOffBadDebt(b1, 5_000e6 + 10); // 10,000 + 5,010 > 15,000
        m.writeOffBadDebt(b1, 5_000e6 - 10);
        (, uint256 used) = PErc20DelegateLossPrototype(address(pUsdc)).lossPeriodState();
        assertLe(_absDiff(used, 15_000e6 - 10), 4, "period counter = amount written off (within share rounding)");
        vm.expectRevert(bytes("per-period cap"));
        m.writeOffBadDebt(b1, 100);
        // next day: allowance resets
        _roll(1 days);
        m.writeOffBadDebt(b1, 8_000e6);
        (, used) = PErc20DelegateLossPrototype(address(pUsdc)).lossPeriodState();
        assertLe(_absDiff(used, 8_000e6), 4, "period counter restarted");
    }

    // ----------------------------------------------------------------- theft vectors
    function _adminBorrowsAgainstCollateral(uint256 usdcAmt) internal {
        _mintP(pWavax, ADMIN_ACCT, Math.mulDiv(100_000e6 * 1e12, 1e8, uint256(realAvaxAnswer)));
        _enter(ADMIN_ACCT);
        (bool ok,) = _borrow(pUsdc, ADMIN_ACCT, usdcAmt);
        require(ok, "admin account borrow");
    }

    function testTheft_UnrestrictedAdmin_WritesOffItsOwnHealthyLoan_SuppliersPay() public {
        if (!_live()) return;
        _unpauseBorrows();
        _supply();
        _adminBorrowsAgainstCollateral(50_000e6);
        uint256 supplyBefore = pUsdc.totalSupply();
        Row memory before = _rowNow();
        _logRow("t=THEFT_open", "before", before);
        _install(protoOpen);
        uint256 stolen = pUsdc.borrowBalanceCurrent(ADMIN_ACCT);
        (uint256 removed, uint256 fromRes) = ILossPrototype(address(pUsdc)).writeOffBadDebt(ADMIN_ACCT, stolen);
        Row memory after_ = _rowNow();
        _logRow("t=THEFT_open", "after_writeoff", after_);
        assertLe(_absDiff(removed, 50_000e6), TOL);
        assertEq(fromRes, 0);
        assertEq(pUsdc.borrowBalanceStored(ADMIN_ACCT), 0, "the admin's debt is gone");
        // the admin keeps the 50,000 USDC AND redeems its collateral
        uint256 pw = pWavax.balanceOf(ADMIN_ACCT);
        vm.prank(ADMIN_ACCT);
        require(pWavax.redeem(pw) == 0, "collateral redeemed");
        assertGt(IERC20(WAVAX).balanceOf(ADMIN_ACCT), 0, "collateral withdrawn");
        assertEq(IERC20(USDC).balanceOf(ADMIN_ACCT), 50_000e6, "the borrowed cash stays with the admin's account");
        // suppliers pay: total claims fall by the whole amount (no reserves to absorb it), pro rata
        assertLe(_absDiff(_sumClaims(before) - _sumClaims(after_), 50_000e6), 16, "suppliers lose exactly the written-off amount");
        assertLt(after_.rate, before.rate);
        assertEq(supplyBefore, pUsdc.totalSupply());
        // the same attempt with the precondition in the bytecode fails
        emit log_string(string.concat("LOSS|THEFT|variant=unrestricted", _kv("stolen", 50_000e6), _kv("rateBefore", before.rate), _kv("rateAfter", after_.rate), "|END"));
    }

    function testTheft_PreconditionStopsIt_StrictRevertsOnTheHealthyLoan() public {
        if (!_live()) return;
        _unpauseBorrows();
        _supply();
        _adminBorrowsAgainstCollateral(50_000e6);
        _install(protoStrict);
        vm.expectRevert(bytes("account is not in shortfall"));
        ILossPrototype(address(pUsdc)).writeOffBadDebt(ADMIN_ACCT, 49_000e6);
    }

    function testTheft_CapAloneBoundsEachCallButNotTheTotal_PeriodCapBoundsThePeriod() public {
        if (!_live()) return;
        _unpauseBorrows();
        _supply();
        _adminBorrowsAgainstCollateral(50_000e6);
        _install(protoCapOnly); // precondition OFF, 10,000 per call
        ILossPrototype m = ILossPrototype(address(pUsdc));
        vm.expectRevert(bytes("per-call cap"));
        m.writeOffBadDebt(ADMIN_ACCT, 10_000e6 + 1);
        uint256 calls;
        while (pUsdc.borrowBalanceStored(ADMIN_ACCT) > 0) {
            m.writeOffBadDebt(ADMIN_ACCT, _min(pUsdc.borrowBalanceStored(ADMIN_ACCT), 10_000e6));
            calls++;
        }
        assertEq(calls, 5, "a per-call cap alone only needs more calls: the whole 50,000 is gone");
        emit log_string(string.concat("LOSS|THEFT|variant=percall-cap-only", _kv("stolen", 50_000e6), _kv("calls", calls), "|END"));
    }

    function testTheft_OracleManipulationPassesThePrecondition_StrictHasNoCap() public {
        if (!_live()) return;
        _unpauseBorrows();
        _supply();
        _adminBorrowsAgainstCollateral(50_000e6);
        // a manipulated (here: mocked) collateral price of 1 wei: the precondition reads the SAME oracle, so a healthy loan "looks" defaulted
        vm.mockCall(address(oracle), abi.encodeWithSelector(oracle.getUnderlyingPrice.selector, PToken(address(pWavax))), abi.encode(uint256(1)));
        (,, uint256 sf) = controller.getAccountLiquidity(ADMIN_ACCT);
        assertGt(sf, 0, "under the manipulated price the account is in shortfall");
        _install(protoStrict);
        (uint256 removed,) = ILossPrototype(address(pUsdc)).writeOffBadDebt(ADMIN_ACCT, pUsdc.borrowBalanceCurrent(ADMIN_ACCT)); // strict has no cap: passes
        assertLe(_absDiff(removed, 50_000e6), TOL, "STRICT (no cap): the precondition alone does not stop a manipulated oracle");
    }

    function testTheft_OracleManipulation_WithCapsLimitedToThePeriodAllowance() public {
        if (!_live()) return;
        _unpauseBorrows();
        _supply();
        _adminBorrowsAgainstCollateral(50_000e6);
        vm.mockCall(address(oracle), abi.encodeWithSelector(oracle.getUnderlyingPrice.selector, PToken(address(pWavax))), abi.encode(uint256(1)));
        _install(protoCapped); // 10,000 per call, 15,000 per day
        ILossPrototype m = ILossPrototype(address(pUsdc));
        m.writeOffBadDebt(ADMIN_ACCT, 10_000e6);
        m.writeOffBadDebt(ADMIN_ACCT, 5_000e6);
        vm.expectRevert(bytes("per-period cap"));
        m.writeOffBadDebt(ADMIN_ACCT, 1);
        assertLe(_absDiff(pUsdc.borrowBalanceStored(ADMIN_ACCT), 35_000e6), TOL, "only the 15,000 period allowance was forgiven");
    }

    // ----------------------------------------------------------------- install / storage
    function testInstall_PlainDelegateHasNoWriteOff_UpgradePreservesEveryStorageSlot() public {
        if (!_live()) return;
        _buildEvent(0, 99, 0);
        ILossPrototype m = ILossPrototype(address(pUsdc));
        vm.expectRevert();
        m.writeOffBadDebt(_borrower(0), 1); // the plain delegate has no such function
        bytes32[96] memory slots;
        for (uint256 s; s < 96; ++s) {
            slots[s] = vm.load(address(pUsdc), bytes32(s));
        }
        bytes32 bankSlot = 0xe730f71cfe4f5b50c65508b2ca4b864ce7682a04ce43876ecdb364c635640500;
        bytes32 lossSlot = keccak256(abi.encode(uint256(keccak256("peridot.storage.LossPrototype")) - 1)) & ~bytes32(uint256(0xff));
        bytes32 slots_bank = vm.load(address(pUsdc), bankSlot);
        uint256 supply = pUsdc.totalSupply();
        uint256 borrows = pUsdc.totalBorrows();
        uint256 reserves = pUsdc.totalReserves();
        uint256 rate = pUsdc.exchangeRateStored();
        Row memory pre = _rowNow();
        address oldImpl = pUsdc.implementation();
        _install(protoStrict);
        assertTrue(pUsdc.implementation() != oldImpl, "implementation replaced");
        uint256 changed;
        for (uint256 s; s < 96; ++s) {
            bytes32 v = vm.load(address(pUsdc), bytes32(s));
            if (v != slots[s]) {
                changed++;
                assertEq(address(uint160(uint256(slots[s]))), oldImpl, "the only slot that changes held the old implementation");
                assertEq(address(uint160(uint256(v))), address(protoStrict), "and now holds the new implementation");
            }
        }
        assertEq(changed, 1, "exactly one storage slot of the proxy changed: the implementation pointer");
        assertEq(vm.load(address(pUsdc), lossSlot), bytes32(0), "namespaced loss slot starts empty");
        assertEq(vm.load(address(pUsdc), bankSlot) , slots_bank, "borrow-accounting namespace (enabled flag) untouched");
        assertEq(pUsdc.totalSupply(), supply);
        assertEq(pUsdc.totalBorrows(), borrows);
        assertEq(pUsdc.totalReserves(), reserves);
        assertEq(pUsdc.exchangeRateStored(), rate);
        Row memory post = _rowNow();
        assertEq(post.cash, pre.cash);
        assertEq(post.defDebt, pre.defDebt);
        // ordinary operation continues after the upgrade
        _mintP(pUsdc, SEEDER, 1_000e6);
        (uint256 c, uint256 g) = _exit(3);
        assertEq(c, g);
        // and the old implementation can be put back
        pUsdc._setImplementation(oldImpl, false, "");
        assertEq(pUsdc.implementation(), oldImpl);
        assertEq(pUsdc.totalBorrows(), borrows);
    }

    // ================================================================= CROSS-SCENARIO (same event)
    function _cross(uint256 seedBp) internal {
        uint256 base = vm.snapshotState();
        Evt memory e0 = _buildEvent(0, 99, 0);
        uint256 L = _loss(e0);
        _back(base);
        uint256 R = L * seedBp / 10_000;
        Evt memory e = _buildEvent(R, 99, 0);
        string memory tag = string.concat("t=X_R", vm.toString(seedBp), "_");
        uint256 rt = _rateTol();
        Out memory o0 = _scenario(string.concat(tag, "S0"), S0, 0, true);
        _back(e.snap);
        Out memory o1 = _scenario(string.concat(tag, "S1"), S1, L, true);
        _back(e.snap);
        Out memory o2 = _scenario(string.concat(tag, "S2"), S2, L, true);
        _back(e.snap);
        Out memory o3 = _scenario(string.concat(tag, "S3"), S3, 0, true);
        // distinguishing equalities at the action step
        assertEq(o0.act.defDebt, L, "S0 debt recorded");
        assertEq(o2.act.defDebt, L, "S2 debt recorded");
        assertEq(o1.act.defDebt, 0, "S1 debt removed");
        assertEq(o3.act.defDebt, 0, "S3 debt removed");
        assertEq(o0.act.rate, e.evt.rate, "S0 rate");
        assertEq(o1.act.rate, e.evt.rate, "S1 rate");
        assertEq(o2.act.rate, e.evt.rate, "S2 rate");
        if (L > R) assertLt(o3.act.rate, e.evt.rate, "S3 rate falls when loss > reserves"); else assertLe(_absDiff(o3.act.rate, e.evt.rate), rt);
        assertEq(o0.act.reserves, R, "S0 reserves");
        assertEq(o1.act.reserves, R, "S1 reserves");
        assertEq(o2.act.reserves, R + L, "S2 reserves");
        assertLe(_absDiff(o3.act.reserves, R - _min(L, R)), TOL, "S3 reserves");
        assertEq(o0.act.cash, e.evt.cash);
        assertEq(o1.act.cash, e.evt.cash + L);
        assertEq(o2.act.cash, e.evt.cash + L);
        assertEq(o3.act.cash, e.evt.cash);
        // suppliers' total loss at exit
        uint256 short0 = _sumClaim(o0) - _sumGot(o0);
        assertLe(_absDiff(short0, _max0(L, R)), TOL, "S0: suppliers lose max(0, L-R) (one supplier, by queue position)");
        assertEq(_sumClaim(o1) - _sumGot(o1), 0, "S1: nobody loses");
        assertEq(_sumClaim(o2) - _sumGot(o2), 0, "S2 at t0: nobody loses (but see the drift and revocability tests)");
        assertEq(_sumClaim(o3) - _sumGot(o3), 0, "S3: no exit shortfall");
        assertLe(_absDiff(_sumClaims(e.evt) - _sumClaim(o3), _max0(L, R)), 8, "S3: the loss moved into the claims (recognised), pro rata");
        _assertConserved(e, o0, "X S0");
        _assertConserved(e, o1, "X S1");
        _assertConserved(e, o2, "X S2");
        _assertConserved(e, o3, "X S3");
        emit log_string(
            string.concat(
                "LOSS|CROSS", _kv("reservesBp", seedBp), _kv("loss", L), _kv("reserves", R), _kv("S0_lost", short0), _kv("S1_treasury", o1.treasuryIn), _kv("S2_treasury", o2.treasuryIn),
                _kv("S3_recognised", _max0(L, R)), "|END"
            )
        );
    }

    function testCross_SameEvent_ReservesZero() public {
        if (!_live()) return;
        _cross(0);
    }

    function testCross_SameEvent_ReservesThirtyPercentOfLoss() public {
        if (!_live()) return;
        _cross(3_000);
    }

    function testCross_SameEvent_ReservesCoverTheLoss() public {
        if (!_live()) return;
        _cross(15_000);
    }

    // ================================================================= INTERACTIONS
    function testHealthyBorrowerOutstanding_IlliquidityIsCashNotLoss_S0VersusS3() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        // a healthy borrower takes 20,000 USDC of the remaining cash after the event
        _mintP(pWavax, HB, Math.mulDiv(60_000e6 * 1e12, 1e8, uint256(avaxAnswer)));
        _enter(HB);
        (bool ok,) = _borrow(pUsdc, HB, 20_000e6);
        require(ok, "hb borrow");
        uint256 snap = vm.snapshotState();
        Row memory s0 = _rowNow();
        _logRow("t=HB_S0", "with_healthy_borrow", s0);
        // S0: claims - cash = (loss + healthy debt) - reserves
        uint256 healthy = pUsdc.borrowBalanceStored(HB);
        assertLe(_absDiff(_sumClaims(s0) - s0.cash, L + healthy - e.evt.reserves), 16, "S0: claims - cash = bad debt + healthy debt - reserves");
        _writeOffAll(protoStrict);
        Row memory s3 = _rowNow();
        _logRow("t=HB_S3", "after_writeoff", s3);
        assertLe(_absDiff(_sumClaims(s3) - s3.cash, healthy), 16, "S3: claims - cash = healthy debt only (a liquidity gap that repayment closes), no loss gap");
        // the healthy borrower repays: S3 is whole, S0 keeps the loss gap
        _back(snap);
        _repay(pUsdc, HB, type(uint256).max);
        Row memory s0r = _rowNow();
        assertLe(_absDiff(_sumClaims(s0r) - s0r.cash, L), 16, "S0 after the healthy debt is repaid: shortfall = loss - reserves");
        _back(snap);
        _writeOffAll(protoStrict);
        _repay(pUsdc, HB, type(uint256).max);
        Row memory s3r = _rowNow();
        assertLe(_sumClaims(s3r), s3r.cash + 8, "S3 after the repayment: cash covers every claim");
    }

    function testS3_Recognition_PushesALeveragedSupplierIntoShortfall_S0AndS1DoNot() public {
        if (!_live()) return;
        Evt memory e = _buildEvent(0, 99, 0);
        uint256 L = _loss(e);
        // a supplier that uses its pUSDC as collateral for a WAVAX loan at 99% of its power (opened after the event, prices at -50%)
        _mintP(pUsdc, LEVERED, 30_000e6);
        _enter(LEVERED);
        (, uint256 liq,) = controller.getAccountLiquidity(LEVERED);
        (bool ok,) = _borrow(pWavax, LEVERED, liq * 99 / 100 * 1e8 / uint256(avaxAnswer));
        require(ok, "levered borrow");
        (,, uint256 sf0) = controller.getAccountLiquidity(LEVERED);
        assertEq(sf0, 0, "healthy before");
        uint256 snap = vm.snapshotState();
        // S0 and S1: the exchange rate does not move
        _repayBehalf(L);
        (,, uint256 sfS1) = controller.getAccountLiquidity(LEVERED);
        assertEq(sfS1, 0, "S1: still healthy");
        _back(snap);
        (,, uint256 sfS0) = controller.getAccountLiquidity(LEVERED);
        assertEq(sfS0, 0, "S0: still healthy (the loss is hidden in the exchange rate)");
        // S3: the recognition lowers the collateral value of a pUSDC holder who borrows against it
        _writeOffAll(protoStrict);
        (,, uint256 sfS3) = controller.getAccountLiquidity(LEVERED);
        assertGt(sfS3, 0, "S3: the recognised loss puts a 99%-levered pUSDC holder into shortfall");
        emit log_string(string.concat("LOSS|LEVERED", _kv("loss", L), _kv("shortfallUsd18", sfS3), "|END"));
    }
}
