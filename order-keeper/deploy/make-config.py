#!/usr/bin/env python3
"""Generates the order keeper's host.json (PUBLIC values only) from the margin addresses file and the template.
Usage: python3 order-keeper/deploy/make-config.py <keeper address> [--margin contracts/ceremony/margin-addresses.env] [--out FILE]
No key, no endpoint, no password."""
import json, os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def arg(n, d=None):
    a = sys.argv[1:]; return a[a.index(n) + 1] if n in a else d
keeper = sys.argv[1]
assert keeper.startswith("0x") and len(keeper) == 42
m = {}
for line in open(os.path.join(ROOT, arg("--margin", "contracts/ceremony/margin-addresses.env"))):
    if line.startswith("export "):
        k, v = line[7:].strip().split("=", 1); m[k] = v.strip('"')
c = json.load(open(os.path.join(ROOT, "order-keeper/config/order-keeper.example.json")))
c.update(label="pilot-avalanche-margin", registry=m["M_REGISTRY"], closeAdapter=m["M_CLOSE_ADAPTER"], marginExecutor=m["M_EXECUTOR"], marginVault=m["M_VAULT"])
c["keeper"]["address"] = keeper
c["alerts"]["channel"] = "log"
c["logs"].update(chunkBlocks=100, maxChunksPerCycle=10)  # the keeper validator caps the chunk at 100; the cross-check reads OrderCreated events from the head forward
out = arg("--out", os.path.join(ROOT, "order-keeper/config/host.json"))
json.dump(c, open(out, "w"), indent=2); open(out, "a").write("\n"); print("wrote", out)
