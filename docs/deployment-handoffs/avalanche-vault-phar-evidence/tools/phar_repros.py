"""Minimal reproductions of every discrepancy found by the independent verification (EXPERIMENTAL; see
docs/deployment-handoffs/avalanche-vault-phar-decisions.md section A). Run: python3 -I phar_repros.py
Each block prints REPRODUCED when the defect is present in refmodel2.py as committed, and NOT REPRODUCED otherwise."""
import sys
from fractions import Fraction as F
sys.path.insert(0, __file__.rsplit('/', 1)[0] if '/' in __file__ else '.')
import refmodel2 as M
from refmodel2 import Env, WEEK, START_PERIOD as P0, Blocked


def mk(variant='W1'):
    e = Env(variant)
    e.v.add_nft(1)
    e.g.notify('PHAR', 100)
    e.advance(200, ids=[])
    return e


def report(name, cond, text):
    print('%-4s %-11s %s' % (name, 'REPRODUCED' if cond else 'NOT REPRODUCED', text))


# R1 model bug: an NFT created while the exposure reading is down, after a supply change, is recorded with the supply at the
# START of the outage instead of the supply in force. Exposure vanishes (sum W+Z+U != Tt) or lands on the wrong holder.
e = mk()
e.v.deposit('A', 248)
e.v.read_ok = False
e.advance(WEEK + 7, ids=[1])
e.v.redeem('A', 50)                     # a burn during the outage: a supply event inside the failure span
e.advance(3 * WEEK, ids=[])
e.v.add_nft(2)                          # new NFT inside the same span (fail span still open)
e.advance(3 * WEEK)
e.v.read_ok = True
e.v.touch_safe(); e.drain_all()
p = P0 + 4
tot = e.v.W.get(('A', p), F(0)) + e.v.Z.get(p, F(0)) + e.v.U.get(p, F(0))
report('R1', tot != e.v.Tt[p], 'period %d: sum(W)+Z+U = %s but Tt = %s (true exposure is all A\'s)' % (p, tot, e.v.Tt[p]))

# R2 model bug: burning (draining) an NFT in period p leaves (nft, p) unsealed, final(p) is False for ever, and claim() stops at
# the first non-final period, so every later period stays unclaimable although the gauge owes nothing.
e = mk()
e.v.deposit('A', 100)
e.v.add_nft(2, F(1, 2))
e.advance(3 * WEEK)
e.advance(200, ids=[])
e.v.retire(2, 'keeper')
e.v.burn_nft(2)
e.advance(2 * WEEK, ids=[1])
for _ in range(3):
    e.v.touch_safe(); e.drain_all(); e.v.harvest('keeper')
cur = e.g.period()
stuck = [q for q in range(P0, cur) if not e.v.final(q)]
paid = e.v.claim('A')
report('R2', bool(stuck), 'non-final periods %s although the gauge owes nothing; claim pays %s' % (stuck, dict(paid)))

# R3 model gap: Gauge2.will_slash (the vault guard) ignores a blacklist of the OWNER (the position manager), which the
# specified guard (validateReward with owner = position manager) does detect. The gauge slashes; the loss is booked.
e = mk()
e.v.deposit('A', 100); e.advance(WEEK // 3); e.advance(200, ids=[])
e.g.black_wallets.add('posmgr')
rep = e.v.harvest('keeper')
report('R3', any(r[0] == 'SLASHED' for r in rep), 'harvest outcome %s' % [r[0] for r in rep])

# R4 model gap: Vault2.retire() makes a liquidity change (auto-claim) without the window guard that the specification requires
# for every call that can auto-claim (5.5, rebalance). A freshly minted NFT is inside its own window.
e = mk()
e.v.deposit('A', 100)
e.v.add_nft(2, F(1, 2))
e.advance(5)
e.v.retire(2, 'keeper')                 # the auto-claim is slashed: a forfeit DEBT is written against NFT 2
e.advance(2 * WEEK, ids=[1])
for _ in range(3):
    e.v.touch_safe(); e.drain_all(); e.v.harvest('keeper')
lost = sum(e.v.lost.values(), F(0))
report('R4', lost > 0 and e.g.r33['PHAR'] > 0, 'NFT 2 retired 5 s after its mint: forfeited to r33 at the next clean claim: %s (booked as loss %s)' % (e.g.r33['PHAR'], lost))

# R5 premise gap: GaugeV3.sweepForfeited is permissionless and not modelled. Once a debt exists, anyone can realise the forfeit,
# and the vault (which only books what its own calls moved) never sees it: outstanding(p) stays > 0, final(p) stays False.
e = mk()
e.v.deposit('A', 100); e.advance(WEEK // 3); e.advance(200, ids=[])
saved = e.v.will_slash
e.v.will_slash = lambda *a, **k: None          # a guard failure (e.g. a governance change racing the call)
e.v.harvest('keeper')                           # clean harvest
e.advance(100)
e.g.validator = 'always'
e.v._pm_change_booked(1, 'user')                # a liquidity change whose auto-claim is slashed (guard failed): debt > 0
e.g.validator = 'normal'
e.v.will_slash = saved
debt = dict(e.g.debt)
# third party sweepForfeited (GaugeV3 source), emulated on the mirror: forfeited-only _getReward for periods lastClaim..debt.period
for tok in M.TOKS:
    d = e.g.debt.get((1, tok))
    if not d:
        continue
    for q in range(max(e.g.lastClaim.get((1, tok), 0), e.g.first_period), d[0] + 1):
        unpaid = e.g.cache_earned(1, q, tok)
        if unpaid == 0:
            continue
        f = e.g.forfeited_share(1, q, tok, unpaid)
        if q == d[0]:
            e.g.debt[(1, tok)] = (d[0], d[1] - min(d[1], f))
        e.g.claimed[(1, q, tok)] = e.g.claimed.get((1, q, tok), F(0)) + f
        e.g.r33[tok] += f
e.advance(2 * WEEK, ids=[])
for _ in range(3):
    e.v.touch_safe(); e.drain_all(); e.v.harvest('keeper')
q = P0
report('R5', not e.v.final(q) and e.v._outstanding(q, 'PHAR') > 0, 'debt %s; after an external sweep outstanding(%d)=%s, final=%s' % (debt, q, e.v._outstanding(q, 'PHAR'), e.v.final(q)))

# R6 mirror deviation (benign direction): the real gauge caches an ended period's seconds per (period, POSITION HASH), not per
# token (periodAmountsWritten, GaugeV3 340-343). A claim for ANY token after the period ended caches it; later a failing pool
# read no longer hides that period's unpaid PHAR. Gauge2.cache_earned returns 0 for every period whenever the read fails.
import phar_oracle as O
g = M.Gauge2(); o = O.OracleGauge(P0)
g.pm_mint(1); o.lm[1] = g.now
g.notify('PHAR', 100); o.S[(P0, 'PHAR')] += 100
g.advance = None
t0 = g.now
g.add_seconds(1, WEEK // 2); o.T[(1, P0)] += F(WEEK // 2)
g.now = (P0 + 1) * WEEK + 500
g.get_period_reward(1, P0, ['XPHAR'], 'vault', 'k'); o.get_period(g.now, 1, P0, ['XPHAR'], 'vault', 'k')   # pays nothing, caches
g.pool_ok = False; o.pool_ok = False
g.get_period_reward(1, P0, ['PHAR'], 'vault', 'k'); o.get_period(g.now, 1, P0, ['PHAR'], 'vault', 'k')
report('R6', g.bal.get(('vault', 'PHAR'), F(0)) == 0 and o.bal[('vault', 'PHAR')] > 0,
       'pool read failing after an XPHAR-only claim cached the period: model paid %s, source-based oracle paid %s' % (g.bal.get(('vault', 'PHAR'), F(0)), o.bal[('vault', 'PHAR')]))

# R7 benign difference: with NO validator set (Gauge validator == none) the model's guard returns "not blocked"; the specified
# guard still applies the explicit lastModified clause (5.5). The gauge slashes nothing in that state, so nothing is lost.
e = mk()
e.v.deposit('A', 100)
e.g.validator = 'none'
try:
    e.v.redeem('A', 100)
    blocked = False
except Blocked:
    blocked = True
report('R7', not blocked, 'W1 redeem inside the window with validator=none: model does not refuse (specification refuses)')
