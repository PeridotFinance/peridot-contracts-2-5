#!/usr/bin/env python3
"""Summarise AvalancheCapacityMatrixFork / AvalancheFallbackMatrixFork forge output against the required-scenario manifest.

usage: avalanche-capacity-report.py [--strict] [--status status.txt] [--manifest m.json] out1.txt [...] > report.md

Verdicts per scenario (slice, cfg, side, margin, k):
  PASS                      every opened position had a liquidation attempt, every attempt succeeded, every position ends LIQUIDATED with
                            zero debt or ACTIVE and not liquidatable, no insurance token drawn, no bad debt (valued at the oracle AND at the
                            real pool price)
  PASS-INSURANCE-ASSISTED   same, but any insurance pToken was drawn; never counted as a pass
  FAIL-PARTIAL              the first attempt succeeded but a later required liquidation failed, or a position is left liquidatable
  FAIL-FIRST                the first attempt failed
  FAIL-BADDEBT              attempts succeeded but debt above remaining collateral is left
  FAIL-OPEN                 the requested number of positions could not be opened
  INCOMPLETE-COVERAGE       some opened positions never became liquidatable on the path: the stress did not reach them (no evidence)
  UNTRIGGERED / NOT-RUN     no position became liquidatable / no rows (or no end-of-path snapshot): no evidence
Caps are derived ONLY from the candidate configuration, class stress/aggregate, verdict PASS and an `external` price regime
(mocked, synthetic and external->synthetic never count). A size counts only if it passes EVERY stress slice (a slice that did not run
that size disqualifies it) and every smaller size also passes. Aggregates must pass every variant (base, 50% liquidity removal,
oracle lag) and every smaller aggregate must pass. The safety factor is applied to the validated figure and shown in every unit.
Exit code: 0 complete, 2 with --strict when a manifest scenario is NOT-RUN or has conflicting records, a manifest test output is missing, --status reports a failed test,
or an aggregate group lacks a mandatory variant (base, removal50, fixedlag100) or the candidate has no aggregate scenarios at all. Any of these suppresses every validated-cap output.
"""
import sys, json, collections, os

args = sys.argv[1:]
strict = "--strict" in args
args = [a for a in args if a != "--strict"]
mpath = os.path.join(os.path.dirname(os.path.abspath(__file__)), "avalanche-capacity-manifest.json")
status_path = None
if "--manifest" in args:
    i = args.index("--manifest"); mpath = args[i + 1]; del args[i:i + 2]
if "--status" in args:
    i = args.index("--status"); status_path = args[i + 1]; del args[i:i + 2]
manifest = json.load(open(mpath))
USDC_DEC, WAVAX_DEC = 6, 18
failed_tests = []
if status_path and os.path.exists(status_path):
    failed_tests = [l.strip() for l in open(status_path) if l.startswith("FAILED")]

def usd(c): return f"{int(c)/100:,.0f}"
def tok(v, asset):
    d = USDC_DEC if asset == "USDC" else WAVAX_DEC
    return f"{int(v)/10**d:,.4f} {asset}"

MX, MXT, MXEND, MXSUM, MXOPEN, OX, SG, MXF, MXFSUM, MXIDS = [], [], [], [], [], [], [], [], [], []
files_seen = []
seen_paths = set()
for f in args:
    rp = os.path.realpath(f)
    if rp in seen_paths: continue  # never count the same output twice
    seen_paths.add(rp); files_seen.append(f); cur = os.path.basename(f)
    pending = None
    for ln in open(f, errors="replace").read().splitlines():
        ln = ln.strip()
        if not ln.endswith("|END") and not ln.startswith("SG|") and not ln.startswith("SG2|"):
            continue
        p = ln.split("|"); t = p[0]
        if t == "MX":
            MX.append(dict(src=cur, slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), path=int(p[6]), lag=int(p[7]), rem=int(p[8]),
                           step=int(p[9]), target=int(p[10]), pool=int(p[11]), oracle=int(p[12]), liq=p[13] == "1", ok=p[14] == "1",
                           rev=p[15], repay=int(p[16]), seized=int(p[17]), reward=int(p[18]), surplus=int(p[19]), ins=int(p[20]),
                           cost=int(p[22]), exec=int(p[23]), gas=int(p[24])))
        elif t == "MXT":
            MXT.append(dict(src=cur, slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), id=int(p[6]), step=int(p[7]), ok=p[8] == "1",
                            repayT=int(p[9]), seizedT=int(p[10]), rewardT=int(p[11]), surplusT=int(p[12]), insU=int(p[13]), insW=int(p[14]),
                            debtLeftT=int(p[15]), status=int(p[16]), flashU=int(p[17]), flashW=int(p[18]), cashU=int(p[19]), cashW=int(p[20])))
        elif t == "MXEND":
            MXEND.append(dict(src=cur, slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), id=int(p[6]), status=int(p[7]), liqable=p[8] == "1",
                              debtT=int(p[9]), debtC=int(p[10]), collC=int(p[11]), badC=int(p[12]), badPoolC=int(p[13])))
        elif t == "MXSUM":
            MXSUM.append(dict(src=cur, slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), flashU=int(p[6]), flashW=int(p[7]), cashU=int(p[8]),
                              cashW=int(p[9]), insU=int(p[10]), insW=int(p[11]), insC=int(p[12])))
        elif t == "MXF":
            MXF.append(dict(src=cur, slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), id=int(p[6]), step=int(p[7]), ok=p[8] == "1",
                            rev=p[9], pool=int(p[10]), debtBefore=int(p[11]), repaidT=int(p[12]), repaidC=int(p[13]), seizedC=int(p[14]), status=int(p[15])))
        elif t == "MXFSUM":
            MXFSUM.append(dict(src=cur, slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), budU=int(p[6]), budW=int(p[7]), leftU=int(p[8]),
                               leftW=int(p[9]), invU=int(p[10]), invW=int(p[11]), invC=int(p[12]), redU=int(p[13]), redW=int(p[14])))
        elif t == "MXIDS":
            MXIDS.append(dict(src=cur, slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), opened=int(p[6]),
                              ids=[int(x) for x in p[7].split(",") if x]))
        elif t == "MXOPEN":
            MXOPEN.append(dict(src=cur, slice=p[1], cfg=p[2], side=p[3], margin=int(p[4]), k=int(p[5]), opened=int(p[6]), rev=p[7]))
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
fbg = collections.defaultdict(list)
for r in MXF: fbg[key(r)].append(r)
sumg = {key(r): r for r in MXSUM}
fbsum = {key(r): r for r in MXFSUM}
openg = {key(r): r for r in MXOPEN}
idsg = collections.defaultdict(list)
for r in MXIDS: idsg[key(r)].append(r)
LEV = manifest["leverageX100"]

def regime(rows):
    """mocked = oracle cheat-coded with the pool untouched; external = the real pool reached the intended grid price (within 500 bps)
    at every liquidation attempt; synthetic = the pool overshot or hit its floor/ceiling and the oracle followed it to a price no
    external market produced; external->synthetic = first attempt external, later steps not."""
    att = [r for r in rows if r["liq"]]
    if not att: return "-"
    if att[0]["path"] == 0: return "mocked"
    flags = [abs(r["pool"] - r["target"]) > 500 for r in att]
    if not any(flags): return "external"
    return "synthetic" if flags[0] else "external->synthetic"

def resolved_end(e):
    return (e["status"] == 6 and e["debtT"] == 0) or (e["status"] == 2 and not e["liqable"])

def record_state(k):
    """Reconcile the records of one scenario against the ACTUAL opened position ids logged by the engine.
    Returns (state, opened_ids): NOT-RUN (nothing / no snapshots), CONFLICT (duplicate, missing, extra or cross-file records), OK."""
    rows = grp.get(k, []); ends = endg.get(k, []); ts = tokg.get(k, []); idl = idsg.get(k, [])
    if not rows and not ends and not idl: return "NOT-RUN", None
    if not idl: return "NOT-RUN", None                      # no record of which positions were opened
    if len(idl) != 1: return "CONFLICT", None               # duplicate / conflicting open records
    ids = idl[0]["ids"]; opened = set(ids)
    if len(ids) != len(opened) or len(opened) != k[4] or idl[0]["opened"] != len(ids): return "CONFLICT", opened
    if not ends: return "NOT-RUN", opened
    end_ids = [e["id"] for e in ends]
    if len(end_ids) != len(set(end_ids)) or set(end_ids) != opened: return "CONFLICT", opened   # exactly one final snapshot per opened id
    if any(t["id"] not in opened for t in ts): return "CONFLICT", opened
    if len({r["src"] for r in rows + ends + ts + idl}) > 1: return "CONFLICT", opened            # same scenario from two outputs
    return "OK", opened

def verdict(k):
    if k in openg and openg[k]["opened"] < k[4]: return "FAIL-OPEN"
    st, opened = record_state(k)
    if st == "NOT-RUN": return "NOT-RUN"
    if st == "CONFLICT": return "CONFLICTING-RECORDS"
    rows = grp.get(k, []); ends = endg.get(k, [])
    att = [r for r in rows if r["liq"]]
    if not att: return "UNTRIGGERED"
    ts = tokg.get(k, [])
    if {t["id"] for t in ts} != opened: return "INCOMPLETE-COVERAGE"   # attempts must cover exactly the opened positions
    if not att[0]["ok"]: return "FAIL-FIRST"
    if not all(r["ok"] for r in att) or not all(resolved_end(e) for e in ends): return "FAIL-PARTIAL"
    bad = sum(max(e["badC"], e["badPoolC"]) for e in ends)
    if bad > 0 and "synthetic" not in regime(rows): return "FAIL-BADDEBT"
    if sum(t["insU"] + t["insW"] for t in ts) > 0: return "PASS-INSURANCE-ASSISTED"
    return "PASS"

required = []
for s in manifest["slices"]:
    for cfg in s["cfgs"]:
        for side in ("long", "short"):
            for m in s["margins"]:
                required.append(dict(slice=s["slice"], cls=s["class"], variantOf=s.get("variantOf", s["slice"]), key=(s["slice"], cfg, side, m, s["k"])))
def cls_of(cfg, cl):
    if cfg == "ALT-guard300-2x25": return "diagnostic"
    if cfg.startswith("ALT-"): return "alternative"
    return cl
verd = {r["key"]: verdict(r["key"]) for r in required}
reg = {r["key"]: regime(grp.get(r["key"], [])) for r in required}
notrun = [r for r in required if verd[r["key"]] == "NOT-RUN"]
tests_missing = [t for t in manifest["tests"] if not any(t in os.path.basename(f) for f in files_seen)]

out = []
out.append("# Avalanche capacity matrix (generated)\n")
out.append("Generated by `contracts/tools/avalanche-capacity-report.py` against `contracts/tools/avalanche-capacity-manifest.json`. "
           "Evidence classes: `oracle-only` = MOCKED oracle, pool untouched (reference, never used for caps); `pool-follows` / `lag*` / `fixedlag*` = pool moved by REAL swaps; "
           "`removal*` = EMULATED third-party liquidity removal; `agg-*` = correlated sequential positions; cfg `ALT-*` = alternatives (no launch cap), "
           "`ALT-guard300-2x25` = LOOSENED GUARDS, diagnostic only (never emits a cap).\n")
conflicts = [r for r in required if verd[r["key"]] == "CONFLICTING-RECORDS"]
# Mandatory aggregate variants are part of GLOBAL completeness. They are fixed here, independent of the manifest, so a manifest that
# omits a variant (or all aggregates) cannot make the remaining evidence look complete.
REQ_AGG_VARIANTS = {"base", "removal50", "fixedlag100"} | set(manifest.get("aggregateRequiredVariants", []))
agg_slices = [s for s in manifest["slices"] if s["class"] == "aggregate" and manifest["candidate"] in s["cfgs"]]
groups = collections.OrderedDict()
for s in agg_slices:
    for m in s["margins"]:
        groups.setdefault((s.get("variantOf", s["slice"]), m, s["k"]), []).append((s["slice"], s.get("variantKind", "base")))
agg_missing = [(g, sorted(REQ_AGG_VARIANTS - {kd for _, kd in v})) for g, v in groups.items() if REQ_AGG_VARIANTS - {kd for _, kd in v}]
agg_absent = not groups   # no aggregate evidence at all for the candidate
fb_pre = [(cl, k) for sl in manifest.get("fallbackSlices", []) for cl in [sl["class"]] for cfg in sl["cfgs"] for side in ("long","short") for m in sl["margins"] for k in [(sl["slice"], cfg, side, m, sl["k"])]]
fb_incomplete = [k for _, k in fb_pre if verdict(k) in ("NOT-RUN", "CONFLICTING-RECORDS")]
status_line = f"Manifest scenarios: {len(required)}; fallback scenarios: {len(fb_pre)}; NOT-RUN: {len(notrun)}; conflicting records: {len(conflicts)}; incomplete fallback scenarios: {len(fb_incomplete)}; manifest test outputs missing: {len(tests_missing)}; tests reported FAILED by the runner: {len(failed_tests)}; aggregate groups missing a required variant: {len(agg_missing)}{' (no aggregate scenarios at all)' if agg_absent else ''}. "
incomplete = bool(notrun or tests_missing or failed_tests or conflicts or fb_incomplete or agg_missing or agg_absent)
out.append(status_line + ("**EVIDENCE INCOMPLETE OR TESTS FAILED: every validated-cap output is SUPPRESSED below**\n" if incomplete else "All manifest scenarios produced rows.\n"))
if tests_missing: out.append("Missing test outputs: " + ", ".join(tests_missing) + "\n")
if failed_tests: out.append("Failed: " + "; ".join(failed_tests) + "\n")
if agg_missing: out.append("Aggregate groups missing mandatory variants: " + "; ".join(f"{g[0]} ({g[2]} x {g[1]:,}): {', '.join(m)}" for g, m in agg_missing) + "\n")
cnt = collections.Counter((cls_of(r["key"][1], r["cls"]), verd[r["key"]]) for r in required)
out.append("Verdict counts by class: " + "; ".join(f"{c}/{v}: {n}" for (c, v), n in sorted(cnt.items())) + "\n")

def row_for(k, cls):
    rows = grp.get(k, []); att = [r for r in rows if r["liq"]]; ends = endg.get(k, []); ts = tokg.get(k, [])
    ok = [r for r in att if r["ok"]]
    asset = "WAVAX" if k[2] == "short" else "USDC"
    firstfail = next((r for r in att if not r["ok"]), None)
    insU = sum(t["insU"] for t in ts); insW = sum(t["insW"] for t in ts)
    return dict(k=k, cls=cls, v=verd.get(k) or verdict(k), first=("ok" if att and att[0]["ok"] else ("FAIL" if att else "-")), att=f"{len(ok)}/{len(att)}",
                end=(f"{sum(1 for e in ends if e['status']==6)} liquidated / {sum(1 for e in ends if e['status']==2)} active ({sum(1 for e in ends if e['status']==2 and e['liqable'])} still liquidatable)" if ends else "-"),
                debt=tok(sum(e["debtT"] for e in ends), asset), bad=usd(sum(max(e["badC"], e["badPoolC"]) for e in ends)),
                ins=f"{usd(sum(r['ins'] for r in att))} ({tok(insU,'USDC')}, {tok(insW,'WAVAX')})", regime=regime(rows),
                firstfail=(f"step {firstfail['step']} oracle {firstfail['oracle']} bps / pool {firstfail['pool']} bps: {firstfail['rev']}" if firstfail else "-"),
                sm=sumg.get(k), side_asset=asset, repay=sum(t["repayT"] for t in ts if t["ok"]), reward=sum(t["rewardT"] for t in ts if t["ok"]),
                surplus=sum(t["surplusT"] for t in ts if t["ok"]))

out.append("## Scenario verdicts (complete path)\n")
out.append("`first` = first liquidation attempt; `attempts` = successful/total required attempts along the path; `end state` counts every opened position; "
           "`price regime`: `mocked` = oracle moved by cheat code with the pool untouched, `external` = the real pool reached the intended grid price, `synthetic` = the pool overshot/hit its floor or ceiling and the oracle followed it to a price no external market produced (debt valuations there are n/m); "
           "`outstanding debt` (base units, all opened positions) and `bad debt` (USD of debt above remaining collateral, the larger of the oracle valuation and the REAL POOL-price valuation; shown only when no step is synthetic) are separate; "
           "`insurance` = fund consumption (USD and base units).\n")
out.append("| class | slice | cfg | side | margin each (USD) | k | price regime | verdict | first | attempts | end state | outstanding debt | bad debt (USD) | insurance used | first failure |")
out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
rows_out = []
for r in required:
    cls = cls_of(r["key"][1], r["cls"]); rr = row_for(r["key"], cls); rows_out.append(rr); k = r["key"]
    syn = "synthetic" in rr["regime"]
    out.append(f"| {cls} | {k[0]} | {k[1]} | {k[2]} | {k[3]:,} | {k[4]} | {rr['regime']} | **{rr['v']}** | {rr['first']} | {rr['att']} | {rr['end']} | {rr['debt']} | "
               + ("n/m (synthetic price)" if syn else rr['bad']) + f" | {rr['ins']} | {rr['firstfail']} |")

# ---------------------------------------------------------------- derived limits (candidate, PASS + external only)
cand = manifest["candidate"]; sf = manifest["safetyFactor"]; lev = LEV[cand]
def counts(v, k): return v == "PASS" and reg.get(k) == "external"
out.append("\n## Derived limits for the candidate configuration\n")
if incomplete:
    out.append("**SUPPRESSED: the evidence is incomplete or a required test failed (see the header). No validated single-position or aggregate cap, and no safety-adjusted figure, is emitted.**\n")
else:
  if True:
    out.append(f"`{cand}` only. Single position: the largest margin size M such that EVERY size <= M passes EVERY required `stress` slice (verdict PASS in an `external` price regime; a slice that did not run a size disqualifies it). "
               f"Aggregate: the largest total T such that EVERY aggregate scenario with total <= T passes every variant of its group (base, 50% liquidity removal, 100 bps oracle lag). "
               f"Safety factor {sf} is applied to the validated figure and shown beside it, in margin, gross notional and debt.\n")
    stress = [s for s in manifest["slices"] if s["class"] == "stress" and cand in s["cfgs"]]
    sizes = sorted({m for s in stress for m in s["margins"]})
    out.append("| side | validated single-position margin (USD) | after safety factor | disqualifying scenarios |")
    out.append("|---|---|---|---|")
    for side in ("long", "short"):
        validated = None; bad = collections.defaultdict(list)
        for m in sizes:
            ok_all = True
            for s in stress:
                k = (s["slice"], cand, side, m, s["k"])
                if m not in s["margins"]:
                    ok_all = False; bad[s["slice"]].append(f"{m//1000}k:NOT-TESTED"); continue
                if not counts(verd.get(k), k):
                    ok_all = False; bad[s["slice"]].append(f"{m//1000}k:{verd.get(k)}/{reg.get(k)}")
            if ok_all: validated = m
            else: break  # monotone: a failing size blocks every larger size
        out.append(f"| {side} | " + (f"{validated:,}" if validated else "**NONE (unsupported)**") + " | " + (f"{validated//sf:,}" if validated else "-") + " | "
                   + ("; ".join(f"{a}: {', '.join(b)}" for a, b in bad.items()) or "-") + " |")

    out.append("\n| side | aggregate group | variants (verdict/regime) | total margin (USD) | gross notional (USD) | debt (USD) | counts toward cap |")
    out.append("|---|---|---|---|---|---|---|")
    agg_valid = {}
    for side in ("long", "short"):
        glist = sorted(groups.items(), key=lambda kv: kv[0][1] * kv[0][2])
        validated = None; blocked = False
        for (vo, m, kk), variants in glist:
            tm = m * kk; gross = tm * lev // 100; debt = gross - tm
            vs = []; allpass = True
            # The section 4 aggregate needs EVERY required variant; a manifest that omits one cannot weaken this rule.
            kinds = {kd for _, kd in variants}
            missing = sorted(REQ_AGG_VARIANTS - kinds)
            if missing:
                allpass = False; vs.append("MISSING-VARIANT: " + ", ".join(missing))
            for v, kd in variants:
                key_ = (v, cand, side, m, kk)
                vs.append(f"{v} [{kd}]: {verd.get(key_)}/{reg.get(key_)}")
                if not counts(verd.get(key_), key_): allpass = False
            good = allpass and not blocked
            if good: validated = (tm, gross, debt)
            else: blocked = True
            out.append(f"| {side} | {vo} ({kk} x {m:,}) | {'; '.join(vs)} | {tm:,} | {gross:,} | {debt:,} | {'yes' if good else 'no'} |")
        agg_valid[side] = validated
        if validated:
            tm, gross, debt = validated
            out.append(f"| {side} | **validated aggregate** | | **{tm:,}** | **{gross:,}** | **{debt:,}** | |")
            out.append(f"| {side} | after safety factor {sf} | | {tm//sf:,} | {gross//sf:,} | {debt//sf:,} | |")
        else:
            out.append(f"| {side} | **validated aggregate** | | **NONE (unsupported)** | | | |")

out.append("\n## Funding and token-unit accounting (stress and aggregate scenarios, candidate config)\n")
out.append("Repayment and keeper compensation in base units of the debt asset, borrower surplus in USDC base units; flash vault and market cash at the end of the path (start: flash vault 3,200,000 USDC and 105,000 WAVAX; supplier cash about 3.4M USDC and 112k WAVAX).\n")
out.append("| slice | cfg | side | margin each | k | repaid | keeper reward | borrower surplus (USDC) | flash vault end (USDC / WAVAX) | market cash end (USDC / WAVAX) |")
out.append("|---|---|---|---|---|---|---|---|---|---|")
for rr in rows_out:
    k = rr["k"]
    if k[1] != cand or rr["cls"] not in ("stress", "aggregate") or not rr["sm"]: continue
    sm = rr["sm"]
    out.append(f"| {k[0]} | {k[1]} | {k[2]} | {k[3]:,} | {k[4]} | {tok(rr['repay'], rr['side_asset'])} | {tok(rr['reward'], rr['side_asset'])} | {tok(rr['surplus'],'USDC')} | "
               f"{sm['flashU']/1e6:,.0f} / {sm['flashW']/1e18:,.0f} | {sm['cashU']/1e6:,.0f} / {sm['cashW']/1e18:,.0f} |")

# ---------------------------------------------------------------- funded fallback
fb_required = []
for sl in manifest.get("fallbackSlices", []):
    for cfg in sl["cfgs"]:
        for side in ("long", "short"):
            for m in sl["margins"]:
                fb_required.append((sl["class"], (sl["slice"], cfg, side, m, sl["k"])))

def fb_verdict(k):
    if k in openg and openg[k]["opened"] < k[4]: return "FAIL-OPEN"
    st, opened = record_state(k)
    if st == "NOT-RUN": return "NOT-RUN"
    if st == "CONFLICT": return "CONFLICTING-RECORDS"
    rows = grp.get(k, []); att = [r for r in rows if r["liq"]]; ends = endg.get(k, [])
    if not att: return "UNTRIGGERED"
    funded = fbg.get(k, []); ts = tokg.get(k, [])
    if {t["id"] for t in ts} != opened: return "INCOMPLETE-COVERAGE"
    resolved = all(resolved_end(e) for e in ends)
    normal_ok = all(r["ok"] for r in att)
    ins = sum(t["insU"] + t["insW"] for t in ts) > 0
    bad = sum(max(e["badC"], e["badPoolC"]) for e in ends)
    syn = "synthetic" in regime(rows)
    if resolved and normal_ok and not funded:
        return "PASS-NORMAL" + ("-INSURANCE-ASSISTED" if ins else "")
    if resolved and any(f["ok"] for f in funded):
        if bad > 0 and not syn: return "FAIL-BADDEBT"
        return "PASS-VIA-FALLBACK" + ("-INSURANCE-ASSISTED" if ins else "")
    fails = [f for f in funded if not f["ok"]]
    if fails:
        r0 = fails[0]["rev"]
        if "LiquidationError(28)" in r0 or "exceeds balance" in r0 or "exceeds allowance" in r0: return "FAIL-FUNDING-EXHAUSTED"
        if "LiquidationError(32)" in r0: return "FAIL-FLOOR-DECLINED"
        return "FAIL-FALLBACK"
    return "FAIL-UNRESOLVED"

fbv = {k: fb_verdict(k) for _, k in fb_required}
fb_notrun = [k for k, v in fbv.items() if v == "NOT-RUN"]
fb_conflicts = [k for k, v in fbv.items() if v == "CONFLICTING-RECORDS"]
if fb_required:
    out.append("\n## Funded in-kind fallback with finite funding (class `fallback*`)\n")
    out.append(f"One allowlisted funder, funded ONCE per scenario ({manifest['fallbackBudget']['USDC']:,} USDC and {manifest['fallbackBudget']['WAVAX']:,} WAVAX, approvals limited to the budget), no replenishment between attempts, "
               "cumulative seized inventory. At each stressed step the NORMAL route is attempted first; positions it leaves liquidatable go to the funded route at the same state. "
               "`fb-nofloor-*` runs the funder with no break-even floor (it absorbs any shortfall); all others use the floor (`minSeizeValueBps` = 10,000). "
               "`redeemable now` = min(inventory, market cash) per market (an upper bound: other holders compete for the same cash). Funder P&L is seized value minus repaid value at the oracle price at each attempt (not realised). "
               "The route draws no insurance; `insurance used` is the NORMAL route's draw. The USDC-depeg slice applies the depeg AFTER the positions are opened.\n")
    out.append("| class | slice | cfg | side | margin each | k | price regime | verdict | normal route ok/total | funded ok/total | first funded failure | funder repaid | budget left (USDC / WAVAX) | inventory (underlying USDC / WAVAX) | inventory USD | redeemable now (USDC / WAVAX) | funder P&L (USD) | normal-route insurance (USD) | outstanding debt | bad debt (USD) |")
    out.append("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for cl, k in fb_required:
        rows = grp.get(k, []); att = [r for r in rows if r["liq"]]; ok = [r for r in att if r["ok"]]
        funded = fbg.get(k, []); fok = [f for f in funded if f["ok"]]; ends = endg.get(k, []); sm = fbsum.get(k)
        asset = "WAVAX" if k[2] == "short" else "USDC"; rg = regime(rows); syn = "synthetic" in rg
        ff = next((f for f in funded if not f["ok"]), None)
        pnl = sum(f["seizedC"] - f["repaidC"] for f in fok)
        debtT = sum(e["debtT"] for e in ends); badC = sum(max(e["badC"], e["badPoolC"]) for e in ends)
        out.append(f"| {cl} | {k[0]} | {k[1]} | {k[2]} | {k[3]:,} | {k[4]} | {rg} | **{fbv[k]}** | {len(ok)}/{len(att)} | {len(fok)}/{len(funded)} | "
                   + (f"step {ff['step']} pool {ff['pool']} bps: {ff['rev']}" if ff else "-") + " | "
                   + (tok(sum(f['repaidT'] for f in fok), asset) if fok else "-") + " | "
                   + (f"{sm['leftU']/1e6:,.0f} / {sm['leftW']/1e18:,.1f}" if sm else "-") + " | "
                   + (f"{sm['invU']/1e6:,.2f} / {sm['invW']/1e18:,.2f}" if sm else "-") + " | " + (usd(sm['invC']) if sm and not syn else ("n/m" if sm else "-")) + " | "
                   + (f"{sm['redU']/1e6:,.2f} / {sm['redW']/1e18:,.2f}" if sm else "-") + " | " + ("n/m" if syn else usd(pnl)) + " | "
                   + usd(sum(r['ins'] for r in att)) + " | " + (tok(debtT, asset) if ends else "-") + " | " + ("n/m" if syn else usd(badC)) + " |")
    out.append("\nFunder budget requirements are the tokens repaid in scenarios that completed; FAIL-FUNDING-EXHAUSTED would show the fixed budget running out (no replenishment).\n")

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
if strict and incomplete:
    sys.stderr.write(f"INCOMPLETE EVIDENCE: {len(notrun)} NOT-RUN, {len(conflicts)} conflicting-record scenarios, {len(fb_incomplete)} incomplete fallback scenarios, {len(tests_missing)} missing test outputs, {len(failed_tests)} failed tests, {len(agg_missing)} aggregate groups missing a mandatory variant{', no aggregate scenarios' if agg_absent else ''}\n")
    sys.exit(2)
