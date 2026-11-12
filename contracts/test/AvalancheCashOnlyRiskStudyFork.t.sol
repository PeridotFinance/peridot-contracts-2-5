// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheCashOnlyBase.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";

/**
 * @notice RISK STUDY for the CASH-ONLY lending product (pUSDC + pWAVAX, no margin stack). Measures, it does not choose.
 *
 * EVERYTHING HERE IS A SYNTHETIC GRID on the margin-free fixture (`AvalancheCashOnlyBase`, pinned fork block 99,200,000):
 *   - collateral factors, liquidation incentives, close factors, rate-model shapes, reserve factors and cash-floor sizes are GRID
 *     POINTS, not candidates and not recommendations. No production value is chosen, borrowing is paused at deployment and stays
 *     paused (the tests unpause inside their own fork only).
 *   - the AVAX / USDC feeds are MOCKED to move the price instantly (`vm.mockCall`), so there is no Chainlink deviation threshold,
 *     heartbeat, round gap or latency; liquidation is by ONE harness-funded liquidator with no competition, no gas price, no swap
 *     and no redemption latency; collateral is `deal`-minted (no real liquidity); interest accrues on block.number (the fixture's
 *     rate model assumes 31,536,000 blocks per year, i.e. 1 block per second) and only in the tests that `vm.roll`.
 *
 * DIRECTION CODES. `W` = WAVAX collateral / USDC debt (hurt by an AVAX FALL). `U` = USDC collateral / WAVAX debt (hurt by an AVAX
 * RISE, or by a USDC depeg: only the AVAX/USDC price RATIO matters for these two assets).
 * UTILISATION. `util` = BORROWER utilisation = borrowed value as a percent of the account's `getAccountLiquidity` borrowing power
 * (the capacity-matrix definition). `mktUtilBp` = MARKET utilisation = borrows / (cash + borrows - reserves) of the debt market.
 * USD values are micro-USD (usd6 = USD x 1e6) at the prices stated per column.
 *
 * MACHINE-READABLE OUTPUT (`RISK|<kind>|key=value|...|END`, one line per cell, parse with tools of your choice):
 *   RISK|CELL|mode=gap|path  dir cf(bp of 10000) li(bp, 10800 = 1.08) close(bp) util(%) n shock(AVAX bp of pin) ... see _emitCell
 *   debt0Usd/coll0Usd  initial debt / collateral at PIN prices;  short = accounts in shortfall right after the shock
 *   txs = successful liquidations;  maxr = most liquidations on one account;  repaidUsd = liquidator budget used (shock prices)
 *   netUsd/protoUsd = seized value kept by the liquidator / protocol share booked to the collateral market's totalReserves
 *   profitBp = (netUsd - repaidUsd) / repaidUsd, signed;  badShock/badPin = bad debt valued at shock / pin prices
 *   badPred = closed-form prediction (see _pred), residShort = accounts still in shortfall at the end, residColl = of those, with collateral left
 *   gasMax/gasAvg = gas of liquidateBorrow measured with gasleft() around the call (mocked feeds, warm accounts: see gas test)
 *   exitShort = debt-market supplier claims minus cash (debt units): how much of the claims cannot be paid in cash; lpExitBp = share of LP claim withdrawable
 * Other kinds: RISK|STALE, RISK|STALEOPEN, RISK|EXIT, RISK|IRM, RISK|ACCR, RISK|RESFIRST, RISK|GAS, RISK|MON, RISK|EQV, RISK|SUMMARY.
 *
 * ASSERTIONS are accounting identities and harness-behaved checks only (setup borrows succeeded, every cell emitted a line, seized
 * value = repay x incentive within 1%, protocol share = 2.8% of the seize, totalBorrows moved by the repay, borrower debts sum to
 * totalBorrows, cash + borrows - reserves = claims, the closed-form prediction agrees with the measurement). No fairness threshold.
 */
contract AvalancheCashOnlyRiskStudyForkTest is AvalancheCashOnlyBase {
    uint256 internal constant N = 3; // borrowers per cell
    uint256 internal constant COLL_USD6 = 10_000e6; // collateral per borrower at pin prices
    uint256 internal constant DUST_USD6 = 10_000; // USD 0.01
    uint256 internal constant MAX_CALLS = 60;

    address[] internal bs; // borrowers of the current cell (set BEFORE the cell snapshot)

    struct Ctx {
        bool uCol;
        uint256 cfBps;
        uint256 util;
        uint256 li;
        uint256 closeF;
        PErc20Delegator colM;
        PErc20Delegator debtM;
        address colAsset;
        address debtAsset;
        uint256 debt0;
        uint256 debt0Usd;
        uint256 coll0Usd;
        uint256 mktUtilBp;
        int256 avaxPin;
        int256 usdcPin;
    }

    struct Res {
        uint256 short;
        uint256 txs;
        uint256 maxRounds;
        uint256 gasSum;
        uint256 gasMax;
        uint256 repaidUnits;
        uint256 repaidUsd;
        uint256 netUsd;
        uint256 protoUsd;
        uint256 firstShortStep;
        uint256 backlogSteps;
        uint256 peakStepUsd;
        uint256 steps;
    }

    struct Agg {
        uint256 cells;
        uint256 idViol;
        uint256 predMismatch;
        uint256 setupFail;
        uint256 acctViol;
    }

    PeridottrollerAvalanche internal ctrlA;

    function _init() internal returns (bool live) {
        if (address(controller) == address(0)) return false; // skipped (no RPC)
        ctrlA = PeridottrollerAvalanche(address(controller));
        return true;
    }

    // ------------------------------------------------------------------ small helpers
    function _u(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _i(int256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _kv(string memory k, uint256 v) internal pure returns (string memory) {
        return string.concat("|", k, "=", vm.toString(v));
    }

    function _kvi(string memory k, int256 v) internal pure returns (string memory) {
        return string.concat("|", k, "=", vm.toString(v));
    }

    function _usd6(address asset, uint256 amt) internal view returns (uint256) {
        return _usd6At(asset, amt, avaxAnswer, usdcAnswer);
    }

    function _usd6At(address asset, uint256 amt, int256 avax8, int256 usdc8) internal pure returns (uint256) {
        return asset == USDC ? Math.mulDiv(amt, uint256(usdc8), 1e8) : Math.mulDiv(amt, uint256(avax8), 1e20);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function _colUnits(PErc20Delegator m, uint256 pTokens) internal view returns (uint256) {
        return Math.mulDiv(pTokens, m.exchangeRateStored(), 1e18);
    }

    function _claims(PErc20Delegator m) internal view returns (uint256) {
        return Math.mulDiv(m.totalSupply(), m.exchangeRateStored(), 1e18);
    }

    function _mktUtilBp(PErc20Delegator m) internal view returns (uint256) {
        uint256 b = m.totalBorrows();
        uint256 den = m.getCash() + b - m.totalReserves();
        return den == 0 ? 0 : b * 1e4 / den;
    }

    // ------------------------------------------------------------------ position setup
    function _setup(uint256 snapBase, bool uCol, uint256 cfBps, uint256 util, Agg memory agg) internal returns (Ctx memory x) {
        vm.revertToState(snapBase);
        _setPrices(realAvaxAnswer, usdcAnswer);
        _unpauseBorrows();
        x.uCol = uCol;
        x.cfBps = cfBps;
        x.util = util;
        x.colM = uCol ? pUsdc : pWavax;
        x.debtM = uCol ? pWavax : pUsdc;
        x.colAsset = uCol ? USDC : WAVAX;
        x.debtAsset = uCol ? WAVAX : USDC;
        x.avaxPin = realAvaxAnswer;
        x.usdcPin = usdcAnswer;
        require(controller._setCollateralFactor(PToken(address(x.colM)), cfBps * 1e14) == 0, "set cf");
        delete bs;
        uint256 collUnits;
        for (uint256 i; i < N; ++i) {
            address b = address(uint160(0x9000 + i));
            bs.push(b);
            _mintP(x.colM, b, uCol ? COLL_USD6 : Math.mulDiv(COLL_USD6 * 1e12, 1e8, uint256(realAvaxAnswer)));
            _enter(b);
            (, uint256 liq,) = controller.getAccountLiquidity(b);
            uint256 amt = uCol ? Math.mulDiv(liq * util / 100, 1e8, uint256(realAvaxAnswer)) : liq * util / 100 / 1e12;
            (bool ok,) = _borrow(x.debtM, b, amt);
            if (!ok) agg.setupFail++;
            x.debt0 += x.debtM.borrowBalanceStored(b);
            collUnits += _colUnits(x.colM, x.colM.balanceOf(b));
        }
        x.debt0Usd = _usd6(x.debtAsset, x.debt0);
        x.coll0Usd = _usd6(x.colAsset, collUnits);
        x.mktUtilBp = _mktUtilBp(x.debtM);
    }

    // ------------------------------------------------------------------ liquidation (one harness-funded liquidator)
    function _liqOnce(Ctx memory x, Res memory r, address b, uint256 repay, Agg memory agg) internal returns (bool ok) {
        deal(x.debtAsset, CAROL, IERC20(x.debtAsset).balanceOf(CAROL) + repay);
        vm.prank(CAROL);
        IERC20(x.debtAsset).approve(address(x.debtM), repay);
        uint256 cB = x.colM.balanceOf(CAROL);
        uint256 resB = x.colM.totalReserves();
        uint256 borrowsB = x.debtM.totalBorrows();
        uint256 g = gasleft();
        vm.prank(CAROL);
        (bool s, bytes memory ret) = address(x.debtM).call(abi.encodeWithSelector(PErc20.liquidateBorrow.selector, b, repay, address(x.colM)));
        g = g - gasleft();
        ok = s && ret.length == 32 && abi.decode(ret, (uint256)) == 0;
        if (!ok) return false;
        uint256 netUnits = _colUnits(x.colM, x.colM.balanceOf(CAROL) - cB);
        uint256 protoUnits = x.colM.totalReserves() - resB;
        uint256 repayUsd = _usd6(x.debtAsset, repay);
        uint256 netUsd = _usd6(x.colAsset, netUnits);
        uint256 protoUsd = _usd6(x.colAsset, protoUnits);
        uint256 grossUsd = netUsd + protoUsd;
        r.txs++;
        r.gasSum += g;
        if (g > r.gasMax) r.gasMax = g;
        r.repaidUnits += repay;
        r.repaidUsd += repayUsd;
        r.netUsd += netUsd;
        r.protoUsd += protoUsd;
        // identities (rounding tolerance: 1% plus USD 0.01)
        if (_absDiff(grossUsd, Math.mulDiv(repayUsd, x.li, 1e18)) > repayUsd / 100 + DUST_USD6) agg.idViol++;
        if (_absDiff(protoUsd, Math.mulDiv(grossUsd, 0.028e18, 1e18)) > grossUsd / 100 + DUST_USD6) agg.idViol++;
        if (_absDiff(borrowsB - x.debtM.totalBorrows(), repay) > repay / 1_000_000 + 100) agg.idViol++;
    }

    /// @dev A sophisticated liquidator: repay the close-factor maximum, shrunk to what the remaining collateral can pay, repeat.
    function _liqBorrower(Ctx memory x, Res memory r, address b, uint256 maxCalls, Agg memory agg) internal returns (uint256 calls) {
        for (; calls < maxCalls; ++calls) {
            (, , uint256 sf) = controller.getAccountLiquidity(b);
            if (sf == 0) break;
            uint256 colBal = x.colM.balanceOf(b);
            if (_usd6(x.colAsset, _colUnits(x.colM, colBal)) < DUST_USD6) break;
            uint256 repay = Math.mulDiv(x.debtM.borrowBalanceCurrent(b), x.closeF, 1e18);
            (, uint256 seize) = controller.liquidateCalculateSeizeTokens(address(x.debtM), address(x.colM), repay);
            if (seize > colBal) repay = Math.mulDiv(repay, colBal, seize);
            bool done;
            for (uint256 a; a < 8 && repay > 0; ++a) {
                if (_usd6(x.debtAsset, repay) < DUST_USD6) {
                    repay = 0;
                    break;
                }
                if (_liqOnce(x, r, b, repay, agg)) {
                    done = true;
                    break;
                }
                repay = repay * 99_999 / 100_000;
            }
            if (!done) break;
        }
        if (calls > r.maxRounds) r.maxRounds = calls;
    }

    function _clearStep(Ctx memory x, Res memory r, uint256 maxCalls, Agg memory agg) internal {
        for (uint256 i; i < bs.length; ++i) _liqBorrower(x, r, bs[i], maxCalls, agg);
    }

    function _countShort() internal view returns (uint256 n) {
        for (uint256 i; i < bs.length; ++i) {
            (, , uint256 sf) = controller.getAccountLiquidity(bs[i]);
            if (sf > 0) n++;
        }
    }

    function _countLiquidatable(Ctx memory x) internal view returns (uint256 n) {
        for (uint256 i; i < bs.length; ++i) {
            (, , uint256 sf) = controller.getAccountLiquidity(bs[i]);
            if (sf > 0 && _usd6(x.colAsset, _colUnits(x.colM, x.colM.balanceOf(bs[i]))) >= DUST_USD6) n++;
        }
    }

    // ------------------------------------------------------------------ closed-form prediction (a CROSS-CHECK of the harness)
    /// @dev With rho = collateral value / debt value after the shock, repeated liquidation at incentive LI leaves bad debt iff rho < LI:
    ///      each round moves rho to (rho - c*LI)/(1 - c) (c = close factor), which rises iff rho > LI; when rho < LI the collateral runs
    ///      out first and the unpaid debt is D * (1 - rho/LI). It is independent of the close factor. A healthy account is not liquidated at all.
    function _pred(Ctx memory x, uint256 shockBps) internal pure returns (uint256 predUsd, bool safe) {
        uint256 rho0 = Math.mulDiv(x.coll0Usd, 1e18, x.debt0Usd);
        uint256 rho = x.uCol ? Math.mulDiv(rho0, 1e4, shockBps) : Math.mulDiv(rho0, shockBps, 1e4);
        // also nothing happens while the account is still healthy (rho >= 1 / CF): possible only when CF x LI > 1, i.e. CF above ~92%
        safe = rho >= x.li || rho * x.cfBps >= 1e18 * 1e4;
        uint256 dShock = x.uCol ? Math.mulDiv(x.debt0Usd, shockBps, 1e4) : x.debt0Usd;
        predUsd = safe ? 0 : Math.mulDiv(dShock, x.li - rho, x.li);
    }

    // ------------------------------------------------------------------ end-of-cell metrics, identities, one RISK line
    struct Fin {
        uint256 residShort;
        uint256 residColl;
        uint256 badShock;
        uint256 badUnits;
        uint256 badPin;
        uint256 debtLeftUnits;
        uint256 cash;
        uint256 claims;
        uint256 exitShort;
        uint256 lpExitBp;
        uint256 carolClaimUnits;
        uint256 colCash;
        uint256 mktUtilAfterBp;
    }

    function _fin(Ctx memory x, Agg memory agg) internal view returns (Fin memory f) {
        uint256 sumBorrows;
        for (uint256 i; i < bs.length; ++i) {
            address b = bs[i];
            (, , uint256 sf) = controller.getAccountLiquidity(b);
            uint256 debtLeft = x.debtM.borrowBalanceStored(b);
            uint256 collUnits = _colUnits(x.colM, x.colM.balanceOf(b));
            uint256 collUsd = _usd6(x.colAsset, collUnits);
            uint256 leftUsd = _usd6(x.debtAsset, debtLeft);
            sumBorrows += debtLeft;
            f.debtLeftUnits += debtLeft;
            if (sf > 0) {
                f.residShort++;
                if (collUsd >= DUST_USD6) f.residColl++;
            }
            if (leftUsd > collUsd) {
                f.badShock += leftUsd - collUsd;
                f.badUnits += Math.mulDiv(debtLeft, leftUsd - collUsd, leftUsd);
            }
        }
        f.badPin = _usd6At(x.debtAsset, f.badUnits, x.avaxPin, x.usdcPin);
        f.cash = x.debtM.getCash();
        f.claims = _claims(x.debtM);
        f.exitShort = f.claims > f.cash ? f.claims - f.cash : 0;
        uint256 lpClaim = _colUnits(x.debtM, x.debtM.balanceOf(LP));
        f.lpExitBp = lpClaim == 0 ? 0 : _min(f.cash, lpClaim) * 1e4 / lpClaim;
        f.carolClaimUnits = _colUnits(x.colM, x.colM.balanceOf(CAROL));
        f.colCash = x.colM.getCash();
        f.mktUtilAfterBp = _mktUtilBp(x.debtM);
        // accounting identities (not fairness thresholds)
        uint256 tb = x.debtM.totalBorrows();
        if (_absDiff(sumBorrows, tb) > 10 + tb / 1_000_000_000) agg.acctViol++;
        if (_absDiff(x.debtM.getCash() + tb - x.debtM.totalReserves(), f.claims) > 2) agg.acctViol++;
    }

    function _emitCell(string memory mode, Ctx memory x, Res memory r, Fin memory f, uint256 shockBps, uint256 predUsd, uint256 nShortAtShock) internal {
        int256 profitBp = r.repaidUsd == 0 ? int256(0) : (int256(r.netUsd) - int256(r.repaidUsd)) * 1e4 / int256(r.repaidUsd);
        string memory s = string.concat("RISK|CELL|mode=", mode, "|dir=", x.uCol ? "U" : "W");
        s = string.concat(s, _kv("cf", x.cfBps), _kv("li", x.li / 1e14), _kv("close", x.closeF / 1e14), _kv("util", x.util), _kv("n", N), _kv("shock", shockBps));
        s = string.concat(s, _kv("mktUtilBp", x.mktUtilBp), _kv("debt0Usd", x.debt0Usd), _kv("coll0Usd", x.coll0Usd), _kv("short", nShortAtShock));
        s = string.concat(s, _kv("txs", r.txs), _kv("maxr", r.maxRounds), _kv("repaidUsd", r.repaidUsd), _kv("repaidUnits", r.repaidUnits), _kv("netUsd", r.netUsd), _kv("protoUsd", r.protoUsd));
        s = string.concat(s, _kvi("profitBp", profitBp), _kv("badShock", f.badShock), _kv("badPin", f.badPin), _kv("badUnits", f.badUnits), _kv("badPred", predUsd));
        s = string.concat(s, _kv("residShort", f.residShort), _kv("residColl", f.residColl), _kv("gasMax", r.gasMax), _kv("gasAvg", r.txs == 0 ? 0 : r.gasSum / r.txs));
        s = string.concat(s, _kv("exitShort", f.exitShort), _kv("lpExitBp", f.lpExitBp), _kv("debtLeft", f.debtLeftUnits), _kv("mktUtilAfterBp", f.mktUtilAfterBp));
        s = string.concat(s, _kv("firstShortStep", r.firstShortStep), _kv("backlogSteps", r.backlogSteps), _kv("peakStepUsd", r.peakStepUsd), _kv("steps", r.steps), "|END");
        emit log_string(s);
    }

    // ================================================================= (a)+(b) GAP and (c-lite) close-factor grid
    uint256[4] internal LIS = [uint256(1.05e18), 1.08e18, 1.10e18, 1.15e18];
    uint256[3] internal UTILS = [uint256(70), 90, 99];

    function _gapShocks(bool uCol) internal pure returns (uint256[] memory sh) {
        if (!uCol) {
            sh = new uint256[](6); // AVAX -20 .. -70 percent (bp of pin)
            sh[0] = 8_000; sh[1] = 7_000; sh[2] = 6_000; sh[3] = 5_000; sh[4] = 4_000; sh[5] = 3_000;
        } else {
            sh = new uint256[](6); // AVAX +25 .. +100 (and +150, +200 beyond the task list)
            sh[0] = 12_500; sh[1] = 15_000; sh[2] = 17_500; sh[3] = 20_000; sh[4] = 25_000; sh[5] = 30_000;
        }
    }

    function _gapVariant(uint256 snapCell, Ctx memory x, uint256 li, uint256 closeF, uint256 shockBps, Agg memory agg) internal returns (Fin memory f) {
        vm.revertToState(snapCell);
        _setPrices(realAvaxAnswer, usdcAnswer);
        require(controller._setLiquidationIncentive(li) == 0, "li");
        require(controller._setCloseFactor(closeF) == 0, "close");
        x.li = li;
        x.closeF = closeF;
        _setAvaxBps(shockBps);
        Res memory r;
        uint256 nShort = _countShort();
        _clearStep(x, r, MAX_CALLS, agg);
        f = _fin(x, agg);
        (uint256 pred,) = _pred(x, shockBps);
        // harness cross-check: measured bad debt agrees with the closed form (1% of the debt at the shock plus USD 0.05)
        uint256 dShock = x.uCol ? Math.mulDiv(x.debt0Usd, shockBps, 1e4) : x.debt0Usd;
        if (_absDiff(f.badShock, pred) > dShock / 100 + 50_000) agg.predMismatch++;
        _emitCell("gap", x, r, f, shockBps, pred, nShort);
        agg.cells++;
    }

    function _gapGrid(bool uCol, uint256[] memory cfs) internal returns (Agg memory agg) {
        uint256 base = vm.snapshotState();
        uint256[] memory sh = _gapShocks(uCol);
        for (uint256 ci; ci < cfs.length; ++ci) {
            for (uint256 ui; ui < UTILS.length; ++ui) {
                Ctx memory x = _setup(base, uCol, cfs[ci], UTILS[ui], agg);
                uint256 snapCell = vm.snapshotState();
                for (uint256 si; si < sh.length; ++si) {
                    for (uint256 li; li < LIS.length; ++li) _gapVariant(snapCell, x, LIS[li], 0.5e18, sh[si], agg);
                    _gapVariant(snapCell, x, 1.08e18, 0.25e18, sh[si], agg);
                    _gapVariant(snapCell, x, 1.08e18, 0.9e18, sh[si], agg);
                }
            }
        }
        emit log_string(string.concat("RISK|SUMMARY|grid=gap|dir=", uCol ? "U" : "W", _kv("cells", agg.cells), _kv("setupFail", agg.setupFail), _kv("idViol", agg.idViol), _kv("acctViol", agg.acctViol), _kv("predMismatch", agg.predMismatch), "|END"));
        assertEq(agg.cells, cfs.length * UTILS.length * sh.length * (LIS.length + 2), "every cell emitted exactly one line");
        assertEq(agg.setupFail, 0, "every setup borrow succeeded");
        assertEq(agg.idViol, 0, "liquidation identities (seize = repay x incentive, 2.8% share, totalBorrows delta)");
        assertEq(agg.acctViol, 0, "market accounting identities");
        assertEq(agg.predMismatch, 0, "measured bad debt agrees with the closed form (harness check)");
    }

    function _cfs3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory v) {
        v = new uint256[](3);
        v[0] = a; v[1] = b; v[2] = c;
    }

    function _cfs2(uint256 a, uint256 b) internal pure returns (uint256[] memory v) {
        v = new uint256[](2);
        v[0] = a; v[1] = b;
    }

    function testRisk_Gap_W_cf30_40_50() public {
        if (!_init()) return;
        _gapGrid(false, _cfs3(3_000, 4_000, 5_000));
    }

    function testRisk_Gap_W_cf55_60_65() public {
        if (!_init()) return;
        _gapGrid(false, _cfs3(5_500, 6_000, 6_500));
    }

    function testRisk_Gap_W_cf70_75_80() public {
        if (!_init()) return;
        _gapGrid(false, _cfs3(7_000, 7_500, 8_000));
    }

    function testRisk_Gap_W_cf85_90() public {
        if (!_init()) return;
        _gapGrid(false, _cfs2(8_500, 9_000));
    }

    function testRisk_Gap_U_cf30_40_50() public {
        if (!_init()) return;
        _gapGrid(true, _cfs3(3_000, 4_000, 5_000));
    }

    function testRisk_Gap_U_cf55_60_65() public {
        if (!_init()) return;
        _gapGrid(true, _cfs3(5_500, 6_000, 6_500));
    }

    function testRisk_Gap_U_cf70_75_80() public {
        if (!_init()) return;
        _gapGrid(true, _cfs3(7_000, 7_500, 8_000));
    }

    function testRisk_Gap_U_cf85_90() public {
        if (!_init()) return;
        _gapGrid(true, _cfs2(8_500, 9_000));
    }

    // ================================================================= (a) GRADUAL paths with liquidation at each step
    function _pathVariant(uint256 snapCell, Ctx memory x, uint256 li, uint256 stepBps, uint256 k, Agg memory agg) internal {
        vm.revertToState(snapCell);
        _setPrices(realAvaxAnswer, usdcAnswer);
        require(controller._setLiquidationIncentive(li) == 0, "li");
        require(controller._setCloseFactor(0.5e18) == 0, "close");
        x.li = li;
        x.closeF = 0.5e18;
        Res memory r;
        uint256 limit = x.uCol ? 30_000 : 2_000;
        uint256 tgt = 10_000;
        uint256 step;
        uint256 nShortTotal;
        while (true) {
            step++;
            tgt = x.uCol ? _min(tgt + stepBps, limit) : (tgt > limit + stepBps ? tgt - stepBps : limit);
            _setAvaxBps(tgt);
            uint256 ns = _countShort();
            nShortTotal += ns;
            if (ns > 0 && r.firstShortStep == 0) r.firstShortStep = step;
            uint256 before = r.repaidUsd;
            _clearStep(x, r, k, agg);
            if (r.repaidUsd - before > r.peakStepUsd) r.peakStepUsd = r.repaidUsd - before;
            if (_countLiquidatable(x) > 0) r.backlogSteps++;
            if (tgt == limit) break;
        }
        r.steps = step;
        Fin memory f = _fin(x, agg);
        _emitCell(string.concat("path-k", _u(k), "-step", _u(stepBps)), x, r, f, tgt, 0, nShortTotal);
        agg.cells++;
    }

    function _pathGrid(bool uCol, uint256[] memory cfs) internal {
        Agg memory agg;
        uint256 base = vm.snapshotState();
        uint256[3] memory steps = uCol ? [uint256(1_000), 2_500, 5_000] : [uint256(500), 1_000, 2_000];
        uint256[2] memory utils = [uint256(90), 99];
        uint256[2] memory ks = [uint256(1), 4];
        uint256 expected;
        for (uint256 ci; ci < cfs.length; ++ci) {
            for (uint256 ui; ui < utils.length; ++ui) {
                Ctx memory x = _setup(base, uCol, cfs[ci], utils[ui], agg);
                uint256 snapCell = vm.snapshotState();
                for (uint256 si; si < steps.length; ++si) {
                    for (uint256 ki; ki < ks.length; ++ki) {
                        _pathVariant(snapCell, x, 1.08e18, steps[si], ks[ki], agg);
                        expected++;
                    }
                }
                // incentive sensitivity on the middle step, single liquidation call per step
                _pathVariant(snapCell, x, 1.05e18, steps[1], 1, agg);
                _pathVariant(snapCell, x, 1.15e18, steps[1], 1, agg);
                expected += 2;
            }
        }
        emit log_string(string.concat("RISK|SUMMARY|grid=path|dir=", uCol ? "U" : "W", _kv("cells", agg.cells), _kv("setupFail", agg.setupFail), _kv("idViol", agg.idViol), _kv("acctViol", agg.acctViol), "|END"));
        assertEq(agg.cells, expected, "every cell emitted exactly one line");
        assertEq(agg.setupFail, 0);
        assertEq(agg.idViol, 0);
        assertEq(agg.acctViol, 0);
    }

    function testRisk_Path_W() public {
        if (!_init()) return;
        uint256[] memory cfs = new uint256[](7);
        cfs[0] = 3_000; cfs[1] = 4_000; cfs[2] = 5_000; cfs[3] = 6_000; cfs[4] = 7_000; cfs[5] = 8_000; cfs[6] = 9_000;
        _pathGrid(false, cfs);
    }

    function testRisk_Path_U() public {
        if (!_init()) return;
        uint256[] memory cfs = new uint256[](8);
        cfs[0] = 3_000; cfs[1] = 4_000; cfs[2] = 5_000; cfs[3] = 6_000; cfs[4] = 7_000; cfs[5] = 7_500; cfs[6] = 8_000; cfs[7] = 9_000;
        _pathGrid(true, cfs);
    }

    // ================================================================= (c) STALE-FEED windows
    struct Actors {
        address p1;
        address p2;
        address erin;
        address q;
        address rr;
    }

    function _staleActors() internal returns (Actors memory a) {
        a.p1 = address(0xE001);
        a.p2 = address(0xE002);
        a.erin = address(0xE003);
        a.q = address(0xE004);
        a.rr = address(0xE005);
        _unpauseBorrows();
        _mintP(pWavax, a.p1, 1_000e18);
        _enter(a.p1);
        _mintP(pUsdc, a.p2, 20_000e6);
        _enter(a.p2);
        _mintP(pWavax, a.erin, 10e18);
        _enter(a.erin);
        _mintP(pWavax, a.q, Math.mulDiv(COLL_USD6 * 1e12, 1e8, uint256(realAvaxAnswer)));
        _enter(a.q);
        (, uint256 liq,) = controller.getAccountLiquidity(a.q);
        (bool ok,) = _borrow(pUsdc, a.q, liq * 99 / 100 / 1e12);
        require(ok, "q borrow");
        _mintP(pUsdc, a.rr, 10_000e6);
        _enter(a.rr);
        (, liq,) = controller.getAccountLiquidity(a.rr);
        (ok,) = _borrow(pWavax, a.rr, Math.mulDiv(liq * 99 / 100, 1e8, uint256(realAvaxAnswer)));
        require(ok, "r borrow");
        // Q and R are made liquidatable AT THE PIN PRICE (admin lowers the collateral factors): a stand-in for "an account that is already
        // underwater when the feed goes quiet". The liquidation probes then show whether the controller will act on it.
        require(controller._setCollateralFactor(PToken(address(pWavax)), 0.3e18) == 0, "cf w");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), 0.3e18) == 0, "cf u");
    }

    struct Flags {
        bool pW;
        bool pU;
        bool bU;
        bool bW;
        bool rd;
        bool rp;
        bool lW;
        bool lU;
        uint256 lWcode;
        uint256 lUcode;
        uint256 accruedPpm;
    }

    function _staleProbe(Actors memory a) internal returns (Flags memory fl) {
        fl.pW = oracle.getUnderlyingPrice(PToken(address(pWavax))) > 0;
        fl.pU = oracle.getUnderlyingPrice(PToken(address(pUsdc))) > 0;
        (fl.bU,) = _borrow(pUsdc, a.p1, 1e6);
        (fl.bW,) = _borrow(pWavax, a.p2, 1e16);
        (fl.rd,) = _redeemUnderlying(pWavax, a.erin, 1e16);
        (fl.rp,) = _repay(pUsdc, a.q, 1e6);
        (fl.lW, fl.lWcode,) = _liquidate(pUsdc, pWavax, a.q, 1e6);
        (fl.lU, fl.lUcode,) = _liquidate(pWavax, pUsdc, a.rr, 1e16);
    }

    function _staleRow(uint256 snap, uint32 maxAvax, uint32 maxUsdc, uint256 d, Actors memory a) internal returns (uint256 viol) {
        vm.revertToState(snap);
        _setPrices(realAvaxAnswer, usdcAnswer); // fresh round stamped "now" (the last update before the quiet period)
        inner.configureFeed(WAVAX, AVAX_FEED, maxAvax);
        inner.configureFeed(USDC, USDC_FEED, maxUsdc);
        uint256 qBefore = pUsdc.borrowBalanceStored(a.q);
        vm.warp(block.timestamp + d);
        vm.roll(block.number + d); // one block per second, the fixture's rate-model assumption
        uint256 accrued = (pUsdc.borrowBalanceCurrent(a.q) - qBefore) * 1e6 / qBefore;
        Flags memory fl = _staleProbe(a);
        string memory s = string.concat("RISK|STALE", _kv("maxAvax", maxAvax), _kv("maxUsdc", maxUsdc), _kv("d", d));
        s = string.concat(s, _kv("priceW", fl.pW ? 1 : 0), _kv("priceU", fl.pU ? 1 : 0), _kv("borrowUsdc", fl.bU ? 1 : 0), _kv("borrowWavax", fl.bW ? 1 : 0));
        s = string.concat(s, _kv("entrantRedeem", fl.rd ? 1 : 0), _kv("repay", fl.rp ? 1 : 0), _kv("liqW", fl.lW ? 1 : 0), _kv("liqWcode", fl.lWcode), _kv("liqU", fl.lU ? 1 : 0), _kv("liqUcode", fl.lUcode));
        emit log_string(string.concat(s, _kv("accruedPpm", accrued), "|END"));
        // fail-closed semantics (behaviour identities, the documented availability cost): every price-dependent action needs BOTH prices
        bool both = d <= maxAvax && d <= maxUsdc;
        if (fl.pW != (d <= maxAvax) || fl.pU != (d <= maxUsdc)) viol++;
        if (fl.bU != both || fl.bW != both || fl.rd != both || fl.lW != both || fl.lU != both) viol++;
        if (!fl.rp) viol++; // repay is never blocked
        if (!both && (fl.lWcode != PRICE_ERROR_CODE || fl.lUcode != PRICE_ERROR_CODE)) viol++;
    }

    function testRisk_Stale_AvailabilityMatrix() public {
        if (!_init()) return;
        Actors memory a = _staleActors();
        uint256 snap = vm.snapshotState();
        uint256 viol;
        uint256 rows;
        // (AVAX max age, USDC max age, quiet period D): D around each max age; 1,200 / 90,000 are the fixture (production candidates) values
        uint256[3][14] memory t = [
            [uint256(300), 90_000, 150], [uint256(300), 90_000, 301], [uint256(300), 90_000, 3_600],
            [uint256(1_200), 90_000, 600], [uint256(1_200), 90_000, 1_201], [uint256(1_200), 90_000, 5_000], [uint256(1_200), 90_000, 89_000], [uint256(1_200), 90_000, 90_001],
            [uint256(3_600), 90_000, 1_800], [uint256(3_600), 90_000, 3_601], [uint256(3_600), 90_000, 7_200],
            [uint256(90_000), 90_000, 45_000], [uint256(90_000), 90_000, 90_001],
            [uint256(1_000_000), 90_000, 90_001] // AVAX tolerant, USDC alone stale
        ];
        for (uint256 i; i < t.length; ++i) {
            viol += _staleRow(snap, uint32(t[i][0]), uint32(t[i][1]), t[i][2], a);
            rows++;
        }
        emit log_string(string.concat("RISK|SUMMARY|grid=stale-availability", _kv("rows", rows), _kv("behaviourViolations", viol), "|END"));
        assertEq(rows, 14);
        assertEq(viol, 0, "fail-closed behaviour as documented (price needed for borrow, entrant redeem, liquidation; repay always works)");
    }

    /// @dev Positions opened at the STALE price just before the feed refreshes, then the refresh brings an instant shock.
    function _staleOpen(uint256 base, bool uCol, uint256 cfBps, uint32 maxAvax, uint256 d, uint256 shock, Agg memory agg) internal {
        Ctx memory x = _setup(base, uCol, cfBps, 90, agg);
        require(controller._setLiquidationIncentive(1.08e18) == 0 && controller._setCloseFactor(0.5e18) == 0, "params");
        x.li = 1.08e18;
        x.closeF = 0.5e18;
        inner.configureFeed(WAVAX, AVAX_FEED, maxAvax);
        vm.warp(block.timestamp + d);
        vm.roll(block.number + d);
        address atk = address(0x9100);
        bool opened;
        (uint256 err, uint256 liq,) = controller.getAccountLiquidity(atk);
        // the attacker deposits the collateral first (needs no price), then borrows at 99% of the (stale-priced) borrowing power
        _mintP(x.colM, atk, uCol ? COLL_USD6 : Math.mulDiv(COLL_USD6 * 1e12, 1e8, uint256(realAvaxAnswer)));
        _enter(atk);
        (err, liq,) = controller.getAccountLiquidity(atk);
        uint256 lateDebt;
        if (err == 0 && liq > 0) {
            uint256 amt = uCol ? Math.mulDiv(liq * 99 / 100, 1e8, uint256(realAvaxAnswer)) : liq * 99 / 100 / 1e12;
            (opened,) = _borrow(x.debtM, atk, amt);
            if (opened) {
                bs.push(atk);
                lateDebt = _usd6(x.debtAsset, x.debtM.borrowBalanceStored(atk));
            }
        }
        _setAvaxBps(shock); // the refresh: fresh round at the shocked price
        Res memory r;
        _clearStep(x, r, MAX_CALLS, agg);
        uint256 badLate;
        uint256 badPre;
        for (uint256 i; i < bs.length; ++i) {
            uint256 left = _usd6(x.debtAsset, x.debtM.borrowBalanceStored(bs[i]));
            uint256 coll = _usd6(x.colAsset, _colUnits(x.colM, x.colM.balanceOf(bs[i])));
            uint256 bad = left > coll ? left - coll : 0;
            if (opened && i == bs.length - 1) badLate = bad;
            else badPre += bad;
        }
        string memory s = string.concat("RISK|STALEOPEN|dir=", uCol ? "U" : "W", _kv("cf", cfBps), _kv("maxAvax", maxAvax), _kv("d", d), _kv("shock", shock));
        s = string.concat(s, _kv("staleBorrowAllowed", opened ? 1 : 0), _kv("lateDebtUsd", lateDebt), _kv("badPreUsd", badPre), _kv("badLateUsd", badLate), "|END");
        emit log_string(s);
        agg.cells++;
    }

    function testRisk_Stale_OpenAtStalePriceThenRefreshShock() public {
        if (!_init()) return;
        Agg memory agg;
        uint256 base = vm.snapshotState();
        uint256[3] memory ds = [uint256(600), 1_201, 5_000]; // before the 1,200 s max age, just after, well after
        uint256 expected;
        for (uint256 dirI; dirI < 2; ++dirI) {
            bool uCol = dirI == 1;
            uint256 cf = uCol ? 7_500 : 6_000;
            uint256[2] memory shocks = uCol ? [uint256(17_500), 20_000] : [uint256(6_000), 4_000];
            for (uint256 si; si < 2; ++si) {
                for (uint256 di; di < 3; ++di) {
                    _staleOpen(base, uCol, cf, 1_200, ds[di], shocks[si], agg);
                    expected++;
                }
                _staleOpen(base, uCol, cf, 90_000, 45_000, shocks[si], agg); // loose AVAX max age: the stale price is still accepted 12.5 hours later
                expected++;
            }
        }
        assertEq(agg.cells, expected);
        assertEq(agg.setupFail, 0);
        assertEq(agg.idViol, 0);
    }

    // ================================================================= market utilisation, the cash floor, and exits
    function _pushMarketUtil(Ctx memory x, uint256 targetBp, uint256 floorBp) internal returns (uint256 realBp, bool floorHit) {
        PErc20Delegator m = x.colM;
        address whale = address(0xDEAD0002);
        if (x.uCol) _mintP(pWavax, whale, 120_000e18);
        else _mintP(pUsdc, whale, 2_000_000e6);
        _enter(whale);
        uint256 supplyUnits = m.getCash() + m.totalBorrows() - m.totalReserves();
        uint256 floor = supplyUnits * floorBp / 1e4;
        if (floor > 0) require(ctrlA._setBorrowCashFloor(PToken(address(m)), floor) == 0, "floor");
        uint256 desired = supplyUnits * targetBp / 1e4;
        uint256 cash = m.getCash();
        uint256 amt = desired > m.totalBorrows() ? desired - m.totalBorrows() : 0;
        if (amt > cash) amt = cash;
        if (amt > 0) {
            (bool ok,) = _borrow(m, whale, amt);
            if (!ok) {
                floorHit = true;
                uint256 allowed = cash > floor ? cash - floor : 0;
                if (allowed > 0) {
                    (ok,) = _borrow(m, whale, allowed);
                    require(ok, "borrow down to the floor");
                }
            }
        }
        realBp = _mktUtilBp(m);
    }

    function _exitCell(uint256 base, bool uCol, uint256 targetBp, uint256 floorBp, Agg memory agg) internal {
        Ctx memory x = _setup(base, uCol, uCol ? 7_500 : 6_000, 99, agg);
        (uint256 realBp, bool hit) = _pushMarketUtil(x, targetBp, floorBp);
        require(controller._setLiquidationIncentive(1.08e18) == 0 && controller._setCloseFactor(0.5e18) == 0, "params");
        x.li = 1.08e18;
        x.closeF = 0.5e18;
        uint256 shock = uCol ? 20_000 : 5_000; // AVAX +100% / -50%: the worst gap with a clean liquidation of every borrower
        _setAvaxBps(shock);
        Res memory r;
        _clearStep(x, r, MAX_CALLS, agg);
        Fin memory f = _fin(x, agg);
        uint256 claim = f.carolClaimUnits;
        uint256 cash = x.colM.getCash();
        uint256 lpClaim = _colUnits(x.colM, x.colM.balanceOf(LP));
        uint256 snap = vm.snapshotState();
        // (a) the liquidator redeems first
        uint256 redeemable = _min(cash, claim);
        bool okA = true;
        if (redeemable > 0) (okA,) = _redeemUnderlying(x.colM, CAROL, redeemable);
        uint256 carolBp = claim == 0 ? 0 : redeemable * 1e4 / claim;
        vm.revertToState(snap);
        // (b) the supplier LP withdraws first (a run), then the liquidator
        uint256 lpOut = _min(cash, lpClaim);
        bool okB = true;
        if (lpOut > 0) (okB,) = _redeemUnderlying(x.colM, LP, lpOut);
        uint256 cash2 = x.colM.getCash();
        uint256 carolAfter = claim == 0 ? 0 : _min(cash2, claim) * 1e4 / claim;
        string memory s = string.concat("RISK|EXIT|dir=", uCol ? "U" : "W", _kv("floorBp", floorBp), _kv("targetBp", targetBp), _kv("realUtilBp", realBp), _kv("floorHit", hit ? 1 : 0));
        s = string.concat(s, _kv("colCashAfter", cash), _kv("carolClaim", claim), _kv("carolRedeemBp", carolBp), _kv("lpClaim", lpClaim), _kv("lpRedeemBp", lpClaim == 0 ? 0 : lpOut * 1e4 / lpClaim));
        s = string.concat(s, _kv("carolAfterLpRunBp", carolAfter), _kv("badShock", f.badShock), _kv("debtMktExitShort", f.exitShort), "|END");
        emit log_string(s);
        assertTrue(okA && okB, "redeems of the computed available amounts succeed");
        agg.cells++;
    }

    function testRisk_Exit_MarketUtilisationAndCashFloor() public {
        if (!_init()) return;
        Agg memory agg;
        uint256 base = vm.snapshotState();
        uint256[5] memory targets = [uint256(0), 5_000, 8_000, 9_500, 10_000];
        uint256[4] memory floors = [uint256(0), 500, 1_000, 2_000];
        uint256 expected;
        for (uint256 dirI; dirI < 2; ++dirI) {
            for (uint256 ti; ti < targets.length; ++ti) {
                for (uint256 fi; fi < floors.length; ++fi) {
                    _exitCell(base, dirI == 1, targets[ti], floors[fi], agg);
                    expected++;
                }
            }
        }
        assertEq(agg.cells, expected);
        assertEq(agg.setupFail, 0);
        assertEq(agg.idViol, 0);
        assertEq(agg.acctViol, 0);
    }

    // ================================================================= rate-model shapes and reserve accrual (SYNTHETIC shapes)
    function _shape(uint256 i) internal returns (ConfigurableJumpRateModelV2) {
        // (base, multiplier, jump multiplier, kink) per year; shape 0 is the fixture placeholder
        if (i == 0) return new ConfigurableJumpRateModelV2(31_536_000, 0.02e18, 0.1e18, 1e18, 0.8e18, address(this));
        if (i == 1) return new ConfigurableJumpRateModelV2(31_536_000, 0, 0.08e18, 2e18, 0.9e18, address(this));
        return new ConfigurableJumpRateModelV2(31_536_000, 0.02e18, 0.15e18, 3e18, 0.7e18, address(this));
    }

    function _accrRun(uint256 snap, ConfigurableJumpRateModelV2 m, uint256 sh, uint256 rf, uint256 util, uint256 blocks) internal {
        vm.revertToState(snap);
        require(PToken(address(pUsdc))._setInterestRateModel(m) == 0, "irm");
        require(PErc20(address(pUsdc))._setReserveFactor(rf) == 0, "rf");
        uint256 b0 = pUsdc.totalBorrows();
        uint256 r0 = pUsdc.totalReserves();
        uint256 rate = m.getBorrowRate(pUsdc.getCash(), b0, r0);
        vm.roll(block.number + blocks);
        pUsdc.accrueInterest();
        uint256 dB = pUsdc.totalBorrows() - b0;
        uint256 dR = pUsdc.totalReserves() - r0;
        assertLe(_absDiff(dB, Math.mulDiv(b0, rate * blocks, 1e18)), 2, "interest = borrows x rate x blocks");
        assertLe(_absDiff(dR, Math.mulDiv(dB, rf, 1e18)), 2, "reserves = interest x reserve factor");
        string memory s = string.concat("RISK|ACCR|shape=", _u(sh), _kv("rfBp", rf / 1e14), _kv("utilPct", util), _kv("borrows0", b0), _kv("dBorrows", dB), _kv("dReserves", dR));
        emit log_string(string.concat(s, _kv("reserveBpOfBorrowsPerYear", dR * (31_536_000 / blocks) * 1e4 / b0), "|END"));
    }

    function testRisk_RateModels_ReserveAccrual() public {
        if (!_init()) return;
        ConfigurableJumpRateModelV2[3] memory shapes = [_shape(0), _shape(1), _shape(2)]; // created BEFORE the snapshot so they survive reverts
        uint256 base = vm.snapshotState();
        uint256[3] memory rfs = [uint256(0.05e18), 0.10e18, 0.20e18];
        uint256[7] memory pts = [uint256(20), 50, 70, 80, 90, 95, 99];
        uint256 lines;
        // (1) the rate model alone (pure view calls on the real contract): borrow APR, supply APR and the reserve accrual rate on borrows
        for (uint256 sh; sh < 3; ++sh) {
            ConfigurableJumpRateModelV2 m = shapes[sh];
            for (uint256 pi; pi < pts.length; ++pi) {
                uint256 rate = m.getBorrowRate(100e18 - pts[pi] * 1e18, pts[pi] * 1e18, 0);
                uint256 aprBp = rate * 31_536_000 * 1e4 / 1e18;
                for (uint256 ri; ri < rfs.length; ++ri) {
                    uint256 supBp = m.getSupplyRate(100e18 - pts[pi] * 1e18, pts[pi] * 1e18, 0, rfs[ri]) * 31_536_000 * 1e4 / 1e18;
                    string memory s = string.concat("RISK|IRM|shape=", _u(sh), _kv("utilPct", pts[pi]), _kv("rfBp", rfs[ri] / 1e14), _kv("borrowAprBp", aprBp));
                    emit log_string(string.concat(s, _kv("supplyAprBp", supBp), _kv("reserveAprOnBorrowsBp", aprBp * rfs[ri] / 1e18), "|END"));
                    lines++;
                }
            }
        }
        assertEq(lines, 3 * 7 * 3);
        // (2) the same on the fork: real accrueInterest on pUSDC over 100,000 blocks, scaled to a year (identity: reserves = interest x reserve factor)
        uint256 blocks = 100_000;
        uint256 runs;
        uint256[3] memory utils = [uint256(50), 80, 95];
        for (uint256 ui; ui < utils.length; ++ui) {
            vm.revertToState(base);
            _setPrices(realAvaxAnswer, usdcAnswer);
            _unpauseBorrows();
            address whale = address(0xDEAD0003);
            _mintP(pWavax, whale, 120_000e18);
            _enter(whale);
            uint256 supplyUnits = pUsdc.getCash() + pUsdc.totalBorrows() - pUsdc.totalReserves();
            (bool ok,) = _borrow(pUsdc, whale, supplyUnits * utils[ui] / 100);
            require(ok, "whale borrow");
            uint256 snap = vm.snapshotState();
            for (uint256 sh; sh < 3; ++sh) {
                ConfigurableJumpRateModelV2 m = shapes[sh];
                for (uint256 ri; ri < rfs.length; ++ri) {
                    _accrRun(snap, m, sh, rfs[ri], utils[ui], blocks);
                    runs++;
                }
            }
        }
        assertEq(runs, 27);
    }

    // ================================================================= reserve-first / who bears a loss in a plain market
    function testRisk_ReserveFirst_ExitIdentity() public {
        if (!_init()) return;
        Agg memory agg;
        uint256 base = vm.snapshotState();
        Ctx memory x = _setup(base, false, 6_000, 99, agg);
        require(controller._setLiquidationIncentive(1.08e18) == 0 && controller._setCloseFactor(0.5e18) == 0, "params");
        x.li = 1.08e18;
        x.closeF = 0.5e18;
        uint256 exch0 = pUsdc.exchangeRateStored();
        uint256 claims0 = _claims(pUsdc);
        _setAvaxBps(5_000); // AVAX -50%: bad debt in USDC
        Res memory r;
        _clearStep(x, r, MAX_CALLS, agg);
        Fin memory f = _fin(x, agg);
        uint256 exch1 = pUsdc.exchangeRateStored();
        uint256 loss = f.debtLeftUnits; // every remaining borrow is unrecoverable (collateral exhausted)
        emit log_string(string.concat("RISK|RESFIRST|case=no-markdown", _kv("exchRateBefore", exch0), _kv("exchRateAfter", exch1), _kv("claimsBefore", claims0), _kv("claimsAfter", _claims(pUsdc)), _kv("cashAfter", f.cash), _kv("lossUnits", loss), _kv("residColl", f.residColl), "|END"));
        assertLe(_absDiff(exch0, exch1), 2, "bad debt does NOT lower the exchange rate: the unpaid borrow still counts as an asset");
        assertGt(loss, 0, "the scenario produced bad debt");
        assertEq(f.residColl, 0, "no account with collateral left");
        uint256 snap = vm.snapshotState();
        uint256[4] memory rs = [uint256(0), loss / 2, loss * 101 / 100, loss * 2];
        address treasury = address(0x7EA5);
        for (uint256 i; i < rs.length; ++i) {
            vm.revertToState(snap);
            if (rs[i] > 0) {
                deal(USDC, treasury, rs[i]);
                vm.startPrank(treasury);
                IERC20(USDC).approve(address(pUsdc), rs[i]);
                require(PErc20(address(pUsdc))._addReserves(rs[i]) == 0, "add reserves");
                vm.stopPrank();
            }
            uint256 cash = pUsdc.getCash();
            uint256 claims = _claims(pUsdc);
            uint256 short = claims > cash ? claims - cash : 0;
            uint256 lpTokens = pUsdc.balanceOf(LP);
            uint256 lpClaim = _colUnits(pUsdc, lpTokens);
            uint256 before = IERC20(USDC).balanceOf(LP);
            (bool ok,) = _try(LP, address(pUsdc), abi.encodeWithSelector(PErc20.redeem.selector, lpTokens));
            uint256 got = IERC20(USDC).balanceOf(LP) - before;
            string memory s = string.concat("RISK|RESFIRST|case=reserves-added", _kv("addedReserves", rs[i]), _kv("lossUnits", loss), _kv("totalReserves", pUsdc.totalReserves()), _kv("cash", cash), _kv("claims", claims));
            emit log_string(string.concat(s, _kv("exitShortfall", short), _kv("lpFullExitOk", ok ? 1 : 0), _kv("lpClaim", lpClaim), _kv("lpGot", got), "|END"));
            uint256 expectShort = loss > rs[i] ? loss - rs[i] : 0;
            assertLe(_absDiff(short, expectShort), loss / 1_000_000 + 10, "exit shortfall = max(0, loss - reserves held in the market)");
            if (rs[i] >= loss * 101 / 100) assertTrue(ok, "reserves >= loss: the last supplier can exit in full");
            else assertFalse(ok, "reserves < loss: a full exit is not possible");
        }
        // option: the treasury repays the unrecoverable borrows ON BEHALF of the exhausted accounts (existing function, no code change)
        vm.revertToState(snap);
        deal(USDC, treasury, loss * 2);
        vm.startPrank(treasury);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        uint256 paid;
        for (uint256 i; i < bs.length; ++i) {
            uint256 owed = pUsdc.borrowBalanceCurrent(bs[i]);
            if (owed == 0) continue;
            require(pUsdc.repayBorrowBehalf(bs[i], owed) == 0, "repay behalf");
            paid += owed;
        }
        vm.stopPrank();
        uint256 cashB = pUsdc.getCash();
        uint256 claimsB = _claims(pUsdc);
        (bool okB,) = _try(LP, address(pUsdc), abi.encodeWithSelector(PErc20.redeem.selector, pUsdc.balanceOf(LP)));
        emit log_string(string.concat("RISK|RESFIRST|case=treasury-repays-on-behalf", _kv("paidUnits", paid), _kv("lossUnits", loss), _kv("cash", cashB), _kv("claims", claimsB), _kv("lpFullExitOk", okB ? 1 : 0), _kv("totalBorrowsAfter", pUsdc.totalBorrows()), "|END"));
        assertLe(_absDiff(paid, loss), loss / 1_000_000 + 10, "the treasury pays exactly the unrecoverable debt");
        assertTrue(okB, "after the on-behalf repayment the last supplier exits in full");
    }

    // ================================================================= price-ratio equivalence (USDC depeg == AVAX rise)
    function testRisk_RatioEquivalence_UsdcDepegVsAvaxRise() public {
        if (!_init()) return;
        Agg memory agg;
        uint256 base = vm.snapshotState();
        Ctx memory x = _setup(base, true, 7_500, 99, agg);
        uint256 snap = vm.snapshotState();
        Fin memory fa = _gapVariant(snap, x, 1.08e18, 0.5e18, 20_000, agg); // AVAX x2, USDC 1.0
        // (b) USDC halves, AVAX unchanged: the same price ratio
        vm.revertToState(snap);
        _setPrices(realAvaxAnswer, usdcAnswer / 2);
        Res memory r;
        _clearStep(x, r, MAX_CALLS, agg);
        Fin memory fb = _fin(x, agg);
        uint256 aBp = fa.badUnits * 1e4 / x.debt0;
        uint256 bBp = fb.badUnits * 1e4 / x.debt0;
        emit log_string(string.concat("RISK|EQV|case=AVAXx2-vs-USDCx0.5", _kv("badFracOfDebtBp_avaxUp", aBp), _kv("badFracOfDebtBp_usdcDown", bBp), "|END"));
        assertLe(_absDiff(aBp, bBp), 20, "bad debt as a share of the debt is the same for the same price ratio");
        assertEq(agg.idViol, 0);
    }

    // ================================================================= gas of a liquidation and of the redemption of the seized claim
    function _cool(Ctx memory x, address borrower) internal {
        address[16] memory a = [
            address(x.debtM), address(x.colM), address(controller), address(oracle), address(inner), AVAX_FEED, USDC_FEED, USDC, WAVAX, CAROL, borrower,
            PErc20Delegator(payable(address(x.debtM))).implementation(), unitroller.peridottrollerImplementation(),
            address(uint160(uint256(vm.load(USDC, 0x7050c9e0f4ca769c69bd3a8ef740bc37934f8e2c036e5a723fd8ee048ed3f8c3)))),
            _aggregatorOf(AVAX_FEED), _aggregatorOf(USDC_FEED)
        ];
        for (uint256 i; i < a.length; ++i) if (a[i] != address(0)) vm.cool(a[i]);
    }

    function _aggregatorOf(address feed) internal view returns (address agg) {
        (bool ok, bytes memory ret) = feed.staticcall(abi.encodeWithSignature("aggregator()"));
        if (ok && ret.length == 32) agg = abi.decode(ret, (address));
    }

    function _gasRun(bool uCol, uint256 mode, uint256 snap, address b, Ctx memory x) internal returns (uint256 gLiq, uint256 gRedeem) {
        vm.revertToState(snap);
        if (mode == 0) _setPrices(realAvaxAnswer, usdcAnswer); // mocked feeds (what every other cell uses)
        uint256 repay = x.debtM.borrowBalanceStored(b) / 4;
        deal(x.debtAsset, CAROL, repay);
        vm.prank(CAROL);
        IERC20(x.debtAsset).approve(address(x.debtM), repay);
        if (mode == 2) _cool(x, b);
        uint256 g = gasleft();
        vm.prank(CAROL);
        (bool s, bytes memory ret) = address(x.debtM).call(abi.encodeWithSelector(PErc20.liquidateBorrow.selector, b, repay, address(x.colM)));
        gLiq = g - gasleft();
        require(s && abi.decode(ret, (uint256)) == 0, "gas liquidation failed");
        if (mode == 2) _cool(x, b);
        uint256 tokens = x.colM.balanceOf(CAROL);
        g = gasleft();
        vm.prank(CAROL);
        (s, ret) = address(x.colM).call(abi.encodeWithSelector(PErc20.redeem.selector, tokens));
        gRedeem = g - gasleft();
        require(s && abi.decode(ret, (uint256)) == 0, "gas redeem failed");
        uCol;
    }

    function testRisk_Gas_LiquidationAndRedemption() public {
        if (!_init()) return;
        for (uint256 d; d < 2; ++d) {
            bool uCol = d == 1;
            // NO feed mocks yet: real Chainlink rounds at the pin block. Liquidatable by lowering the collateral factor (price unchanged).
            Ctx memory x;
            x.uCol = uCol;
            x.colM = uCol ? pUsdc : pWavax;
            x.debtM = uCol ? pWavax : pUsdc;
            x.colAsset = uCol ? USDC : WAVAX;
            x.debtAsset = uCol ? WAVAX : USDC;
            x.li = 1.08e18;
            _unpauseBorrows();
            address b = address(uint160(0x9300 + d));
            _mintP(x.colM, b, uCol ? COLL_USD6 : Math.mulDiv(COLL_USD6 * 1e12, 1e8, uint256(realAvaxAnswer)));
            _enter(b);
            (, uint256 liq,) = controller.getAccountLiquidity(b);
            uint256 amt = uCol ? Math.mulDiv(liq * 99 / 100, 1e8, uint256(realAvaxAnswer)) : liq * 99 / 100 / 1e12;
            (bool ok,) = _borrow(x.debtM, b, amt);
            require(ok, "borrow");
            require(controller._setCollateralFactor(PToken(address(x.colM)), 0.3e18) == 0, "cf");
            (, , uint256 sf) = controller.getAccountLiquidity(b);
            require(sf > 0, "liquidatable");
            uint256 snap = vm.snapshotState();
            // order matters: the mocked run installs mocks that persist, so it goes last
            (uint256 l1, uint256 r1) = _gasRun(uCol, 1, snap, b, x);
            (uint256 l2, uint256 r2) = _gasRun(uCol, 2, snap, b, x);
            (uint256 l0, uint256 r0) = _gasRun(uCol, 0, snap, b, x);
            emit log_string(string.concat("RISK|GAS|dir=", uCol ? "U" : "W", _kv("liqMockedWarm", l0), _kv("liqRealWarm", l1), _kv("liqRealCold", l2), _kv("redeemMockedWarm", r0), _kv("redeemRealWarm", r1), _kv("redeemRealCold", r2), "|END"));
            assertGt(l1, 0);
            assertGt(l2, l1 - 1, "cold access costs at least as much as warm");
            vm.clearMockedCalls();
            vm.revertToState(snap);
        }
    }

    // ================================================================= monitoring metrics: each failure mode flips its metric
    struct Mon {
        uint256 ageAvax;
        uint256 maxAvax;
        uint256 ageUsdc;
        uint256 maxUsdc;
        bool zeroW;
        bool zeroU;
        uint256 utilW;
        uint256 utilU;
        uint256 capUseW;
        uint256 capUseU;
        uint256 headroomW; // cash - floor, 0 when at/below the floor
        uint256 headroomU;
        bool belowFloorW;
        bool belowFloorU;
        uint256 errAccts;
        uint256 nShort;
        uint256 shortfall18;
        uint256 badDebt18;
        uint256 reservesW;
        uint256 reservesU;
        uint256 needU; // liquidator inventory required = sum of close factor x debt of accounts in shortfall (debt-asset units)
        uint256 needW;
        bool liqUnderfundedU;
        bool liqUnderfundedW;
    }

    function _age(address feed) internal view returns (uint256) {
        (, , , uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        return block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
    }

    function _mon(string memory phase) internal returns (Mon memory m) {
        (, uint32 mA,,) = inner.feeds(WAVAX);
        (, uint32 mU,,) = inner.feeds(USDC);
        m.ageAvax = _age(AVAX_FEED);
        m.maxAvax = mA;
        m.ageUsdc = _age(USDC_FEED);
        m.maxUsdc = mU;
        uint256 pW = oracle.getUnderlyingPrice(PToken(address(pWavax)));
        uint256 pU = oracle.getUnderlyingPrice(PToken(address(pUsdc)));
        m.zeroW = pW == 0;
        m.zeroU = pU == 0;
        m.utilW = _mktUtilBp(pWavax);
        m.utilU = _mktUtilBp(pUsdc);
        uint256 capW = controller.borrowCaps(address(pWavax));
        uint256 capU = controller.borrowCaps(address(pUsdc));
        m.capUseW = capW == 0 ? 0 : pWavax.totalBorrows() * 1e4 / capW;
        m.capUseU = capU == 0 ? 0 : pUsdc.totalBorrows() * 1e4 / capU;
        uint256 fW = ctrlA.borrowCashFloor(address(pWavax));
        uint256 fU = ctrlA.borrowCashFloor(address(pUsdc));
        m.belowFloorW = fW > 0 && pWavax.getCash() < fW;
        m.belowFloorU = fU > 0 && pUsdc.getCash() < fU;
        m.headroomW = pWavax.getCash() > fW ? pWavax.getCash() - fW : 0;
        m.headroomU = pUsdc.getCash() > fU ? pUsdc.getCash() - fU : 0;
        for (uint256 i; i < bs.length; ++i) {
            (uint256 err, , uint256 sf) = controller.getAccountLiquidity(bs[i]);
            if (err != 0) m.errAccts++;
            if (sf > 0) {
                m.nShort++;
                m.shortfall18 += sf;
                m.needU += Math.mulDiv(pUsdc.borrowBalanceStored(bs[i]), controller.closeFactorMantissa(), 1e18);
                m.needW += Math.mulDiv(pWavax.borrowBalanceStored(bs[i]), controller.closeFactorMantissa(), 1e18);
            }
            if (pW > 0 && pU > 0) {
                uint256 coll = (_colUnits(pWavax, pWavax.balanceOf(bs[i])) * pW + _colUnits(pUsdc, pUsdc.balanceOf(bs[i])) * pU) / 1e18;
                uint256 debt = (pWavax.borrowBalanceStored(bs[i]) * pW + pUsdc.borrowBalanceStored(bs[i]) * pU) / 1e18;
                if (debt > coll) m.badDebt18 += debt - coll;
            }
        }
        m.reservesW = pWavax.totalReserves();
        m.reservesU = pUsdc.totalReserves();
        m.liqUnderfundedU = IERC20(USDC).balanceOf(CAROL) < m.needU || IERC20(USDC).allowance(CAROL, address(pUsdc)) < m.needU;
        m.liqUnderfundedW = IERC20(WAVAX).balanceOf(CAROL) < m.needW || IERC20(WAVAX).allowance(CAROL, address(pWavax)) < m.needW;
        string memory s = string.concat("RISK|MON|phase=", phase, _kv("ageAvax", m.ageAvax), _kv("maxAvax", m.maxAvax), _kv("ageUsdc", m.ageUsdc), _kv("maxUsdc", m.maxUsdc), _kv("zeroSentinelW", m.zeroW ? 1 : 0), _kv("zeroSentinelU", m.zeroU ? 1 : 0));
        s = string.concat(s, _kv("utilW", m.utilW), _kv("utilU", m.utilU), _kv("capUseWbp", m.capUseW), _kv("capUseUbp", m.capUseU), _kv("headroomU", m.headroomU), _kv("belowFloorU", m.belowFloorU ? 1 : 0), _kv("accountsPriceError", m.errAccts));
        s = string.concat(s, _kv("accountsShort", m.nShort), _kv("shortfall18", m.shortfall18), _kv("badDebt18", m.badDebt18), _kv("reservesU", m.reservesU), _kv("needU", m.needU), _kv("needW", m.needW), _kv("liqUnderfundedU", m.liqUnderfundedU ? 1 : 0), "|END");
        emit log_string(s);
    }

    function testRisk_Monitoring_EachFailureFlipsItsMetric() public {
        if (!_init()) return;
        Agg memory agg;
        uint256 base = vm.snapshotState();
        Ctx memory x = _setup(base, false, 6_000, 90, agg);
        uint256 snap0 = vm.snapshotState();
        Mon memory m = _mon("healthy");
        assertEq(m.errAccts + m.nShort, 0, "healthy: no shortfall, no price errors");
        assertTrue(!m.zeroW && !m.zeroU && m.ageAvax <= m.maxAvax && m.ageUsdc <= m.maxUsdc && m.badDebt18 == 0 && !m.belowFloorU);
        // 1. feed freshness: age above max age
        vm.warp(block.timestamp + m.maxAvax + 1);
        m = _mon("feed-age-over-max");
        assertTrue(m.ageAvax > m.maxAvax, "feed age metric flips");
        assertTrue(m.zeroW && m.errAccts == N, "zero sentinel and price-error accounts follow");
        // 2. zero sentinel with a FRESH round (answer 0): the age metric stays green, the sentinel metric flips
        vm.revertToState(snap0);
        _setPrices(0, usdcAnswer);
        m = _mon("zero-answer-fresh-round");
        assertTrue(m.ageAvax <= m.maxAvax && m.zeroW && m.errAccts == N, "sentinel flips while the age metric stays green");
        // 3. price gap: shortfall accounts, inventory requirement, liquidator under-funded (CAROL empty), then bad debt after liquidation
        vm.revertToState(snap0);
        _setPrices(realAvaxAnswer, usdcAnswer);
        _setAvaxBps(4_000);
        m = _mon("gap-AVAX-minus-60pct");
        assertEq(m.nShort, N);
        assertTrue(m.shortfall18 > 0 && m.needU > 0 && m.liqUnderfundedU, "shortfall metric and liquidator under-funded flag flip");
        deal(USDC, CAROL, m.needU);
        vm.prank(CAROL);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        m = _mon("liquidator-funded");
        assertTrue(!m.liqUnderfundedU, "funding the inventory clears the flag");
        require(controller._setLiquidationIncentive(1.08e18) == 0 && controller._setCloseFactor(0.5e18) == 0, "params");
        x.li = 1.08e18;
        x.closeF = 0.5e18;
        Res memory r;
        _clearStep(x, r, MAX_CALLS, agg);
        m = _mon("after-liquidation");
        assertTrue(m.badDebt18 > 0, "borrows above collateral are visible after the liquidator has done its best");
        // 4. utilisation vs cap
        vm.revertToState(snap0);
        _setPrices(realAvaxAnswer, usdcAnswer);
        uint256[] memory capMarkets = new uint256[](1);
        capMarkets[0] = pUsdc.totalBorrows() * 105 / 100;
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        controller._setMarketBorrowCaps(ps, capMarkets);
        m = _mon("cap-nearly-reached");
        assertGe(m.capUseU, 9_500, "cap usage metric flips");
        (bool ok,) = _borrow(pUsdc, bs[0], pUsdc.totalBorrows() / 10);
        assertFalse(ok, "borrow beyond the cap is refused");
        // 5. cash vs borrow cash floor
        vm.revertToState(snap0);
        _setPrices(realAvaxAnswer, usdcAnswer);
        uint256 cash = pUsdc.getCash();
        require(ctrlA._setBorrowCashFloor(PToken(address(pUsdc)), cash - 1e6) == 0, "floor");
        m = _mon("cash-near-floor");
        assertEq(m.headroomU, 1e6, "headroom = cash - floor");
        (ok,) = _borrow(pUsdc, bs[0], 2e6);
        assertFalse(ok, "a borrow that would cross the floor is refused");
        require(ctrlA._setBorrowCashFloor(PToken(address(pUsdc)), cash + 1) == 0, "floor2");
        m = _mon("cash-below-floor");
        assertTrue(m.belowFloorU && m.headroomU == 0, "below-floor flag flips");
        // 6. reserve growth
        vm.revertToState(snap0);
        _setPrices(realAvaxAnswer, usdcAnswer);
        uint256 r0 = pUsdc.totalReserves();
        vm.roll(block.number + 100_000);
        pUsdc.accrueInterest();
        m = _mon("reserve-growth");
        assertGt(m.reservesU, r0, "reserves grow with accrued interest");
        // 7. feed and market inputs the monitors read exist as view calls with the shapes used above
        (AggregatorV3Interface f,,, bool en) = inner.feeds(WAVAX);
        assertTrue(en && address(f) == AVAX_FEED);
    }
}
