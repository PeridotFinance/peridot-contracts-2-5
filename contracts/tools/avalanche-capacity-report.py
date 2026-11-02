#!/usr/bin/env python3
"""Summarise AvalancheCapacityMatrixFork.t.sol forge output against the required-scenario manifest.

usage: avalanche-capacity-report.py [--strict] [--manifest tools/avalanche-capacity-manifest.json] out1.txt [...] > report.md

Verdicts per scenario (slice, cfg, side, margin, k):
  PASS                      every required liquidation succeeded, every opened position ends LIQUIDATED (zero debt) or
                            ACTIVE and not liquidatable, no insurance used, no bad debt
  PASS-INSURANCE-ASSISTED   same, but the insurance fund was drawn; NEVER counted as a pass for caps
  FAIL-PARTIAL              the first attempt succeeded but a later required liquidation failed or a position is left
                            liquidatable / with debt at the end of the path
  FAIL-FIRST                the first attempt failed
  FAIL-BADDEBT              attempts succeeded but debt exceeding remaining collateral is left
  FAIL-OPEN                 the scenario could not open the requested number of positions
  UNTRIGGERED               no position became liquidatable on the reachable path: no evidence
  NOT-RUN                   no rows for a manifest entry: no evidence
Caps are derived only from class `stress`/`aggregate` scenarios of the candidate configuration, only from PASS verdicts;
`reference`, `alternative` and `diagnostic` classes never emit launch caps.
Exit code: 0 complete, 2 with --strict when any manifest scenario is NOT-RUN or a manifest test produced no output.
"""
import sys, json, collections, os

args = sys.argv[1:]
strict = "--strict" in args
args = [a for a in args if a != "--strict"]
mpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), "avalanche-capacity-manifest.json")
if "--manifest" in args:
    i = args.index("--manifest"); mpath = args[i + 1]; del args[i:i + 2]
manifest = json.load(open(mpath))
USDC_DEC, WAVAX_DEC = 6, 18

def usd(c): return f"{int(c)/100:,.0f}"
def tok(v, side_asset):
    d = USDC_DEC if side_asset == "USDC" else WAVAX_DEC
    return f"{int(v)/10**d:,.4f} {side_asset}"

MX, MXT, MXEND, MXSUM, MXOPEN, OX, SG = [], [], [], [], [], [], []
files_seen = []
for f in args:
    files_seen.append(f)
    pending = None
    for ln in open(f, errors="replace").read().splitlines():
        ln = ln.strip()
        if not ln.endswith("|END") and not ln.startswith("SG|") and not ln.startswith("SG2|"):
            continue
        p = ln.split("|")
        t = p[0]
        if t == "MX":
            MX.append(dict(slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), path=int(p[6]), lag=int(p[7]), rem=int(p[8]),
                           step=int(p[9]), target=int(p[10]), pool=int(p[11]), oracle=int(p[12]), liq=p[13] == "1", ok=p[14] == "1",
                           rev=p[15], repay=int(p[16]), seized=int(p[17]), reward=int(p[18]), surplus=int(p[19]), ins=int(p[20]),
                           cost=int(p[22]), exec=int(p[23]), gas=int(p[24])))
        elif t == "MXT":
            MXT.append(dict(slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), id=int(p[6]), step=int(p[7]), ok=p[8] == "1",
                            repayT=int(p[9]), seizedT=int(p[10]), rewardT=int(p[11]), surplusT=int(p[12]), insU=int(p[13]), insW=int(p[14]),
                            debtLeftT=int(p[15]), status=int(p[16]), flashU=int(p[17]), flashW=int(p[18]), cashU=int(p[19]), cashW=int(p[20])))
        elif t == "MXEND":
            MXEND.append(dict(slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), id=int(p[6]), status=int(p[7]), liqable=p[8] == "1",
                              debtT=int(p[9]), debtC=int(p[10]), collC=int(p[11]), badC=int(p[12])))
        elif t == "MXSUM":
            MXSUM.append(dict(slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), flashU=int(p[6]), flashW=int(p[7]), cashU=int(p[8]),
                              cashW=int(p[9]), insU=int(p[10]), insW=int(p[11]), insC=int(p[12])))
        elif t == "MXOPEN":
            MXOPEN.append(dict(slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), opened=int(p[6]), rev=p[7]))
        elif t == "OX":
            OX.append(dict(dir=p[1], util=int(p[2]), n=int(p[3]), step=int(p[4]), target=int(p[5]), short=int(p[6]), repay=int(p[7]),
                           seized=int(p[8]), proto=int(p[9]), resid=int(p[10]), bad=int(p[11])))
        elif ln.startswith("SG|"):
            pending = p
        elif ln.startswith("SG2|") and pending:
            SG.append((pending, p)); pending = None

def key(r): return (r["slice"], r["cfg"], r["side"], r["margin"], r["k"])
grp = collections.defaultdict(list)
for r in MX: grp[key(r)].append(r)
endg = collections.defaultdict(list)
for r in MXEND: endg[key(r)].append(r)
tokg = collections.defaultdict(list)
for r in MXT: tokg[key(r)].append(r)
sumg = {key(r): r for r in MXSUM}
openg = {key(r): r for r in MXOPEN}

LEV = manifest["leverageX100"]
def verdict(k):
    rows = grp.get(k, [])
    if k in openg and openg[k]["opened"] < k[4]:
        return "FAIL-OPEN"
    if not rows and k not in endg:
        return "NOT-RUN"
    att = [r for r in rows if r["liq"]]
    if not att:
        return "UNTRIGGERED"
    ends = endg.get(k, [])
    if len(ends) < k[4]:
        return "NOT-RUN"  # no end-of-scenario snapshot for every position: incomplete evidence
    if not att[0]["ok"]:
        return "FAIL-FIRST"
    unresolved = [e for e in ends if not (e["status"] == 6 and e["debtT"] == 0) and not (e["status"] == 2 and not e["liqable"])]
    bad = sum(e["badC"] for e in ends)
    if not all(r["ok"] for r in att) or unresolved:
        return "FAIL-PARTIAL"
    if bad > 0:
        return "FAIL-BADDEBT"
    if sum(r["ins"] for r in att) > 0:
        return "PASS-INSURANCE-ASSISTED"
    return "PASS"

# --- manifest expansion
required = []
for s in manifest["slices"]:
    for cfg in s["cfgs"]:
        for side in ("long", "short"):
            for m in s["margins"]:
                required.append(dict(slice=s["slice"], cls=s["class"], key=(s["slice"], cfg, side, m, s["k"])))
if "alternative" not in manifest:
    pass
def cls_of(cfg, cl):
    if cfg == "ALT-guard300-2x25": return "diagnostic"
    if cfg.startswith("ALT-"): return "alternative"
    return cl
verd = {}
for r in required:
    verd[r["key"]] = verdict(r["key"])
notrun = [r for r in required if verd[r["key"]] == "NOT-RUN"]
tests_missing = []
for t in manifest["tests"]:
    if not any(t in f for f in files_seen):
        tests_missing.append(t)

out = []
out.append("# Avalanche capacity matrix (generated)\n")
out.append("Generated by `contracts/tools/avalanche-capacity-report.py` against `contracts/tools/avalanche-capacity-manifest.json`. "
           "Evidence classes: `oracle-only` = MOCKED oracle, pool untouched (reference, never used for caps); `pool-follows` / `lag*` / `fixedlag*` = pool moved by REAL swaps; "
           "`removal*` = EMULATED third-party liquidity removal; `agg-*` = correlated sequential positions; cfg `ALT-*` = alternatives (no launch cap), "
           "`ALT-guard300-2x25` = LOOSENED GUARDS, diagnostic only (never emits a cap).\n")
out.append(f"Manifest scenarios: {len(required)}; NOT-RUN: {len(notrun)}; manifest test outputs missing: {len(tests_missing)}. "
           + ("**EVIDENCE INCOMPLETE**\n" if notrun or tests_missing else "All manifest scenarios produced rows.\n"))
if tests_missing:
    out.append("Missing test outputs: " + ", ".join(tests_missing) + "\n")

def regime(rows):
    """mocked = oracle moved by cheat code, pool untouched; external = the real pool reached the intended price grid point
    (within 500 bps) at every liquidation attempt; synthetic = the pool overshot / hit its floor or ceiling and the oracle
    followed it to a price no external market produced (valuations at that price are not meaningful);
    external->synthetic = the first attempt was at an external price, later steps were not."""
    att = [r for r in rows if r["liq"]]
    if not att: return "-"
    if att[0]["path"] == 0: return "mocked"
    flags = [abs(r["pool"] - r["target"]) > 500 for r in att]
    if not any(flags): return "external"
    return "synthetic" if flags[0] else "external->synthetic"

def row_for(k, cls):
    rows = grp.get(k, []); att = [r for r in rows if r["liq"]]
    ends = endg.get(k, []); ts = tokg.get(k, [])
    ok = [r for r in att if r["ok"]]
    side_asset_debt = "WAVAX" if k[2] == "short" else "USDC"
    liqd = sum(1 for e in ends if e["status"] == 6)
    act = sum(1 for e in ends if e["status"] == 2)
    liqable_end = sum(1 for e in ends if e["status"] == 2 and e["liqable"])
    debtC = sum(e["debtC"] for e in ends); debtT = sum(e["debtT"] for e in ends)
    badC = sum(e["badC"] for e in ends)
    insC = sum(r["ins"] for r in att)
    insU = sum(t["insU"] for t in ts); insW = sum(t["insW"] for t in ts)
    firstfail = next((r for r in att if not r["ok"]), None)
    sm = sumg.get(k)
    return dict(k=k, cls=cls, v=verd.get(k) or verdict(k), first=("ok" if att and att[0]["ok"] else ("FAIL" if att else "-")),
                att=f"{len(ok)}/{len(att)}", end=f"{liqd} liquidated / {act} active ({liqable_end} still liquidatable)" if ends else "-",
                debt=tok(debtT, side_asset_debt), bad=usd(badC),
                ins=f"{usd(insC)} ({tok(insU,'USDC')}, {tok(insW,'WAVAX')})",
                repay=sum(t['repayT'] for t in ts if t['ok']), reward=sum(t['rewardT'] for t in ts if t['ok']),
                firstfail=(f"step {firstfail['step']} oracle {firstfail['oracle']} bps / pool {firstfail['pool']} bps: {firstfail['rev']}" if firstfail else "-"),
                sm=sm, side_asset=side_asset_debt, regime=regime(rows), cost=max([r["cost"] for r in att] or [0]),
                surplus=sum(t['surplusT'] for t in ts if t['ok']))

out.append("## Scenario verdicts (complete path)\n")
out.append("`first` = first liquidation attempt; `attempts` = successful/total required attempts along the path; `end state` counts every opened position; "
           "`price regime`: `mocked` = oracle moved by cheat code with the pool untouched, `external` = the real pool reached the intended grid price, `synthetic` = the pool overshot/hit its floor or ceiling and the oracle followed it to a price no external market produced (debt valuations there are reported as n/m). "
           "`outstanding debt` (base units of the debt asset, all opened positions) and `bad debt` (USD value of debt above remaining collateral at the end-of-path oracle price; shown only when the whole path is at externally reachable prices) are separate; "
           "`insurance` = fund consumption (USD and base units). All amounts are sums over the opened positions.\n")
out.append("| class | slice | cfg | side | margin each (USD) | k | price regime | verdict | first | attempts | end state | outstanding debt | bad debt (USD) | insurance used | first failure |")
out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
rows_out = []
for r in required:
    cls = cls_of(r["key"][1], r["cls"])
    rr = row_for(r["key"], cls); rows_out.append(rr)
    k = r["key"]
    syn = "synthetic" in rr["regime"]
    out.append(f"| {cls} | {k[0]} | {k[1]} | {k[2]} | {k[3]:,} | {k[4]} | {rr['regime']} | **{rr['v']}** | {rr['first']} | {rr['att']} | {rr['end']} | "
               + rr['debt'] + " | " + ("n/m (synthetic price)" if syn else rr['bad']) + f" | {rr['ins']} | {rr['firstfail']} |")

# --- derived limits (candidate only, PASS only)
cand = manifest["candidate"]; sf = manifest["safetyFactor"]
out.append("\n## Derived limits for the candidate configuration (PASS verdicts only)\n")
out.append(f"Single-position: the largest margin size whose verdict is PASS (no insurance, no bad debt, full path resolved) in EVERY required `stress` scenario for `{cand}` and the side. "
           "A missing, untriggered, failed or insurance-assisted scenario for a size disqualifies that size. "
           "Aggregate: taken only from the sequential correlated `agg-*` executions, in three units: margin, gross notional (margin x leverage) and debt (gross - margin); "
           "the safety factor is shown separately and is NOT used to substitute for aggregate validation.\n")
out.append("| side | validated single-position margin (USD) | disqualifying scenarios |")
out.append("|---|---|---|")
lev = LEV[cand]
for side in ("long", "short"):
    sizes = sorted({m for s in manifest["slices"] if s["class"] == "stress" and cand in s["cfgs"] for m in s["margins"]})
    passing = []; bad = collections.defaultdict(list)
    for m in sizes:
        ok_all = True
        for s in manifest["slices"]:
            if s["class"] != "stress" or cand not in s["cfgs"] or m not in s["margins"]: continue
            v = verd.get((s["slice"], cand, side, m, s["k"]))
            if v != "PASS":
                ok_all = False; bad[s["slice"]].append(f"{m//1000}k:{v}")
        if ok_all: passing.append(m)
    best = max(passing) if passing else None
    out.append(f"| {side} | " + (f"{best:,}" if best else "**NONE (unsupported)**") + " | " + ("; ".join(f"{a}: {', '.join(b)}" for a, b in bad.items()) or "-") + " |")

out.append("\n| side | aggregate scenario | verdict | margin (USD) | gross notional (USD) | debt (USD) | after safety factor (margin) |")
out.append("|---|---|---|---|---|---|---|")
for side in ("long", "short"):
    best = None
    for s in manifest["slices"]:
        if s["class"] != "aggregate" or cand not in s["cfgs"]: continue
        for m in s["margins"]:
            k = (s["slice"], cand, side, m, s["k"]); v = verd.get(k)
            tm = m * s["k"]; gross = tm * lev // 100; debt = gross - tm
            out.append(f"| {side} | {s['slice']} ({s['k']} x {m:,}) | {v} | {tm:,} | {gross:,} | {debt:,} | " + (f"{tm//sf:,}" if v == "PASS" else "-") + " |")
            if v == "PASS" and (best is None or tm > best): best = tm
    out.append(f"| {side} | **validated aggregate** | | " + (f"{best:,}" if best else "**NONE (unsupported)**") + " | | | |")

out.append("\n## Funding and token-unit accounting (aggregate and stress scenarios, candidate config)\n")
out.append("Keeper compensation, repayment and borrower surplus in base units of the relevant asset; flash vault and market cash at the end of the path (start: flash vault 3,200,000 USDC and 105,000 WAVAX; supplier cash about 3.4M USDC and 112k WAVAX).\n")
out.append("| slice | cfg | side | margin each | k | repaid | keeper reward | borrower surplus (USDC) | flash vault end (USDC / WAVAX) | market cash end (USDC / WAVAX) |")
out.append("|---|---|---|---|---|---|---|---|---|---|")
for rr in rows_out:
    k = rr["k"]
    if k[1] != cand or rr["cls"] not in ("stress", "aggregate"): continue
    sm = rr["sm"]
    if not sm: continue
    out.append(f"| {k[0]} | {k[1]} | {k[2]} | {k[3]:,} | {k[4]} | {tok(rr['repay'], rr['side_asset'])} | {tok(rr['reward'], rr['side_asset'])} | {tok(rr['surplus'],'USDC')} | "
               f"{sm['flashU']/1e6:,.0f} / {sm['flashW']/1e18:,.0f} | {sm['cashU']/1e6:,.0f} / {sm['cashW']/1e18:,.0f} |")

out.append("\n## Open failures\n")
out.append("| slice | cfg | side | margin each | requested k | opened | revert |")
out.append("|---|---|---|---|---|---|---|")
for o in openg.values():
    out.append(f"| {o['slice']} | {o['cfg']} | {o['side']} | {o['margin']:,} | {o['k']} | {o['opened']} | {o['rev']} |")

if OX:
    out.append("\n## Ordinary lending liquidations (funded liquidator, no swap)\n")
    out.append("USD, sums over the borrowers (each USD 10k collateral). `path` = price moves step by step with liquidations at every step; `GAP` = price jumps straight to the level. "
               "Bad debt = residual debt not covered by remaining collateral at that price; it can be nonzero on a gradual path at large moves too.\n")
    out.append("| mode / direction | borrow util % | borrowers | AVAX bps of pin | in shortfall | repaid (liquidator budget) | net seized | protocol share | residual debt | bad debt |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for r in OX:
        if r["short"] == 0 and r["bad"] == 0 and r["repay"] == 0: continue
        out.append(f"| {r['dir']} | {r['util']} | {r['n']} | {r['target']} | {r['short']} | {usd(r['repay'])} | {usd(r['seized'])} | {usd(r['proto'])} | {usd(r['resid'])} | {usd(r['bad'])} |")
    fb = {}
    for r in OX:
        if r["bad"] > 0: fb.setdefault((r["dir"], r["util"], r["n"]), r["target"])
    out.append("\nFirst step with bad debt: " + ("; ".join(f"{k[0]} util {k[1]}% n={k[2]}: {v} bps" for k, v in fb.items()) or "none in the tested range"))

if SG:
    out.append("\n## Swap-guard reconciliation (real `IsolatedMarginSwapModule`, USD 5k notional)\n")
    out.append("`delta` = oracle price relative to the pool price (bps). Expected/min/actual are token base units; exec/pool/oracle are USD per AVAX x1e8.\n")
    out.append("| guard | direction | oracle vs pool (bps) | oracle | pool | expected out | min out | actual out | exec price | result |")
    out.append("|---|---|---|---|---|---|---|---|---|---|")
    for p, q in SG:
        kv = dict(x.split("=") for x in p[4:] if "=" in x)
        res = q[1] + ("" if q[2] == "-" else f": {q[2]}")
        out.append(f"| {p[1]} | {p[2]} | {p[3]} | {kv['oracleE8']} | {kv['poolE8']} | {kv['expectedOut']} | {kv['minOut']} | {kv['actualOut']} | {kv['execE8']} | {res} |")

print("\n".join(out))
if strict and (notrun or tests_missing):
    sys.stderr.write(f"INCOMPLETE EVIDENCE: {len(notrun)} NOT-RUN scenarios, {len(tests_missing)} missing test outputs\n")
    sys.exit(2)
