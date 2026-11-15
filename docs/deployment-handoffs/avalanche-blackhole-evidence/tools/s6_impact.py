# Sale price impact for the reward tokens at the pin block, using the pairs' own getAmountOut (fee included) and reserves.
import json, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from rpcpy import call, sel, u, addr
OUT = os.path.join(os.path.dirname(__file__), "..", "data"); PIN = 100006143
BLACK = "0xcd94a87696FAC69Edae3a70fE5725307Ae1c43f6"; PHAR = "0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7"
USDC = "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"; WAVAX = "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7"
AVAXFEED = "0x0A77230d17318075983913bC2145DB16C7366156"
pad = lambda a: a[2:].lower().rjust(64, "0")
lr = call(AVAXFEED, sel("latestRoundData()"), PIN); avax = u(lr, 1) / 1e8
dec = call(AVAXFEED, sel("decimals()"), PIN)
print("AVAX/USD chainlink at pin", avax)
PAIRS = {
 "BLACK": [("blackhole-v2 BLACK/USDC", "0x0d9fd6dd9b1ff55fb0a9bb0e5f1b6a2d65b741a3", BLACK),
           ("blackhole-v2 BLACK/WAVAX", "0x14e4a5bed2e5e688ee1a5ca3a4914250d1abd573", BLACK)],
 "PHAR": [("pharaoh-legacy PHAR/WAVAX", "0x0afdee8162ccead9ac6a30c94f691e6e7d1af670", PHAR),
          ("pharaoh-legacy PHAR/USDC", "0x1b7bcd44e77adbb31bea105842139d78f352dc81", PHAR)]}
res = {"avax_usd_pin": avax, "pairs": []}
for tok, lst in PAIRS.items():
    for name, pair, tin in lst:
        t0 = addr(call(pair, sel("token0()"), PIN)); t1 = addr(call(pair, sel("token1()"), PIN))
        rv = call(pair, sel("getReserves()"), PIN); r0, r1 = u(rv, 0), u(rv, 1)
        stable = u(call(pair, sel("stable()"), PIN)) if True else 0
        other = t1 if t0.lower() == tin.lower() else t0
        rin, rout = (r0, r1) if t0.lower() == tin.lower() else (r1, r0)
        dout = 6 if other.lower() == USDC.lower() else 18
        usd_per_out = 1.0 if other.lower() == USDC.lower() else avax
        mid = (rout / 10**dout) / (rin / 1e18) * usd_per_out  # USD per reward token, marginal (reserve ratio, no fee)
        tvl_other_side = rout / 10**dout * usd_per_out
        row = {"token": tok, "pool": name, "pair": pair, "stable": bool(stable), "reserve_reward_token": rin / 1e18,
               "reserve_other": rout / 10**dout, "other_side_usd": tvl_other_side, "mid_usd_per_token": mid, "sales": []}
        for usd in (500, 2000):
            amt = int(usd / mid * 1e18)
            out = u(call(pair, sel("getAmountOut(uint256,address)") + hex(amt)[2:].rjust(64, "0") + pad(tin), PIN))
            got = out / 10**dout * usd_per_out
            row["sales"].append({"target_usd_at_mid": usd, "tokens_sold": amt / 1e18, "usd_out": got, "realised_vs_mid_pct": (got / usd - 1) * 100,
                                 "realised_usd_per_token": got / (amt / 1e18)})
        res["pairs"].append(row); print(json.dumps(row, indent=1))
json.dump(res, open(os.path.join(OUT, "sale_impact.json"), "w"), indent=1)
