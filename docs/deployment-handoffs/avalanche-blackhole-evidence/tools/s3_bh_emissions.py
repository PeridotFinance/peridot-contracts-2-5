# Public Routescan: RewardAdded(uint256) events of the two Blackhole GaugeCL contracts (weekly BLACK notified to the gauge).
import json, urllib.request, time, os, subprocess
OUT = os.path.join(os.path.dirname(__file__), "..", "data")
topic = subprocess.check_output(["cast", "keccak", "RewardAdded(uint256)"]).decode().strip()
G = {"bh_wbtc_btcb": "0x27a4ABa43385a1bf38e5Ed3140658E74886F9b03", "bh_ausd_usdc": "0xB456B3d0c8e50A1f61224C172af8a9AD928aF4FA"}
res = {}
for n, g in G.items():
    u = f"https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api?module=logs&action=getLogs&fromBlock=92124275&toBlock=100006143&address={g}&topic0={topic}&page=1&offset=1000"
    r = json.load(urllib.request.urlopen(u, timeout=60))["result"]
    res[n] = [{"b": int(l["blockNumber"], 16), "ts": int(l["timeStamp"], 16), "amount": int(l["data"], 16)} for l in r]
    time.sleep(0.5)
json.dump(res, open(os.path.join(OUT, "bh_reward_added.json"), "w"), indent=1)
import datetime
for n, rows in res.items():
    print(n)
    for x in rows: print(" ", datetime.datetime.utcfromtimestamp(x["ts"]), x["ts"]//604800, x["amount"]/1e18)
