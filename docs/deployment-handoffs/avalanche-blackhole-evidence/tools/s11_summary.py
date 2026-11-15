import json, os, statistics as st
D = os.path.join(os.path.dirname(__file__), "..", "data"); J = lambda n: json.load(open(os.path.join(D, n)))
a = J("analysis.json"); si = J("sale_impact.json"); ex = J("extra.json")
PR = {"BLACK": {"mid": si["pairs"][0]["mid_usd_per_token"], "s500": si["pairs"][0]["sales"][0]["realised_usd_per_token"], "s2000": si["pairs"][0]["sales"][1]["realised_usd_per_token"], "small": ex["small_sales"][0]["usd_per_token"]},
      "PHAR": {"mid": si["pairs"][2]["mid_usd_per_token"], "s500": si["pairs"][2]["sales"][0]["realised_usd_per_token"], "s2000": si["pairs"][2]["sales"][1]["realised_usd_per_token"], "small": ex["small_sales"][1]["usd_per_token"]}}
S = {}
for n, rows in a["emissions"].items():
    r8 = [r for r in rows if not r["partial"]]; tok = r8[0]["reward_token"]; p = PR[tok]
    E = [r["emission_tokens"] for r in r8]; M = [r["tokens_per_1000usd_marginal"] for r in r8]; V = [r["mean_usd_of_L_in_pm01pct_band"] for r in r8]; SH = [r["marginal_share_of_1000usd_pm01pct"] for r in r8]
    lv = a["lvr"][n]["per_week"]
    g = {k: [w[k] for w in lv.values()] for k in ("parity_pos_lvr_gross", "market_pos_lvr_gross", "parity_pos_lvr_net", "market_pos_lvr_net", "parity_pos_fee")}
    S[n] = {"token": tok, "gauge_weekly_tokens": E, "gauge_weekly_usd_mid_total": sum(E) / 8 * p["mid"], "gauge_tokens_med": st.median(E), "gauge_tokens_mean": st.mean(E),
            "per1000_tokens": M, "per1000_tokens_median": st.median(M), "per1000_tokens_mean": st.mean(M), "per1000_tokens_min": min(M), "per1000_tokens_max": max(M),
            "per1000_usd_median": {k: st.median(M) * v for k, v in p.items()}, "per1000_usd_mean": {k: st.mean(M) * v for k, v in p.items()},
            "inrange_band_usd_median": st.median(V), "inrange_band_usd_min": min(V), "inrange_band_usd_max": max(V), "marginal_share_median": st.median(SH),
            "lvr_gross_per1000_week_median": {k: st.median(v) for k, v in g.items()}, "lvr_gross_per1000_week_mean": {k: st.mean(v) for k, v in g.items()}, "lvr_gross_per1000_week_max": {k: max(v) for k, v in g.items()},
            "total_8wk_volume_usd": sum(w["vol"] for w in lv.values()), "n_swaps_8wk": sum(w["n"] for w in lv.values())}
json.dump({"prices": PR, "summary": S}, open(os.path.join(D, "summary.json"), "w"), indent=1)
print(json.dumps(PR))
for n, s in S.items(): print(n, json.dumps({k: v for k, v in s.items() if k not in ("per1000_tokens", "gauge_weekly_tokens")}, default=lambda x: round(x, 4)))
