# Archive eth_call samples (paid endpoint via env AVALANCHE_RPC) every 2 days at 12:00 UTC: tick, pool liquidity, Blackhole gauge virtual-pool liquidity, sAVAX rate.
import json, os, time, sys
sys.path.insert(0, os.path.dirname(__file__))
from rpcpy import call, sel, u, s
OUT = os.path.join(os.path.dirname(__file__), "..", "data")
blocks = json.load(open(os.path.join(OUT, "sample_blocks.json")))
bl = sorted((int(t), b) for t, b in blocks["samples"].items())
bl.append((0, blocks["pin_block"]))  # pin
BH = {"bh_wbtc_btcb": ("0xfc231423e1a863d94abb21d9f68e8c2589b3edb9", "0x27a4ABa43385a1bf38e5Ed3140658E74886F9b03"),
      "bh_ausd_usdc": ("0x10ed86c3d147dcd4bdecacff5ada625328b9678d", "0xB456B3d0c8e50A1f61224C172af8a9AD928aF4FA")}
PH = {"ph_usdc_usdt": "0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0", "ph_savax_wavax": "0x65B9016c376604Fe0aF38c1E336Ffcec0F8ecBbD"}
S_GS, S_SLOT0, S_LIQ, S_TS = sel("globalState()"), sel("slot0()"), sel("liquidity()"), sel("totalSupply()")
SAVAX = "0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE"; S_RATE = sel("getPooledAvaxByShares(uint256)")
rows = []
for ts, b in bl:
    r = {"ts": ts, "block": b}
    for n, (pool, gauge) in BH.items():
        r[n] = {"tick": s(call(pool, S_GS, b), 1), "L": u(call(pool, S_LIQ, b)) if False else u(call(pool, S_LIQ, b)),
                "Lstaked": u(call(gauge, S_TS, b))}
        time.sleep(0.1)
    for n, pool in PH.items():
        r[n] = {"tick": s(call(pool, S_SLOT0, b), 1), "L": u(call(pool, S_LIQ, b))}
        time.sleep(0.1)
    r["savax_rate"] = u(call(SAVAX, S_RATE + (1 * 10**18).to_bytes(32, "big").hex(), b)) / 1e18
    rows.append(r); print(ts, b, flush=True)
json.dump(rows, open(os.path.join(OUT, "samples.json"), "w"), indent=1)
