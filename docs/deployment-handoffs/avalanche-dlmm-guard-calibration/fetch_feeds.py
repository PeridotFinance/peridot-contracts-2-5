"""W-CAL step 1 (read-only): Chainlink proxy round data via latest-state eth_call getRoundData(roundId) (round data is stored on chain forever,
so no archive state is needed and the fork lock is not required). Endpoint is read ONLY from env AVALANCHE_RPC (never printed/written).
usage: fetch_feeds.py meta                      -> data/feed_meta.json (decimals, phases, aggregators, min/maxAnswer, per-phase first/last round time)
       fetch_feeds.py range LEG T0 T1 TAG       -> data/feed_rounds_<LEG>_<TAG>.json: every round with updatedAt in [T0,T1] (unix s), any phase
Row = [roundId, answer, startedAt, updatedAt, answeredInRound]"""
import os, sys, json, bisect
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, "/Users/joshua/Peridot/peridot-contracts-2-5/docs/deployment-handoffs/avalanche-pharaoh-dlmm-evidence/tools")
os.environ.setdefault("RPC_COUNT_FILE", "/tmp/wcal_rpc_count")
from rpcpy import call, sel, u, s, addr
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data")
FEEDS = {"USDC": "0xF096872672F44d6EBA71458D74fe67F9a77a23B9", "USDT": "0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a"}
def pad(n): return hex(n)[2:].rjust(64, "0")
GRD = sel("getRoundData(uint80)")
def rd(p, k, n):
    try: r = call(p, GRD + pad((k << 64) | n))
    except RuntimeError: return None
    if u(r, 3) == 0: return None
    return [u(r, 0), s(r, 1), u(r, 2), u(r, 3), u(r, 4)]
def last_round(p, k):
    lo, hi = 1, 1
    while rd(p, k, hi) is not None: lo = hi; hi *= 2
    while hi - lo > 1:
        m = (lo + hi) // 2
        if rd(p, k, m) is not None: lo = m
        else: hi = m
    return lo
def meta():
    meta = {}
    for leg, p in FEEDS.items():
        ph = u(call(p, sel("phaseId()")))
        m = {"proxy": p, "decimals": u(call(p, sel("decimals()"))), "phaseId": ph, "version": u(call(p, sel("version()"))), "phases": {}}
        lr = call(p, sel("latestRoundData()")); m["latest"] = [u(lr, 0), s(lr, 1), u(lr, 2), u(lr, 3), u(lr, 4)]
        for k in range(1, ph + 1):
            a = addr(call(p, sel("phaseAggregators(uint16)") + pad(k)))
            d = {"aggregator": a}
            for f in ("minAnswer()", "maxAnswer()"):
                try: d[f[:-2]] = s(call(a, sel(f)))
                except Exception as e: d[f[:-2]] = "ERR " + str(e)[:60]
            n = last_round(p, k); d["last_round_n"] = n; d["first"] = rd(p, k, 1); d["last"] = rd(p, k, n)
            m["phases"][k] = d; print(leg, k, n, file=sys.stderr)
        meta[leg] = m
    json.dump(meta, open(os.path.join(OUT, "feed_meta.json"), "w"), indent=1)
def rng(leg, t0, t1, tag):
    p = FEEDS[leg]; M = json.load(open(os.path.join(OUT, "feed_meta.json")))[leg]; rows = []
    for k, d in M["phases"].items():
        k = int(k); n = d["last_round_n"]
        if d["last"][3] < t0 or d["first"][3] > t1: continue
        lo, hi = 1, n          # first n with updatedAt >= t0
        while lo < hi:
            m = (lo + hi) // 2
            if rd(p, k, m)[3] >= t0: hi = m
            else: lo = m + 1
        start = max(1, lo - 1)   # include the round in force at t0
        ns = []; x = start
        # fetch forward in parallel batches until updatedAt > t1
        while x <= n:
            batch = list(range(x, min(n, x + 16) + 1))
            with ThreadPoolExecutor(4) as ex: res = list(ex.map(lambda i: rd(p, k, i), batch))
            rows += [r for r in res if r]; x = batch[-1] + 1
            if res[-1] and res[-1][3] > t1: break
    json.dump(rows, open(os.path.join(OUT, "feed_rounds_%s_%s.json" % (leg, tag)), "w")); print(leg, tag, len(rows), "rounds", file=sys.stderr)
if __name__ == "__main__":
    if sys.argv[1] == "meta": meta()
    else: rng(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
