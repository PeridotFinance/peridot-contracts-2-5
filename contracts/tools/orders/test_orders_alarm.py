import io
import json
import tempfile
import unittest
from pathlib import Path

import orders_alarm as al

GOOD = {'head_lag': 5, 'balance_wei': 100 * al.GAS_FLOOR_WEI, 'nonce': 7}


class Classify(unittest.TestCase):
    def test_rpc_failure_first(self):
        self.assertEqual(al.classify({})['state'], 'RPC_FAILURE')
        self.assertEqual(al.classify(dict(GOOD, due=[], head_lag=al.HEAD_MAX_LAG + 1))['state'], 'RPC_FAILURE')

    def test_gas_floors(self):
        self.assertEqual(al.classify(dict(GOOD, due=[], balance_wei=al.GAS_FLOOR_WEI - 1))['state'], 'GAS_CRITICAL')
        self.assertEqual(al.classify(dict(GOOD, due=[], balance_wei=3 * al.GAS_FLOOR_WEI))['state'], 'GAS_LOW')

    def test_idle_and_served_do_not_page(self):
        r = al.classify(dict(GOOD, due=[]))
        self.assertEqual((r['state'], r['page']), ('IDLE', False))
        r = al.classify(dict(GOOD, due=['r4'], due_after=[], nonce_after=8))
        self.assertEqual((r['state'], r['page']), ('SERVED', False))

    def test_still_due_with_a_still_nonce_is_stalled(self):
        r = al.classify(dict(GOOD, due=['o3', 'r4'], due_after=['r4'], nonce_after=7))
        self.assertEqual((r['state'], r['page'], r['stillDue']), ('STALLED', True, ['r4']))

    def test_still_due_while_sending_is_failed_sends(self):
        r = al.classify(dict(GOOD, due=['r4'], due_after=['r4'], nonce_after=9))
        self.assertEqual((r['state'], r['page']), ('FAILED_SENDS', True))

    def test_new_work_in_the_second_read_alone_is_not_a_stall(self):
        r = al.classify(dict(GOOD, due=['o3'], due_after=['o5'], nonce_after=7))
        self.assertEqual(r['state'], 'SERVED')


class Observe(unittest.TestCase):
    def test_second_read_only_when_something_is_due(self):
        calls = {'sleep': 0}

        class P:
            def __init__(self, out, rc=0):
                self.stdout, self.returncode, self.stderr = out, rc, ''

        def run(args, capture_output=True, text=True):
            if args[1] == 'block':
                return P('1000\n')
            if args[1] == 'balance':
                return P(str(100 * al.GAS_FLOOR_WEI))
            if args[1] == 'nonce':
                return P('7')
            if 'nextOrderId()(uint256)' in args:
                return P('2\n')
            if 'canExecute(uint256)(bool,uint256,uint8)' in args:
                return P('true\n1\n0\n')
            return P('0\n')

        o = al.observe({'registry': '0x' + '11' * 20}, '0x' + '22' * 20, 1001, run=run,
                       sleep=lambda s: calls.__setitem__('sleep', s))
        self.assertEqual(o['due'], ['o1'])
        self.assertEqual(o['due_after'], ['o1'])
        self.assertEqual(calls['sleep'], al.STALL_WINDOW)
        self.assertEqual(al.classify(o)['state'], 'STALLED')


class Issue(unittest.TestCase):
    def test_one_issue_created_updated_and_closed(self):
        page = al.classify(dict(GOOD, due=['r4'], due_after=['r4'], nonce_after=7))
        self.assertEqual(al.issue_plan(page, None)['op'], 'create')
        issue = {'number': 1, 'body': al.issue_plan(page, None)['body']}
        self.assertNotIn('comment', al.issue_plan(page, issue), 'same state: no new comment')
        self.assertEqual(al.issue_plan(al.classify(dict(GOOD, due=[])), issue)['op'], 'close')

    def test_drill_pages_without_reading(self):
        j = Path(tempfile.mkdtemp()) / 'j.json'
        j.write_text(json.dumps({'registry': '0x' + '11' * 20}))
        buf = io.StringIO()
        rc = al.run(['--journal', str(j), '--drill'], observer=lambda *a: self.fail('read'), out=buf)
        self.assertEqual(rc, 1)
        self.assertIn('DRILL', buf.getvalue())


if __name__ == '__main__':
    unittest.main()
