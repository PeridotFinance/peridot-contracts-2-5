"""Reference model 2 of the PHAR entitlement ledger (exact rationals, NOT Solidity). EXPERIMENTAL.

Extends tools/refmodel.py (left untouched so the sha256 cited in the references file stays valid). Adds:
  * Gauge2: a mirror of the GaugeV3 / RamsesV3PositionManager / RewardValidator behaviour that was READ from source and
    probed (probe/ P1..P9, probe2/ Q1..Q10): per-NFT lastModified, threshold window, forfeit DEBT with the _forfeitedShare
    cascade, periodClaimedAmount, r33, getReward (all periods) vs getPeriodReward (one period), auto-claim on every liquidity
    change, gauge-side pool-read failure (treated as zero, lastClaim still advances), validator replaced/reverting, blacklist,
    governance threshold changes, xRatio (a second reward token appearing mid-period), retired and burned NFTs.
  * Vault2: the period-exposure ledger with (a) recording and settlement that are BOUNDED per call (deferred segments,
    checkpoint compaction, permissionless drain), (b) UNRESOLVED intervals when the pool's period-seconds reading fails
    (never attributed by elapsed time; reconciled only by an explicit, externally supplied split), (c) funding by per-period
    calls with an explicit classification (paid / slashed / nothing owed / no effect), losses booked as external losses borne
    pro rata by recorded exposure, (d) two liquidity-change policies: W1 (revert inside the window) and EPOCH (queue, one net
    liquidity change per batch, rate limited to once per live threshold + margin) with an optional idle buffer.
  * Env: a harness holding an independent ground-truth oracle of exposure (per holder and period) that does not use any of the
    vault's code path, used for the ownership-correctness property.
Limits: see the proposal, section "What the model proves and does not". Rationals, not floors; no gas; no reentrancy; no
storage layout; the gauge mirror follows the lines that were read, not the deployed bytecode.
"""
from fractions import Fraction as F
from collections import deque

WEEK = 604800
START_PERIOD = 100          # debt.period == 0 means "no debt" in the gauge, so periods start above 0
TOKS = ('PHAR', 'XPHAR')
ZERO_SUPPLY = '__zero_supply__'


class GaugeRevert(Exception):
    pass


class Blocked(Exception):
    """A liquidity-changing operation is refused because it would be slashed (W1 / EPOCH guard)."""
    def __init__(self, reason, retry_after=None):
        super().__init__(reason)
        self.reason = reason
        self.retry_after = retry_after


class Unavailable(Exception):
    """The pool's period-seconds reading is unavailable: mint/transfer/deposit fail closed."""


class Gauge2:
    def __init__(s):
        s.now = START_PERIOD * WEEK
        s.S = {}             # (period, tok) -> emission notified for that period (can grow while the period is current)
        s.T = {}             # (id, period) -> in-range seconds (already multiplied by liquidity share)
        s.claimed = {}       # (id, period, tok) -> paid + forfeited
        s.lastClaim = {}     # (id, tok)
        s.debt = {}          # (id, tok) -> (period, amount)
        s.lm = {}            # id -> lastModified
        s.burned = set()
        s.share = {}         # id -> liquidity share used by accrue()
        s.threshold = 111
        s.antisybil = True
        s.validator = 'normal'      # normal | none | revert | always  (always == implementation replaced by "slash everything")
        s.black_wallets = set()
        s.black_hashes = set()      # NFT ids
        s.r33 = {t: F(0) for t in TOKS}
        s.bal = {}           # (holder, tok)
        s.pool_ok = True     # the gauge's own staticcall to the pool succeeds
        s.mode = 'ok'        # ok | revert (call reverts) | zero (call returns, pays nothing, changes nothing)
        s.autoclaim = True   # position manager auto-claims on increase/decrease
        s.first_period = START_PERIOD

    # ---- time/exposure
    def period(s, t=None):
        return (s.now if t is None else t) // WEEK

    def add_seconds(s, id_, secs):
        """accrue in-range seconds for NFT id over [now, now+secs], splitting at period boundaries; advances now"""
        t = s.now
        end = t + secs
        while t < end:
            nxt = min(end, (t // WEEK + 1) * WEEK)
            d = nxt - t
            s.T[(id_, t // WEEK)] = s.T.get((id_, t // WEEK), F(0)) + d * s.share.get(id_, F(1))
            t = nxt
        s.now = end

    def notify(s, tok, amount, period=None):
        p = s.period() if period is None else period
        assert p >= s.period()
        s.S[(p, tok)] = s.S.get((p, tok), F(0)) + F(amount)

    # ---- views (mirror the gauge)
    def owed(s, id_, p, tok):
        return s.S.get((p, tok), F(0)) * s.T.get((id_, p), F(0)) / WEEK

    def cache_earned(s, id_, p, tok):
        if not s.pool_ok:
            return F(0)
        o = s.owed(id_, p, tok) - s.claimed.get((id_, p, tok), F(0))
        return o if o > 0 else F(0)

    def forfeited_share(s, id_, p, tok, unpaid):
        dp, da = s.debt.get((id_, tok), (0, F(0)))
        if dp == 0 or p > dp:
            return F(0)
        return unpaid if p < dp else min(unpaid, da)

    def period_earned(s, id_, p, tok):
        u = s.cache_earned(id_, p, tok)
        return u - s.forfeited_share(id_, p, tok, u)

    def earned(s, id_, tok):
        lc = max(s.lastClaim.get((id_, tok), 0), s.first_period)
        return sum((s.period_earned(id_, p, tok) for p in range(lc, s.period() + 1)), F(0))

    # ---- validator
    def should_slash(s, id_, receiver, origin):
        v = s.validator
        if v == 'none':
            return False
        if v == 'revert' or v == 'always':
            return True
        if receiver in s.black_wallets or origin in s.black_wallets or 'posmgr' in s.black_wallets or id_ in s.black_hashes:
            return True
        if not s.antisybil:
            return False
        lm = s.lm.get(id_, 0)
        if lm == 0:
            return False
        return s.now - lm <= s.threshold

    # ---- claim paths
    def _get_reward(s, id_, p, tok, receiver, origin):
        unpaid = s.cache_earned(id_, p, tok)
        if unpaid == 0:
            return
        forf = s.forfeited_share(id_, p, tok, unpaid)
        if s.should_slash(id_, receiver, origin):
            forf = unpaid
        paid = unpaid - forf
        dp, da = s.debt.get((id_, tok), (0, F(0)))
        if p == dp:
            s.debt[(id_, tok)] = (dp, da - min(da, forf))
        s.claimed[(id_, p, tok)] = s.claimed.get((id_, p, tok), F(0)) + forf + paid
        if forf:
            s.r33[tok] += forf
        if paid:
            s.bal[(receiver, tok)] = s.bal.get((receiver, tok), F(0)) + paid

    def get_all_rewards(s, id_, toks, receiver, origin):
        """_getAllRewards: slashed => record a forfeit DEBT against the current period and return (zero payment, no revert)."""
        if id_ in s.burned:
            raise GaugeRevert('burned')
        if s.mode == 'revert':
            raise GaugeRevert('mode')
        if s.mode == 'zero':
            return
        cur = s.period()
        if s.should_slash(id_, receiver, origin):
            for tok in toks:
                s.debt[(id_, tok)] = (cur, s.cache_earned(id_, cur, tok))
            return
        for tok in toks:
            lc = max(s.lastClaim.get((id_, tok), 0), s.first_period)
            for p in range(lc, cur + 1):
                s._get_reward(id_, p, tok, receiver, origin)
            s.lastClaim[(id_, tok)] = cur

    def get_period_reward(s, id_, p, toks, receiver, origin):
        """getPeriodReward: ONE period, evaluated by _getReward (slash forfeits that period only, writes no debt)."""
        if id_ in s.burned:
            raise GaugeRevert('burned')
        if s.mode == 'revert':
            raise GaugeRevert('mode')
        if s.mode == 'zero':
            return
        for tok in toks:
            s._get_reward(id_, p, tok, receiver, origin)

    # ---- position manager
    def pm_mint(s, id_, share=F(1)):
        s.share[id_] = F(share)
        s.lm[id_] = s.now

    def pm_change(s, id_, origin, new_share=None):
        """increaseLiquidity / decreaseLiquidity: auto-claim with the OLD lastModified (swallowed), then lastModified = now"""
        if id_ in s.burned:
            raise GaugeRevert('burned')
        if s.autoclaim:
            try:
                s.get_all_rewards(id_, TOKS, 'vault', origin)
            except GaugeRevert:
                pass
        s.lm[id_] = s.now
        if new_share is not None:
            s.share[id_] = F(new_share)

    def pm_burn(s, id_):
        s.burned.add(id_)          # succeeds with rewards outstanding (probe P5)


# ----------------------------------------------------------------------------------------------------------------------

class Vault2:
    """Exposure ledger. All attribution code (touch/_apply/drain/close_open/settle_steps/reconcile) is clock free: the only
    time inputs are period indices and, for the window guard, the gauge's lastModified/threshold (never for attribution)."""

    def __init__(s, g, variant='W1', margin=10, buffer_bps=0):
        s.g = g
        s.variant = variant
        s.margin = margin
        s.buffer_bps = buffer_bps
        s.bal = {}
        s.supply = F(0)
        s.idle = F(0)
        s.deployed = F(0)
        s.nfts = {}              # id -> dict(cursor, state, born)
        s.main = None
        s.Trec = {}              # (id, p)
        s.sealed = set()         # (id, p) read after the period ended
        s.J = {}; s.Tt = {}; s.Z = {}; s.U = {}; s.W = {}
        s.backlog = []           # deferred record segments: dict(id, p, end, supply)
        s.fail = None            # open reading-failure span
        s.open = {}              # h -> (period, jPaid)
        s.segs = {}              # h -> deque of closed multi-period segments (b, p, jStart, end)
        s.funded = {}; s.lost = {}
        s.claim_cursor = {}      # (h, tok) -> next unpaid final period
        s.paid_out = {}          # (h, tok)
        s.donated = {t: F(0) for t in TOKS}
        s.reports = []
        s.vault_bal = {t: F(0) for t in TOKS}   # PHAR/XPHAR owned by the vault (mirror of g.bal[('vault', tok)])
        s.q_dep = {}; s.q_wd = {}
        s.steps = 0              # work counter of the last public call (gas proxy)
        s.read_ok = True         # the vault's own direct pool read works
        s.reconciled = {}

    # ------------------------------------------------------------------ recording
    def _apply(s, p, d, sup, unresolved=False):
        if d == 0:
            return
        s.Tt[p] = s.Tt.get(p, F(0)) + d
        if unresolved:
            s.U[p] = s.U.get(p, F(0)) + d
        elif sup > 0:
            s.J[p] = s.J.get(p, F(0)) + d / sup
        else:
            s.Z[p] = s.Z.get(p, F(0)) + d

    def _read(s, id_, p):
        if not s.read_ok:
            raise Unavailable('pool period-seconds reading unavailable')
        return s.g.T.get((id_, p), F(0))

    def touch(s):
        """Record exposure up to now. O(#NFTs) inline work; ended periods are DEFERRED to the backlog. Returns False if the
        reading is unavailable (nothing is recorded or attributed)."""
        cur = s.g.period()
        if not s.read_ok:
            if s.fail is None:
                s.fail = {'supply_start': s.supply, 'start': {i: n['cursor'] for i, n in s.nfts.items()}, 'events': []}
            return False
        if s.fail is not None:
            s._resolve_fail(cur)
        for i, n in s.nfts.items():
            if n['state'] == 'drained':
                continue
            if n['cursor'] < cur:
                s.backlog.append({'id': i, 'p': n['cursor'], 'end': cur - 1, 'supply': s.supply, 'unres': set()})
                n['cursor'] = cur
            T = s._read(i, cur)
            d = T - s.Trec.get((i, cur), F(0))
            if d < 0:
                return False
            s._apply(cur, d, s.supply)
            s.Trec[(i, cur)] = T
            s.steps += 1
        return True

    def _resolve_fail(s, cur):
        """The reading is back. Periods in which a supply event (a burn) happened during the failure are UNRESOLVED: the split
        inside the period is unknowable without a clock, so their whole dT since the last good record goes to U[p]. Other
        periods are exact (the supply was constant while they ran) and are deferred to the backlog with that supply."""
        f = s.fail
        s.fail = None
        events = dict(f['events'])                 # period -> supply after the last event in that period
        for i, n in s.nfts.items():
            if n['state'] == 'drained':
                continue
            start = f['start'].get(i, n['cursor'])
            sup = f['supply_start']
            for q in range(start, cur + 1):
                if q < cur:
                    s.backlog.append({'id': i, 'p': q, 'end': q, 'supply': sup, 'unres': {q} if q in events else set()})
                else:
                    T = s._read(i, cur)
                    d = T - s.Trec.get((i, cur), F(0))
                    s._apply(cur, d, sup, unresolved=(cur in events))
                    s.Trec[(i, cur)] = T
                if q in events:
                    sup = events[q]
            n['cursor'] = cur

    def drain(s, max_steps):
        """Process deferred record steps in FIFO order. Each step reads one (NFT, ended period) and applies it with the supply
        that was in force. A failing read leaves the step at the head (nothing attributed). Returns steps done."""
        done = 0
        while s.backlog and done < max_steps:
            seg = s.backlog[0]
            p = seg['p']
            try:
                T = s._read(seg['id'], p)
            except Unavailable:
                break
            d = T - s.Trec.get((seg['id'], p), F(0))
            if d < 0:
                break
            s._apply(p, d, seg['supply'], unresolved=(p in seg['unres']))
            s.Trec[(seg['id'], p)] = T
            s.sealed.add((seg['id'], p))
            seg['p'] += 1
            done += 1
            if seg['p'] > seg['end']:
                s.backlog.pop(0)
        s.steps += done
        return done

    def _record_ready(s, q):
        return not any(seg['p'] <= q for seg in s.backlog) and s.fail is None

    # ------------------------------------------------------------------ accounts
    def close_open(s, h):
        """Close the account's open segment at the current period: O(1). Multi-period backlog is DEFERRED (checkpoint
        compaction): at most one closed segment per period in which the account is touched."""
        cur = s.g.period()
        b = s.bal.get(h, F(0))
        lp, jp = s.open.get(h, (cur, s.J.get(cur, F(0))))
        if b > 0:
            if lp == cur:
                s.W[(h, cur)] = s.W.get((h, cur), F(0)) + b * (s.J.get(cur, F(0)) - jp)
            else:
                s.segs.setdefault(h, deque()).append((b, lp, jp, cur - 1))
                s.W[(h, cur)] = s.W.get((h, cur), F(0)) + b * s.J.get(cur, F(0))
        s.open[h] = (cur, s.J.get(cur, F(0)))
        s.steps += 1

    def settle_steps(s, h, max_steps):
        """Advance the account's closed segments by up to max_steps (account, period) steps. Needs the period's J to be final
        (record backlog drained for it); returns steps done. Never changes any other account."""
        done = 0
        dq = s.segs.get(h)
        while dq and done < max_steps:
            b, p, jp, end = dq[0]
            if not s._record_ready(p):
                break
            js = jp
            s.W[(h, p)] = s.W.get((h, p), F(0)) + b * (s.J.get(p, F(0)) - js)
            done += 1
            if p == end:
                dq.popleft()
            else:
                dq[0] = (b, p + 1, F(0), end)
        s.steps += done
        return done

    def settled_through(s, h):
        """first period NOT yet fully attributed to h (periods below it have final W)"""
        dq = s.segs.get(h)
        if dq:
            return dq[0][1]
        return s.open.get(h, (s.g.period(), 0))[0]

    def progress(s, h, n):
        """Permissionless: advance record backlog and h's segments by at most n steps in total."""
        s.steps = 0
        s.touch_safe()
        s.close_open(h)
        k = s.settle_steps(h, n)
        k += s.drain(n - k)
        k += s.settle_steps(h, n - k)
        return k

    def touch_safe(s):
        try:
            return s.touch()
        except Unavailable:
            return False

    # ------------------------------------------------------------------ supply changes
    def _supply_change(s, from_h, to_h, n, allow_degraded):
        ok = s.touch_safe()
        if not ok and not allow_degraded:
            raise Unavailable('mint/transfer need a working reading')
        for h in (from_h, to_h):
            if h:
                s.close_open(h)
        if from_h:
            s.bal[from_h] = s.bal.get(from_h, F(0)) - n
        else:
            s.supply += n
        if to_h:
            s.bal[to_h] = s.bal.get(to_h, F(0)) + n
        else:
            s.supply -= n
        if not ok:
            s.fail['events'].append((s.g.period(), s.supply))
        for h in (from_h, to_h):
            if h:
                s.open[h] = (s.g.period(), s.J.get(s.g.period(), F(0)))

    def free(s, h):
        """shares not locked by a pending withdrawal request (locked shares keep their exposure but cannot move)"""
        return s.bal.get(h, F(0)) - s.q_wd.get(h, F(0))

    def transfer(s, a, b, n):
        n = F(n)
        assert s.free(a) >= n
        s._supply_change(a, b, n, allow_degraded=False)

    # ------------------------------------------------------------------ guard and funding
    def threshold_live(s):
        return s.g.threshold

    def will_slash(s, id_, origin, margin=None):
        margin = s.margin if margin is None else margin
        g = s.g
        if g.validator == 'none':
            return None
        if g.validator in ('revert', 'always'):
            return 'validator'
        if origin in g.black_wallets or 'vault' in g.black_wallets or id_ in g.black_hashes:
            return 'blacklist'
        if g.now - g.lm.get(id_, 0) <= s.threshold_live() + margin:
            return 'window'
        return None

    def _outstanding(s, p, tok):
        tgt = sum((s.g.S.get((p, tok), F(0)) * s.Trec.get((i, p), F(0)) / WEEK for i in s.nfts), F(0))
        return tgt - s.funded.get((p, tok), F(0)) - sum((v for (pp, t, c), v in s.lost.items() if pp == p and t == tok), F(0))

    def harvest(s, origin, max_periods=10**9):
        """Permissionless. Per-period claims so each paid unit is attributed to its period. Never called inside the window or
        for a blacklisted origin (the guard). Returns a list of classified outcomes."""
        s.steps = 0
        out = []
        s.touch_safe()
        cur = s.g.period()
        n_calls = 0
        for i, n in s.nfts.items():
            if i in s.g.burned:
                continue
            why = s.will_slash(i, origin)
            if why:
                out.append(('BLOCKED', i, why))
                continue
            for p in range(s.g.first_period, cur + 1):
                if not (p == cur or (i, p) in s.sealed):
                    continue
                for tok in TOKS:
                    owed_l = s.g.S.get((p, tok), F(0)) * s.Trec.get((i, p), F(0)) / WEEK - s.g.claimed.get((i, p, tok), F(0))
                    if owed_l <= 0:
                        continue
                    if n_calls >= max_periods:
                        out.append(('PAGE_LIMIT', i, p))
                        return out
                    n_calls += 1
                    s.steps += 1
                    b0 = s.g.bal.get(('vault', tok), F(0)); c0 = s.g.claimed.get((i, p, tok), F(0))
                    try:
                        s.g.get_period_reward(i, p, [tok], 'vault', origin)
                    except GaugeRevert:
                        out.append(('CALL_REVERTED', i, p, tok))
                        continue
                    paid = s.g.bal.get(('vault', tok), F(0)) - b0
                    cd = s.g.claimed.get((i, p, tok), F(0)) - c0
                    forf = cd - paid
                    if paid:
                        s.funded[(p, tok)] = s.funded.get((p, tok), F(0)) + paid
                    if forf:
                        s.lost[(p, tok, 'SLASHED')] = s.lost.get((p, tok, 'SLASHED'), F(0)) + forf
                    if cd == 0:
                        out.append(('NO_EFFECT_ZERO_PAYMENT', i, p, tok))     # owed per exposure, gauge pays 0, nothing recorded
                    elif forf:
                        out.append(('SLASHED', i, p, tok, forf))
                    else:
                        out.append(('PAID', i, p, tok, paid))
        s.vault_bal = {t: s.g.bal.get(('vault', t), F(0)) for t in TOKS}
        s.reports.extend(out)
        return out

    def advance_gauge_lastclaim(s, origin):
        """hygiene: one getReward-equivalent when the gauge owes nothing raw, so lastClaim moves; must pay exactly zero"""
        for i in s.nfts:
            if i in s.g.burned or s.will_slash(i, origin):
                continue
            lc = [max(s.g.lastClaim.get((i, t), 0), s.g.first_period) for t in TOKS]
            if all(s.g.cache_earned(i, p, t) == 0 for t in TOKS for p in range(min(lc), s.g.period() + 1)):
                b0 = {t: s.g.bal.get(('vault', t), F(0)) for t in TOKS}
                s.g.get_all_rewards(i, TOKS, 'vault', origin)
                assert all(s.g.bal.get(('vault', t), F(0)) == b0[t] for t in TOKS)

    # ------------------------------------------------------------------ finality, entitlement, claim
    def final(s, p):
        cur = s.g.period()
        if p >= cur or not s._record_ready(p):
            return False
        for i, n in s.nfts.items():
            if n['born'] <= p and (i, p) not in s.sealed:
                return False
        return all(s._outstanding(p, t) == 0 for t in TOKS)

    def entitlement(s, h, p, tok):
        """None unless the period is final AND h is attributed through p"""
        if not s.final(p) or s.settled_through(h) <= p:
            return None
        Tt = s.Tt.get(p, F(0))
        return F(0) if Tt == 0 else s.funded.get((p, tok), F(0)) * s.W.get((h, p), F(0)) / Tt

    def reserved_unresolved(s, p, tok):
        Tt = s.Tt.get(p, F(0))
        return F(0) if Tt == 0 else s.funded.get((p, tok), F(0)) * s.U.get(p, F(0)) / Tt

    def bucket_zero(s, p, tok):
        Tt = s.Tt.get(p, F(0))
        return F(0) if Tt == 0 else s.funded.get((p, tok), F(0)) * s.Z.get(p, F(0)) / Tt

    def claim(s, h, max_steps=10**9):
        """Pay what is final and attributed; returns {tok: amount}. Bounded: at most max_steps account/record steps and the
        same number of payment periods. Works with zero balance, paused, any time after."""
        s.steps = 0
        s.touch_safe()
        s.close_open(h)
        k = s.settle_steps(h, max_steps)
        k += s.drain(max_steps - k)
        k += s.settle_steps(h, max_steps - k)
        paid = {t: F(0) for t in TOKS}
        for tok in TOKS:
            p = s.claim_cursor.get((h, tok), s.g.first_period)
            n = 0
            while p < s.g.period() and n < max_steps:
                e = s.entitlement(h, p, tok)
                if e is None:
                    break
                paid[tok] += e
                p += 1
                n += 1
            s.claim_cursor[(h, tok)] = p
            s.paid_out[(h, tok)] = s.paid_out.get((h, tok), F(0)) + paid[tok]
        return paid

    def reconcile(s, p, split):
        """Operator-supplied resolution of an UNRESOLVED interval: split = {holder: weight}. No default rule exists, because the
        only computable split uses timestamps, which the design forbids as an automatic rule."""
        assert s.final_pending_ok(p)
        tot = sum(split.values())
        u = s.U.pop(p, F(0))
        for h, w in split.items():
            part = u * F(w) / F(tot)
            if h == ZERO_SUPPLY:                  # the part of the interval in which nobody held shares
                s.Z[p] = s.Z.get(p, F(0)) + part
            else:
                s.W[(h, p)] = s.W.get((h, p), F(0)) + part
        s.reconciled[p] = s.reconciled.get(p, F(0)) + u

    def final_pending_ok(s, p):
        return p < s.g.period() and s._record_ready(p)

    # ------------------------------------------------------------------ NFTs
    def add_nft(s, id_, share=F(1)):
        s.g.pm_mint(id_, share)
        s.nfts[id_] = {'cursor': s.g.period(), 'state': 'active', 'born': s.g.period()}
        if s.main is None:
            s.main = id_

    def retire(s, id_, origin):
        s.harvest(origin)
        s._pm_change_booked(id_, origin, new_share=0)
        s.nfts[id_]['state'] = 'retired'

    def burn_nft(s, id_):
        """Only when nothing is outstanding for it: never burn an NFT with rewards outstanding (probe P5)."""
        cur = s.g.period()
        for p in range(s.g.first_period, cur + 1):
            for t in TOKS:
                if s.g.S.get((p, t), F(0)) * s.Trec.get((id_, p), F(0)) / WEEK - s.g.claimed.get((id_, p, t), F(0)) > 0:
                    raise Blocked('rewards outstanding')
        if s.g.share.get(id_, F(0)) != 0:
            raise Blocked('liquidity not removed')
        s.g.pm_burn(id_)
        s.nfts[id_]['state'] = 'drained'

    # ------------------------------------------------------------------ user operations (variants)
    def _guard(s, origin):
        why = s.will_slash(s.main, origin)
        if why:
            retry = (s.g.lm.get(s.main, 0) + s.threshold_live() + s.margin) if why == 'window' else None
            raise Blocked(why, retry)

    def _pm_change_booked(s, id_, origin, new_share=None):
        """ONE liquidity change on an NFT. Its auto-claim cannot be avoided (probe: increase/decrease always call it). Everything
        it pays is booked PER PERIOD from the gauge's own periodClaimedAmount deltas (needs no pool read), so even when the
        exposure reading is down nothing is unexplained; any remainder goes to the donated counter, never to holders."""
        cur = s.g.period()
        snap = {}
        for tok in TOKS:
            lc = max(s.g.lastClaim.get((id_, tok), 0), s.g.first_period)
            for p in range(lc, cur + 1):
                u = s.g.cache_earned(id_, p, tok)
                snap[(p, tok)] = (s.g.claimed.get((id_, p, tok), F(0)), s.g.forfeited_share(id_, p, tok, u))
        before = {t: s.g.bal.get(('vault', t), F(0)) for t in TOKS}
        s.g.pm_change(id_, origin, new_share=new_share)
        booked = {t: F(0) for t in TOKS}
        for (p, tok), (c0, forf0) in snap.items():
            dc = s.g.claimed.get((id_, p, tok), F(0)) - c0
            if dc:
                paid = dc - forf0
                if paid:
                    s.funded[(p, tok)] = s.funded.get((p, tok), F(0)) + paid
                    booked[tok] += paid
                if forf0:
                    s.lost[(p, tok, 'SLASHED')] = s.lost.get((p, tok, 'SLASHED'), F(0)) + forf0
        for tok in TOKS:
            extra = s.g.bal.get(('vault', tok), F(0)) - before[tok] - booked[tok]
            if extra:
                s.donated[tok] += extra       # unexplained inflow: never allocated to holders (should not occur)

    def _liquidity_op(s, origin, delta):
        """harvest (clean), then ONE liquidity change on the main NFT; the auto-claim then pays (about) zero"""
        s.harvest(origin)
        s._pm_change_booked(s.main, origin)

    def deposit(s, h, x, origin='user'):
        x = F(x)
        if s.variant == 'W1':
            if not s.touch_safe():
                raise Unavailable('deposit needs a working reading')
            s._guard(origin)
            s._liquidity_op(origin, x)
            s._supply_change(None, h, x, allow_degraded=False)
            s.deployed += x
        else:
            s.q_dep[h] = s.q_dep.get(h, F(0)) + x     # escrowed; shares minted at processing; no exposure while queued
        return x

    def redeem(s, h, x, origin='user'):
        """x shares. Paid from idle without any liquidity change when idle covers it; otherwise W1 removes liquidity inside the
        guard, EPOCH queues the request (the shares keep their exposure until processing)."""
        x = F(x)
        assert s.free(h) >= x
        if s.idle >= x:
            s._supply_change(h, None, x, allow_degraded=True)     # burn proceeds even if the reading fails (unresolved)
            s.idle -= x
            return 'paid_from_idle'
        if s.variant == 'W1':
            s.touch_safe()
            s._guard(origin)
            s._liquidity_op(origin, -x)
            s._supply_change(h, None, x, allow_degraded=True)
            s.deployed -= x
            return 'paid_from_liquidity'
        s.q_wd[h] = s.q_wd.get(h, F(0)) + x
        return 'queued'

    def process_batch(s, origin='keeper'):
        """EPOCH: permissionless, one net liquidity change at most per (threshold + margin). Empty batches change nothing."""
        assert s.variant == 'EPOCH'
        if not (s.q_dep or s.q_wd):
            return 'empty'
        s._guard(origin)
        ok = s.touch_safe()
        # reading down: principal EXIT stays available (withdrawals proceed, their interval becomes UNRESOLVED); deposits stay queued
        dep = sum(s.q_dep.values(), F(0)) if ok else F(0)
        wd = sum(s.q_wd.values(), F(0))
        nav = s.idle + s.deployed
        target_idle = (nav + dep - wd) * F(s.buffer_bps, 10000)
        net_deploy = (s.idle + dep - wd) - target_idle      # >0 deploy, <0 remove
        if not ok:
            net_deploy = min(net_deploy, F(0))
        if net_deploy != 0:
            s._liquidity_op(origin, net_deploy)
        if ok:
            for h, x in list(s.q_dep.items()):
                s._supply_change(None, h, x, allow_degraded=False)
        for h, x in list(s.q_wd.items()):
            s._supply_change(h, None, x, allow_degraded=True)
        if ok:
            s.idle = target_idle
            s.deployed = (nav + dep - wd) - s.idle
        else:
            s.deployed = max(F(0), nav - wd - s.idle)
            s.idle = nav - wd - s.deployed
        if ok:
            s.q_dep = {}
        s.q_wd = {}
        return 'processed' if ok else 'processed_exits_only'



# ----------------------------------------------------------------------------------------------------------------------

class Env:
    """Harness: gauge + vault + an independent ground-truth oracle of exposure (does not use any vault code path)."""

    def __init__(s, variant='W1', **kw):
        s.g = Gauge2()
        s.v = Vault2(s.g, variant, **kw)
        s.truth = {}      # (h, p) -> true exposure
        s.truthZ = {}     # p -> true zero-supply exposure
        s.truthTt = {}

    def advance(s, secs, ids=None):
        """let time pass with the given NFTs in range (default: all active). The ORACLE attributes exposure with the true
        balances in force, independently of anything the vault records."""
        ids = [i for i, n in s.v.nfts.items() if n['state'] == 'active'] if ids is None else ids
        t = s.g.now
        end = t + secs
        while t < end:
            nxt = min(end, (t // WEEK + 1) * WEEK)
            d = nxt - t
            p = t // WEEK
            for i in ids:
                dT = d * s.g.share.get(i, F(1))
                if dT == 0:
                    continue
                s.g.T[(i, p)] = s.g.T.get((i, p), F(0)) + dT
                s.truthTt[p] = s.truthTt.get(p, F(0)) + dT
                if s.v.supply > 0:
                    for h, b in s.v.bal.items():
                        if b:
                            s.truth[(h, p)] = s.truth.get((h, p), F(0)) + dT * b / s.v.supply
                else:
                    s.truthZ[p] = s.truthZ.get(p, F(0)) + dT
            t = nxt
        s.g.now = end

    def drain_all(s, h_list=None, limit=100000):
        s.v.touch_safe()
        k = 0
        while s.v.backlog and k < limit:
            n = s.v.drain(1000)
            k += 1
            if n == 0:
                break
        for h in (h_list or list(s.v.bal)):
            s.v.close_open(h)
            s.v.settle_steps(h, 10**9)
