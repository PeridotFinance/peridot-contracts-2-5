#!/usr/bin/env python3
"""Read-only alarm for the order keeper (TP/SL orders and range take-profit finalisation). Chain reads only; it never
signs or sends. Same pattern as PeridotV2-Robinhood keeper/alarm.py: `classify` is pure, one state per observation, one
de-duplicated GitHub issue assigned to the operator.

Orders and bands have no age on chain, so a stall is measured inside one run: the alarm reads what is due, waits
STALL_WINDOW (several keeper intervals), and reads again. Work still due and a keeper nonce that did not move is STALLED;
work still due while the nonce moved means sends are failing (FAILED_SENDS).

    python3 tools/orders/orders_alarm.py --journal deployments/orders-mainnet.json            # exits 1 on a page
    python3 tools/orders/orders_alarm.py --journal ... --notify                                # also keeps the issue
    python3 tools/orders/orders_alarm.py --journal ... --notify --drill                        # delivery test
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

RPC = os.environ.get('RH_RPC', 'https://rpc.mainnet.chain.robinhood.com')
ASSIGNEE = 'joshschcom'
ISSUE_TITLE = 'Order keeper alarm: TP/SL or range finalisation needs attention'
ISSUE_AUTHOR = 'github-actions[bot]'
GAS_PER_SEND = 4_000_000  # orders_keeper GAS_LIMIT
GAS_PRICE_CAP_WEI = 100_000_000  # orders_keeper MAX_GAS_PRICE_WEI
GAS_FLOOR_WEI = GAS_PER_SEND * GAS_PRICE_CAP_WEI  # below one send the keeper can do nothing
GAS_LOW_SENDS = 10
HEAD_MAX_LAG = 900
STALL_WINDOW = int(os.environ.get('ALARM_STALL_WINDOW', 150))  # five keeper intervals of 30 s
PAGES = {'GAS_CRITICAL', 'GAS_LOW', 'STALLED', 'FAILED_SENDS', 'RPC_FAILURE', 'DRILL'}


def _result(state, message, **fields):
    return dict(state=state, page=state in PAGES, message=message, **fields)


def classify(o):
    """The one state for an observation. Pure."""
    missing = [k for k in ('head_lag', 'balance_wei', 'nonce', 'due') if o.get(k) is None]
    if missing or o['head_lag'] > HEAD_MAX_LAG:
        detail = 'reads failed: ' + ','.join(missing) if missing else 'chain head is ' + str(o['head_lag']) + ' s old'
        return _result('RPC_FAILURE', "The alarm's own reads failed, so nothing is known about the keeper: " + detail)
    fields = {'sendsOfGasLeft': o['balance_wei'] // GAS_FLOOR_WEI, 'due': o['due']}
    if o['balance_wei'] < GAS_FLOOR_WEI:
        return _result('GAS_CRITICAL', 'Keeper balance is below one send at the gas cap: orders and finalisations '
                       'cannot be sent', **fields)
    if o['balance_wei'] < GAS_LOW_SENDS * GAS_FLOOR_WEI:
        return _result('GAS_LOW', 'Under ' + str(GAS_LOW_SENDS) + ' sends of gas left', **fields)
    if not o['due']:
        return _result('IDLE', 'Nothing is due: no executable order and no fully converted band', **fields)
    still = sorted(set(o['due']) & set(o.get('due_after') or []))
    if not still:
        return _result('SERVED', 'Work was due and the keeper cleared it within ' + str(STALL_WINDOW) + ' s', **fields)
    fields['stillDue'] = still
    if o.get('nonce_after') is not None and o['nonce_after'] > o['nonce']:
        return _result('FAILED_SENDS', 'Still due after ' + str(STALL_WINDOW) + ' s although the keeper sent ' +
                       str(o['nonce_after'] - o['nonce']) + ' transactions: sends are reverting or failing', **fields)
    return _result('STALLED', 'Still due after ' + str(STALL_WINDOW) + ' s and the keeper nonce did not move: dead '
                   'process, hung worker or sends failing before they are mined', **fields)


# --- reads ------------------------------------------------------------------------------------------------------

def cast(*args, run=subprocess.run):
    r = run(['cast', *args, '--rpc-url', RPC], capture_output=True, text=True)
    return r


def read_due(journal, keeper, run=subprocess.run):
    """Ids of executable orders ('o<id>') and finalisable bands ('r<positionId>')."""
    due = []
    reg = journal['registry']
    n = int(cast('call', reg, 'nextOrderId()(uint256)', run=run).stdout.split()[0])
    for oid in range(1, n):
        out = cast('call', reg, 'canExecute(uint256)(bool,uint256,uint8)', str(oid), run=run).stdout.split('\n')
        if out and out[0].strip() == 'true':
            due.append('o' + str(oid))
    if journal.get('rangeCustodian') and journal.get('executor'):
        m = int(cast('call', journal['executor'], 'nextPositionId()(uint256)', run=run).stdout.split()[0])
        for pid in range(1, m):
            if cast('call', journal['rangeCustodian'], 'isActive(uint256)(bool)', str(pid), run=run).stdout.strip() != 'true':
                continue
            r = cast('call', journal['rangeCustodian'], 'finalize(uint256)', str(pid), '--from', keeper, run=run)
            if r.returncode == 0:
                due.append('r' + str(pid))
    return due


def observe(journal, keeper, wall, run=subprocess.run, sleep=time.sleep):
    o = {}
    try:
        head = int(cast('block', 'latest', '--field', 'timestamp', run=run).stdout.strip())
        o['head_lag'] = max(0, wall - head)
        o['balance_wei'] = int(cast('balance', keeper, run=run).stdout.strip())
        o['nonce'] = int(cast('nonce', keeper, run=run).stdout.strip())
        o['due'] = read_due(journal, keeper, run=run)
        if o['due']:
            sleep(STALL_WINDOW)
            o['due_after'] = read_due(journal, keeper, run=run)
            o['nonce_after'] = int(cast('nonce', keeper, run=run).stdout.strip())
    except (ValueError, IndexError):
        pass
    return o


# --- the one GitHub issue (as keeper/alarm.py) -----------------------------------------------------------------

def issue_plan(result, issue):
    if not result['page']:
        return {'op': 'close', 'comment': 'Recovered: now ' + result['state'] + '. ' + result['message']} if issue \
            else {'op': 'none'}
    body = '**' + result['state'] + '**: ' + result['message'] + '\n\n<!-- orders-alarm ' + \
        json.dumps({'state': result['state']}) + ' -->\n'
    if not issue:
        return {'op': 'create', 'body': body}
    plan = {'op': 'update', 'body': body}
    m = re.search(r'<!-- orders-alarm (\{.*?\}) -->', issue.get('body') or '')
    if not m or json.loads(m.group(1)).get('state') != result['state']:
        plan['comment'] = 'Now ' + result['state'] + ': ' + result['message']
    return plan


def github_api(method, path, payload=None, env=os.environ):
    request = urllib.request.Request('https://api.github.com/repos/' + env['GITHUB_REPOSITORY'] + path, method=method,
                                     data=json.dumps(payload).encode() if payload is not None else None)
    request.add_header('Authorization', 'Bearer ' + env['GITHUB_TOKEN'])
    request.add_header('Accept', 'application/vnd.github+json')
    with urllib.request.urlopen(request, timeout=30) as answer:
        return json.loads(answer.read() or 'null')


def find_issue(api=github_api):
    for issue in api('GET', '/issues?state=open&creator=' + urllib.request.quote(ISSUE_AUTHOR) + '&per_page=100'):
        if issue.get('title') == ISSUE_TITLE and (issue.get('user') or {}).get('login') == ISSUE_AUTHOR:
            return issue
    return None


def apply_plan(plan, issue, api=github_api):
    if plan['op'] == 'create':
        api('POST', '/issues', {'title': ISSUE_TITLE, 'body': plan['body'], 'assignees': [ASSIGNEE]})
        return
    if plan['op'] == 'none':
        return
    number = str(issue['number'])
    if plan.get('comment'):
        api('POST', '/issues/' + number + '/comments', {'body': plan['comment']})
    api('PATCH', '/issues/' + number, {'body': plan['body']} if plan['op'] == 'update' else {'state': 'closed'})


def run(argv=None, observer=observe, finder=find_issue, applier=apply_plan, clock=time.time, out=sys.stdout):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--journal', required=True)
    p.add_argument('--keeper', default=os.environ.get('ORDERS_KEEPER'))
    p.add_argument('--notify', action='store_true')
    p.add_argument('--drill', action='store_true')
    a = p.parse_args(argv)
    notify_failed, issue = False, None
    if a.notify:
        try:
            issue = finder()
        except (OSError, ValueError, KeyError):
            notify_failed = True
    if a.drill:
        o, result = {}, _result('DRILL', 'Delivery test, not a real alarm. Run again without drill to close this.')
    else:
        o = observer(json.loads(Path(a.journal).read_text()), a.keeper, int(clock()))
        result = classify(o)
    if a.notify and not notify_failed:
        try:
            applier(issue_plan(result, issue), issue)
        except (OSError, ValueError, KeyError):
            notify_failed = True
    print(json.dumps({'observation': o, 'result': result, 'notifyFailed': notify_failed}, indent=1), file=out)
    print(('::error::' if result['page'] else '::notice::') + result['state'] + ': ' + result['message'], file=out)
    return 1 if result['page'] or notify_failed else 0


if __name__ == '__main__':
    sys.exit(run())
