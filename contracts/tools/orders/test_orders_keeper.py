import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import orders_keeper as ok


class FakeChain:
    """Scripted registry: orders map id -> (executable, price, reason); `sim` maps id -> error signature."""

    def __init__(self, orders, sim=None, gas_price=20_000_000):
        self.orders, self.sim, self.gas_price = orders, sim or {}, gas_price
        self.sent, self.reads = [], []

    def __call__(self, args, capture_output=True, text=True):
        real = subprocess.run
        if args[:2] == ['cast', 'sig']:
            return real(args, capture_output=True, text=True)
        out = lambda s, rc=0, err='': subprocess.CompletedProcess(args, rc, s, err)
        if args[1] == 'gas-price':
            return out(str(self.gas_price) + '\n')
        if args[1] == 'call' and args[3].startswith('nextOrderId'):
            return out('%d\n' % (max(self.orders, default=0) + 1))
        if args[1] == 'call' and args[3].startswith('canExecute'):
            oid = int(args[4])
            self.reads.append(oid)
            ex, price, reason = self.orders[oid]
            return out('%s\n%d\n%d\n' % ('true' if ex else 'false', price, reason))
        if args[1] == 'call' and args[3].startswith('executeOrder'):
            oid = int(args[4])
            if oid in self.sim:
                sel = real(['cast', 'sig', self.sim[oid]], capture_output=True, text=True).stdout.strip()
                return out('', 1, 'execution reverted, data: "' + sel + '"')
            return out('true\n')
        if args[1] == 'send':
            oid = int(args[4])
            self.sent.append(oid)
            self.orders[oid] = (False, 0, 1)
            return out(json.dumps({'status': '0x1', 'transactionHash': '0x' + 'ab' * 32, 'gasUsed': '0x10'}))
        return out('')


def keeper(chain, state=None):
    d = tempfile.mkdtemp()
    j = Path(d) / 'journal.json'
    j.write_text(json.dumps({'registry': '0x' + '11' * 20}))
    s = Path(d) / 'state.json'
    if state is not None:
        s.write_text(state)
    return ok.Keeper(j, '0x' + '33' * 20, ['--unlocked'], s, rpc='http://x', runner=chain)


class Tests(unittest.TestCase):
    def test_executes_only_executable_orders_and_only_with_execute(self):
        chain = FakeChain({1: (True, 100, 0), 2: (False, 100, 6), 3: (False, 0, 5)})
        lines, rc = keeper(chain).step(False)
        self.assertEqual(chain.sent, [])
        self.assertEqual([l['action'] for l in lines], ['due (dry run)', 'wait', 'wait'])
        lines, rc = keeper(chain).step(True)
        self.assertEqual(chain.sent, [1])
        self.assertEqual(rc, 0)

    def test_sweeps_expired_inactive_and_transferred(self):
        chain = FakeChain({1: (False, 0, 2), 2: (False, 0, 3), 3: (False, 0, 4), 4: (False, 0, 7)})
        keeper(chain).step(True)
        self.assertEqual(chain.sent, [1, 2, 3], 'paused (7) waits; the rest are swept')

    def test_sweep_can_be_turned_off(self):
        chain = FakeChain({1: (False, 0, 2)})
        old = ok.SWEEP
        ok.SWEEP = False
        try:
            keeper(chain).step(True)
        finally:
            ok.SWEEP = old
        self.assertEqual(chain.sent, [])

    def test_simulation_refusal_is_a_wait_or_attention(self):
        chain = FakeChain({1: (True, 100, 0), 2: (True, 100, 0), 3: (True, 100, 0)},
                          sim={1: 'InvalidClose(uint8)', 2: 'Panic(uint256)', 3: 'V4TooLittleReceived(uint256,uint256)'})
        lines, rc = keeper(chain).step(True)
        self.assertEqual(chain.sent, [])
        self.assertEqual(lines[0]['action'], 'wait')
        self.assertEqual(lines[1]['action'], 'ATTENTION')
        self.assertEqual(lines[2]['action'], 'wait', 'pool beyond the slippage floor: wait')
        self.assertEqual(rc, 2)

    def test_gas_cap_blocks_sends(self):
        chain = FakeChain({1: (True, 100, 0)}, gas_price=10**12)
        lines, _ = keeper(chain).step(True)
        self.assertEqual(chain.sent, [])
        self.assertEqual(lines[0]['action'], 'wait (gas price above cap)')

    def test_send_budget_per_step(self):
        chain = FakeChain({i: (True, 100, 0) for i in range(1, 15)})
        keeper(chain).step(True)
        self.assertEqual(len(chain.sent), ok.MAX_SENDS_PER_STEP)

    def test_final_orders_are_not_reread_and_the_cursor_advances(self):
        chain = FakeChain({1: (False, 0, 1), 2: (False, 0, 1), 3: (False, 100, 6), 4: (False, 0, 1)})
        k = keeper(chain)
        k.step(True)
        self.assertEqual(k.state['firstOpen'], 3)
        self.assertEqual(k.state['final'], [4])
        chain.reads.clear()
        k.step(True)
        self.assertEqual(chain.reads, [3], 'only the still-open order is read again')

    def test_executed_order_becomes_final(self):
        chain = FakeChain({1: (True, 100, 0), 2: (False, 100, 6)})
        k = keeper(chain)
        k.step(True)
        chain.reads.clear()
        k.step(True)
        self.assertEqual(chain.reads, [2])

    def test_state_from_another_registry_is_discarded(self):
        k = keeper(FakeChain({}), state=json.dumps({'registry': '0x' + '99' * 20, 'firstOpen': 50, 'final': [51]}))
        self.assertEqual(k.state['firstOpen'], 1)
        self.assertEqual(k.state['final'], [])

    def test_empty_state_file_is_no_state(self):
        self.assertEqual(keeper(FakeChain({}), state='').state['firstOpen'], 1)


if __name__ == '__main__':
    unittest.main()


class RangeChain(FakeChain):
    """Adds a range custodian: bands maps positionId -> (active, finalize_error_or_None, status)."""

    def __init__(self, bands, **kw):
        super().__init__({}, **kw)
        self.bands = bands
        self.finalized = []

    def __call__(self, args, capture_output=True, text=True):
        real = subprocess.run
        out = lambda s, rc=0, err='': subprocess.CompletedProcess(args, rc, s, err)
        if args[:2] == ['cast', 'call'] and args[3].startswith('nextPositionId'):
            return out('%d\n' % (max(self.bands, default=0) + 1))
        if args[:2] == ['cast', 'call'] and args[3].startswith('isActive'):
            return out('true\n' if self.bands[int(args[4])][0] else 'false\n')
        if args[:2] == ['cast', 'call'] and args[3].startswith('getOrder'):
            st = self.bands[int(args[4])][2]
            return out('(0x%s, 0x%s, %d, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)\n' % ('aa' * 20, 'bb' * 20, st))
        if args[:2] == ['cast', 'call'] and args[3].startswith('finalize'):
            err = self.bands[int(args[4])][1]
            if err:
                sel = real(['cast', 'sig', err], capture_output=True, text=True).stdout.strip()
                return out('', 1, 'execution reverted, data: "' + sel + '"')
            return out('0x\n')
        if args[:2] == ['cast', 'send'] and args[3].startswith('finalize'):
            pid = int(args[4])
            self.finalized.append(pid)
            self.bands[pid] = (False, None, 2)
            return out(json.dumps({'status': '0x1', 'transactionHash': '0x' + 'cd' * 32, 'gasUsed': '0x20'}))
        return super().__call__(args, capture_output, text)


def range_keeper(chain):
    d = tempfile.mkdtemp()
    j = Path(d) / 'journal.json'
    j.write_text(json.dumps({'registry': '0x' + '11' * 20, 'rangeCustodian': '0x' + '44' * 20, 'executor': '0x' + '55' * 20}))
    return ok.Keeper(j, '0x' + '33' * 20, ['--unlocked'], Path(d) / 's.json', rpc='http://x', runner=chain)


class RangeTests(unittest.TestCase):
    def test_fully_converted_band_is_finalised_only_with_execute(self):
        chain = RangeChain({1: (True, None, 1)})
        lines, _ = range_keeper(chain).step(False)
        self.assertEqual(lines[-1]['action'], 'finalise due (dry run)')
        self.assertEqual(chain.finalized, [])
        k = range_keeper(chain)
        lines, rc = k.step(True)
        self.assertEqual(chain.finalized, [1])
        self.assertEqual(rc, 0)
        lines, _ = k.step(True)
        self.assertEqual(lines[-1]['action'], 'none (finalised)')

    def test_partial_fill_reversal_stale_oracle_and_pool_deviation_wait(self):
        chain = RangeChain({1: (True, 'BandNotFullyConverted()', 1), 2: (True, 'OracleUnavailable()', 1),
                            3: (True, 'PoolOracleDeviation(uint256,uint256)', 1)})
        lines, rc = range_keeper(chain).step(True)
        self.assertEqual([l['action'] for l in lines], ['wait', 'wait', 'wait'])
        self.assertEqual(chain.finalized, [])
        self.assertEqual(rc, 0)

    def test_unknown_refusal_needs_a_person(self):
        chain = RangeChain({1: (True, 'Panic(uint256)', 1)})
        lines, rc = range_keeper(chain).step(True)
        self.assertEqual(lines[-1]['action'], 'ATTENTION')
        self.assertEqual(rc, 2)

    def test_band_removed_by_a_risk_path_is_recorded_once_and_never_touched(self):
        chain = RangeChain({1: (True, 'BandNotFullyConverted()', 1)})
        k = range_keeper(chain)
        k.step(True)
        chain.bands[1] = (False, None, 3)  # liquidator, stop-loss or owner unwound it
        lines, _ = k.step(True)
        self.assertEqual(lines, [{'range': 1, 'status': 'unwound',
                                  'action': 'none (removed by a risk path (liquidation, stop-loss or owner))'}])
        lines, _ = k.step(True)
        self.assertEqual(lines, [])
        self.assertEqual(chain.finalized, [])
        self.assertNotIn('send', [c for c in chain.sent])

    def test_gas_cap_blocks_finalisation(self):
        chain = RangeChain({1: (True, None, 1)}, gas_price=10**12)
        lines, _ = range_keeper(chain).step(True)
        self.assertEqual(lines[-1]['action'], 'wait (gas price above cap)')
        self.assertEqual(chain.finalized, [])
