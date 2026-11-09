#!/usr/bin/env python3
"""Mutation check of the range take-profit fork tests: applies ONE mutation at a time to src/, runs the fork suites (./run-fork.sh, which takes the
shared fork lock, one job at a time), records killed / survived / inconclusive, and ALWAYS restores the file. A run that did not compile or crashed
before any test ran is INCONCLUSIVE, never counted as a kill. Run after `forge clean && forge build` has been done once.
    python3 tools/mutation-check.py [mutant-id ...]
"""
import re, shutil, subprocess, sys, os, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)) + "/.."
os.chdir(HERE)
CUST = "src/RangeTakeProfit.sol"
LIQ = "src/engine/IsolatedMarginLiquidatorUpgradeable.sol"
RISK = "src/engine/IsolatedMarginRiskEngineUpgradeable.sol"
MUTANTS = [
    ("M1", CUST, "        _checkPoolAgainstOracle(p);\n        uint16 slip", "        uint16 slip", "finalize without the pool-vs-oracle check"),
    ("M2", CUST, "if (enforceFloor) _checkFloor(idx, o, r, x.p1, slip);", "", "finalize without the slippage floor"),
    ("M3", CUST, "executor.rangeReturn(positionId, last);", "executor.rangeReturn(positionId, false);", "finalize never settles the position"),
    ("M4", CUST, "r.status == Status.ACTIVE && tick >= r.tickUpper) {\n                _removeRung", "r.status == Status.ACTIVE && tick >= r.tickLower) {\n                _removeRung", "a partly filled rung is finalised (tick >= lower)"),
    ("M5", CUST, "        if (msg.sender != liquidator && msg.sender != orderAdapter && msg.sender != o.owner) revert NotAuthorized();\n", "", "unwind open to anyone"),
    ("M6", LIQ, "            if (custodian != address(0)) IRangeUnwind(custodian).unwind(params.positionId);\n        }", "        }", "liquidateFunded does not unwind"),
    ("M7", CUST, "int24 lower = _ceil(tick + distance);", "int24 lower = _floor(tick + distance);", "band snapped TOWARD the market"),
    ("M8", CUST, "uint256 amount = i + 1 == preset.levels ? remaining : Math.mulDiv(collateralCommitted, preset.weightBps[i], BPS);", "uint256 amount = Math.mulDiv(collateralCommitted, preset.weightBps[i], BPS);", "last rung does not take the remainder (rounding dust left in the custodian)"),
    ("M9", CUST, "        if (riskEngine.isLiquidatable(p.account)) revert WouldBeLiquidatable();\n", "", "no liquidatable check after the bands are placed"),
    ("M10", RISK, 'require(bandCollateral == 0 && bandQuote == 0, "RiskEngine: range order active");', "", "a position may be closed while rungs hold its collateral (the orphan defect)"),
    ("M11", CUST, "        if (_orders[positionId].status == Status.ACTIVE) revert PositionNotEligible(4);\n", "", "a second order on the same position is accepted"),
    ("M12", CUST, "            if (r.status == Status.ACTIVE && tick >= r.tickUpper) {\n                any = true;", "            if (r.status == Status.ACTIVE && tick >= r.tickLower) {\n                any = true;", "readiness (the keeper's gate) uses the lower tick"),
]
MUTANTS = [m for m in MUTANTS if m[4]]

def main():
    want = set(sys.argv[1:])
    results = []
    for mid, path, old, new, why in MUTANTS:
        if want and mid not in want:
            continue
        src = open(path).read()
        if src.count(old) != 1:
            results.append((mid, why, "INCONCLUSIVE (pattern not found exactly once)"))
            continue
        bak = tempfile.mktemp()
        shutil.copy(path, bak)
        try:
            open(path, "w").write(src.replace(old, new))
            p = subprocess.run(["./run-fork.sh", "--match-contract", "Range(Lifecycle|Risk)ForkTest"], capture_output=True, text=True)
            out = p.stdout + p.stderr
            if p.returncode == 42:
                results.append((mid, why, "STOPPED: rate limit seen"))
                break
            m = re.findall(r"Suite result: \w+\. (\d+) passed; (\d+) failed", out)
            if not m:
                results.append((mid, why, "INCONCLUSIVE (no suite result: compile error or crash)"))
            else:
                failed = sum(int(b) for a, b in m)
                results.append((mid, why, f"KILLED ({failed} failing tests)" if failed else "SURVIVED"))
        finally:
            shutil.copy(bak, path)
            os.remove(bak)
    for r in results:
        print(f"{r[0]:4} {r[2]:48} {r[1]}")
    survivors = [r for r in results if r[2].startswith("SURVIVED")]
    sys.exit(1 if survivors else 0)

main()
