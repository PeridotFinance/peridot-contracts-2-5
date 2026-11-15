# Public Routescan getLogs: all Swap events of one pool between two blocks, decoded to JSONL. No private RPC used.
import json, urllib.request, time, sys, os
pool, name, frm, to = sys.argv[1].lower(), sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"  # Swap(address,address,int256,int256,uint160,uint128,int24)
OUT = os.path.join(os.path.dirname(__file__), "..", "data"); os.makedirs(OUT, exist_ok=True)
def s256(h):
    v = int(h, 16); return v - (1 << 256) if v >= (1 << 255) else v
def get(u):
    for i in range(4):
        try: return json.load(urllib.request.urlopen(u, timeout=60))
        except Exception as e: time.sleep(2 + 2*i)
    raise SystemExit("fail " + u[:80])
rows = []; WIN = 150000; OFF = 1000; b = frm
while b <= to:
    e = min(b + WIN - 1, to); page = 1
    while True:
        r = get(f"https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api?module=logs&action=getLogs&fromBlock={b}&toBlock={e}&address={pool}&topic0={TOPIC}&page={page}&offset={OFF}")
        res = r.get("result") or []
        if isinstance(res, str): res = []
        for l in res:
            d = l["data"][2:]; w = [d[i:i+64] for i in range(0, 320, 64)]
            tick = s256(w[4][-6:].rjust(64, "f" if int(w[4][-6], 16) >= 8 else "0")) if False else None
            t = int(w[4], 16); t = t - (1 << 256) if t >= (1 << 255) else t
            rows.append({"b": int(l["blockNumber"], 16), "ts": int(l["timeStamp"], 16), "a0": s256(w[0]), "a1": s256(w[1]),
                         "sp": int(w[2], 16), "L": int(w[3], 16), "tick": t, "tx": l["transactionHash"]})
        if len(res) < OFF: break
        page += 1; time.sleep(0.4)
        if page * OFF > 10000: print("WARN window too dense", b, e); break
    b = e + 1; time.sleep(0.3)
with open(os.path.join(OUT, f"swaps_{name}.jsonl"), "w") as f:
    for x in rows: f.write(json.dumps(x) + "\n")
print(name, len(rows), "swaps", rows[0]["ts"] if rows else None, rows[-1]["ts"] if rows else None)
