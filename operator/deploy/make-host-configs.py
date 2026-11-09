#!/usr/bin/env python3
"""Generates the four per-host configurations (PUBLIC values only) from the deployed addresses, the one-input sizing and the host addresses.
Sources: docs/deployment-handoffs/avalanche-pilot-addresses.json, contracts/ceremony/pilot-sizing.json, operator/config/pilot.example.json (template),
the four public Droplet addresses below, and the reference-pool floor recorded by operator/scripts/compute-min-pool-liquidity.ts.
Output: operator/config/hosts/{op1,op2,keeper,rebalancer}.json. No key, no endpoint, no password.
Usage: python3 operator/deploy/make-host-configs.py [--margin margin-addresses.json]   (the margin block is written only with that file)
"""
import copy
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # repo
OP = os.path.join(ROOT, "operator")

HOSTS = {
    "op1": "0xA7640fc537E2172eD6c4b4A809C9456AbD60fbF4",
    "op2": "0xfbb137eBcBb0F7eb2Ba70F59ff0be9B0A0c5125d",
    "keeper": "0xaF0FAcd12A02b5b030eC7C3bf5dE0726C828935D",
    "rebalancer": "0x70f341B85222cF2E590E40d596DdBD7bF0a3ddB9",
}
# recorded by compute-min-pool-liquidity.js on 9 Nov 2026 (50% of the 7-day median of pool.liquidity(), archive reads, 169 hourly samples, 0 failed)
REFERENCE = {
    "toleranceBp": 500,
    "minPoolLiquidity": "1783127772391886766",
    "minPoolLiquiditySource": {
        "fromBlock": 99236259,
        "toBlock": 99856331,
        "samples": 169,
        "medianLiquidity": "3566255544783773533",
        "method": "50% of the median of pool.liquidity() sampled every 3600 s over 7 days (block time 0.975 s); min 1025890592826714279, max 5593890921320581419; 0 failed samples",
    },
}
LOG_CHUNK = 1000  # PAID Alchemy app (operator decision 9 Nov 2026, IP-allowlisted to the four Droplets): measured 10,000-block getLogs ok, 3/3 identical counts; 1,000 per request keeps responses small. The old Free-tier app allowed 10 blocks; the Avalanche public RPC 100 blocks and answered 429 (1015) under bursts
POLL_SECONDS = 30  # free-tier state endpoint: fewer reads per hour than the 15 s of the template


def main():
    addrs = json.load(open(os.path.join(ROOT, "docs/deployment-handoffs/avalanche-pilot-addresses.json")))
    sizing = json.load(open(os.path.join(ROOT, "contracts/ceremony/pilot-sizing.json")))
    tmpl = json.load(open(os.path.join(OP, "config/pilot.example.json")))
    oc = sizing["operator_config"]
    floor = sizing["process_gas_floor_wei"]
    lend = addrs["lending"]
    base = copy.deepcopy(tmpl)
    base["deployment"] = dict(controller=lend["controller"], pWavax=lend["markets"]["pWAVAX"]["address"], pUsdc=lend["markets"]["pUSDC"]["address"],
                              oracle=lend["oracle"], deploymentBlock=addrs["deployBlock"])
    base["pilot"].update(usdcBorrowCapUsd=oc["usdcBorrowCapUsd"], protectionCapitalUsd=oc["protectionCapitalUsd"],
                         operatorInventoryMinUsd=oc["operatorInventoryMinUsd"], operatorInventoryTargetUsd=oc["operatorInventoryTargetUsd"], cashFloorBp=oc["cashFloorBp"])
    base["operators"] = [dict(name="op1", address=HOSTS["op1"]), dict(name="op2", address=HOSTS["op2"])]
    base["reference"] = REFERENCE
    base["treasury"] = dict(address=HOSTS["keeper"])
    base["monitor"]["pollSeconds"] = POLL_SECONDS
    base["monitor"]["statePath"] = "/data/state/state.json"
    # MEASURED 9 Nov 2026: the Avalanche public RPC refuses eth_getLogs over 100 blocks (not the 2,048 assumed); the free Alchemy app 10 blocks
    base["monitor"]["logChunkBlocks"] = LOG_CHUNK
    base["monitor"]["logs"]["chunkBlocks"] = LOG_CHUNK
    base["monitor"]["logs"]["maxChunksPerCycle"] = 20  # up to 20,000 blocks per cycle (about 7 s with 300 ms between requests, src/logpace.ts)
    base["monitor"]["minOperatorGasWei"] = floor
    base["executor"].update(enabled=False, operator="UNSET", keystorePath="UNSET", minGasWei=floor)
    base["rebalancer"].update(enabled=False, keystorePath="UNSET", minGasWei=floor)
    base["keeper"].update(enabled=False, keystorePath="UNSET", dailySpendCapUsdc=int(oc["keeperDailySpendCapUsdc"]), minGasWei=floor)
    base.pop("margin", None)  # the margin block is added with the margin addresses (stage 4), see avalanche-margin-operator-step.md
    outdir = os.path.join(OP, "config", "hosts")
    os.makedirs(outdir, exist_ok=True)
    for role in HOSTS:
        c = copy.deepcopy(base)
        ks = f"/data/keystore/{role}.json"
        if role in ("op1", "op2"):
            c["executor"].update(enabled=True, operator=role, keystorePath=ks, passwordEnv="OPERATOR_KEYSTORE_PASSWORD")
        elif role == "keeper":
            c["keeper"].update(enabled=True, keystorePath=ks)
        else:
            c["rebalancer"].update(enabled=True, keystorePath=ks)
        if role == "keeper":  # operator decision 9 Nov 2026: the keeper's chain-event scans (borrower index, 24 h spend) use the PUBLIC log endpoint: 100-block chunks
            c["monitor"]["logChunkBlocks"] = 100
            c["monitor"]["logs"]["chunkBlocks"] = 100
            c["monitor"]["logs"]["maxChunksPerCycle"] = 20
        c["monitor"]["pollSeconds"] = {"op1": POLL_SECONDS, "op2": POLL_SECONDS, "keeper": 60, "rebalancer": 120}[role]  # free-tier request budget: the executors stay at 30 s, the keeper and the hourly rebalancer poll less often
        json.dump(c, open(os.path.join(outdir, f"{role}.json"), "w"), indent=2)
        open(os.path.join(outdir, f"{role}.json"), "a").write("\n")
        print("wrote", os.path.join("operator/config/hosts", f"{role}.json"))


if __name__ == "__main__":
    sys.exit(main())
