# Public Routescan: map timestamps to blocks (no private RPC). Output: ../data/sample_blocks.json
import json, urllib.request, time, os
OUT = os.path.join(os.path.dirname(__file__), "..", "data"); os.makedirs(OUT, exist_ok=True)
def blk(ts):
    u = f"https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api?module=block&action=getblocknobytime&timestamp={ts}&closest=before"
    for i in range(3):
        try:
            r = json.load(urllib.request.urlopen(u, timeout=30)); return int(r["result"])
        except Exception as e: time.sleep(2)
    raise SystemExit("routescan fail")
E0 = 1793836800  # Thu 5 Nov 2026 00:00 UTC (current epoch start)
epochs = [E0 - k*604800 for k in range(0, 14)]  # 14 epoch starts, covers 90d for peg
res = {"epoch_start_blocks": {}, "samples": {}}
for e in epochs:
    res["epoch_start_blocks"][e] = blk(e); time.sleep(0.3)
# 2-day samples from 10 Sep 00:00 to now at 12:00 UTC
t = 1788998400 + 12*3600
while t < 1794384293:
    res["samples"][t] = blk(t); t += 2*86400; time.sleep(0.3)
res["pin_block"] = 100006143
json.dump(res, open(os.path.join(OUT, "sample_blocks.json"), "w"), indent=1)
print(len(res["samples"]), "samples")
