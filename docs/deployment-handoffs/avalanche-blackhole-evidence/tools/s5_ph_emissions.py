# Pharaoh GaugeV3.tokenTotalSupplyByPeriod(period, token) at the pin block: weekly PHAR / xPHAR notified to each gauge.
import json, os, sys, time
sys.path.insert(0, os.path.dirname(__file__))
from rpcpy import call, sel, u
OUT = os.path.join(os.path.dirname(__file__), "..", "data"); PIN = 100006143
G = {"ph_usdc_usdt": "0xf51B4EB0f6801729170d18BEe67C7F5d98985572", "ph_savax_wavax": "0xCB348abA8D8CE40a45353955ad63ca72095E152d"}
PHAR = "0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7"; XPHAR = "0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A"
S = sel("tokenTotalSupplyByPeriod(uint256,address)")
pad = lambda a: a[2:].lower().rjust(64, "0")
res = {}
for n, g in G.items():
    res[n] = {}
    for p in range(2958, 2967):
        d = S + hex(p)[2:].rjust(64, "0")
        res[n][p] = {"PHAR": u(call(g, d + pad(PHAR), PIN)) / 1e18, "xPHAR": u(call(g, d + pad(XPHAR), PIN)) / 1e18}
        time.sleep(0.1)
VOTER = "0x" + "0"*40
json.dump(res, open(os.path.join(OUT, "ph_emissions.json"), "w"), indent=1)
for n, v in res.items(): print(n, {p: round(x["PHAR"], 3) for p, x in v.items()}, "xPHAR sum", sum(x["xPHAR"] for x in v.values()))
