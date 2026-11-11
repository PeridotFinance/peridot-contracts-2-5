"""Minimal JSON-RPC helper. Endpoint is read ONLY from env AVALANCHE_RPC and never printed or written.
Counts calls in a file (RPC_COUNT_FILE) so the report can state the total."""
import os, json, urllib.request, time, sys
_URL = os.environ.get("AVALANCHE_RPC")
_CNT = os.environ.get("RPC_COUNT_FILE", "/tmp/bh_rpc_count")
def _count(n):
    with open(_CNT, "a") as f: f.write("1\n" * n)
def rpc(method, params, retries=2):
    if not _URL: raise SystemExit("AVALANCHE_RPC not set")
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(_URL, body, {"Content-Type": "application/json"})
    _count(1)
    try:
        r = json.load(urllib.request.urlopen(req, timeout=60))
    except urllib.error.HTTPError as e:
        if e.code == 429: print("HTTP 429 from paid endpoint: STOP", file=sys.stderr); raise SystemExit(429)
        raise
    if "error" in r: raise RuntimeError(str(r["error"])[:200])
    return r["result"]
def call(to, data, block="latest"):
    return rpc("eth_call", [{"to": to, "data": data}, block if isinstance(block, str) else hex(block)])
def sel(sig):
    import subprocess
    return subprocess.check_output(["cast", "sig", sig]).decode().strip()
def u(x, i=0): return int(x[2 + 64*i: 2 + 64*(i+1)], 16)
def s(x, i=0):
    v = u(x, i); return v - (1 << 256) if v >= (1 << 255) else v
def addr(x, i=0): return "0x" + x[2 + 64*i + 24: 2 + 64*(i+1)]
