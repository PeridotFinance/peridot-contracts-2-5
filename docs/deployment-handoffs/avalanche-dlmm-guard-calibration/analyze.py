"""W-CAL analysis (local data only, no RPC). Inputs: data/feed_rounds_{USDC,USDT}_all.json (fetch_feeds.py), the evidence pool series
(data/active_series.json in avalanche-pharaoh-dlmm-evidence, read-only, path via EVID env or default). Output: data/results.json (+ stdout).
Window = 30 UTC days 2026-10-12 00:00 .. 2026-11-10 23:59:59 (same as the second measurement)."""
import json, os, bisect, calendar, statistics, collections, datetime, sys
HERE = os.path.dirname(os.path.abspath(__file__)); D = os.path.join(HERE, "data")
EVID = os.environ.get("EVID", "/Users/joshua/Peridot/peridot-contracts-2-5/docs/deployment-handoffs/avalanche-pharaoh-dlmm-evidence/data")
def utc(y, m, d, H=0, M=0, S=0): return calendar.timegm((y, m, d, H, M, S))
W0 = utc(2026, 10, 12); W1 = utc(2026, 11, 11)           # [W0, W1)
fmt = lambda t: datetime.datetime.utcfromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S")
P0 = 1 << 23
# ---------- feeds ----------
def load_feed(leg):
    rows = json.load(open(os.path.join(D, "feed_rounds_%s_all.json" % leg)))
    ph = collections.defaultdict(list)
    for r in rows: ph[r[0] >> 64].append(r)
    for k in ph: ph[k].sort(key=lambda r: r[0])
    ks = sorted(ph); out = []
    for i, k in enumerate(ks):                  # a phase is in force from its first round until the next phase's first round
        end = ph[ks[i + 1]][0][3] if i + 1 < len(ks) else 1 << 62
        out += [r for r in ph[k] if r[3] < end]
    out.sort(key=lambda r: (r[3], r[0]))
    return out
FEED = {l: load_feed(l) for l in ("USDC", "USDT")}
FT = {l: [r[3] for r in FEED[l]] for l in FEED}
def feed_at(l, t):                              # (answer/1e8, updatedAt) in force at t
    i = bisect.bisect_right(FT[l], t) - 1
    r = FEED[l][i]; return r[1] / 1e8, r[3]
R = {}
# ---------- Q1: cadence ----------
def cadence(l, a, b):
    rs = [r for r in FEED[l] if a <= r[3] < b]
    inforce = FEED[l][bisect.bisect_right(FT[l], a) - 1]
    ts = [inforce[3]] + [r[3] for r in rs]; ans = [inforce[1]] + [r[1] for r in rs]
    gaps = [y - x for x, y in zip(ts, ts[1:])]
    tail = b - ts[-1]
    # staleness age at each instant: max age = max(gap, tail)  (age just before each update)
    pts = sorted(gaps)
    # fraction-of-time age > X
    def frac_age_gt(X): return sum(max(0, g - X) for g in gaps + [tail]) / (b - a)
    return {"rounds_in_window": len(rs), "max_age_s": max(gaps + [tail]), "max_age_h": round(max(gaps + [tail]) / 3600, 2),
            "median_gap_h": round(statistics.median(gaps) / 3600, 2) if gaps else None, "p90_gap_h": round(pts[int(.9 * (len(pts) - 1))] / 3600, 2) if pts else None,
            "gaps_over_24h": sum(1 for g in gaps if g > 86400), "gaps_over_26h": sum(1 for g in gaps if g > 93600),
            "age_at_window_end_h": round(tail / 3600, 2), "min_answer": min(ans) / 1e8, "max_answer": max(ans) / 1e8,
            "min_answer_ts": fmt(ts[ans.index(min(ans))]), "max_answer_ts": fmt(ts[ans.index(max(ans))]),
            "max_dev_bps_from_1": round(max(abs(x - 1e8) for x in ans) / 1e4, 2)}
R["cadence_window"] = {l: cadence(l, W0, W1) for l in FEED}
t_now = max(FT["USDC"][-1], FT["USDT"][-1])
R["cadence_phase3_since_aug2026"] = {l: cadence(l, utc(2026, 8, 3, 20), t_now + 1) for l in FEED}
R["cadence_all_history"] = {l: cadence(l, FEED[l][0][3] + 1, t_now + 1) for l in FEED}
by_year = {}
for l in FEED:
    for y in range(2021, 2027):
        a, b = max(utc(y, 1, 1), FT[l][0] + 1), utc(y + 1, 1, 1)
        if a < b and b <= t_now + 1e9:
            c = cadence(l, a, min(b, t_now + 1)); by_year.setdefault(l, {})[y] = {k: c[k] for k in ("rounds_in_window", "max_age_h", "median_gap_h", "gaps_over_24h", "gaps_over_26h", "min_answer", "max_answer")}
R["cadence_by_year"] = by_year
# ---------- pool series ----------
a = json.load(open(os.path.join(EVID, "active_series.json"))); TS, IDS = a["ts"], a["id"]
def active_before(t): return IDS[bisect.bisect_left(TS, t) - 1]
# breakpoints in window: pool events and feed updates
i0 = bisect.bisect_left(TS, W0); i1 = bisect.bisect_left(TS, W1)
ev_t = TS[i0:i1]; ev_id = IDS[i0:i1]
def oracle_ratio(t, orient):            # orient 'XY': pool tokenX=USDt, tokenY=USDC -> price(Y per X) = USDT/USDC
    c, _ = feed_at("USDC", t); u_, _ = feed_at("USDT", t)
    return (u_ / c) if orient == "XY" else (c / u_)
def dev_bps(id_, t, orient): return ((1.0001 ** (id_ - P0)) / oracle_ratio(t, orient) - 1) * 1e4
bps = {}
for orient in ("XY", "spec_literal"):
    o = orient if orient == "XY" else "YX"
    devs = [dev_bps(i, t, o) for t, i in zip(ev_t, ev_id)]
    bps[orient] = devs
# breakpoints for episode computation
bp = sorted(set(ev_t) | {t for l in FEED for t in FT[l] if W0 <= t < W1} | {W0})
def state_at(t): return active_before(t + 1)      # id after all events with ts <= t
def episodes(thr, o):
    ep = []; start = None
    for j, t in enumerate(bp):
        d = dev_bps(state_at(t), t, o); bad = abs(d) > thr
        if bad and start is None: start = t
        if not bad and start is not None: ep.append((start, t)); start = None
    if start is not None: ep.append((start, W1))
    return ep
# keeper-wanted re-centres: G1 (3 bins = active +-1) P1 exit-triggered, re-centre at exit+60 s  (literal copy of v2/a1/recount_p1.py k=1, but returning the times)
def p1_schedule(k=1, delay=60):
    c = active_before(W0); pend = None; i = bisect.bisect_left(TS, W0); n = len(TS); sched = []; exits = []
    groups = []
    while i < n and TS[i] < W1:
        j = i
        while j < n and TS[j] == TS[i]: j += 1
        groups.append((TS[i], IDS[j - 1])); i = j
    out_since = None
    for (t, last) in groups:
        while pend is not None and pend <= t:
            T = pend; c = active_before(T); sched.append((T, active_before(T))); pend = None; out_since = None
        was_out = out_since is not None; now_out = abs(last - c) > k
        if now_out and not was_out: out_since = t
        if not now_out and was_out: out_since = None
        if now_out and pend is None: pend = t + delay; exits.append(t)
    while pend is not None and pend < W1:
        T = pend; sched.append((T, active_before(T))); pend = None
    return sched, exits
sched, exits = p1_schedule()
R["window"] = {"start": fmt(W0), "end_exclusive": fmt(W1), "pool_events": len(ev_t), "keeper_recentres_G1_P1": len(sched), "exits_seen": len(exits)}
# ---------- Q2 table ----------
dtab = {}
for orient, o in (("XY (correct: tokenX=USDt, price=Y/X=USDT/USDC)", "XY"), ("spec_literal (USDC/USDT) - INVERTED vs pool", "YX")):
    devs = bps["XY" if o == "XY" else "spec_literal"]
    ad = [abs(x) for x in devs]
    rows = {"dev_bps_distribution_events": {"median": round(statistics.median(devs), 2), "p1": round(sorted(devs)[int(.01 * len(devs))], 2), "p99": round(sorted(devs)[int(.99 * len(devs))], 2),
                                          "min": round(min(devs), 2), "max": round(max(devs), 2), "abs_p99": round(sorted(ad)[int(.99 * len(ad))], 2), "abs_max": round(max(ad), 2)}}
    for thr in (20, 30, 40, 50, 60, 80, 100):
        nev = sum(1 for x in ad if x > thr); mins = len({t // 60 for t, x in zip(ev_t, ad) if x > thr})
        ep = episodes(thr, o); dur = [e - s for s, e in ep]
        blocked = []
        for (T, idT) in sched:
            if abs(dev_bps(idT, T, o)) > thr:
                # keeper retries; first breakpoint >= T where the guard is clear
                k = bisect.bisect_left(bp, T); w = None
                while k < len(bp):
                    if abs(dev_bps(state_at(bp[k]), bp[k], o)) <= thr: w = bp[k] - T; break
                    k += 1
                blocked.append(w if w is not None else W1 - T)
        rows[str(thr)] = {"events_over": nev, "events_pct": round(100 * nev / len(ad), 3), "distinct_minutes": mins, "episodes": len(ep), "longest_episode_s": max(dur) if dur else 0,
                          "total_seconds_over": sum(dur), "pct_of_window_time": round(100 * sum(dur) / (W1 - W0), 4),
                          "recentres_blocked": len(blocked), "of_recentres": len(sched), "blocked_delay_s_max": max(blocked) if blocked else 0, "blocked_delay_s_median": statistics.median(blocked) if blocked else 0}
    dtab[orient] = rows
R["pool_vs_oracle"] = dtab
# per-day worst
byday = collections.defaultdict(list)
for t, x in zip(ev_t, bps["XY"]): byday[(t - W0) // 86400].append(x)
R["pool_vs_oracle_daily_extremes_XY"] = {fmt(W0 + 86400 * d)[:10]: {"min": round(min(v), 1), "max": round(max(v), 1), "median": round(statistics.median(v), 1)} for d, v in sorted(byday.items())}
# worst 8 events
worst = sorted(range(len(ev_t)), key=lambda j: -abs(bps["XY"][j]))[:8]
R["pool_vs_oracle_worst_events_XY"] = [{"ts": fmt(ev_t[j]), "id": ev_id[j], "dev_bps": round(bps["XY"][j], 2)} for j in worst]
# ---------- leg band ----------
def leg_band(l, band):
    rs = [(FT[l][i], FEED[l][i][1]) for i in range(len(FT[l]))]
    # time-weighted over window
    pts = [(W0, feed_at(l, W0)[0])] + [(r[3], r[1] / 1e8) for r in FEED[l] if W0 < r[3] < W1]
    out = 0; cnt = 0
    for j, (t, v) in enumerate(pts):
        e = pts[j + 1][0] if j + 1 < len(pts) else W1
        if abs(v - 1) * 1e4 > band: out += e - t; cnt += 1
    return {"rounds_outside": cnt, "seconds_outside": out}
R["leg_band"] = {l: {str(b): leg_band(l, b) for b in (20, 30, 50, 100)} for l in FEED}
# ---------- Q4 ----------
def perday(ts_list):
    c = collections.Counter((t - W0) // 86400 for t in ts_list); v = [c.get(d, 0) for d in range(30)]
    sv = sorted(v); return {"max": max(v), "p90": sv[int(math.ceil(.9 * 30)) - 1], "median": statistics.median(v), "mean": round(sum(v) / 30, 2), "per_day": v}
import math
def stats_cnt(label, ts_list):
    pd_ = perday(ts_list)
    ch = collections.Counter(t // 3600 for t in ts_list); mx_h = max(ch.values()) if ch else 0
    return {"count": len(ts_list), "per_day": pd_, "max_per_hour": mx_h}
Tsched = [T for T, _ in sched]
R["rebalance_counts_G1_P1"] = {"recentre_times (exit+60 s)": stats_cnt("rc", Tsched), "exit_times": stats_cnt("ex", exits)}
# also the 5-bin and 1-bin reference
for k in (0, 2):
    s2, e2 = p1_schedule(k); R["rebalance_counts_G%d_P1" % k] = {"recentres": stats_cnt("rc", [T for T, _ in s2])["count"], "max_per_day": perday([T for T, _ in s2])["max"], "max_per_hour": stats_cnt("", [T for T, _ in s2])["max_per_hour"]}
# cooldown: actual = max(desired, last_actual + cd)
def cooldown(cd):
    last = None; delays = []; acts = []
    for T in Tsched:
        a_ = T if last is None else max(T, last + cd); delays.append(a_ - T); last = a_; acts.append(a_)
    gaps = [y - x for x, y in zip(Tsched, Tsched[1:])]
    return {"cooldown_s": cd, "delayed": sum(1 for d in delays if d > 0), "max_delay_s": max(delays), "median_delay_of_delayed_s": statistics.median([d for d in delays if d > 0]) if any(delays) else 0,
            "total_delay_s": sum(delays), "min_gap_between_desired_s": min(gaps), "gaps_lt_111s": sum(1 for g in gaps if g < 111), "gaps_lt_120s": sum(1 for g in gaps if g < 120), "gaps_lt_300s": sum(1 for g in gaps if g < 300),
            "gaps_lt_600s": sum(1 for g in gaps if g < 600)}
R["cooldown_effect"] = {str(cd): cooldown(cd) for cd in (111, 120, 300, 600)}
# the day-level cap: with cap C how many rebalances (G1) are refused
R["cap_effect"] = {str(c): sum(max(0, v - c) for v in perday(Tsched)["per_day"]) for c in (8, 12, 16, 24, 32, 48)}
# rolling 24 h maximum (if the contract counts a rolling day instead of a UTC day)
import bisect as _b
roll = max(_b.bisect_right(Tsched, t + 86400) - i for i, t in enumerate(Tsched))
R["rebalance_counts_G1_P1"]["max_rolling_24h"] = roll
R["rebalance_counts_G1_P1"]["max_per_hour_rolling"] = max(_b.bisect_right(Tsched, t + 3600) - i for i, t in enumerate(Tsched))
# incomplete rounds (answeredInRound < roundId) and non-positive answers anywhere in history
R["feed_integrity"] = {l: {"rounds": len(FEED[l]), "answeredInRound_lt_roundId": sum(1 for r in FEED[l] if r[4] < r[0]), "answer_le_0": sum(1 for r in FEED[l] if r[1] <= 0)} for l in FEED}
json.dump(R, open(os.path.join(D, "results.json"), "w"), indent=1)
print(json.dumps({k: v for k, v in R.items() if k not in ("pool_vs_oracle_daily_extremes_XY",)}, indent=1)[:20000])
