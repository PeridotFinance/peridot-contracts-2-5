#!/usr/bin/env python3
"""Fixture tests for avalanche-capacity-report.py: the generator must not turn weak evidence into a cap.
Run: python3 tools/avalanche-capacity-report.test.py"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(HERE, "avalanche-capacity-report.py")

def mx(slice_, cfg, side, margin, k, step, pool, target, ok=True, liq=True, path=1, ins=0, rev="-"):
    # MX|slice|cfg|side|margin|k|path|lag|rem|step|target|pool|oracle|liq|ok|rev|repay|seized|reward|surplus|ins|resid|cost|exec|gas|END
    return "|".join(["MX", slice_, cfg, side, str(margin), str(k), str(path), "0", "0", str(step), str(target), str(pool), str(pool),
                     "1" if liq else "0", "1" if ok else "0", rev, "0", "0", "0", "0", str(ins), "0", "0", "0", "0", "END"])

def mxt(slice_, cfg, side, margin, k, id_, step, ok=True, insU=0):
    return "|".join(["MXT", slice_, cfg, side, str(margin), str(k), str(id_), str(step), "1" if ok else "0", "0", "0", "0", "0",
                     str(insU), "0", "0", "6", "0", "0", "0", "0", "END"])

def mxend(slice_, cfg, side, margin, k, id_, status=6, liqable=False, debtT=0, bad=0, badPool=0):
    return "|".join(["MXEND", slice_, cfg, side, str(margin), str(k), str(id_), str(status), "1" if liqable else "0", str(debtT), "0", "0", str(bad), str(badPool), "END"])

def scenario(slice_, cfg, side, margin, k, ids_attempted=None, pool=7000, target=7000, ok=True, status=6, ins=0, bad=0):
    ids_attempted = list(range(1, k + 1)) if ids_attempted is None else ids_attempted
    lines = [mx(slice_, cfg, side, margin, k, 3, pool, target, ok=ok)]
    lines += [mxt(slice_, cfg, side, margin, k, i, 3, ok=ok, insU=ins) for i in ids_attempted]
    lines += [mxend(slice_, cfg, side, margin, k, i, status=status, bad=bad) for i in range(1, k + 1)]
    return lines

def run(manifest, lines, strict=False):
    with tempfile.TemporaryDirectory() as d:
        mp = os.path.join(d, "m.json"); json.dump(manifest, open(mp, "w"))
        fp = os.path.join(d, "testX.txt"); open(fp, "w").write("\n".join("  " + l for l in lines) + "\n")
        r = subprocess.run([sys.executable, REPORT, "--manifest", mp] + (["--strict"] if strict else []) + [fp], capture_output=True, text=True)
        return r.returncode, r.stdout, r.stderr

def manifest(slices, tests=("testX",)):
    return {"leverageX100": {"cand": 200}, "candidate": "cand", "safetyFactor": 2, "tests": list(tests), "slices": slices, "fallbackBudget": {"USDC": 1, "WAVAX": 1}}

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

# 1. every opened position must have been attempted
m = manifest([{"slice": "s", "class": "stress", "cfgs": ["cand"], "margins": [1000], "k": 5}])
rc, out, _ = run(m, scenario("s", "cand", "long", 1000, 5, ids_attempted=[1]))
check("k=5 with one attempted id is INCOMPLETE-COVERAGE, not PASS", "INCOMPLETE-COVERAGE" in out and "**PASS**" not in out)

# 2. a PASS in a synthetic regime never counts toward a cap
m = manifest([{"slice": "s", "class": "stress", "cfgs": ["cand"], "margins": [1000], "k": 1}])
rc, out, _ = run(m, scenario("s", "cand", "long", 1000, 1, pool=22000, target=15000))
check("synthetic-regime PASS yields no validated single-position margin", "**PASS**" in out and "| long | **NONE (unsupported)**" in out)
rc, out, _ = run(m, scenario("s", "cand", "long", 1000, 1, pool=15000, target=15000))
check("external-regime PASS yields a validated margin", "| long | 1,000 | 500 |" in out)

# 3. non-monotone: 5k fails, 25k passes => no cap above 1k
m = manifest([{"slice": "s", "class": "stress", "cfgs": ["cand"], "margins": [1000, 5000, 25000], "k": 1}])
lines = scenario("s", "cand", "long", 1000, 1, pool=7000, target=7000) + scenario("s", "cand", "long", 5000, 1, pool=7000, target=7000, ok=False, status=2) + scenario("s", "cand", "long", 25000, 1, pool=7000, target=7000)
rc, out, _ = run(m, lines)
check("a failing 5k blocks the passing 25k (monotone)", "| long | 1,000 | 500 |" in out)

# 4. a size not run in every stress slice cannot be validated
m = manifest([{"slice": "a", "class": "stress", "cfgs": ["cand"], "margins": [1000, 5000], "k": 1},
              {"slice": "b", "class": "stress", "cfgs": ["cand"], "margins": [5000], "k": 1}])
lines = scenario("a", "cand", "long", 1000, 1, pool=7000, target=7000) + scenario("a", "cand", "long", 5000, 1, pool=7000, target=7000) + scenario("b", "cand", "long", 5000, 1, pool=7000, target=7000)
rc, out, _ = run(m, lines)
check("size 1k not tested in slice b is NOT-TESTED and blocks the cap", "1k:NOT-TESTED" in out and "| long | **NONE (unsupported)**" in out)

# 5. aggregate: all variants must pass; a failing variant blocks the aggregate
m = manifest([{"slice": "g", "class": "aggregate", "cfgs": ["cand"], "margins": [1000], "k": 2, "variantOf": "g"},
              {"slice": "g-rem", "class": "aggregate", "cfgs": ["cand"], "margins": [1000], "k": 2, "variantOf": "g"}])
lines = scenario("g", "cand", "long", 1000, 2, pool=7000, target=7000) + scenario("g-rem", "cand", "long", 1000, 2, pool=7000, target=7000, ok=False, status=2)
rc, out, _ = run(m, lines)
check("aggregate with a failing removal variant has no validated aggregate", "| long | **validated aggregate** | | **NONE (unsupported)**" in out)
lines = scenario("g", "cand", "long", 1000, 2, pool=7000, target=7000) + scenario("g-rem", "cand", "long", 1000, 2, pool=7000, target=7000)
rc, out, _ = run(m, lines)
check("aggregate passing every variant is validated and halved by the safety factor", "**2,000**" in out and "| 1,000 | 2,000 | 1,000 |" in out)

# 6. insurance tokens drawn => never PASS
m = manifest([{"slice": "s", "class": "stress", "cfgs": ["cand"], "margins": [1000], "k": 1}])
rc, out, _ = run(m, scenario("s", "cand", "long", 1000, 1, pool=7000, target=7000, ins=1))
check("1 base unit of insurance makes it insurance-assisted, not PASS", "PASS-INSURANCE-ASSISTED" in out and "**PASS**" not in out)

# 7. loosened-guard diagnostic and alternative configs never emit caps
m = {"leverageX100": {"cand": 200, "ALT-guard300-2x25": 200}, "candidate": "cand", "safetyFactor": 2, "tests": ["testX"],
     "slices": [{"slice": "s", "class": "stress", "cfgs": ["ALT-guard300-2x25"], "margins": [1000], "k": 1}], "fallbackBudget": {"USDC": 1, "WAVAX": 1}}
rc, out, _ = run(m, scenario("s", "ALT-guard300-2x25", "long", 1000, 1, pool=7000, target=7000))
check("diagnostic config PASS is labelled diagnostic and yields no cap", "| diagnostic |" in out and "| long | **NONE (unsupported)**" in out)

# 8. NOT-RUN scenarios: strict exits 2 and the header says incomplete
m = manifest([{"slice": "s", "class": "stress", "cfgs": ["cand"], "margins": [1000], "k": 1}])
rc, out, err = run(m, [], strict=True)
check("strict run with NOT-RUN scenarios exits 2 and flags incomplete evidence", rc == 2 and "EVIDENCE INCOMPLETE" in out)

# 9. the same output passed twice is not double counted
with tempfile.TemporaryDirectory() as d:
    mp = os.path.join(d, "m.json"); json.dump(manifest([{"slice": "s", "class": "stress", "cfgs": ["cand"], "margins": [1000], "k": 1}]), open(mp, "w"))
    fp = os.path.join(d, "testX.txt"); open(fp, "w").write("\n".join(scenario("s", "cand", "long", 1000, 1, pool=7000, target=7000)))
    r = subprocess.run([sys.executable, REPORT, "--manifest", mp, fp, fp], capture_output=True, text=True)
    check("duplicate input file does not double count", "**PASS**" in r.stdout and "INCOMPLETE-COVERAGE" not in r.stdout)

if fails:
    print(f"\n{len(fails)} FAILED"); sys.exit(1)
print("\nall generator fixtures passed")
