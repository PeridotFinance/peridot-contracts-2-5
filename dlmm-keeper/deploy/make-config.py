#!/usr/bin/env python3
"""Generates the DLMM keeper's host.json (PUBLIC values only, mode dry-run) from the template and explicit arguments.
Usage: python3 dlmm-keeper/deploy/make-config.py --vault 0x.. --keeper 0x.. --usdc 0x.. --usdt 0x.. --feed-usdc 0x.. --feed-usdt 0x.. [--out FILE]
No key, no endpoint, no password. The pair is already in the template (the live Pharaoh USDC/USDt pair)."""
import json, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
def arg(n, d=None):
    a = sys.argv[1:]
    return a[a.index(n) + 1] if n in a else d
def addr(n):
    v = arg(n)
    assert v and v.startswith("0x") and len(v) == 42, f"{n} must be a 0x address"
    return v
c = json.load(open(os.path.join(HERE, "..", "config", "dlmm-keeper.example.json")))
c.update(label="pilot-avalanche-dlmm-usdc-usdt", mode="dry-run", vault=addr("--vault"), assetToken=addr("--usdc"), pairToken=addr("--usdt"))
c["feeds"] = {"asset": addr("--feed-usdc"), "pair": addr("--feed-usdt")}
c["keeper"]["address"] = addr("--keeper")
c["alerts"]["channel"] = "log"
out = arg("--out", os.path.join(HERE, "..", "config", "host.json"))
json.dump(c, open(out, "w"), indent=2); open(out, "a").write("\n"); print("wrote", out)
