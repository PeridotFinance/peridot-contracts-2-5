# (a) USD conversion of depth; (b) fee-only sale quotes for actual weekly amounts; (c) staked share; (d) GeckoTerminal TVL/volume snapshot for the 4 pools.
import json, os, sys, urllib.request, time
sys.path.insert(0, os.path.dirname(__file__))
D = os.path.join(os.path.dirname(__file__), "..", "data"); PIN = 100006143
J = lambda n: json.load(open(os.path.join(D, n)))
llama = J("llama_4h.json"); last = lambda s: llama[s]["prices"][-1]["price"]
avax = J("sale_impact.json")["avax_usd_pin"]
dep = {}
CFG = {"bh_wbtc_btcb": (8, 8, last("WBTC"), last("BTCb")), "bh_ausd_usdc": (6, 6, 1.0, 1.0), "ph_usdc_usdt": (6, 6, 1.0, 1.0)}
for n in ["bh_wbtc_btcb", "bh_ausd_usdc", "ph_usdc_usdt", "ph_savax_wavax"]:
    d = J(f"depth_{n}.json")
    if n == "ph_savax_wavax": d0, d1, p0, p1 = 18, 18, avax * 1.2930, avax
    else: d0, d1, p0, p1 = CFG[n]
    out = {}
    for dirn, dec, p in (("up", d1, p1), ("down", d0, p0)):  # up: token1 in; down: token0 in
        t = d["raw"][dirn]
        out[dirn] = {x: {"usd": v["raw_in"] / 10 ** dec * p, "reachable": v["reachable"]} for x, v in t["targets"].items()}
        out[dirn]["dry_at_pct"] = d["raw"][dirn]["dry_at_pct"]
    dep[n] = out; print(n, json.dumps(out))
json.dump(dep, open(os.path.join(D, "depth_usd.json"), "w"), indent=1)
# staked share of pool liquidity (Blackhole)
smp = J("samples.json"); sh = {}
for n in ("bh_wbtc_btcb", "bh_ausd_usdc"):
    xs = [r[n]["Lstaked"] / r[n]["L"] for r in smp if r["ts"] and r[n]["L"]]; sh[n] = {"mean": sum(xs) / len(xs), "min": min(xs), "max": max(xs), "n": len(xs)}
print("staked/L", sh)
# fee-only quotes for realistic weekly amounts
from rpcpy import call, sel, u
pad = lambda a: a[2:].lower().rjust(64, "0")
Q = [("BLACK/USDC", "0x0d9fd6dd9b1ff55fb0a9bb0e5f1b6a2d65b741a3", "0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6", 1600, 6, 1.0),
     ("PHAR/WAVAX", "0x0afdee8162ccead9ac6a30c94f691e6e7d1af670", "0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7", 25, 18, avax),
     ("PHAR/WAVAX", "0x0afdee8162ccead9ac6a30c94f691e6e7d1af670", "0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7", 440, 18, avax)]
si = J("sale_impact.json"); mids = {"BLACK/USDC": si["pairs"][0]["mid_usd_per_token"], "PHAR/WAVAX": si["pairs"][2]["mid_usd_per_token"]}
res = []
for name, pair, tin, amt, dout, pusd in Q:
    out = u(call(pair, sel("getAmountOut(uint256,address)") + hex(amt * 10**18)[2:].rjust(64, "0") + pad(tin), PIN)) / 10 ** dout * pusd
    res.append({"pair": name, "tokens": amt, "usd_out": out, "usd_per_token": out / amt, "vs_mid_pct": (out / amt / mids[name] - 1) * 100}); print(res[-1])
json.dump({"staked_share": sh, "small_sales": res}, open(os.path.join(D, "extra.json"), "w"), indent=1)
snap = {}
for n, a in {"bh_wbtc_btcb": "0xfc231423e1a863d94abb21d9f68e8c2589b3edb9", "bh_ausd_usdc": "0x10ed86c3d147dcd4bdecacff5ada625328b9678d", "ph_usdc_usdt": "0x9bfe3108cc16d17a9ec65545a0f50b2ca1c970c0", "ph_savax_wavax": "0x65b9016c376604fe0af38c1e336ffcec0f8ecbbd"}.items():
    try:
        r = json.load(urllib.request.urlopen(f"https://api.geckoterminal.com/api/v2/networks/avax/pools/{a}", timeout=30))["data"]["attributes"]
        snap[n] = {"name": r["name"], "reserve_in_usd": r["reserve_in_usd"], "volume_h24": r["volume_usd"]["h24"], "volume_h6": r["volume_usd"]["h6"]}
    except Exception as e: snap[n] = {"err": str(e)}
    time.sleep(2.5)
json.dump(snap, open(os.path.join(D, "gecko_snapshot.json"), "w"), indent=1); print(snap)
