"""W-CAL Q3: stablecoin excursions seen by the Avalanche Chainlink feeds (local data from fetch_feeds.py). Episode = consecutive rounds (in force) with |answer-1| > 20 bps,
merged if separated by less than 6 h. Output data/depegs.json and stdout."""
import json, os, datetime, sys
sys.argv = ["x"]
HERE = os.path.dirname(os.path.abspath(__file__)); D = os.path.join(HERE, "data")
import importlib.util
spec = importlib.util.spec_from_file_location("an", os.path.join(HERE, "analyze.py"))
# reuse only the feed loader (analyze.py is cheap, but avoid side effects: re-implement)
import collections
def load_feed(leg):
    rows = json.load(open(os.path.join(D, "feed_rounds_%s_all.json" % leg))); ph = collections.defaultdict(list)
    for r in rows: ph[r[0] >> 64].append(r)
    for k in ph: ph[k].sort(key=lambda r: r[0])
    ks = sorted(ph); out = []
    for i, k in enumerate(ks):
        end = ph[ks[i + 1]][0][3] if i + 1 < len(ks) else 1 << 62
        out += [r for r in ph[k] if r[3] < end]
    return sorted(out, key=lambda r: (r[3], r[0]))
f = lambda t: datetime.datetime.utcfromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S")
out = {}
for leg in ("USDC", "USDT"):
    F = load_feed(leg); eps = []; cur = None
    for i, r in enumerate(F):
        dev = abs(r[1] - 1e8) / 1e4
        if dev > 20:
            if cur and r[3] - cur["last_bad_t"] < 6 * 3600: cur["i1"] = i; cur["last_bad_t"] = r[3]
            else:
                cur = {"i0": i, "i1": i, "last_bad_t": r[3]}; eps.append(cur)
    res = []
    for e in eps:
        lo = max(0, e["i0"] - 3); hi = min(len(F) - 1, e["i1"] + 2)
        ctx = F[lo:hi + 1]; rs = F[e['i0']:e['i1'] + 1]; worst = max(rs, key=lambda r: abs(r[1] - 1e8))
        first_gt = lambda th: next((r for r in rs if abs(r[1] - 1e8) / 1e4 > th), None)
        # when did the previous in-band round occur (the feed state before the move)
        prev = F[e["i0"] - 1]
        d = {"first_round_over_20bps": f(F[e["i0"]][3]), "worst_answer": worst[1] / 1e8, "worst_ts": f(worst[3]), "rounds_in_episode": e["i1"] - e["i0"] + 1,
             "last_round_over_20bps": f(F[e["i1"]][3]), "feed_state_before": [f(prev[3]), prev[1] / 1e8],
             "first_over_50bps": f(first_gt(50)[3]) if first_gt(50) else None, "first_over_100bps": f(first_gt(100)[3]) if first_gt(100) else None,
             "secs_first_20_to_first_50": (first_gt(50)[3] - F[e["i0"]][3]) if first_gt(50) else None}
        # seconds the feed read > 50 bps off, time weighted
        sec50 = 0
        for j in range(e['i0'], e['i1'] + 1):
            if abs(F[j][1] - 1e8) / 1e4 > 50 and j + 1 < len(F): sec50 += F[j + 1][3] - F[j][3]
        d["seconds_in_force_over_50bps"] = sec50; d["max_dev_bps"] = round(abs(worst[1] - 1e8) / 1e4, 1)
        d["rounds_with_context"] = [[f(r[3]), r[1] / 1e8] for r in ctx][:40]
        res.append(d)
    out[leg] = res
json.dump(out, open(os.path.join(D, "depegs.json"), "w"), indent=1)
for leg, rs in out.items():
    print("==", leg)
    for d in rs:
        print({k: v for k, v in d.items() if k != "rounds_with_context"})

# ---- how often would each legBand have latched (distinct excursions, merged if < 6 h apart), by era ----
eras = {"all (2021-07 .. 2026-11)": 0, "since 2023-04-01": calendar_ts(2023, 4, 1) if False else 1680307200, "since 2024-09-01 (current aggregator family, phase 2+)": 1725148800}
tab = {}
for leg in ("USDC", "USDT"):
    F = load_feed(leg)
    for band in (30, 50, 75, 100, 150):
        for en, t0 in eras.items():
            eps = []; last = None; sec = 0
            for i, r in enumerate(F):
                if r[3] < t0: continue
                if abs(r[1] - 1e8) / 1e4 > band:
                    if last is None or r[3] - last > 6 * 3600: eps.append(r[3])
                    last = r[3]
            tab.setdefault(leg, {}).setdefault(str(band), {})[en] = {"distinct_excursions": len(eps), "first_times": [f(t) for t in eps][:12]}
json.dump(tab, open(os.path.join(D, "band_latch_counts.json"), "w"), indent=1)
for leg in tab:
    for band in tab[leg]: print(leg, band, {e: v["distinct_excursions"] for e, v in tab[leg][band].items()})
# Mar 2023 USDC timeline: first round beyond each threshold, seconds from the first move of 20 bps
for leg in ("USDC", "USDT"):
    F = load_feed(leg); w = [r for r in F if 1678400000 <= r[3] <= 1678800000]
    for th in (20, 30, 50, 75, 100, 150, 300):
        r = next((r for r in w if abs(r[1] - 1e8) / 1e4 > th), None); print("Mar2023", leg, th, f(r[3]) if r else None, r[1] / 1e8 if r else None)
