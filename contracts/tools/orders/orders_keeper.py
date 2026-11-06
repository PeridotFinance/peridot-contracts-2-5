#!/usr/bin/env python3
"""TP/SL order keeper for MarginOrderRegistry (chain-agnostic EVM; Robinhood journal by default).

One step:
  * scan order ids from the first not-yet-final one up to nextOrderId - 1;
  * canExecute(id) decides, and executeOrder is simulated exactly as it would be sent, then sent only if the simulation
    succeeds and the gas price is under the cap:
      reason 0 (executable)                          -> execute
      reason 2/3/4 (expired, inactive, owner changed)  -> sweep: executeOrder marks it EXPIRED/CANCELLED (SWEEP=off skips)
      reason 5/6/7 (oracle, trigger, paused)          -> wait
      reason 1 (not open)                             -> final, never read again
  * a failed simulation of a due order is a wait when the close path refused on slippage or a moved price, ATTENTION
    otherwise.

    python3 orders_keeper.py --journal deployments/orders-mainnet.json [--execute] [--once]

Execution is permissionless: the keeper wallet needs gas only and receives nothing; proceeds go to the position owner.
Without --execute nothing is sent. Logs are JSON lines and never contain secrets.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

RPC = os.environ.get('RH_RPC', 'https://rpc.mainnet.chain.robinhood.com')
GAS_LIMIT = int(os.environ.get('ORDERS_GAS_LIMIT', 4_000_000))
MAX_GAS_PRICE_WEI = int(os.environ.get('MAX_GAS_PRICE_WEI', 100_000_000))  # 0.1 gwei, as for the other keepers
MAX_SENDS_PER_STEP = int(os.environ.get('ORDERS_MAX_SENDS', 10))
SWEEP = os.environ.get('SWEEP', 'on') == 'on'

# Simulation failures that mean "not now" rather than "a person should look".
WAIT_ERRORS = {
    'TriggerNotReached(uint256,uint256)',
    'OracleUnavailable()',
    'ExecutionPaused()',
    'InvalidClose(uint8)',  # adapter: price moved between canExecute and execute, or close fee above the cap
    'V4TooLittleReceived(uint256,uint256)',  # the pool is further from the oracle than the order's slippage allows
}
REASON_NAMES = {0: 'executable', 1: 'final', 2: 'expired', 3: 'position inactive', 4: 'owner changed',
                5: 'oracle unavailable', 6: 'trigger not reached', 7: 'paused'}


class Keeper:
    def __init__(self, journal_path, sender, signer, state_path, rpc=RPC, runner=subprocess.run):
        d = json.loads(Path(journal_path).read_text())
        self.registry, self.rpc = d['registry'], rpc
        self.sender, self.signer, self.runner = sender, signer, runner
        self.state_path = Path(state_path)
        text = self.state_path.read_text().strip() if self.state_path.exists() else ''
        self.state = json.loads(text) if text else {}
        if self.state.get('registry', self.registry).lower() != self.registry.lower():
            self.state = {}  # a different registry (redeploy or another chain): its ids mean nothing here
        self.state['registry'] = self.registry
        self.state.setdefault('firstOpen', 1)
        self.state.setdefault('final', [])

    def cast(self, *args, check=True):
        r = self.runner(['cast', *args, '--rpc-url', self.rpc], capture_output=True, text=True)
        if check and r.returncode:
            raise RuntimeError((r.stderr or r.stdout).strip()[:300])
        return r

    def classify(self, output):
        m = re.search(r'0x[0-9a-fA-F]{8}', output or '')
        if not m:
            return 'unknown', False
        code = m.group(0).lower()
        for sig in WAIT_ERRORS | {'OrderNotOpen()', 'ReentrancyGuardReentrantCall()'}:
            if self.runner(['cast', 'sig', sig], capture_output=True, text=True).stdout.strip().lower() == code:
                return sig.split('(')[0], sig in WAIT_ERRORS
        return 'unknown(' + code + ')', False

    def can_execute(self, order_id):
        out = self.cast('call', self.registry, 'canExecute(uint256)(bool,uint256,uint8)', str(order_id)).stdout.split('\n')
        return out[0].strip() == 'true', int(out[1].split()[0]), int(out[2].split()[0])

    def simulate(self, order_id):
        r = self.cast('call', self.registry, 'executeOrder(uint256,bytes)(bool)', str(order_id), '0x',
                      '--from', self.sender, '--gas-limit', str(GAS_LIMIT), check=False)
        if r.returncode == 0:
            return 'ok', True
        return self.classify(r.stderr + r.stdout)

    def send(self, order_id):
        r = self.cast('send', self.registry, 'executeOrder(uint256,bytes)', str(order_id), '0x', *self.signer,
                      '--from', self.sender, '--gas-limit', str(GAS_LIMIT), '--json', check=False)
        if r.returncode:
            return {'action': 'SEND FAILED'}
        try:
            receipt = json.loads(r.stdout)
        except ValueError:
            return {'action': 'UNCONFIRMED'}
        ok = str(receipt.get('status')).lower() in ('0x1', '1')
        return {'action': 'sent' if ok else 'REVERTED ON-CHAIN', 'tx': receipt.get('transactionHash'),
                'gasUsed': int(str(receipt.get('gasUsed', '0x0')), 16)}

    def gas_ok(self):
        return int(self.cast('gas-price').stdout.strip()) <= MAX_GAS_PRICE_WEI

    def save(self):
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps(self.state, indent=2) + '\n')

    def step(self, execute):
        out, rc, sends = [], 0, 0
        next_id = int(self.cast('call', self.registry, 'nextOrderId()(uint256)').stdout.split()[0])
        final = set(self.state['final'])
        for oid in range(self.state['firstOpen'], next_id):
            if oid in final:
                continue
            executable, price, reason = self.can_execute(oid)
            line = {'order': oid, 'reason': REASON_NAMES.get(reason, str(reason))}
            if reason == 1:
                final.add(oid)
                continue
            due = executable or (SWEEP and reason in (2, 3, 4))
            if not due:
                out.append(dict(line, action='wait'))
                continue
            line['price'] = price
            name, ok = self.simulate(oid)
            if name != 'ok':
                out.append(dict(line, simulation=name, action='wait' if ok else 'ATTENTION'))
                rc = rc if ok else 2
                continue
            if not execute:
                out.append(dict(line, action='due (dry run)'))
            elif sends >= MAX_SENDS_PER_STEP:
                out.append(dict(line, action='wait (send budget for this step used)'))
            elif not self.gas_ok():
                out.append(dict(line, action='wait (gas price above cap)'))
            else:
                res = self.send(oid)
                sends += 1
                out.append(dict(line, **res))
                if res['action'] == 'sent':
                    final.add(oid)  # executed, expired or cancelled: either way no longer open
                else:
                    rc = 3
        # Advance the cursor past the leading run of final ids so a long history is not rescanned.
        first = self.state['firstOpen']
        while first < next_id and first in final:
            final.discard(first)
            first += 1
        self.state['firstOpen'], self.state['final'] = first, sorted(final)
        self.save()
        return out, rc


def main(argv=None):
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('--journal', required=True)
    p.add_argument('--sender', default=os.environ.get('ORDERS_KEEPER'))
    p.add_argument('--keystore', default=os.environ.get('ORDERS_KEEPER_KEYSTORE'))
    p.add_argument('--password-file', default=os.environ.get('ORDERS_KEEPER_PASSWORD_FILE'))
    p.add_argument('--unlocked', action='store_true', help='local fork rehearsal only')
    p.add_argument('--state', default=os.environ.get('ORDERS_KEEPER_STATE', 'orders-keeper-state.json'))
    p.add_argument('--execute', action='store_true')
    p.add_argument('--once', action='store_true')
    p.add_argument('--interval', type=int, default=int(os.environ.get('INTERVAL_SECONDS', 30)))
    a = p.parse_args(argv)
    signer = ['--unlocked'] if a.unlocked else (['--keystore', a.keystore, '--password-file', a.password_file] if a.keystore else [])
    if a.execute and (not signer or not a.sender):
        print(json.dumps({'status': 'refused', 'detail': 'no signer or sender configured'}))
        return 2
    k = Keeper(a.journal, a.sender or '0x' + '00' * 20, signer, a.state)
    while True:
        lines, rc = k.step(a.execute)
        for line in lines:
            print(json.dumps(dict(line, time=int(time.time()))), flush=True)
        if a.once:
            return rc
        time.sleep(a.interval)


if __name__ == '__main__':
    sys.exit(main())
