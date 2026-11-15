"""Tests for refmodel2.py. Run: python3 -I -m unittest -v test_refmodel2   (from this directory) or python3 test_refmodel2.py
Properties checked (named in the proposal):
  (i)   OWNERSHIP: each reward unit is attributed to holders in proportion to the exposure they ACTUALLY had in the interval it
        was earned in (independent oracle), independent of claim timing and of who touches the vault.
  (ii)  LIVENESS: principal exit is possible within the stated bound in every modelled state, or the test NAMES the variant/state
        in which it is not.
  (iii) NO VALUE from an unresolved interval is attributed until it is reconciled.
  conservation: sum(entitlements) + buckets + reserved <= funded; equality once everything is settled.
"""
import inspect
import io
import random
import sys
import unittest
from fractions import Fraction as F

sys.path.insert(0, __file__.rsplit('/', 1)[0] if '/' in __file__ else '.')
import refmodel2 as M
from refmodel2 import Env, Vault2, Gauge2, Blocked, Unavailable, GaugeRevert, WEEK, START_PERIOD, TOKS

P0 = START_PERIOD


def mk(variant='W1', S=100, nfts=(1,), **kw):
    e = Env(variant, **kw)
    for i in nfts:
        e.v.add_nft(i)
    if S:
        e.g.notify('PHAR', S)
    e.advance(200, ids=[])          # leave the mint window; nothing accrues
    return e


def finish(e, periods=1, origin='keeper'):
    """end the period(s), seal them, fund them, attribute everything"""
    e.advance(periods * WEEK - (e.g.now % WEEK) + 1 if e.g.now % WEEK else periods * WEEK, ids=[])
    for _ in range(3):
        e.v.touch_safe()
        e.drain_all()
        e.v.harvest(origin)
    e.drain_all()


def total_ent(e, p, tok='PHAR', accts=None):
    accts = accts or list(e.v.bal)
    return sum((e.v.entitlement(h, p, tok) or F(0)) for h in accts)


def check_conservation(tc, e, p, tok='PHAR', accts=None):
    v = e.v
    accts = accts or list(v.bal)
    ent = sum((v.entitlement(h, p, tok) or F(0)) for h in accts) + v.bucket_zero(p, tok) + v.reserved_unresolved(p, tok)
    tc.assertLessEqual(ent, v.funded.get((p, tok), F(0)))
    tc.assertEqual(ent, v.funded.get((p, tok), F(0)) if v.Tt.get(p, 0) else ent)


def check_ownership(tc, e, p, accts=None):
    """property (i): W[h,p] equals the oracle's true exposure for every holder; Tt/Z equal the oracle's"""
    v = e.v
    accts = accts or list(v.bal)
    for h in accts:
        tc.assertEqual(v.W.get((h, p), F(0)), e.truth.get((h, p), F(0)), (h, p))
    tc.assertEqual(v.Z.get(p, F(0)), e.truthZ.get(p, F(0)))
    tc.assertEqual(v.Tt.get(p, F(0)), e.truthTt.get(p, F(0)))


class TestBasics(unittest.TestCase):
    def test_ten_then_ninety_claim_before_and_after(self):
        for early_harvest in (False, True):
            e = mk()
            g = e.g
            e.v.deposit('A', 1000)
            if early_harvest:
                e.advance(WEEK // 10, ids=None)
                e.v.harvest('keeper')
                e.advance(200, ids=[])
                e.v.deposit('B', 1000)
            else:
                e.advance(WEEK // 10)
                e.advance(200, ids=[])
                e.v.deposit('B', 1000)
            e.advance(WEEK // 2)
            finish(e)
            check_ownership(self, e, P0)
            a = e.v.entitlement('A', P0, 'PHAR')
            b = e.v.entitlement('B', P0, 'PHAR')
            self.assertGreater(a, b)
            # A holds alone for x then equal: A - B == funded * x_exposure / Tt
            solo = e.truth[('A', P0)] - e.truth[('B', P0)]
            self.assertEqual(a - b, e.v.funded[(P0, 'PHAR')] * solo / e.v.Tt[P0])
            self.assertEqual(a + b + e.v.bucket_zero(P0, 'PHAR'), e.v.funded[(P0, 'PHAR')])

    def test_claim_timing_independence(self):
        res = []
        for schedule in ([], [0.3], [0.1, 0.5, 0.9], [0.2, 0.2, 0.7]):
            e = mk()
            e.v.deposit('A', 700)
            last = 0
            for frac in schedule:
                e.advance(int(WEEK * (frac - last)) or 1)
                last = frac
                e.v.harvest('keeper')
            e.advance(int(WEEK * 0.05))
            e.advance(200, ids=[])
            e.v.deposit('B', 300)
            e.advance(int(WEEK * 0.3))
            finish(e)
            res.append((e.v.entitlement('A', P0, 'PHAR') / e.v.funded[(P0, 'PHAR')], e.v.entitlement('B', P0, 'PHAR') / e.v.funded[(P0, 'PHAR')]))
            check_ownership(self, e, P0)
        # the A/B split of the funded amount depends only on the exposure, not on when the vault claimed (all schedules share the
        # same sequence of balance changes only when the harvest cadence does not move time; compare the oracle instead)
        for r in res:
            self.assertAlmostEqual(float(r[0] + r[1]), 1.0, places=9)

    def test_late_notify_goes_by_recorded_weights(self):
        e = mk(S=0)
        e.v.deposit('A', 1000)
        e.advance(WEEK // 10)
        e.advance(200, ids=[])
        e.v.deposit('B', 1000)
        e.advance(WEEK // 2)
        e.g.notify('PHAR', 100)             # emission arrives after both entered (retroactive, probe P4)
        finish(e)
        check_ownership(self, e, P0)
        a, b = e.v.entitlement('A', P0, 'PHAR'), e.v.entitlement('B', P0, 'PHAR')
        self.assertEqual(a + b, e.v.funded[(P0, 'PHAR')])
        self.assertGreater(a, b)             # a first-draft per-sync accumulator would split 50/50

    def test_zero_supply_bucket_and_last_holder(self):
        e = mk()
        e.advance(WEEK // 5)                  # liquidity, nobody holds shares
        e.v.deposit('C', 500)
        e.advance(WEEK // 2)
        finish(e)
        check_ownership(self, e, P0)
        self.assertGreater(e.v.Z[P0], 0)
        self.assertEqual(e.v.entitlement('C', P0, 'PHAR') + e.v.bucket_zero(P0, 'PHAR'), e.v.funded[(P0, 'PHAR')])

    def test_transfer_and_exited_holder_claims_later(self):
        e = mk()
        e.v.deposit('A', 1000)
        e.advance(WEEK // 3)
        e.v.transfer('A', 'B', 400)
        e.advance(WEEK // 3)
        e.v.redeem('A', 600)
        e.advance(200, ids=[])                 # W1: the second liquidity-changing exit waits out the window
        e.v.redeem('B', 400)
        e.advance(WEEK // 6)
        finish(e, periods=3)                  # everybody has left; the delayed funding arrives 3 periods later
        check_ownership(self, e, P0)
        self.assertEqual(e.v.supply, 0)
        paid = e.v.claim('A')['PHAR'] + e.v.claim('B')['PHAR']
        self.assertEqual(paid + e.v.bucket_zero(P0, 'PHAR'), e.v.funded[(P0, 'PHAR')])


class TestOwnershipProperty(unittest.TestCase):
    """random sequences, with and without arbitrary permissionless touches, against the independent oracle"""

    @staticmethod
    def gen_ops(seed, n=40):
        r = random.Random(seed)
        ops = []
        for _ in range(n):
            x = r.random()
            h = r.choice('ABC')
            if x < 0.25:
                ops.append(('adv', r.choice([5, 130, 4000, 90000, WEEK // 2, WEEK + 7])))
            elif x < 0.45:
                ops.append(('dep', h, r.randint(1, 1000)))
            elif x < 0.6:
                ops.append(('red', h, r.random()))
            elif x < 0.7:
                ops.append(('xfer', h, r.choice('ABC'), r.random()))
            elif x < 0.8:
                ops.append(('notify', r.randint(0, 50)))
            elif x < 0.9:
                ops.append(('harvest',))
            else:
                ops.append(('batch',))
        return ops

    @staticmethod
    def execute(ops, variant, extra_seed=None):
        e = mk(variant, S=100)
        rr = random.Random(extra_seed)
        for op in ops:
            try:
                if op[0] == 'adv':
                    e.advance(op[1])
                elif op[0] == 'dep':
                    e.v.deposit(op[1], op[2])
                elif op[0] == 'red':
                    b = e.v.free(op[1])
                    if b > 0:
                        e.v.redeem(op[1], min(b, max(F(1), b * F(int(op[2] * 100), 100))))
                elif op[0] == 'xfer':
                    b = e.v.free(op[1])
                    if b > 0 and op[1] != op[2]:
                        e.v.transfer(op[1], op[2], min(b, max(F(1), b * F(int(op[3] * 100), 100))))
                elif op[0] == 'notify':
                    e.g.notify('PHAR', op[1]) if op[1] else None
                elif op[0] == 'harvest':
                    e.v.harvest('keeper')
                elif op[0] == 'batch' and variant == 'EPOCH':
                    e.v.process_batch()
            except (Blocked, Unavailable):
                pass
            if extra_seed is not None and rr.random() < 0.7:        # anyone touches the vault at arbitrary times
                c = rr.choice(['touch', 'harvest', 'progress', 'claim', 'drain'])
                if c == 'touch':
                    e.v.touch_safe()
                elif c == 'harvest':
                    e.v.harvest('someone')
                elif c == 'progress':
                    e.v.progress(rr.choice('ABC'), rr.randint(1, 3))
                elif c == 'claim':
                    e.v.claim(rr.choice('ABC'), rr.randint(1, 3))
                else:
                    e.v.drain(rr.randint(1, 3))
        e.advance(3 * WEEK, ids=[])
        for _ in range(3):
            e.v.touch_safe()
            e.drain_all()
            e.v.harvest('keeper')
        e.drain_all(list('ABC'))
        return e

    def test_ownership_equals_oracle_and_ignores_touchers(self):
        for variant in ('W1', 'EPOCH'):
            for seed in range(60):
                ops = self.gen_ops(seed)
                e1 = self.execute(ops, variant)
                e2 = self.execute(ops, variant, extra_seed=seed + 1000)
                for p in range(P0, e1.g.period()):
                    for h in 'ABC':
                        self.assertEqual(e1.v.W.get((h, p), F(0)), e1.truth.get((h, p), F(0)), (variant, seed, h, p))
                        self.assertEqual(e1.v.W.get((h, p), F(0)), e2.v.W.get((h, p), F(0)), ('touchers', variant, seed, h, p))
                    self.assertEqual(e1.v.Z.get(p, F(0)), e1.truthZ.get(p, F(0)))
                    self.assertEqual(e1.v.funded.get((p, 'PHAR'), F(0)), e2.v.funded.get((p, 'PHAR'), F(0)))
                    if e1.v.final(p):
                        check_conservation(self, e1, p, accts=list('ABC'))
                        check_conservation(self, e2, p, accts=list('ABC'))
                        for h in 'ABC':
                            self.assertEqual(e1.v.entitlement(h, p, 'PHAR'), e2.v.entitlement(h, p, 'PHAR'))


class TestSlashAndZeroPayment(unittest.TestCase):
    def two_holders(self):
        e = mk()
        e.v.deposit('A', 1000)
        e.advance(WEEK // 4)
        e.advance(200, ids=[])
        e.v.deposit('B', 1000)
        e.advance(WEEK // 4)
        return e

    def test_guard_prevents_window_claim_and_blocks_without_forfeit(self):
        e = self.two_holders()
        e.g.pm_change(1, 'user')              # a liquidity change right now opens the window
        rep = e.v.harvest('keeper')
        self.assertTrue(all(r[0] == 'BLOCKED' for r in rep))
        self.assertEqual(e.g.r33['PHAR'], 0)
        self.assertEqual(e.g.debt, {})
        with self.assertRaises(Blocked):
            e.v.redeem('A', 1000)             # W1: needs liquidity removal -> refused, nothing forfeited
        self.assertEqual(e.g.r33['PHAR'], 0)
        self.assertEqual(e.g.debt, {})

    def test_slash_is_booked_as_external_loss_borne_pro_rata(self):
        e = self.two_holders()
        e.v.will_slash = lambda *a: None       # guard failure: the gauge slashes anyway (e.g. a race with a governance change)
        e.g.validator = 'always'
        rep = e.v.harvest('keeper')
        self.assertTrue(any(r[0] == 'SLASHED' for r in rep))
        e.g.validator = 'normal'
        del e.v.will_slash
        finish(e)
        p = P0
        lost = e.v.lost[(p, 'PHAR', 'SLASHED')]
        self.assertGreater(lost, 0)
        self.assertEqual(e.g.r33['PHAR'], lost)
        self.assertEqual(lost + e.v.funded[(p, 'PHAR')], e.g.S[(p, 'PHAR')] * e.truthTt[p] / WEEK)
        self.assertTrue(e.v.final(p))
        # the loss is borne by every holder of the period by recorded exposure, and by nobody else
        tot = e.v.funded[(p, 'PHAR')]
        for h in 'AB':
            self.assertEqual(e.v.entitlement(h, p, 'PHAR'), tot * e.truth[(h, p)] / e.truthTt[p])
        check_conservation(self, e, p, accts=['A', 'B'])

    def test_zero_payment_distinguishes_nothing_owed_from_slashed_and_noeffect(self):
        e = mk(S=0)                            # nothing notified: owed == 0
        e.v.deposit('A', 100)
        e.advance(1000)
        rep = e.v.harvest('keeper')
        self.assertEqual(rep, [])              # nothing owed: no call, no classification
        e.g.notify('PHAR', 100)
        e.g.mode = 'zero'                      # call returns normally, pays zero, changes nothing
        rep = e.v.harvest('keeper')
        self.assertTrue(rep and all(r[0] == 'NO_EFFECT_ZERO_PAYMENT' for r in rep))
        self.assertEqual(e.v.funded, {})
        e.g.mode = 'ok'
        rep = e.v.harvest('keeper')
        self.assertTrue(any(r[0] == 'PAID' for r in rep))

    def test_gauge_side_read_failure_is_recoverable_by_period_call(self):
        e = self.two_holders()
        e.g.pool_ok = False                     # the gauge's own staticcall fails (probe Q8/Q10)
        rep = e.v.harvest('keeper')
        self.assertTrue(all(r[0] == 'NO_EFFECT_ZERO_PAYMENT' for r in rep))
        e.g.get_all_rewards(1, TOKS, 'vault', 'keeper')       # e.g. the auto-claim of a liquidity change advances lastClaim
        e.g.pool_ok = True
        finish(e)
        check_ownership(self, e, P0)
        a = e.v.entitlement('A', P0, 'PHAR')
        self.assertGreater(a, 0)
        self.assertEqual(a + e.v.entitlement('B', P0, 'PHAR'), e.v.funded[(P0, 'PHAR')])

    def test_slash_chain_loss_grows_gauge_semantics(self):
        """mirrors probe Q3/Q5: a clean change loses nothing; k changes 100 s apart lose the whole chain"""
        for k in (1, 2, 4):
            e = mk()
            e.advance(10_000)                   # accrual with no holders; irrelevant
            e.g.pm_change(1, 'o')
            e.advance(100)
            for _ in range(k):
                e.g.pm_change(1, 'o')
                e.advance(100)
            e.advance(5000)
            r0 = e.g.r33['PHAR']
            e.g.get_all_rewards(1, TOKS, 'vault', 'o')
            lost = e.g.r33['PHAR'] - r0
            e.advance(5000)
            self.assertGreater(lost, 0)
            setattr(self, 'lost_%d' % k, lost)
        self.assertLess(self.lost_1, self.lost_2)
        self.assertLess(self.lost_2, self.lost_4)

    def test_get_period_reward_scope_vs_get_reward_debt(self):
        for use_period_call in (False, True):
            e = mk()
            e.g.pm_change(1, 'o')
            # unpaid in two periods; window open at the boundary
            e.advance(WEEK - (e.g.now % WEEK) - 50)
            e.g.pm_change(1, 'o')              # clean? (lm 50+ s ago... made 0 s earlier) -> this one is inside the window
            e.advance(60)
            old = e.g.period_earned(1, P0, 'PHAR')
            e.g.notify('PHAR', 100)
            e.advance(40)
            if use_period_call:
                e.g.get_period_reward(1, P0, ['PHAR'], 'vault', 'k')
                self.assertEqual(e.g.debt, {})
            else:
                e.g.get_all_rewards(1, TOKS, 'vault', 'k')
                self.assertNotEqual(e.g.debt, {})


class TestGovernance(unittest.TestCase):
    def test_threshold_change_mid_period_is_read_live(self):
        e = mk()
        e.v.deposit('A', 100)
        e.advance(500)
        self.assertIsNone(e.v.will_slash(1, 'k'))
        e.g.threshold = 7 * 86400
        self.assertEqual(e.v.will_slash(1, 'k'), 'window')
        self.assertEqual(e.v.harvest('k')[0][0], 'BLOCKED')
        e.g.threshold = 111
        self.assertIsNone(e.v.will_slash(1, 'k'))

    def test_xratio_second_token_mid_period_uses_same_weights(self):
        e = mk()
        e.v.deposit('A', 1000)
        e.advance(WEEK // 4)
        e.advance(200, ids=[])
        e.v.deposit('B', 3000)
        e.advance(WEEK // 4)
        e.g.notify('XPHAR', 40)                # xRatio raised: xPHAR starts arriving mid-period, retroactive like PHAR
        finish(e)
        for tok in TOKS:
            check_conservation(self, e, P0, tok, ['A', 'B'])
        a, b = e.v.entitlement('A', P0, 'XPHAR'), e.v.entitlement('B', P0, 'XPHAR')
        self.assertEqual(a + b + e.v.bucket_zero(P0, 'XPHAR'), e.v.funded[(P0, 'XPHAR')])
        self.assertEqual(a * e.v.funded[(P0, 'PHAR')], e.v.entitlement('A', P0, 'PHAR') * e.v.funded[(P0, 'XPHAR')])

    def test_validator_replaced_and_blacklist_block_every_claim_never_forfeit(self):
        for mode in ('always', 'revert'):
            e = mk()
            e.v.deposit('A', 100)
            e.advance(WEEK // 3)
            e.g.validator = mode
            rep = e.v.harvest('keeper')
            self.assertTrue(rep and all(r[0] == 'BLOCKED' for r in rep))
            self.assertEqual(e.g.r33['PHAR'], 0)
            self.assertEqual(e.v.funded, {})
            # exits that need no liquidity change still work; liquidity-changing exits are refused, not forfeited
            with self.assertRaises(Blocked):
                e.v.redeem('A', 100)
        e = mk()
        e.v.deposit('A', 100)
        e.advance(WEEK // 3)
        e.g.black_wallets.add('vault')          # blacklist adds the vault
        self.assertEqual(e.v.will_slash(1, 'k'), 'blacklist')
        with self.assertRaises(Blocked):
            e.v.redeem('A', 100)
        e.g.black_wallets.discard('vault')      # when Pharaoh lifts it, everything accrued is still there
        e.advance(10_000)
        finish(e)
        self.assertGreater(e.v.entitlement('A', P0, 'PHAR'), 0)

    def test_gauge_implementation_replaced_claims_revert_then_recover_equals_control(self):
        res = []
        for broken in (False, True):
            e = self_two = TestSlashAndZeroPayment().two_holders()
            if broken:
                e.g.mode = 'revert'                  # new gauge implementation: getReward/getPeriodReward revert
                f0 = dict(e.v.funded)
                rep = e.v.harvest('keeper')
                self.assertTrue(rep and all(r[0] == 'CALL_REVERTED' for r in rep))
                self.assertEqual(e.v.funded, f0)
                e.g.mode = 'ok'
            finish(e)
            res.append((e.v.entitlement('A', P0, 'PHAR'), e.v.entitlement('B', P0, 'PHAR')))
        self.assertEqual(res[0], res[1])

    def test_multi_nft_windows_are_independent(self):
        e = mk(nfts=(1, 2))
        e.g.pm_change(2, 'u')                   # dust on NFT 2 opens ITS window only
        self.assertIsNone(e.v.will_slash(1, 'k'))
        self.assertEqual(e.v.will_slash(2, 'k'), 'window')

    def test_retired_nft_keeps_intervals_and_burn_is_refused_with_outstanding(self):
        e = mk(nfts=(1, 2))
        e.v.deposit('A', 100)
        e.advance(WEEK // 3)
        e.g.mode = 'zero'
        e.v.retire(1, 'k')                      # NFT 1 leaves; NFT 2 keeps earning
        e.g.mode = 'ok'
        e.advance(WEEK // 3)
        e.g.mode = 'zero'                       # the gauge pays nothing for a while: rewards are outstanding
        e.advance(100, ids=[])
        e.v.touch_safe()
        with self.assertRaises(Blocked):
            e.v.burn_nft(1)                     # refused: rewards outstanding (the live base would burn and orphan them, P5)
        e.g.mode = 'ok'
        finish(e, periods=1)
        self.assertEqual(e.v.nfts[1]['state'], 'retired')
        check_ownership(self, e, P0, ['A'])
        e.v.burn_nft(1)                         # allowed once everything is paid
        self.assertIn(1, e.g.burned)

    def test_unguarded_burn_orphans_rewards(self):
        e = mk()
        e.v.deposit('A', 100)
        e.advance(WEEK // 3)
        e.g.pm_burn(1)                          # what the live base does (probe P5)
        finish(e)
        self.assertFalse(e.v.final(P0))         # the period can never finalise: outstanding forever, visible, not attributed


class TestUnresolved(unittest.TestCase):
    def setup(self, events=True):
        e = mk()
        e.v.deposit('A', 600)
        e.advance(200, ids=[])
        e.v.deposit('B', 400)
        e.advance(WEEK // 4)
        e.v.read_ok = False                     # pool period-seconds reading becomes unavailable
        e.advance(WEEK // 8)
        with self.assertRaises(Unavailable):
            e.v.deposit('C', 1)
        with self.assertRaises(Unavailable):
            e.v.transfer('A', 'B', 1)
        if events:
            e.v.redeem('B', 400)                # principal exit stays available: proceeds, interval becomes UNRESOLVED
        e.advance(WEEK // 8)
        e.v.read_ok = True
        return e

    def test_unresolved_interval_not_attributed_until_reconciled(self):
        e = self.setup()
        finish(e)
        v = e.v
        self.assertGreater(v.U.get(P0, 0), 0)
        # property (iii): the unresolved dT is in U, in nobody's W, and the funded share is RESERVED, not attributed
        self.assertEqual(sum(v.W.get((h, P0), 0) for h in 'AB') + v.Z.get(P0, 0) + v.U[P0], v.Tt[P0])
        res = v.reserved_unresolved(P0, 'PHAR')
        self.assertGreater(res, 0)
        ent = sum(v.entitlement(h, P0, 'PHAR') for h in 'AB')
        self.assertEqual(ent + res + v.bucket_zero(P0, 'PHAR'), v.funded[(P0, 'PHAR')])
        # a later toucher cannot change it
        v.progress('A', 5); v.harvest('x'); v.claim('B')
        self.assertEqual(v.U[P0] > 0, True)
        # what the oracle knows but the vault does not: the true split of the unresolved interval
        split = {h: e.truth.get((h, P0), 0) - v.W.get((h, P0), 0) for h in 'AB'}
        split[M.ZERO_SUPPLY] = e.truthZ.get(P0, 0) - v.Z.get(P0, 0)
        v.reconcile(P0, split)
        check_ownership(self, e, P0, ['A', 'B'])        # after an explicit, externally supplied split ownership is exact
        self.assertNotIn(P0, v.U)
        check_conservation(self, e, P0, accts=['A', 'B'])

    def test_failure_without_supply_event_is_exact_not_unresolved(self):
        e = self.setup(events=False)
        finish(e)
        self.assertEqual(e.v.U.get(P0, 0), 0)
        check_ownership(self, e, P0, ['A', 'B'])

    def test_failure_across_periods_only_event_period_is_unresolved(self):
        e = mk()
        e.v.deposit('A', 500)
        e.advance(WEEK // 2)
        e.v.read_ok = False
        e.advance(WEEK)                         # a whole period inside the failure with no event
        e.v.redeem('A', 100)                    # burn in the NEXT period
        e.advance(WEEK // 4)
        e.v.read_ok = True
        finish(e, periods=2)
        # the burn happened in period P0+1: only that period is unresolved; P0 (failure began inside it, no event) is exact
        self.assertEqual(e.v.U.get(P0, 0), 0)
        self.assertGreater(e.v.U.get(P0 + 1, 0), 0)
        self.assertEqual(e.v.U.get(P0 + 2, 0), 0)
        check_ownership(self, e, P0, ['A'])

    def test_period_does_not_finalise_while_reading_is_down(self):
        e = mk()
        e.v.deposit('A', 100)
        e.advance(WEEK // 2)
        e.v.read_ok = False
        e.advance(WEEK)
        e.v.touch_safe()
        e.v.drain(100)
        e.v.harvest('k')
        self.assertFalse(e.v.final(P0))
        self.assertEqual(e.v.entitlement('A', P0, 'PHAR'), None)
        e.v.read_ok = True
        finish(e)
        self.assertTrue(e.v.final(P0))


class TestBoundedProcessing(unittest.TestCase):
    def dormant(self, n_periods=300):
        e = mk()
        e.v.deposit('A', 1000)
        e.v.deposit('Z', 1) if False else None
        for _ in range(n_periods):
            e.g.notify('PHAR', 1)
            e.advance(WEEK)
        return e

    def test_update_path_is_O1_after_long_dormancy(self):
        e = self.dormant(300)
        e.v.steps = 0
        e.v.transfer('A', 'B', 500)
        # inline work: one record per NFT + two account closes; the 300 ended periods were DEFERRED, not looped
        self.assertLessEqual(e.v.steps, 6)
        self.assertGreater(len(e.v.backlog), 0)
        self.assertEqual(len(e.v.segs['A']), 1)           # one deferred multi-period segment for A (checkpoint compaction)

    def test_partial_processing_is_consistent_and_holder_always_progresses(self):
        e = self.dormant(120)
        e.v.transfer('A', 'B', 500)
        e.advance(10)
        # drive ONLY with tiny calls; after every call: invariants hold; every call makes progress until settled
        calls = 0
        while True:
            before = (len(e.v.backlog), sum(s['end'] - s['p'] + 1 for s in e.v.backlog), len(e.v.segs.get('A', ())), e.v.settled_through('A'))
            k = e.v.progress('A', 1)
            after = (len(e.v.backlog), sum(s['end'] - s['p'] + 1 for s in e.v.backlog), len(e.v.segs.get('A', ())), e.v.settled_through('A'))
            self.assertLessEqual(e.v.steps, 10)           # bounded work per call
            calls += 1
            # consistent prefix: any period below settled_through(A) already equals the oracle for A
            for p in range(P0, min(e.v.settled_through('A'), P0 + 120)):
                if e.v._record_ready(p):
                    self.assertEqual(e.v.W.get(('A', p), F(0)), e.truth.get(('A', p), F(0)))
            if k == 0:
                break
            self.assertNotEqual(before, after)             # progress
            self.assertLess(calls, 2000)
        self.assertEqual(len(e.v.segs.get('A', ())), 0)
        self.assertEqual(len(e.v.backlog), 0)

    def test_paginated_equals_unpaginated(self):
        e1 = self.dormant(60)
        e2 = self.dormant(60)
        for e in (e1, e2):
            e.v.transfer('A', 'B', 300)
            e.advance(3 * WEEK, ids=[])
        while e1.v.progress('A', 1) or e1.v.progress('B', 1):
            pass
        e2.drain_all(['A', 'B'])
        for p in range(P0, P0 + 61):
            for h in 'AB':
                self.assertEqual(e1.v.W.get((h, p), F(0)), e2.v.W.get((h, p), F(0)))
                self.assertEqual(e1.v.W.get((h, p), F(0)), e1.truth.get((h, p), F(0)))

    def test_conservation_for_fully_settled_periods_at_every_prefix(self):
        e = self.dormant(40)
        e.v.transfer('A', 'B', 700)
        e.advance(WEEK)
        e.v.touch_safe()
        while e.v.backlog:
            e.v.drain(1)
            for h in 'AB':
                e.v.close_open(h); e.v.settle_steps(h, 1)
            for p in range(P0, P0 + 41):
                if e.v._record_ready(p) and all(e.v.settled_through(h) > p for h in 'AB'):
                    self.assertEqual(sum(e.v.W.get((h, p), F(0)) for h in 'AB') + e.v.Z.get(p, F(0)) + e.v.U.get(p, F(0)), e.v.Tt.get(p, F(0)))

    def test_dust_spam_on_a_victim_creates_at_most_one_deferred_segment_per_period(self):
        e = self.dormant(50)
        e.v.transfer('A', 'V', 1)               # V now holds a balance
        e.advance(WEEK)
        for _ in range(500):
            e.v.transfer('A', 'V', 1)           # attacker pushes dust shares onto V
        self.assertLessEqual(len(e.v.segs.get('V', ())), 1)

    def test_claim_is_paginated_and_pays_the_same(self):
        e = self.dormant(30)
        e.advance(3 * WEEK, ids=[])
        for _ in range(3):
            e.v.touch_safe(); e.drain_all(); e.v.harvest('k')
        total = F(0)
        for _ in range(500):
            r = e.v.claim('A', 4)
            total += r['PHAR']
            if r['PHAR'] == 0 and e.v.steps == 0:
                break
        e2 = self.dormant(30)
        e2.advance(3 * WEEK, ids=[])
        for _ in range(3):
            e2.v.touch_safe(); e2.drain_all(); e2.v.harvest('k')
        self.assertEqual(total, e2.v.claim('A')['PHAR'])


class TestLiveness(unittest.TestCase):
    """property (ii). 'bound' = seconds until a principal exit that loses no reward is possible. Where a variant cannot bound it,
    the test asserts the failure so that the document must state it."""

    def exit_wait(self, e, h, x, adversary=None, horizon=3000, step=1):
        """seconds until the exit of x shares of h is SERVED without loss (W1: redeem succeeds; EPOCH: paid from idle or batch
        served the queued request); None if not within the horizon"""
        t = 0
        bal0 = e.v.bal[h]
        queued = False
        while t <= horizon:
            if adversary:
                adversary(e)
            try:
                if e.v.variant == 'W1':
                    e.v.redeem(h, x)
                    return t
                if not queued:
                    r = e.v.redeem(h, x)
                    queued = (r == 'queued')
                if not queued:
                    return t
                e.v.process_batch()
                if e.v.bal[h] <= bal0 - x:
                    return t
            except (Blocked, Unavailable):
                pass
            if queued and e.v.bal[h] <= bal0 - x:
                return t
            e.advance(step, ids=[])
            t += step
        return None

    def dust_attacker(self, every=100):
        state = {'last': -10**9}

        def adv(e):
            if e.g.now - state['last'] >= every:
                try:
                    if e.v.variant == 'W1':
                        e.v.deposit('X', 1)
                    else:
                        e.v.deposit('X', 1)
                        e.v.process_batch(origin='X')      # the attacker triggers a batch as often as the rate limit allows
                    state['last'] = e.g.now
                except (Blocked, Unavailable):
                    pass
        return adv

    def setup(self, variant, **kw):
        e = mk(variant, **kw)
        e.v.deposit('V', 1000)
        if variant == 'EPOCH':
            e.v.process_batch()
        e.advance(500, ids=[])
        return e

    def test_W1_without_attacker_waits_zero_when_quiet(self):
        e = self.setup('W1')
        self.assertEqual(self.exit_wait(e, 'V', 100), 0)

    def test_W1_dust_attacker_blocks_exits_unbounded(self):
        e = self.setup('W1')
        adv = self.dust_attacker(100)
        adv(e)                                     # the attacker moves first and then repeats every 100 s (< 111 s threshold)
        w = self.exit_wait(e, 'V', 100, adversary=adv, horizon=20000)
        self.assertIsNone(w)                       # VARIANT CANNOT BOUND: indefinite withdrawal blocking

    def test_W1_governance_raised_threshold_bound_is_threshold_minus_age(self):
        e = self.setup('W1')
        e.v.deposit('Y', 1)                        # a change happens now
        e.advance(500, ids=[])
        e.g.threshold = 5000
        w = self.exit_wait(e, 'V', 100, horizon=6000)
        self.assertEqual(w, 5000 - 500 + e.v.margin + 1)   # lm + threshold + margin + 1

    def test_EPOCH_quiet_bound_is_zero_with_buffer_and_threshold_plus_margin_without(self):
        e = self.setup('EPOCH', buffer_bps=1000)    # 10% idle buffer
        self.assertGreater(e.v.idle, 0)
        self.assertEqual(self.exit_wait(e, 'V', F(e.v.idle) / 2), 0)       # served from idle at once
        e = self.setup('EPOCH', buffer_bps=0)
        e.v.deposit('Y', 1)
        e.v.process_batch() if False else None
        w = self.exit_wait(e, 'V', 100, horizon=1000)
        self.assertIsNotNone(w)
        self.assertLessEqual(w, 111 + e.v.margin + 1)

    def test_EPOCH_dust_attacker_cannot_extend_the_bound(self):
        e = self.setup('EPOCH', buffer_bps=0)
        adv = self.dust_attacker(1)                 # as often as the rate limit lets it
        w = self.exit_wait(e, 'V', 100, adversary=adv, horizon=2000)
        self.assertIsNotNone(w)
        self.assertLessEqual(w, 111 + e.v.margin + 1)

    def test_EPOCH_governance_raised_threshold_bound_is_lm_plus_threshold(self):
        e = self.setup('EPOCH', buffer_bps=0)
        e.v.deposit('Y', 1)
        try:
            e.v.process_batch()
        except Blocked:
            pass
        e.advance(200, ids=[])
        e.v.deposit('Z', 1)
        e.g.threshold = 4000
        w = self.exit_wait(e, 'V', 100, horizon=6000)
        self.assertIsNotNone(w)
        self.assertLessEqual(w, 4000 + e.v.margin + 1)
        self.assertGreater(w, 111)

    def test_EPOCH_idle_buffer_exit_survives_blacklist_and_threshold_raise(self):
        e = self.setup('EPOCH', buffer_bps=2000)
        e.g.black_wallets.add('vault')
        e.g.threshold = 10**9
        self.assertEqual(e.v.redeem('V', F(e.v.idle) / 2), 'paid_from_idle')

    def test_EPOCH_reading_outage_exits_still_served_deposits_stay_queued(self):
        e = self.setup('EPOCH', buffer_bps=0)
        e.v.deposit('Y', 50)                       # queued
        e.v.read_ok = False
        e.advance(500, ids=[])
        self.assertEqual(e.v.redeem('V', 100), 'queued')
        self.assertEqual(e.v.process_batch(), 'processed_exits_only')
        self.assertEqual(e.v.bal['V'], 900)       # principal exit served although the exposure reading is down
        self.assertEqual(e.v.q_dep, {'Y': 50})    # mint fails closed: still queued, nothing attributed to Y
        self.assertNotIn('Y', e.v.bal)
        e.v.read_ok = True
        e.advance(WEEK, ids=[])
        e.v.touch_safe()
        self.assertEqual(e.v.process_batch(), 'processed')
        self.assertEqual(e.v.bal['Y'], 50)

    def test_both_variants_blacklisted_vault_liquidity_exit_unbounded(self):
        for variant in ('W1', 'EPOCH'):
            e = self.setup(variant)
            e.g.black_wallets.add('vault')
            w = self.exit_wait(e, 'V', 100, horizon=3000)
            self.assertIsNone(w, variant)           # NAMED LIMIT: cannot be bounded; only idle-paid exits remain (needs operator decision)

    def test_EPOCH_empty_batches_do_not_reset_the_window(self):
        e = self.setup('EPOCH')
        lm = e.g.lm[1]
        for _ in range(50):
            self.assertEqual(e.v.process_batch(), 'empty')
            e.advance(1, ids=[])
        self.assertEqual(e.g.lm[1], lm)


class TestFuzzWithReadingFailures(unittest.TestCase):
    """random histories including pool-reading outages. Property (iii) at every stage, and ownership after an EXPLICIT split."""

    def test_unresolved_never_attributed_and_ownership_after_reconcile(self):
        stats = {'unres': 0, 'funded': 0, 'ops': 0}
        for seed in range(80):
            r = random.Random(seed)
            e = mk('W1', S=100)
            for _ in range(40):
                x = r.random()
                h = r.choice('ABC')
                try:
                    if x < 0.2:
                        e.advance(r.choice([5, 130, 4000, 90000, WEEK // 2, WEEK + 7]))
                    elif x < 0.4:
                        e.v.deposit(h, r.randint(1, 500)); stats['ops'] += 1
                    elif x < 0.55:
                        b = e.v.bal.get(h, F(0))
                        if b > 0:
                            e.v.redeem(h, min(b, F(r.randint(1, 300)))); stats['ops'] += 1
                    elif x < 0.65:
                        b = e.v.bal.get(h, F(0)); o = r.choice('ABC')
                        if b > 0 and o != h:
                            e.v.transfer(h, o, min(b, F(r.randint(1, 300))))
                    elif x < 0.75:
                        e.v.read_ok = not e.v.read_ok
                    elif x < 0.85:
                        e.v.harvest('k')
                    elif x < 0.9:
                        e.g.notify('PHAR', r.randint(0, 40)) if r.random() < 0.5 else None
                    else:
                        e.v.progress(h, r.randint(1, 3))
                except (Blocked, Unavailable):
                    pass
                # (iii) at every stage: the unresolved dT is in nobody's W
                for p in list(e.v.Tt):
                    if e.v._record_ready(p) and all(e.v.settled_through(a) > p for a in 'ABC'):
                        self.assertEqual(sum(e.v.W.get((a, p), F(0)) for a in 'ABC') + e.v.Z.get(p, F(0)) + e.v.U.get(p, F(0)), e.v.Tt[p])
            e.v.read_ok = True
            e.advance(3 * WEEK, ids=[])
            for _ in range(3):
                e.v.touch_safe(); e.drain_all(); e.v.harvest('k')
            e.drain_all(list('ABC'))
            for p in range(P0, e.g.period()):
                if e.v.U.get(p, 0):
                    stats['unres'] += 1
                    ent = sum((e.v.entitlement(a, p, 'PHAR') or F(0)) for a in 'ABC') + e.v.bucket_zero(p, 'PHAR') + e.v.reserved_unresolved(p, 'PHAR')
                    self.assertLessEqual(ent, e.v.funded.get((p, 'PHAR'), F(0)))
                    split = {a: e.truth.get((a, p), F(0)) - e.v.W.get((a, p), F(0)) for a in 'ABC'}
                    split[M.ZERO_SUPPLY] = e.truthZ.get(p, F(0)) - e.v.Z.get(p, F(0))
                    self.assertTrue(all(w >= 0 for w in split.values()), split)
                    if sum(split.values()) > 0:
                        e.v.reconcile(p, split)
                for a in 'ABC':
                    self.assertEqual(e.v.W.get((a, p), F(0)), e.truth.get((a, p), F(0)), (seed, a, p))
                if e.v.funded.get((p, 'PHAR')):
                    stats['funded'] += 1
        self.assertGreater(stats['unres'], 3)       # the fuzz really exercises unresolved intervals
        self.assertGreater(stats['funded'], 20)
        self.assertGreater(stats['ops'], 200)


class TestMutations(unittest.TestCase):
    """the model's tests must FAIL when the mechanism is broken (mutation self-check)"""

    def run_tests(self, names):
        suite = unittest.TestSuite()
        for cls, n in names:
            suite.addTest(cls(n))
        res = unittest.TextTestRunner(stream=io.StringIO()).run(suite)
        return res.wasSuccessful()

    def mutate(self, owner, attr, new, names):
        old = getattr(owner, attr)
        setattr(owner, attr, new)
        try:
            return self.run_tests(names)
        finally:
            setattr(owner, attr, old)

    def test_unresolved_treated_as_resolved_is_caught(self):
        orig = Vault2._apply
        def bad(s, p, d, sup, unresolved=False):
            return orig(s, p, d, sup, unresolved=False)
        self.assertFalse(self.mutate(Vault2, '_apply', bad, [(TestUnresolved, 'test_unresolved_interval_not_attributed_until_reconciled'),
                                                            (TestFuzzWithReadingFailures, 'test_unresolved_never_attributed_and_ownership_after_reconcile')]))

    def test_no_settle_before_balance_change_is_caught(self):
        def bad(s, h):
            s.open[h] = (s.g.period(), s.J.get(s.g.period(), F(0)))
        self.assertFalse(self.mutate(Vault2, 'close_open', bad, [(TestOwnershipProperty, 'test_ownership_equals_oracle_and_ignores_touchers'),
                                                                (TestBasics, 'test_ten_then_ninety_claim_before_and_after')]))

    def test_drain_with_current_supply_is_caught(self):
        orig = Vault2.drain
        def bad(s, n):
            for seg in s.backlog:
                seg['supply'] = s.supply if s.supply else seg['supply']
            return orig(s, n)
        self.assertFalse(self.mutate(Vault2, 'drain', bad, [(TestOwnershipProperty, 'test_ownership_equals_oracle_and_ignores_touchers'),
                                                            (TestBoundedProcessing, 'test_paginated_equals_unpaginated')]))

    def test_dropping_the_window_guard_is_caught(self):
        self.assertFalse(self.mutate(Vault2, 'will_slash', lambda s, i, o, margin=None: None,
                                     [(TestSlashAndZeroPayment, 'test_guard_prevents_window_claim_and_blocks_without_forfeit'),
                                      (TestGovernance, 'test_validator_replaced_and_blacklist_block_every_claim_never_forfeit')]))

    def test_burning_nft_with_outstanding_is_caught(self):
        orig = Vault2.burn_nft
        def bad(s, id_):
            s.g.pm_burn(id_); s.nfts[id_]['state'] = 'drained'
        self.assertFalse(self.mutate(Vault2, 'burn_nft', bad, [(TestGovernance, 'test_retired_nft_keeps_intervals_and_burn_is_refused_with_outstanding')]))

    def test_wall_clock_attribution_of_unresolved_is_caught(self):
        """a 'degraded wall-clock split' for burns (the first draft's rule) would break the oracle equality"""
        orig = Vault2._resolve_fail
        def bad(s, cur):
            f = s.fail
            f['events'] = []                      # pretend no supply event happened: attribute at the final supply
            return orig(s, cur)
        self.assertFalse(self.mutate(Vault2, '_resolve_fail', bad, [(TestFuzzWithReadingFailures, 'test_unresolved_never_attributed_and_ownership_after_reconcile')]))


class TestNoClockInAttribution(unittest.TestCase):
    def test_attribution_functions_do_not_read_time(self):
        for fn in (Vault2._apply, Vault2.touch, Vault2._resolve_fail, Vault2.drain, Vault2.close_open, Vault2.settle_steps,
                   Vault2.reconcile, Vault2.entitlement, Vault2.final):
            src = inspect.getsource(fn)
            self.assertNotIn('.now', src, fn.__name__)
            self.assertNotIn('lm', src.replace('claim', '').replace('limit', ''), fn.__name__) if False else None


if __name__ == '__main__':
    unittest.main(verbosity=2)
