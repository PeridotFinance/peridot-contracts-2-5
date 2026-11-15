"""Swap depth at the pin block: USD notional of INPUT needed to move the pool price by 1/5/10 percent, both directions, fee ignored (gross).
Algebra Integral pools (Blackhole): walk the initialized-tick linked list (ticks().nextTick/prevTick from nextTickGlobal/prevTickGlobal).
Ramses/Uniswap-v3 pools (Pharaoh): scan tickBitmap words then read ticks(). Floats are used for sqrt prices (relative error ~1e-9, irrelevant for USD depth)."""
import json, os, sys, math
sys.path.insert(0, os.path.dirname(__file__))
from rpcpy import call, sel, u, s
OUT = os.path.join(os.path.dirname(__file__), "..", "data"); PIN = 100006143
MIN_T, MAX_T = -887272, 887272
enc = lambda v: (v & ((1 << 256) - 1)).to_bytes(32, "big").hex()
def sq(t): return 1.0001 ** (t / 2)
def ticks_bh(pool, t):
    r = call(pool, sel("ticks(int24)") + enc(t), PIN); return {"net": s(r, 1), "prev": s(r, 2), "next": s(r, 3), "total": u(r, 0)}
def ticks_ph(pool, t):
    r = call(pool, sel("ticks(int24)") + enc(t), PIN); return {"net": s(r, 1), "gross": u(r, 0)}
def init_ticks_bh(pool, cur):
    up, dn = [], []
    t = s(call(pool, sel("nextTickGlobal()"), PIN))
    while t < MAX_T and len(up) < 400:
        d = ticks_bh(pool, t); up.append((t, d["net"]));
        if d["next"] == t: break
        t = d["next"]
    t = s(call(pool, sel("prevTickGlobal()"), PIN))
    while t > MIN_T and len(dn) < 400:
        d = ticks_bh(pool, t); dn.append((t, d["net"]))
        if d["prev"] == t: break
        t = d["prev"]
    return up, dn
def init_ticks_ph(pool, cur, spacing=1, span=1300):
    lo, hi = cur - span, cur + span
    words = range((lo // spacing) >> 8, ((hi // spacing) >> 8) + 1)
    found = []
    for w in words:
        bm = u(call(pool, sel("tickBitmap(int16)") + enc(w), PIN))
        for bit in range(256):
            if bm >> bit & 1:
                t = ((w << 8) + bit) * spacing
                if lo <= t <= hi: found.append(t)
    out = {t: ticks_ph(pool, t)["net"] for t in found}
    up = sorted((t, n) for t, n in out.items() if t > cur); dn = sorted(((t, n) for t, n in out.items() if t <= cur), reverse=True)
    return up, dn
def walk(cur_tick, sp_x96, L0, up, dn, targets=(1, 5, 10)):
    """Cumulative gross input (raw units of the INPUT token) to push the price to each target. If the liquidity runs out (L<=0 over a
    non-empty segment) before a target, the target is flagged unreachable and 'dry_at_pct' records the price move at which liquidity ends."""
    sp = sp_x96 / 2**96; res = {}
    for direction in ("up", "down"):
        L = L0; sa = sp; tot = 0.0; tl = list(up if direction == "up" else dn); out = {}; dry = None
        for x in targets:
            tgt = sp * math.sqrt(1 + x / 100) if direction == "up" else sp / math.sqrt(1 + x / 100)
            reached = True
            while True:
                nb = (sq(tl[0][0]) if tl else (float("inf") if direction == "up" else 0.0))
                stop = min(nb, tgt) if direction == "up" else max(nb, tgt)
                seg = abs(stop - sa)
                if L <= 0 and seg > 0:
                    if dry is None: dry = (abs(sa / sp) ** 2 - 1) * 100 if direction == "up" else (1 - (sa / sp) ** 2) * 100
                    reached = False; break
                if direction == "up": tot += L * (stop - sa)
                else: tot += L * (1 / stop - 1 / sa)
                sa = stop
                if stop == tgt: break
                L += tl[0][1] if direction == "up" else -tl[0][1]; tl = tl[1:]
            out[x] = {"raw_in": tot, "reachable": reached}
        res[direction] = {"targets": out, "dry_at_pct": dry}
    return res
if __name__ == "__main__":
    which = sys.argv[1]
    CFG = {
     "bh_wbtc_btcb": ("bh", "0xfc231423e1a863d94abb21d9f68e8c2589b3edb9"),
     "bh_ausd_usdc": ("bh", "0x10ed86c3d147dcd4bdecacff5ada625328b9678d"),
     "ph_usdc_usdt": ("ph", "0x9bFE3108Cc16D17a9Ec65545a0f50B2CA1C970c0"),
     "ph_savax_wavax": ("ph", "0x65B9016c376604Fe0aF38c1E336Ffcec0F8ecBbD")}
    kind, pool = CFG[which]
    if kind == "bh":
        gs = call(pool, sel("globalState()"), PIN); sp, tick = u(gs, 0), s(gs, 1)
        up, dn = init_ticks_bh(pool, tick)
    else:
        sl = call(pool, sel("slot0()"), PIN); sp, tick = u(sl, 0), s(sl, 1)
        up, dn = init_ticks_ph(pool, tick)
    L0 = u(call(pool, sel("liquidity()"), PIN))
    r = walk(tick, sp, L0, up, dn)
    out = {"pool": pool, "pin": PIN, "tick": tick, "sqrtPriceX96": sp, "L": L0, "n_up_ticks_read": len(up), "n_dn_ticks_read": len(dn), "raw": r,
           "up_ticks_head": up[:6], "dn_ticks_head": dn[:6]}
    json.dump(out, open(os.path.join(OUT, f"depth_{which}.json"), "w"), indent=1, default=str)
    print(which, json.dumps(out["raw"]), len(up), len(dn))
