"""Randomised differential test: refmodel2.py (gauge mirror + vault ledger) against the independent oracle phar_oracle.py.

Run:  python3 -I phar_difftest.py [--n 3000] [--seed0 0] [--mode aligned|strict|both] [--minimise]
  aligned: the generator avoids the two known model-vs-specification deviations (see the verdict file) so every other mismatch
           stands out; strict: the generator also emits them, so they are re-found and minimised.
Histories are DATA (lists of op tuples), so a failing one is minimised by deleting ops (greedy delta debugging).
Checks per history (all exact rationals, nothing approximate):
  G  after every gauge call: claimed / debt / lastClaim / r33 / balances / lastModified of the model gauge == oracle gauge
     (the oracle replays the same raw call on its own source-based gauge)
  A  exposure: W[h,p], Z[p], Tt[p] == oracle (exact) for every period without a supply change during a reading outage; for the
     others: W <= oracle, W+Z+U == Tt, U == 0 elsewhere, and reconcile() with the oracle-derived residual restores equality
  F  funded[p,tok] == what the oracle gauge paid the vault for p; lost == what the oracle gauge forfeited on vault calls
  N  final(p) <=> p ended and the oracle gauge owes nothing for p (bidirectional liveness of finality)
  C  claim(): total paid out per holder == oracle entitlement summed over the contiguous final prefix
  E  entitlement(h,p) == funded * oracle exposure share, for final periods; conservation sum+buckets <= funded
  B  guard: Blocked/Unavailable raised iff the oracle's section 5.5 predicate says so (reason and retry_after included)
"""
import sys
import random
import argparse
import traceback
from fractions import Fraction as F

sys.path.insert(0, __file__.rsplit('/', 1)[0] if '/' in __file__ else '.')
import refmodel2 as M
from refmodel2 import Env, Blocked, Unavailable, GaugeRevert, WEEK, START_PERIOD, TOKS
import phar_oracle as O

P0 = START_PERIOD
MARGIN = 10


class Mismatch(Exception):
    def __init__(self, kind, detail):
        super().__init__('%s: %s' % (kind, detail))
        self.kind = kind
        self.detail = detail


def nz(d):
    return {k: v for k, v in d.items() if v != 0}


class LG(M.Gauge2):
    """model gauge that reports every external call to a sink (the raw event history)"""

    def __init__(s, sink):
        super().__init__()
        s.sink = sink
        s.depth = 0

    def notify(s, tok, amount, period=None):
        p = s.period() if period is None else period
        super().notify(tok, amount, period)
        s.sink({'k': 'notify', 't': s.now, 'tok': tok, 'amount': F(amount), 'period': p})

    def pm_mint(s, id_, share=F(1)):
        super().pm_mint(id_, share)
        s.sink({'k': 'mint', 't': s.now, 'nft': id_})

    def pm_burn(s, id_):
        super().pm_burn(id_)
        s.sink({'k': 'burn', 't': s.now, 'nft': id_})

    def _call(s, fn, ev):
        s.depth += 1
        raised = False
        try:
            fn()
        except GaugeRevert:
            raised = True
        finally:
            s.depth -= 1
        if s.depth == 0:
            ev['raises'] = raised
            s.sink(ev)
        if raised:
            raise GaugeRevert('x')

    def get_all_rewards(s, id_, toks, receiver, origin):
        return s._call(lambda: super(LG, s).get_all_rewards(id_, toks, receiver, origin),
                       {'k': 'claim_all', 't': s.now, 'nft': id_, 'toks': tuple(toks), 'receiver': receiver, 'origin': origin})

    def get_period_reward(s, id_, p, toks, receiver, origin):
        return s._call(lambda: super(LG, s).get_period_reward(id_, p, toks, receiver, origin),
                       {'k': 'claim_period', 't': s.now, 'nft': id_, 'period': p, 'toks': tuple(toks), 'receiver': receiver, 'origin': origin})

    def pm_change(s, id_, origin, new_share=None):
        return s._call(lambda: super(LG, s).pm_change(id_, origin, new_share),
                       {'k': 'pm_change', 't': s.now, 'nft': id_, 'origin': origin})


class Run:
    def __init__(s, variant, buffer_bps=0, strict=False, mutate_sink=None):
        s.variant = variant
        s.strict = strict
        s.e = Env(variant, margin=MARGIN, buffer_bps=buffer_bps)
        s.R = O.Replay(P0)
        s.log = []
        g = LG(s.sink)
        s.e.g = g
        s.e.v.g = g
        s.g = g
        s.v = s.e.v
        s.stats = {'blocked': 0, 'slashed_calls': 0, 'ops': 0}
        s.extra_nfts = []
        s.reconciled = False
        s.v.add_nft(1)
        g.notify('PHAR', 100)
        s.adv(200, 'none')

    # ------------------------------------------------------------------ sink and per-call comparison
    def sink(s, ev):
        s.log.append(ev)
        raised = s.R.apply(ev)
        if ev['k'] in ('claim_all', 'claim_period', 'pm_change', 'sweep'):
            if raised != ev.get('raises', False):
                raise Mismatch('G', 'revert flag model=%s oracle=%s on %s' % (ev.get('raises'), raised, ev))
            s.cmp_gauge(ev)

    def cmp_gauge(s, ev):
        g, o = s.g, s.R.g
        pairs = [
            ('claimed', nz(g.claimed), nz(dict(o.claimed))),
            ('debt', {k: v for k, v in g.debt.items() if v[1] != 0 or v[0] != 0}, {k: v for k, v in o.debt.items() if v[1] != 0 or v[0] != 0}),
            ('lastClaim', g.lastClaim, o.last_claim),
            ('r33', nz(g.r33), nz(dict(o.r33))),
            ('bal', nz(g.bal), nz(dict(o.bal))),
            ('lm', g.lm, o.lm),
        ]
        for name, a, b in pairs:
            if a != b:
                raise Mismatch('G', '%s differs after %s: model=%s oracle=%s' % (name, ev['k'], a, b))

    # ------------------------------------------------------------------ gov, time
    def gov(s, name, value):
        g = s.g
        mname = {'thr': 'threshold'}.get(name, name)
        if name == 'bl_wallet_add':
            g.black_wallets.add(value)
        elif name == 'bl_wallet_del':
            g.black_wallets.discard(value)
        elif name == 'bl_hash_add':
            g.black_hashes.add(value)
        else:
            setattr(g, mname, value)
        s.sink({'k': 'gov', 't': g.now, 'name': name, 'value': value})

    def active(s):
        return [i for i, n in s.v.nfts.items() if n['state'] == 'active']

    def adv(s, secs, mask):
        g = s.g
        act = s.active()
        ids = {'all': act, 'none': [], 'main': [i for i in act if i == 1], 'last': act[-1:]}[mask]
        t0 = g.now
        for i in ids:
            sh = g.share.get(i, F(1))
            if sh:
                s.sink({'k': 'inrange', 'nft': i, 't0': t0, 't1': t0 + secs, 'share': sh})
        s.e.advance(secs, ids=ids)
        s.R.now = g.now

    # ------------------------------------------------------------------ vault operation with balance logging and prediction
    def vop(s, fn, expect=None):
        """run fn; log balance diffs; check expected exception class/reason (expect = None | ('Blocked', reason, retry) | ('Unavailable',))"""
        v = s.v
        before = dict(v.bal)
        outage = not v.read_ok
        s.R.now = s.g.now
        got = None
        try:
            res = fn()
        except Blocked as ex:
            got = ('Blocked', ex.reason, ex.retry_after)
            res = None
        except Unavailable:
            got = ('Unavailable',)
            res = None
        after = dict(v.bal)
        if got is not None and nz(after) != nz(before):
            raise Mismatch('B', 'refused operation changed balances %s' % (got,))
        if got is not None:
            s.stats['blocked'] += 1
        if expect is not None or got is not None:
            if expect is not None and expect[0] == 'Blocked' and got is not None and got[0] == 'Blocked':
                if got[1] != expect[1] or (expect[2] is not None and got[2] != expect[2]):
                    raise Mismatch('B', 'refusal differs: model=%s oracle=%s now=%s val=%s bl=%s/%s' % (got, expect, s.g.now, s.R.g.validator, sorted(s.R.g.bl_wallets), sorted(s.R.g.bl_hashes)))
            elif (expect is None) != (got is None) or (expect and got and expect[0] != got[0]):
                raise Mismatch('B', 'refusal differs: model=%s oracle=%s now=%s lm=%s thr=%s val=%s bl=%s/%s' % (
                    got, expect, s.g.now, s.R.g.lm.get(1), s.R.g.thr, s.R.g.validator, sorted(s.R.g.bl_wallets), sorted(s.R.g.bl_hashes)))
        for h in set(before) | set(after):
            d = after.get(h, F(0)) - before.get(h, F(0))
            if d:
                s.sink({'k': 'bal', 't': s.g.now, 'h': h, 'delta': d, 'outage': outage})
        return res

    def pred_guard(s, nft=1, origin='user'):
        why = s.R.guard(nft, origin, MARGIN)
        if why is None:
            return None
        retry = s.R.g.lm.get(nft, 0) + s.R.g.thr + MARGIN if why == 'window' else None
        return ('Blocked', why, retry)

    def gauge_events(s):
        return sum(1 for e in s.log if e['k'] in ('claim_all', 'claim_period', 'pm_change'))

    # ------------------------------------------------------------------ ops
    def do(s, op):
        v, g = s.v, s.g
        s.stats['ops'] += 1
        s.R.now = g.now
        k = op[0]
        if k == 'adv':
            s.adv(op[1], op[2])
        elif k == 'adv_lm':
            tgt = s.R.g.lm.get(1, 0) + s.R.g.thr + MARGIN + op[1]
            if tgt > g.now and tgt - g.now < 3 * WEEK:
                s.adv(tgt - g.now, op[2])
        elif k == 'dep':
            h, x = op[1], F(op[2])
            if s.variant == 'W1':
                exp = ('Unavailable',) if not v.read_ok else s.pred_guard()
                b0 = v.bal.get(h, F(0))
                s.vop(lambda: v.deposit(h, x), exp)
                if exp is None and v.bal.get(h, F(0)) - b0 != x:
                    raise Mismatch('B', 'accepted deposit did not mint exactly x')
            else:
                n0 = s.gauge_events()
                s.vop(lambda: v.deposit(h, x))
                if s.gauge_events() != n0:
                    raise Mismatch('B', 'EPOCH: a deposit request touched the gauge (dust would move lastModified)')
        elif k == 'red':
            h = op[1]
            b = v.free(h)
            if b <= 0:
                return
            x = max(F(1), min(b, (b * F(op[2])).__ceil__()))
            if s.variant == 'W1':
                exp = None if v.idle >= x else s.pred_guard()
                b0 = v.bal.get(h, F(0))
                s.vop(lambda: v.redeem(h, x), exp)
                if exp is None and b0 - v.bal.get(h, F(0)) != x:
                    raise Mismatch('B', 'accepted redeem did not burn exactly x')
            else:
                n0 = s.gauge_events()
                idle_covers = v.idle >= x
                s.vop(lambda: v.redeem(h, x))
                if not idle_covers and s.gauge_events() != n0:
                    raise Mismatch('B', 'EPOCH: a queued withdrawal touched the gauge')
        elif k == 'xfer':
            a, b_ = op[1], op[2]
            fb = v.free(a)
            if a == b_ or fb <= 0:
                return
            x = max(F(1), min(fb, (fb * F(op[3])).__ceil__()))
            exp = ('Unavailable',) if not v.read_ok else None
            s.vop(lambda: v.transfer(a, b_, x), exp)
        elif k == 'harv':
            s.vop(lambda: v.harvest(op[1]))
        elif k == 'batch':
            if s.variant != 'EPOCH':
                return
            nonempty = bool(v.q_dep or v.q_wd)
            exp = s.pred_guard(1, op[1]) if nonempty else None
            s.vop(lambda: v.process_batch(op[1]), exp)
            if nonempty and exp is None and v.q_wd:
                raise Mismatch('B', 'EPOCH: an allowed batch left withdrawals queued (exit bound broken)')
        elif k == 'notify':
            g.notify(op[1], op[2], g.period() + op[3] if op[3] else None)
        elif k == 'gov':
            s.gov(op[1], op[2])
        elif k == 'rd':
            v.read_ok = op[1]
        elif k == 'touch':
            v.touch_safe()
        elif k == 'drain':
            v.drain(op[1])
        elif k == 'prog':
            v.progress(op[1], op[2])
        elif k == 'claim':
            v.claim(op[1], op[2])
        elif k == 'nft':
            if 2 not in v.nfts:
                v.add_nft(2, F(op[1]))
                s.extra_nfts.append(2)
        elif k == 'retire':
            if 2 in v.nfts and v.nfts[2]['state'] == 'active' and s.pred_guard(2, 'keeper') is None:
                v.retire(2, 'keeper')
        elif k == 'burn2':
            if 2 in v.nfts and v.nfts[2]['state'] == 'retired':
                try:
                    v.burn_nft(2)
                except Blocked:
                    pass
        else:
            raise ValueError(k)

    # ------------------------------------------------------------------ end of history: settle everything and compare
    def finish(s):
        v, g, e = s.v, s.g, s.e
        v.read_ok = True
        s.gov('mode', 'ok')
        s.gov('pool_ok', True)
        s.adv(3 * WEEK, 'none')
        for _ in range(4):
            s.vop(lambda: v.touch_safe())
            e.drain_all()
            s.vop(lambda: v.harvest('keeper'))
        accts = sorted(set(v.bal) | {'A', 'B', 'C'})
        e.drain_all(accts)
        s.R.now = g.now
        o = s.R.g
        cur = g.period()
        nfts = [i for i in v.nfts]
        # ---- F, N
        for p in range(P0, cur):
            for tok in TOKS:
                mf = v.funded.get((p, tok), F(0))
                of = o.paid_p.get(('vault', p, tok), F(0))
                if mf != of:
                    raise Mismatch('F', 'funded p=%d %s model=%s oracle=%s' % (p, tok, mf, of))
                ml = sum((x for (pp, t, c), x in v.lost.items() if pp == p and t == tok), F(0))
                ol = o.forf_vault_p.get((p, tok), F(0))
                if ml != ol:
                    raise Mismatch('F', 'lost p=%d %s model=%s oracle=%s' % (p, tok, ml, ol))
            owes = any(o.outstanding(nfts, p, t, g.now) > 0 for t in TOKS)
            if v.final(p) == owes:
                raise Mismatch('N', 'final(%d)=%s but oracle gauge owes=%s (validator=%s bl=%s mode=%s)' % (p, v.final(p), owes, o.validator, sorted(o.bl_wallets), o.mode))
        # ---- A, E
        R = s.R
        for p in range(P0, cur):
            amb = p in R.ambig
            tz = R.Tt[p]
            if v.Tt.get(p, F(0)) != tz:
                raise Mismatch('A', 'Tt p=%d model=%s oracle=%s' % (p, v.Tt.get(p, F(0)), tz))
            hs = sorted(set(v.bal) | {h for (h, q) in R.W if q == p})
            if not amb:
                if v.U.get(p, F(0)) != 0:
                    raise Mismatch('A', 'U>0 in p=%d without an outage-time supply change' % p)
                for h in hs:
                    if v.W.get((h, p), F(0)) != R.W[(h, p)]:
                        raise Mismatch('A', 'W[%s,%d] model=%s oracle=%s' % (h, p, v.W.get((h, p), F(0)), R.W[(h, p)]))
                if v.Z.get(p, F(0)) != R.Z[p]:
                    raise Mismatch('A', 'Z p=%d model=%s oracle=%s' % (p, v.Z.get(p, F(0)), R.Z[p]))
            else:
                tot = sum((v.W.get((h, p), F(0)) for h in hs), F(0)) + v.Z.get(p, F(0)) + v.U.get(p, F(0))
                if tot != tz:
                    raise Mismatch('A', 'sum W+Z+U != Tt in ambiguous p=%d: %s vs %s' % (p, tot, tz))
                for h in hs:
                    if v.W.get((h, p), F(0)) > R.W[(h, p)]:
                        raise Mismatch('A', 'over-attribution in ambiguous p=%d holder %s' % (p, h))
                if v.Z.get(p, F(0)) > R.Z[p]:
                    raise Mismatch('A', 'over-attribution of Z in ambiguous p=%d' % p)
        # E before reconcile
        for p in range(P0, cur):
            if not v.final(p):
                continue
            for tok in TOKS:
                funded = v.funded.get((p, tok), F(0))
                tot = F(0)
                for h in sorted(set(v.bal) | {h for (h, q) in R.W if q == p}):
                    me = v.entitlement(h, p, tok)
                    if me is None:
                        raise Mismatch('E', 'entitlement None for settled holder %s final p=%d' % (h, p))
                    oe = R.ent(funded, h, p)
                    if p not in R.ambig and me != oe:
                        raise Mismatch('E', 'entitlement %s p=%d model=%s oracle=%s' % (h, p, me, oe))
                    if me > oe:
                        raise Mismatch('E', 'over-entitled %s p=%d' % (h, p))
                    tot += me
                if tot + v.bucket_zero(p, tok) + v.reserved_unresolved(p, tok) > funded:
                    raise Mismatch('E', 'conservation broken p=%d' % p)
                if p not in R.ambig and R.Tt[p] > 0 and tot + v.bucket_zero(p, tok) != funded:
                    raise Mismatch('E', 'not exact: p=%d %s vs %s' % (p, tot + v.bucket_zero(p, tok), funded))
        # C: claim() (paginated earlier in the history, unbounded now) pays exactly the oracle entitlement of the contiguous final prefix
        for h in sorted(v.bal):
            v.claim(h)
            for tok in TOKS:
                exp_amt = F(0)
                amb_in_prefix = False
                p = P0
                while p < cur and v.final(p):
                    exp_amt += R.ent(v.funded.get((p, tok), F(0)), h, p)
                    amb_in_prefix = amb_in_prefix or p in R.ambig
                    p += 1
                got_amt = v.paid_out.get((h, tok), F(0))
                if got_amt > exp_amt or (not amb_in_prefix and got_amt != exp_amt):
                    raise Mismatch('C', 'claim total %s %s model=%s oracle=%s' % (h, tok, got_amt, exp_amt))
        # reconcile with the oracle-derived residual and re-check exactness
        for p in range(P0, cur):
            if p in R.ambig and v.U.get(p, F(0)):
                hs = sorted(set(v.bal) | {h for (h, q) in R.W if q == p})
                split = {h: R.W[(h, p)] - v.W.get((h, p), F(0)) for h in hs}
                split[M.ZERO_SUPPLY] = R.Z[p] - v.Z.get(p, F(0))
                if sum(split.values(), F(0)) != v.U[p]:
                    raise Mismatch('A', 'residual %s != U %s in p=%d' % (sum(split.values(), F(0)), v.U[p], p))
                if v._record_ready(p) and sum(split.values(), F(0)) > 0:
                    v.reconcile(p, split)
                for h in hs:
                    if v.W.get((h, p), F(0)) != R.W[(h, p)]:
                        raise Mismatch('A', 'after reconcile W[%s,%d] model=%s oracle=%s' % (h, p, v.W.get((h, p), F(0)), R.W[(h, p)]))


# ----------------------------------------------------------------------------------------------------------------------
HOLDERS = 'ABC'
ORIGINS = ('keeper', 'user', 'bot')


def gen(rng, n, variant, strict):
    ops = []
    secs = [1, 5, 60, 111, 112, 121, 122, 130, 4000, 90000, WEEK // 2, WEEK - 1, WEEK + 7, 3 * WEEK]
    for _ in range(n):
        x = rng.random()
        h = rng.choice(HOLDERS)
        if x < 0.16:
            ops.append(('adv', rng.choice(secs), rng.choice(['all', 'all', 'all', 'main', 'none', 'last'])))
        elif x < 0.22:
            ops.append(('adv_lm', rng.choice([-1, 0, 1, 2]), 'all'))
        elif x < 0.34:
            ops.append(('dep', h, rng.randint(1, 600)))
        elif x < 0.44:
            ops.append(('red', h, rng.choice([0.2, 0.5, 1.0])))
        elif x < 0.50:
            ops.append(('xfer', h, rng.choice(HOLDERS), rng.choice([0.3, 1.0])))
        elif x < 0.58:
            ops.append(('harv', rng.choice(ORIGINS)))
        elif x < 0.64:
            ops.append(('batch', rng.choice(ORIGINS)))
        elif x < 0.70:
            ops.append(('notify', rng.choice(['PHAR', 'PHAR', 'PHAR', 'XPHAR']), rng.randint(1, 50), rng.choice([0, 0, 1])))
        elif x < 0.75:
            ops.append(('gov', 'thr', rng.choice([111, 111, 300, 5000, 10 ** 9, 0])))
        elif x < 0.77:
            ops.append(('gov', 'antisybil', rng.random() < 0.5))
        elif x < 0.80:
            choices = ['normal', 'normal', 'revert', 'always'] + (['none'] if strict else [])
            ops.append(('gov', 'validator', rng.choice(choices)))
        elif x < 0.82:
            ops.append(('gov', 'mode', rng.choice(['ok', 'ok', 'revert', 'zero'])))
        elif x < 0.84:
            ops.append(('gov', 'pool_ok', rng.random() < 0.6))
        elif x < 0.87:
            kind = rng.choice(['bl_wallet_add', 'bl_wallet_del', 'bl_hash_add'])
            val = rng.choice(['bot', 'vault', 'user', 'keeper'] + (['posmgr'] if strict else [])) if kind != 'bl_hash_add' else rng.choice([1, 2])
            if kind == 'bl_wallet_del':
                val = rng.choice(['bot', 'vault', 'user', 'keeper', 'posmgr'])
            ops.append(('gov', kind, val))
        elif x < 0.91:
            ops.append(('rd', rng.random() < 0.5))
        elif x < 0.93:
            ops.append(('touch',))
        elif x < 0.95:
            ops.append(('drain', rng.randint(1, 3)))
        elif x < 0.97:
            ops.append(('prog', h, rng.randint(1, 3)) if rng.random() < 0.5 else ('claim', h, rng.randint(1, 4)))
        elif x < 0.985:
            ops.append(rng.choice([('nft', 1), ('nft', F(1, 2)), ('retire',), ('burn2',)]))
        else:
            ops.append(('adv', 3 * WEEK, 'all'))
    return ops


def execute(ops, variant, buffer_bps=0, strict=False):
    r = Run(variant, buffer_bps, strict)
    try:
        for op in ops:
            r.do(op)
        r.finish()
    except Mismatch:
        raise
    except Exception as ex:      # a model crash is itself a finding
        raise Mismatch('crash', '%s: %s | %s' % (type(ex).__name__, ex, traceback.format_exc().splitlines()[-3:]))
    return r


def minimise(ops, variant, buffer_bps, strict, kind):
    """greedy delta debugging keeping the same mismatch kind"""
    def fails(o):
        try:
            execute(o, variant, buffer_bps, strict)
            return False
        except Mismatch as m:
            return m.kind == kind
    cur = list(ops)
    chunk = max(1, len(cur) // 2)
    while chunk >= 1:
        i = 0
        while i < len(cur):
            cand = cur[:i] + cur[i + chunk:]
            if cand != cur and fails(cand):
                cur = cand
            else:
                i += chunk
        chunk //= 2
    return cur


class GaugeRun:
    """gauge mirror alone against the source-based oracle gauge: random raw calls incl. exact threshold boundaries"""

    def __init__(s):
        s.R = O.Replay(P0)
        s.log = []
        s.g = LG(s.sink)
        s.cmp = Run.cmp_gauge.__get__(s)
        s.ids = []

    def sink(s, ev):
        s.log.append(ev)
        raised = s.R.apply(ev)
        if ev['k'] in ('claim_all', 'claim_period', 'pm_change'):
            if raised != ev.get('raises', False):
                raise Mismatch('G', 'revert flag model=%s oracle=%s on %s' % (ev.get('raises'), raised, ev['k']))
            s.cmp(ev)
        if ev['k'] == 'gov':
            pass

    def gov(s, name, value):
        Run.gov(s, name, value)

    def do(s, op):
        g = s.g
        k = op[0]
        if k == 'mint':
            if op[1] not in s.ids:
                g.pm_mint(op[1], F(op[2]))
                s.ids.append(op[1])
        elif k == 'adv':
            t0 = g.now
            for i in s.ids:
                if g.share.get(i, F(1)):
                    s.sink({'k': 'inrange', 'nft': i, 't0': t0, 't1': t0 + op[1], 'share': g.share.get(i, F(1))})
                g.now = t0
                g.add_seconds(i, op[1])
            g.now = t0 + op[1]
        elif k == 'adv_thr' and s.ids:
            tgt = g.lm.get(op[1], 0) + g.threshold + op[2]
            if tgt > g.now and tgt - g.now < 2 * WEEK:
                s.do(('adv', tgt - g.now))
        elif k == 'notify':
            g.notify(op[1], op[2], g.period() + op[3] if op[3] else None)
        elif k == 'gov':
            s.gov(op[1], op[2])
        elif s.ids and k in ('pm', 'all', 'period'):
            i = op[1]
            if i not in s.ids:
                return
            try:
                if k == 'pm':
                    g.pm_change(i, op[2], F(op[3]) if op[3] is not None else None)
                elif k == 'all':
                    g.get_all_rewards(i, op[3], 'vault', op[2])
                else:
                    g.get_period_reward(i, g.period() - op[3], op[4], 'vault', op[2])
            except GaugeRevert:
                pass
        elif k == 'burn' and op[1] in s.ids:
            g.pm_burn(op[1])


def gen_gauge(rng, n, strict=True):
    ops = [('mint', 1, 1), ('notify', 'PHAR', 70, 0)]
    for _ in range(n):
        x = rng.random()
        i = rng.choice([1, 2])
        o = rng.choice(['keeper', 'bot', 'user'])
        if x < 0.2:
            ops.append(('adv', rng.choice([1, 50, 111, 112, 4000, 90000, WEEK // 2, WEEK + 3])))
        elif x < 0.3:
            ops.append(('adv_thr', i, rng.choice([-1, 0, 1])))
        elif x < 0.38:
            ops.append(('mint', 2, rng.choice([1, 2])))
        elif x < 0.5:
            ops.append(('pm', i, o, rng.choice([None, None, 0, 1])))
        elif x < 0.62:
            ops.append(('all', i, o, rng.choice([('PHAR', 'XPHAR'), ('PHAR',), ('XPHAR',)])))
        elif x < 0.78:
            ops.append(('period', i, o, rng.choice([0, 0, 1, 2]), rng.choice([('PHAR',), ('PHAR', 'XPHAR')])))
        elif x < 0.86:
            ops.append(('notify', rng.choice(['PHAR', 'XPHAR']), rng.randint(1, 40), rng.choice([0, 0, 1])))
        elif x < 0.97:
            while True:
                nm, val = rng.choice([('thr', 111), ('thr', 300), ('thr', 0), ('antisybil', True), ('antisybil', False), ('validator', 'normal'), ('validator', 'revert'), ('validator', 'always'), ('validator', 'none'), ('mode', 'ok'), ('mode', 'revert'), ('mode', 'zero'), ('pool_ok', True), ('pool_ok', False), ('bl_wallet_add', 'bot'), ('bl_wallet_add', 'posmgr'), ('bl_wallet_del', 'bot'), ('bl_wallet_del', 'posmgr'), ('bl_hash_add', 1), ('bl_hash_add', 2)])
                if strict or nm != 'pool_ok' or val is True:
                    break
            ops.append(('gov', nm, val))
        else:
            ops.append(('burn', i))
    return ops


def gauge_fuzz(n, seed0=0, length=60, strict=True):
    bad = []
    for i in range(n):
        rng = random.Random(10 ** 6 + seed0 + i)
        ops = gen_gauge(rng, length, strict)
        r = GaugeRun()
        try:
            for op in ops:
                r.do(op)
        except Mismatch as m:
            bad.append((seed0 + i, m, ops))
        except Exception as ex:
            bad.append((seed0 + i, Mismatch('crash', '%s: %s' % (type(ex).__name__, ex)), ops))
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--n', type=int, default=3000)
    ap.add_argument('--seed0', type=int, default=0)
    ap.add_argument('--len', type=int, default=45)
    ap.add_argument('--mode', default='aligned', choices=['aligned', 'strict'])
    ap.add_argument('--minimise', action='store_true')
    ap.add_argument('--show', type=int, default=3)
    ap.add_argument('--gauge', type=int, default=0, help='number of gauge-only histories')
    ap.add_argument('--gauge-aligned', action='store_true', help='gauge-only: never switch the gauge-side pool read off')
    a = ap.parse_args()
    if a.gauge:
        bad = gauge_fuzz(a.gauge, strict=not a.gauge_aligned)
        print('gauge-only histories=%d mismatches=%d' % (a.gauge, len(bad)))
        print('GAUGEFAILSEEDS %s' % sorted(x[0] for x in bad))
        for seed, m, ops in bad[:a.show]:
            print('  seed %d: %s' % (seed, str(m)[:300]))
        if not a.n:
            return 1 if bad else 0
    strict = a.mode == 'strict'
    fails = {}
    cover = {'hist': 0, 'blocked': 0, 'ambig': 0, 'U': 0, 'funded_periods': 0, 'lost': 0, 'final': 0, 'ops': 0, 'crash': 0}
    for i in range(a.n):
        seed = a.seed0 + i
        rng = random.Random(seed)
        variant = 'W1' if i % 2 == 0 else 'EPOCH'
        buf = rng.choice([0, 0, 500, 2000]) if variant == 'EPOCH' else 0
        ops = gen(rng, a.len, variant, strict)
        cover['hist'] += 1
        try:
            r = execute(ops, variant, buf, strict)
            cover['blocked'] += r.stats['blocked']
            cover['ops'] += r.stats['ops']
            cover['ambig'] += len(r.R.ambig)
            cover['U'] += sum(1 for p in range(P0, r.g.period()) if r.R.ambig and p in r.R.ambig)
            cover['funded_periods'] += sum(1 for k, x in r.v.funded.items() if x)
            cover['lost'] += sum(1 for x in r.v.lost.values() if x)
            cover['final'] += sum(1 for p in range(P0, r.g.period()) if r.v.final(p))
        except Mismatch as m:
            key = (m.kind, m.detail.split(' ')[0] if m.kind != 'B' else m.detail[:40])
            if m.kind == 'crash':
                cover['crash'] += 1
            fails.setdefault(m.kind, []).append((seed, variant, buf, ops, m.detail))
    print('mode=%s histories=%d ops=%d' % (a.mode, cover['hist'], cover['ops']))
    print('coverage: refused ops %(blocked)d, ambiguous periods %(ambig)d, funded (period,token) cells %(funded_periods)d, loss entries %(lost)d, final periods checked %(final)d, crashes %(crash)d' % cover)
    tot = sum(len(v) for v in fails.values())
    print('histories with a mismatch: %d' % tot)
    print('FAILSEEDS %s' % sorted(sd for lst in fails.values() for (sd, *_r) in lst))
    for kind, lst in sorted(fails.items()):
        print('  kind %s: %d histories' % (kind, len(lst)))
        if kind == 'B':
            expl = sum(1 for x in lst if 'val=none' in x[4] or "'posmgr'" in x[4])
            print('    of which explained by the known guard deviations (validator=none or position-manager blacklist): %d, unexplained: %d' % (expl, len(lst) - expl))
        for seed, variant, buf, ops, detail in lst[:a.show]:
            print('    seed %d %s buf=%s: %s' % (seed, variant, buf, detail[:300]))
            if a.minimise:
                mo = minimise(ops, variant, buf, strict, kind)
                print('      minimal (%d ops): %s' % (len(mo), mo))
    return 1 if tot else 0


if __name__ == '__main__':
    sys.exit(main())
