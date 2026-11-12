#!/usr/bin/env python3
"""Reference-price tolerance study: Uniswap V3 WAVAX/USDC 0.05% 30-minute TWAP versus the Chainlink AVAX/USD feed the lending oracle uses.
READ-ONLY (eth_getBlockByNumber / eth_call at past blocks). Standard library only. Nothing is signed or sent.

  usage: AVALANCHE_RPC_FOR_ANALYSIS=<archive JSON-RPC URL> python3 -I twap-vs-chainlink.py <days> <step_seconds> <out_prefix>
  (the URL is read from the environment and is never printed or written)

For sample blocks spread over the last <days> days it records, at the SAME block: the Chainlink answer and its age, the 30-minute TWAP from
the pool's own observations (tick-cumulative difference over 1,800 s, rounded as Uniswap's OracleLibrary does), and the gap in basis points.
It also records the Chainlink-vs-Chainlink move over the previous 30 minutes, so a gap can be compared with how fast the market moved.
Output: <out_prefix>.csv (one row per sample) and <out_prefix>.summary.txt (distribution and the largest gaps).
"""
import json, math, os, sys, time, urllib.request, statistics

URL = os.environ.get("AVALANCHE_RPC_FOR_ANALYSIS", "")
POOL = "0xfAe3f424a0a47706811521E3ee268f00cFb5c45E"  # Uniswap V3 WAVAX/USDC 0.05% (token0 = WAVAX 18 dec, token1 = USDC 6 dec)
FEED = "0x0A77230d17318075983913bC2145DB16C7366156"  # Chainlink AVAX/USD (8 decimals)
WINDOW = 1800
BATCH = 20  # the public endpoint answers HTTP 500 to large batches
WORKERS = 6
OBSERVE = "0x883bdbfd" + f"{32:064x}" + f"{2:064x}" + f"{WINDOW:064x}" + f"{0:064x}"
LATEST = "0xfeaf968c"


def rpc(batch):
    req = urllib.request.Request(URL, data=json.dumps(batch).encode(), headers={"Content-Type": "application/json", "User-Agent": "peridot-analysis/1"})
    for attempt in range(6):
        try:
            with urllib.request.urlopen(req, timeout=90) as r:
                out = json.loads(r.read())
            return sorted(out, key=lambda x: x["id"]) if isinstance(out, list) else out
        except Exception as e:  # noqa: BLE001 - retry any transport error, never print the URL
            time.sleep(2 + 3 * attempt)
            last = type(e).__name__ + (" " + str(getattr(e, "code", "")) if hasattr(e, "code") else "")
    raise SystemExit("rpc failed after retries: " + last)


def call(to, data, block):
    return {"jsonrpc": "2.0", "method": "eth_call", "params": [{"to": to, "data": data}, hex(block)]}


def s256(word_hex):
    v = int(word_hex, 16)
    return v - (1 << 256) if v >= (1 << 255) else v


def main():
    if not URL or len(sys.argv) != 4:
        raise SystemExit(__doc__)
    days, step, prefix = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    tip = int(rpc([{"jsonrpc": "2.0", "id": 0, "method": "eth_blockNumber", "params": []}])[0]["result"], 16)
    def ts(b):
        r = rpc([{"jsonrpc": "2.0", "id": 0, "method": "eth_getBlockByNumber", "params": [hex(b), False]}])[0]["result"]
        return int(r["timestamp"], 16)
    t_tip = ts(tip)
    # block time estimate from a 200k-block span; sample blocks are then corrected by reading their real timestamps
    t_old = ts(tip - 200_000)
    bt = (t_tip - t_old) / 200_000.0
    n = days * 86400 // step
    rows, blocks = [], []
    for i in range(n, 0, -1):
        blocks.append(tip - int(i * step / bt))
    # 1) timestamps of the sample blocks (cheap, recent-state independent); 2) Chainlink answer and pool observation at each block, in
    #    parallel batches (the archive node answers about one old-state call per second per connection)
    from concurrent.futures import ThreadPoolExecutor
    def batch_ts(bs):
        chunks = [bs[k:k + BATCH] for k in range(0, len(bs), BATCH)]
        def one(chunk):
            res = rpc([{"jsonrpc": "2.0", "id": j, "method": "eth_getBlockByNumber", "params": [hex(b), False]} for j, b in enumerate(chunk)])
            return [(b, int(r["result"]["timestamp"], 16)) for b, r in zip(chunk, res)]
        with ThreadPoolExecutor(WORKERS) as ex:
            return dict(x for part in ex.map(one, chunks) for x in part)
    tsmap = batch_ts(blocks)
    items = [(FEED, LATEST, b) for b in blocks] + [(POOL, OBSERVE, b) for b in blocks]
    chunks = [items[k:k + BATCH] for k in range(0, len(items), BATCH)]
    done = [0]
    def run_chunk(chunk):
        req = []
        for j, (to, data, b) in enumerate(chunk):
            c = call(to, data, b); c["id"] = j; req.append(c)
        out = rpc(req)
        done[0] += 1
        if done[0] % 10 == 0:
            print("  progress: %d / %d batches" % (done[0], len(chunks)), file=sys.stderr, flush=True)
        return out
    with ThreadPoolExecutor(WORKERS) as ex:
        res = [x for part in ex.map(run_chunk, chunks) for x in part]
    m = len(blocks)
    skipped = 0
    lookback = int(WINDOW / step)  # samples per 30 minutes (the Chainlink move is taken against the sample this many steps earlier)
    cl_series = []
    for i, b in enumerate(blocks):
        a_, o = res[i], res[m + i]
        cl_series.append(s256(a_["result"][2:][64:128]) / 1e8 if "result" in a_ else None)
    for i, b in enumerate(blocks):
        a, o = res[i], res[m + i]
        if "result" not in a or "result" not in o:
            skipped += 1  # e.g. the pool's observation history did not reach back 1,800 s at that block (reverts "OLD")
            continue
        w = [a["result"][2:][k * 64:(k + 1) * 64] for k in range(5)]
        ans, upd = s256(w[1]), int(w[3], 16)
        wo = [o["result"][2:][k * 64:(k + 1) * 64] for k in range(6)]
        tc0, tc1 = s256(wo[3]), s256(wo[4])
        delta = tc1 - tc0
        tick = delta // WINDOW  # floors toward -infinity like OracleLibrary (it floors negative non-multiples)
        twap = 1.0001 ** tick * 1e12
        chainlink = ans / 1e8
        if i < lookback or cl_series[i - lookback] is None:
            skipped += 1  # no sample 30 minutes earlier to measure Chainlink's own move against
            continue
        gap_bp = (twap / chainlink - 1) * 1e4
        move_bp = (chainlink / cl_series[i - lookback] - 1) * 1e4  # Chainlink's own move over the previous ~30 minutes
        rows.append((b, tsmap[b], chainlink, tsmap[b] - upd, twap, gap_bp, move_bp))
    with open(prefix + ".csv", "w") as f:
        f.write("block,timestamp,chainlink_usd,chainlink_age_s,twap30_usd,gap_bp,chainlink_move_30m_bp\n")
        for r in rows:
            f.write("%d,%d,%.6f,%d,%.6f,%.2f,%.2f\n" % r)
    gaps = [abs(r[5]) for r in rows]
    gaps_sorted = sorted(gaps)
    def pct(p):
        return gaps_sorted[min(len(gaps_sorted) - 1, int(math.ceil(p / 100 * len(gaps_sorted))) - 1)]
    with open(prefix + ".summary.txt", "w") as f:
        w = lambda s: (f.write(s + "\n"), print(s))
        w("samples: %d of %d requested (%d skipped: pool history or archive state unavailable)" % (len(rows), n, skipped))
        w("window: %d days, step %d s, block time estimate %.3f s, tip block %d" % (days, step, bt, tip))
        w("signed gap (TWAP vs Chainlink) bp: mean %+.1f, median %+.1f" % (statistics.mean(r[5] for r in rows), statistics.median(r[5] for r in rows)))
        for p in (50, 90, 99, 99.9):
            w("|gap| bp, p%s: %.1f" % (p, pct(p)))
        w("|gap| bp, max: %.1f" % max(gaps))
        fast = [r for r in rows if abs(r[6]) >= 100]
        slow = [r for r in rows if abs(r[6]) < 100]
        if fast:
            w("when Chainlink itself moved >= 100 bp in the previous 30 minutes (%d samples): max |gap| %.1f bp, p90 %.1f bp" % (len(fast), max(abs(r[5]) for r in fast), sorted(abs(r[5]) for r in fast)[int(0.9 * len(fast))]))
        if slow:
            w("when Chainlink moved < 100 bp (%d samples): max |gap| %.1f bp, p99 %.1f bp" % (len(slow), max(abs(r[5]) for r in slow), sorted(abs(r[5]) for r in slow)[min(len(slow) - 1, int(0.99 * len(slow)))]))
        w("largest Chainlink 30-minute move in the sample: %.1f bp" % max(abs(r[6]) for r in rows))
        w("largest Chainlink age in the sample: %d s" % max(r[3] for r in rows))
        w("top 8 gaps (block, UTC timestamp, gap bp, Chainlink 30m move bp):")
        for r in sorted(rows, key=lambda r: -abs(r[5]))[:8]:
            w("  %d  %s  %+.1f  %+.1f" % (r[0], time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(r[1])), r[5], r[6]))


main()
