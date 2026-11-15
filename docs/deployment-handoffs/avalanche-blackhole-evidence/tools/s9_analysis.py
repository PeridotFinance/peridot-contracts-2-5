"""Offline analysis of the saved data (no network). Produces data/analysis.json.
Definitions are stated in the report; formulas are in the code below."""
import json, os, math, bisect, datetime, statistics
D = os.path.join(os.path.dirname(__file__), "..", "data")
J = lambda n: json.load(open(os.path.join(D, n)))
swaps = {n: [json.loads(l) for l in open(os.path.join(D, f"swaps_{n}.jsonl"))] for n in ["bh_wbtc_btcb", "bh_ausd_usdc", "ph_usdc_usdt", "ph_savax_wavax"]}
samples = J("samples.json"); llama = J("llama_4h.json"); bh_em = J("bh_reward_added.json"); ph_em = J("ph_emissions.json"); impact = J("sale_impact.json")
POOLS = {  # dec0, dec1, token0, token1, band-half-width, peg kind
 "bh_wbtc_btcb": (8, 8, "WBTC", "BTCb"), "bh_ausd_usdc": (6, 6, "AUSD", "USDC"),
 "ph_usdc_usdt": (6, 6, "USDt", "USDC"), "ph_savax_wavax": (18, 18, "sAVAX", "WAVAX")}
def px(sym, ts):
    arr = llama[sym]["prices"]; i = bisect.bisect_right([p["timestamp"] for p in arr], ts) - 1
    return arr[max(i, 0)]["price"]
_ts = {k: [p["timestamp"] for p in v["prices"]] for k, v in llama.items()}
def pxf(sym, ts):
    t = _ts[sym]; i = max(bisect.bisect_right(t, ts) - 1, 0); return llama[sym]["prices"][i]["price"]
def pool_price(sp, d0, d1): return (sp / 2**96) ** 2 * 10 ** (d0 - d1)   # token1 per token0 in human units
NOW = 1794384293; T90 = NOW - 90 * 86400
E0 = 1793836800
EPOCHS = [E0 - k * 604800 for k in range(8, -1, -1)]  # 2958..2966 (last partial)
out = {"epochs": EPOCHS}
# ---------- peg ----------
def refratio(name, ts):
    a, b = POOLS[name][2], POOLS[name][3]
    if name == "ph_savax_wavax": return rate_at(ts)   # Llama sAVAX price is unreliable (see report); use the contract exchange rate
    return pxf(b, ts) / pxf(a, ts)   # market (llama) token1/token0
rate_pts = sorted((r["ts"], r["savax_rate"]) for r in samples if r["ts"])
def rate_at(ts):
    i = bisect.bisect_right([t for t, _ in rate_pts], ts) - 1; return rate_pts[max(i, 0)][1]
peg = {}
for n, rows in swaps.items():
    d0, d1 = POOLS[n][:2]; rows = [r for r in rows if r["ts"] >= T90]
    degenerate = [r for r in rows if abs(r["tick"]) > 800000 or r["L"] == 0]
    rows = [r for r in rows if not (abs(r["tick"]) > 800000 or r["L"] == 0)]
    ser = []
    for r in rows:
        p = pool_price(r["sp"], d0, d1)
        ref_par = rate_at(r["ts"]) if n == "ph_savax_wavax" else 1.0
        ser.append((r["ts"], p, p / ref_par - 1, p / refratio(n, r["ts"]) - 1))
    thr = 0.01 if n == "ph_savax_wavax" else 0.0025
    # time-weighted exposure: price persists until next swap
    exp = {t: 0.0 for t in (0.001, 0.0025, 0.005, 0.01, 0.02)}; tot = 0.0
    for i, (ts, p, dev, dm) in enumerate(ser):
        nxt = ser[i + 1][0] if i + 1 < len(ser) else NOW
        for t in exp:
            if abs(dev) > t: exp[t] += nxt - ts
        tot += nxt - ts
    worst = max(ser, key=lambda x: abs(x[2]))
    wi = ser.index(worst)
    # episode: contiguous swaps with |dev|>thr and same sign containing worst
    s0 = wi
    while s0 > 0 and abs(ser[s0 - 1][2]) > thr and (ser[s0 - 1][2] > 0) == (worst[2] > 0): s0 -= 1
    s1 = wi
    while s1 + 1 < len(ser) and abs(ser[s1 + 1][2]) > thr and (ser[s1 + 1][2] > 0) == (worst[2] > 0): s1 += 1
    ep_start = ser[s0][0]; ep_end = ser[s1 + 1][0] if s1 + 1 < len(ser) else NOW
    wsw = rows[wi]; usd0 = abs(wsw["a0"]) / 10 ** d0
    sizeusd = max(abs(wsw["a0"]) / 10 ** d0 * pxf(POOLS[n][2], wsw["ts"]), abs(wsw["a1"]) / 10 ** d1 * pxf(POOLS[n][3], wsw["ts"]))
    devs = [abs(x[2]) for x in ser]
    # distribution of the swap-time deviation (unweighted)
    def notional(r): return max(abs(r["a0"]) / 10 ** d0 * pxf(POOLS[n][2], r["ts"]), abs(r["a1"]) / 10 ** d1 * pxf(POOLS[n][3], r["ts"]))
    big = {}
    for mn in (100, 1000, 10000):
        c = [(abs(x[2]), x, r) for x, r in zip(ser, rows) if notional(r) >= mn]
        if c:
            _, x, r = max(c, key=lambda z: z[0]); big[str(mn)] = {"dev_pct": x[2] * 100, "iso": datetime.datetime.utcfromtimestamp(x[0]).isoformat() + "Z", "notional_usd": notional(r), "n_swaps_ge": len(c)}
    peg[n] = {"degenerate_events": [{"iso": datetime.datetime.utcfromtimestamp(r["ts"]).isoformat() + "Z", "tick": r["tick"], "pool_L_after": r["L"], "block": r["b"], "tx": r["tx"], "notional_usd": notional(r)} for r in degenerate],
              "worst_by_min_swap_notional": big, "n_swaps": len(ser), "first_ts": ser[0][0], "last_ts": ser[-1][0],
              "worst_dev_pct_vs_parity_or_rate": worst[2] * 100, "worst_ts": worst[0], "worst_iso": datetime.datetime.utcfromtimestamp(worst[0]).isoformat() + "Z",
              "worst_pool_price": worst[1], "worst_dev_pct_vs_llama": worst[3] * 100, "worst_swap_usd": sizeusd, "worst_swap_block": wsw["b"], "worst_swap_tx": wsw["tx"],
              "episode_threshold_pct": thr * 100, "episode_start_iso": datetime.datetime.utcfromtimestamp(ep_start).isoformat() + "Z", "episode_duration_h": (ep_end - ep_start) / 3600,
              "episode_n_swaps": s1 - s0 + 1,
              "share_of_time_above_pct": {str(k * 100): v / tot * 100 for k, v in exp.items()}, "hours_above_pct": {str(k * 100): v / 3600 for k, v in exp.items()},
              "median_abs_dev_pct": statistics.median(devs) * 100, "p95_abs_dev_pct": sorted(devs)[int(.95 * len(devs))] * 100,
              "latest_pool_price": ser[-1][1]}
    # llama-vs-parity worst (market)
    arr = [(ts, refratio(n, ts) / (rate_at(ts) if n == "ph_savax_wavax" else 1.0) - 1) for ts in range(T90, NOW, 4 * 3600)]
    w2 = max(arr, key=lambda x: abs(x[1])); peg[n]["llama_worst_dev_pct"] = w2[1] * 100; peg[n]["llama_worst_iso"] = datetime.datetime.utcfromtimestamp(w2[0]).isoformat() + "Z"
out["peg"] = peg
# ---------- arbitrage loss (LVR ex-fee, markout vs reference), 8 completed epochs ----------
# per swap: pnl_i = value(received) - value(paid) at the reference price (the pool's swap amounts include the fee the taker paid).
# LVR_i = fee_i - pnl_i  (value the taker extracted beyond the fee they paid; positive = LP loses). fee_i = amountIn * pool fee rate.
FEE = {"bh_wbtc_btcb": 100e-6, "bh_ausd_usdc": 75e-6, "ph_usdc_usdt": 50e-6, "ph_savax_wavax": 100e-6}
LP_FEE_SHARE = {"bh_wbtc_btcb": 0.0, "bh_ausd_usdc": 0.0, "ph_usdc_usdt": 0.75, "ph_savax_wavax": 0.75}  # Blackhole: communityFee 1000/1000; Pharaoh: feeProtocol 250000/1e6
W0, W1 = EPOCHS[0], EPOCHS[8]
lv = {}
for n, rows in swaps.items():
    d0, d1 = POOLS[n][:2]; r_ = [r for r in rows if W0 <= r["ts"] < W1]
    per_week = {e: {kind + "_" + k: 0.0 for kind in ("parity", "market") for k in ("lvr_net", "lvr_gross", "pos_lvr_net", "pos_lvr_gross", "pos_fee")} for e in EPOCHS[:8]}
    for e in per_week: per_week[e].update({"vol": 0.0, "n": 0})
    worst = {"parity": (-1e18, None), "market": (-1e18, None)}
    for r in r_:
        a0 = r["a0"] / 10 ** d0; a1 = r["a1"] / 10 ** d1; ts = r["ts"]; ep = ts // 604800 * 604800
        if ep not in per_week or abs(r["tick"]) > 800000 or r["L"] == 0: continue
        P = pool_price(r["sp"], d0, d1)
        for kind in ("parity", "market"):
            if kind == "parity":
                p1usd = pxf(POOLS[n][3], ts); p0usd = p1usd * (rate_at(ts) if n == "ph_savax_wavax" else 1.0)
            else:
                p1usd = pxf(POOLS[n][3], ts); p0usd = (p1usd * rate_at(ts)) if n == "ph_savax_wavax" else pxf(POOLS[n][2], ts)
            pnl = a0 * p0usd + a1 * p1usd
            amt_in_usd = a0 * p0usd if a0 > 0 else a1 * p1usd
            fee = amt_in_usd * FEE[n]; lvr = fee - pnl
            sP = math.sqrt(P * 10 ** (d1 - d0)); sa, sb = sP / math.sqrt(1.001), sP * math.sqrt(1.001)
            v_per_L = (1 / sP - 1 / sb) / 10 ** d0 * p0usd + (sP - sa) / 10 ** d1 * p1usd
            Lm = 1000 / v_per_L; share = Lm / (r["L"] + Lm)
            CAP = 2.0  # a USD 1,000 +-0.1 % position cannot lose more than ~its band width (0.2 %, USD 2) in one swap: cap the attribution
            attr = max(-CAP, min(CAP, lvr * share))
            w = per_week[ep]; w[kind + "_lvr_net"] += lvr; w[kind + "_lvr_gross"] += max(0.0, lvr)
            w[kind + "_pos_lvr_net"] += attr; w[kind + "_pos_lvr_gross"] += max(0.0, attr); w[kind + "_pos_fee"] += fee * LP_FEE_SHARE[n] * share
            if attr > worst[kind][0]: worst[kind] = (attr, {"iso": datetime.datetime.utcfromtimestamp(ts).isoformat() + "Z", "tx": r["tx"], "lvr_usd": lvr, "swap_notional_usd": amt_in_usd, "pool_L_after": r["L"], "share_of_1000usd_position": share, "attributed_to_1000usd_position_usd_capped": attr, "attributed_uncapped_usd": lvr * share})
        per_week[ep]["vol"] += max(abs(a0) * pxf(POOLS[n][2], ts), abs(a1) * pxf(POOLS[n][3], ts)); per_week[ep]["n"] += 1
    lv[n] = {"per_week": {str(k // 604800): v for k, v in per_week.items()}, "worst_swap": {k: v[1] for k, v in worst.items()}}
out["lvr"] = lv
# ---------- emissions per $1000 ----------
def tick_to_P(t, d0, d1): return 1.0001 ** t * 10 ** (d0 - d1)
em = {}
for n in swaps:
    d0, d1 = POOLS[n][:2]; rows = []
    for e in EPOCHS:
        if n.startswith("bh"):
            E = sum(x["amount"] for x in bh_em[n] if e <= x["ts"] < e + 604800) / 1e18; tok = "BLACK"
        else:
            E = ph_em[n][str(e // 604800)]["PHAR"]; tok = "PHAR"
        ss = [r for r in samples if r["ts"] and e <= r["ts"] < e + 604800]
        marg = []; head = []; Ls = []; Vin = []
        for r in ss:
            t = r[n]["tick"]; Lp = r[n]["Lstaked"] if n.startswith("bh") else r[n]["L"]; P = tick_to_P(t, d0, d1)
            p1usd = pxf(POOLS[n][3], r["ts"]); p0usd = pxf(POOLS[n][2], r["ts"])
            if n == "ph_savax_wavax": p0usd = p1usd * P
            sP = math.sqrt(P * 10 ** (d1 - d0)); sa, sb = sP / math.sqrt(1.001), sP * math.sqrt(1.001)
            v_per_L = (1 / sP - 1 / sb) / 10 ** d0 * p0usd + (sP - sa) / 10 ** d1 * p1usd
            Lm = 1000 / v_per_L
            marg.append(Lm / (Lp + Lm)); Ls.append(Lp); Vin.append(Lp * v_per_L)
            head.append(1000 / (Lp * v_per_L) if Lp > 0 else float("inf"))
        k = len(ss)
        rows.append({"period": e // 604800, "start_iso": datetime.datetime.utcfromtimestamp(e).strftime("%Y-%m-%d"), "partial": e == EPOCHS[-1], "emission_tokens": E, "reward_token": tok,
                     "n_samples": k, "mean_inrange_staked_L": (sum(Ls) / k if k else None), "mean_usd_of_L_in_pm01pct_band": (sum(Vin) / k if k else None),
                     "marginal_share_of_1000usd_pm01pct": (sum(marg) / k if k else None),
                     "tokens_per_1000usd_marginal": (E * sum(marg) / k if k else None),
                     "tokens_per_1000usd_headline_prorata": (E * sum(min(h, 1e9) for h in head) / k if k else None)})
    em[n] = rows
out["emissions"] = em
json.dump(out, open(os.path.join(D, "analysis.json"), "w"), indent=1)
for n in peg: print(n, json.dumps(peg[n], indent=None)[:900])
