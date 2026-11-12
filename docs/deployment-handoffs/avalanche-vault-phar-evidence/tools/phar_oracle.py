"""Independent ground-truth oracle for the PHAR entitlement design (EXPERIMENTAL). Shares NO code with refmodel2.py.

It consumes a RAW EVENT HISTORY and computes, with exact rationals:
  * the per-period, per-holder EXPOSURE (share-weighted in-range seconds) straight from the definition: while a position is in
    range, every in-range second is split among the share balances in force at that moment, or goes to the zero-supply bucket;
  * a GAUGE replay written from the Solidity text of GaugeV3 / RamsesV3PositionManager / RewardValidator (the copies fetched in
    the scratchpad: GaugeV3.sol _getAllRewards 466-489, _recordForfeit, _forfeitedShare, _claimAll, sweepForfeited, _getReward
    553-583, cachePeriodEarned 316-356; RewardValidator.validateReward 154-193; PositionManager _tryClaimRewards 207-221,
    lastModified 183, 291, 361), so the model's gauge mirror is checked against the source and not against itself;
  * the guard predicate of the proposal's section 5.5 (explicit validator call with owner = position manager, plus the
    lastModified clause), used to predict when a liquidity change must be refused.

Event kinds (dicts, 'k' is the kind, 't' absolute seconds, events are applied strictly in list order):
  inrange {nft, t0, t1, share}     position is in range over [t0, t1) with liquidity share `share`
  bal     {h, delta, outage}       share balance of holder h changes (mint > 0, burn < 0, transfers are two events); `outage`
                                   = the vault's own exposure reading was unavailable when it happened
  notify  {tok, amount, period}
  mint    {nft}                    position manager mint (lastModified = t)
  burn    {nft}                    position manager burn
  gov     {name, value}            threshold / antisybil / validator / mode / pool_ok / bl_wallet_add / bl_wallet_del / bl_hash_add
  claim_all   {nft, toks, receiver, origin, raises}
  claim_period{nft, period, toks, receiver, origin, raises}
  pm_change   {nft, origin, raises}   increase/decrease liquidity: swallowed auto-claim [PHAR, XPHAR] with the OLD lastModified,
                                      then lastModified = t
  sweep       {nft, toks}             permissionless GaugeV3.sweepForfeited
"""
from fractions import Fraction as F
from collections import defaultdict

WEEK = 604800
TOKS = ('PHAR', 'XPHAR')


class Rev(Exception):
    pass


class OracleGauge:
    def __init__(s, first_period):
        s.first = first_period
        s.S = defaultdict(F)            # tokenTotalSupplyByPeriod[period][token]
        s.T = defaultdict(F)            # (nft, period) true in-range seconds * share
        s.claimed = defaultdict(F)      # periodClaimedAmount[(nft, period, token)]
        s.last_claim = {}               # lastClaimByToken[(nft, token)]
        s.debt = {}                     # forfeitedRewards[(nft, token)] = (period, amount)
        s.written = {}                  # periodAmountsWritten cache of ended-period seconds
        s.lm = {}
        s.burned = set()
        s.thr = 111
        s.antisybil = True
        s.validator = 'normal'          # normal | none | revert | always
        s.bl_wallets = set()
        s.bl_hashes = set()
        s.pool_ok = True
        s.mode = 'ok'                   # ok | revert | zero  (behaviour of the gauge implementation, a governance assumption)
        s.bal = defaultdict(F)          # (holder, token)
        s.r33 = defaultdict(F)
        s.paid_p = defaultdict(F)       # (receiver, period, token) paid
        s.forf_p = defaultdict(F)       # (period, token) forfeited (all callers)
        s.forf_vault_p = defaultdict(F)  # forfeited during a call whose receiver is 'vault'

    # cachePeriodEarned
    def unpaid(s, nft, p, tok, now, caching):
        key = (nft, p)
        if key in s.written:
            secs = s.written[key]
        else:
            if not s.pool_ok:
                return F(0)
            secs = s.T[key] if key in s.T else F(0)
            if caching and p < now // WEEK:
                s.written[key] = secs
        amount = s.S[(p, tok)] * secs / WEEK
        c = s.claimed[(nft, p, tok)]
        return amount - c if amount >= c else F(0)

    def forfeited_share(s, nft, p, tok, unpaid):
        d = s.debt.get((nft, tok))
        if d is None or d[0] == 0 or p > d[0]:
            return F(0)
        return unpaid if p < d[0] else min(unpaid, d[1])

    # RewardValidator.validateReward + Gauge._shouldSlash (fail closed)
    def should_slash(s, now, nft, receiver, origin):
        v = s.validator
        if v == 'none':
            return False
        if v in ('revert', 'always'):
            return True
        if 'posmgr' in s.bl_wallets or receiver in s.bl_wallets or origin in s.bl_wallets or nft in s.bl_hashes:
            return True
        if not s.antisybil:
            return False
        lm = s.lm.get(nft, 0)
        if lm == 0:
            return False
        return now - lm <= s.thr

    def _get_reward(s, now, nft, p, tok, receiver, origin, forfeited_only=False):
        unpaid = s.unpaid(nft, p, tok, now, True)
        if unpaid == 0:
            return
        forf = s.forfeited_share(nft, p, tok, unpaid)
        if not forfeited_only and s.should_slash(now, nft, receiver, origin):
            forf = unpaid
        paid = F(0) if forfeited_only else unpaid - forf
        d = s.debt.get((nft, tok))
        if d is not None and p == d[0]:
            s.debt[(nft, tok)] = (d[0], d[1] - min(d[1], forf))
        s.claimed[(nft, p, tok)] += forf + paid
        if forf:
            s.r33[tok] += forf
            s.forf_p[(p, tok)] += forf
            if receiver == 'vault':
                s.forf_vault_p[(p, tok)] += forf
        if paid:
            s.bal[(receiver, tok)] += paid
            s.paid_p[(receiver, p, tok)] += paid

    def get_all(s, now, nft, toks, receiver, origin):
        if nft in s.burned or s.mode == 'revert':
            raise Rev()
        if s.mode == 'zero':
            return
        cur = now // WEEK
        if s.should_slash(now, nft, receiver, origin):
            for tok in toks:                                        # _recordForfeit
                s.debt[(nft, tok)] = (cur, s.unpaid(nft, cur, tok, now, False))
            return
        for tok in toks:                                            # _claimAll
            lc = max(s.last_claim.get((nft, tok), 0), s.first)
            for p in range(lc, cur + 1):
                s._get_reward(now, nft, p, tok, receiver, origin)
            s.last_claim[(nft, tok)] = cur

    def get_period(s, now, nft, p, toks, receiver, origin):
        if nft in s.burned or s.mode == 'revert':
            raise Rev()
        if s.mode == 'zero':
            return
        for tok in toks:
            s._get_reward(now, nft, p, tok, receiver, origin)

    def sweep(s, now, nft, toks):
        for tok in toks:
            d = s.debt.get((nft, tok))
            cutoff = d[0] if d else 0
            start = max(s.last_claim.get((nft, tok), 0), s.first)
            for p in range(start, cutoff + 1):
                s._get_reward(now, nft, p, tok, None, None, forfeited_only=True)

    def pm_change(s, now, nft, origin):
        if nft in s.burned:
            raise Rev()
        try:
            s.get_all(now, nft, TOKS, 'vault', origin)
        except Rev:
            pass
        s.lm[nft] = now

    def earned(s, now, nft, tok):
        lc = max(s.last_claim.get((nft, tok), 0), s.first)
        tot = F(0)
        for p in range(lc, now // WEEK + 1):
            u = s.unpaid(nft, p, tok, now, False)
            tot += u - s.forfeited_share(nft, p, tok, u)
        return tot

    def outstanding(s, nfts, p, tok, now):
        """sum over the NFTs of what the gauge still owes for period p (raw, what a claim could still realise)"""
        tot = F(0)
        for n in nfts:
            amt = s.S[(p, tok)] * s.T[(n, p)] / WEEK
            c = s.claimed[(n, p, tok)]
            if amt > c:
                tot += amt - c
        return tot


class Replay:
    """Applies a raw event list. `compare` (callable) is invoked after every gauge event with the oracle gauge so a driver can
    check the model's state against it."""

    def __init__(s, first_period):
        s.g = OracleGauge(first_period)
        s.bal = defaultdict(F)
        s.W = defaultdict(F)
        s.Z = defaultdict(F)
        s.Tt = defaultdict(F)
        s.ambig = set()                 # periods in which the share supply changed while the vault's reading was down
        s.nfts = []
        s.now = 0

    # ---- exposure
    def inrange(s, nft, t0, t1, share):
        t = t0
        while t < t1:
            nxt = min(t1, (t // WEEK + 1) * WEEK)
            p = t // WEEK
            dT = (nxt - t) * share
            s.g.T[(nft, p)] += dT
            s.Tt[p] += dT
            sup = sum(s.bal.values(), F(0))
            if sup > 0:
                for h, b in s.bal.items():
                    if b:
                        s.W[(h, p)] += dT * b / sup
            else:
                s.Z[p] += dT
            t = nxt

    def apply(s, ev):
        k = ev['k']
        t = ev.get('t', s.now)
        s.now = t
        g = s.g
        if k == 'inrange':
            s.inrange(ev['nft'], ev['t0'], ev['t1'], ev['share'])
            s.now = ev['t1']
        elif k == 'bal':
            s.bal[ev['h']] += ev['delta']
            if ev['outage']:
                s.ambig.add(t // WEEK)
        elif k == 'notify':
            g.S[(ev['period'], ev['tok'])] += ev['amount']
        elif k == 'mint':
            g.lm[ev['nft']] = t
            s.nfts.append(ev['nft'])
        elif k == 'burn':
            g.burned.add(ev['nft'])
        elif k == 'gov':
            n, v = ev['name'], ev['value']
            if n == 'bl_wallet_add':
                g.bl_wallets.add(v)
            elif n == 'bl_wallet_del':
                g.bl_wallets.discard(v)
            elif n == 'bl_hash_add':
                g.bl_hashes.add(v)
            else:
                setattr(g, n, v)
        elif k in ('claim_all', 'claim_period', 'pm_change', 'sweep'):
            raised = False
            try:
                if k == 'claim_all':
                    g.get_all(t, ev['nft'], ev['toks'], ev['receiver'], ev['origin'])
                elif k == 'claim_period':
                    g.get_period(t, ev['nft'], ev['period'], ev['toks'], ev['receiver'], ev['origin'])
                elif k == 'pm_change':
                    g.pm_change(t, ev['nft'], ev['origin'])
                else:
                    g.sweep(t, ev['nft'], ev['toks'])
            except Rev:
                raised = True
            return raised
        else:
            raise ValueError(k)
        return None

    # ---- predictions
    def guard(s, nft, origin, margin):
        """section 5.5 willSlash: explicit validateReward(owner = position manager, receiver = vault, ...) when a validator is
        set, OR the explicit lastModified clause. Returns a reason or None."""
        g = s.g
        if g.validator != 'none':
            if g.validator in ('revert', 'always'):
                return 'validator'
            if 'posmgr' in g.bl_wallets or 'vault' in g.bl_wallets or origin in g.bl_wallets or nft in g.bl_hashes:
                return 'blacklist'
        if s.now - g.lm.get(nft, 0) <= g.thr + margin:
            return 'window'
        return None

    def ent(s, paid_p, h, p):
        """oracle entitlement of holder h for period p given the amount funded for p"""
        if s.Tt[p] == 0:
            return F(0)
        return paid_p * s.W[(h, p)] / s.Tt[p]
