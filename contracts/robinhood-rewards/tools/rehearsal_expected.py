#!/usr/bin/env python3
"""Independent (Python, not the JS generator) recomputation of ONE account's RAM entitlement for an epoch, from raw
eth_getLogs / eth_getBlockByNumber answers of an endpoint. Used by the fork rehearsal as the assertion source.

  rehearsal_expected.py <rpc> <start> <end> <account> [user_bps] [excluded,...]   ->  prints the expected wei amount

Rule (README section 3): every RAM ExternalRewardHeld(pair) in (start, end] is split between rpSPY and rpUSDGs by the
side principal USD of the latest preceding PairCheckpoint (usdg*1e12 vs benchmark+pnl-usdg*1e12); each market pays
user_bps of its part pro rata to time-weighted pToken balances over [ts(start), ts(end)] (excluded holders stay in the
denominator). The account's amount is the sum over both markets (floor per market).
"""
import json, sys, urllib.request

VAULT = '0x67e7742922f4cc88c545e5ab5df402b22db4830b'
PAIR = '0x8f81f5d84aa85b29b5114b8ca1a75266c4dc18785b703e8257ca66ecb4ba5435'
RAM = '0x5173d45a1191ee33cbb7d8c7e65f21b04ed54802'
MARKETS = ['0x14cc6fe0ae856b736fab6678619ced3d4738ea8b', '0x2117c202f356399c9ae2d395d4e155785015ac6b']
T_TRANSFER = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
T_HELD = '0xf88735333bfa624eddfd37925d7e1682d674f44803b67f001600256ec1b07a5e'
T_CKPT = '0x89435eb942d7fca3abf983fcf2b8e2b10331d832dcf9cb033b38fd800b02e379'
SCAN_FROM = 110177000


def rpc(url, method, params):
    req = urllib.request.Request(url, json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode(),
                                 {'Content-Type': 'application/json', 'User-Agent': 'curl/8'})
    with urllib.request.urlopen(req, timeout=120) as r:
        res = json.load(r)
    if 'error' in res:
        raise RuntimeError(res['error'])
    return res['result']


def logs(url, address, topic, a, b):
    out = rpc(url, 'eth_getLogs', [{'address': address, 'topics': [topic], 'fromBlock': hex(a), 'toBlock': hex(b)}])
    return sorted(out, key=lambda l: (int(l['blockNumber'], 16), int(l['logIndex'], 16)))


def words(data):
    d = data[2:]
    return [int(d[i:i + 64], 16) for i in range(0, len(d), 64)]


def main():
    url, start, end, account = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4].lower()
    bps = int(sys.argv[5]) if len(sys.argv) > 5 else 9000
    key = lambda l: (int(l['blockNumber'], 16), int(l['logIndex'], 16))
    held = [l for l in logs(url, VAULT, T_HELD, start + 1, end) if l['topics'][1] == PAIR and l['topics'][2][-40:] == RAM[2:]]
    ckpts = [l for l in logs(url, VAULT, T_CKPT, SCAN_FROM, end) if l['topics'][1] == PAIR]
    part = [0, 0]
    for h in held:
        amt = words(h['data'])[0]
        prev = [c for c in ckpts if key(c) < key(h)]
        if not prev:
            continue
        w = words(prev[-1]['data'])
        bench, pnl, usdg = w[2], w[3] - (1 << 256 if w[3] >> 255 else 0), w[5]
        u = usdg * 10 ** 12
        s = max(bench + pnl - u, 0)
        if s + u == 0:
            continue
        sp = amt * s // (s + u)
        part[0] += sp
        part[1] += amt - sp
    ts = lambda b: int(rpc(url, 'eth_getBlockByNumber', [hex(b), False])['timestamp'], 16)
    t0, t1 = ts(start), ts(end)
    total = 0
    for m, reward in zip(MARKETS, part):
        bal, wsum, mine, last = {}, 0, 0, {}
        evs = logs(url, m, T_TRANSFER, SCAN_FROM, end)
        holders = {}
        for e in evs:
            b = int(e['blockNumber'], 16)
            T = t0 if b <= start else ts(b)
            f, t, v = '0x' + e['topics'][1][-40:], '0x' + e['topics'][2][-40:], int(e['data'], 16)
            for a, dv in ((f, -v), (t, v)):
                if a in (m, '0x' + '0' * 40):
                    continue
                holders[a] = holders.get(a, 0) + holders_bal(bal, a) * (T - last.get(a, t0))
                last[a] = T
                bal[a] = bal.get(a, 0) + dv
        for a in bal:
            holders[a] = holders.get(a, 0) + bal[a] * (t1 - last.get(a, t0))
        wsum = sum(holders.values())
        mine = holders.get(account, 0)
        if wsum:
            total += (reward * bps // 10000) * mine // wsum
    print(total)


def holders_bal(bal, a):
    return bal.get(a, 0)


if __name__ == '__main__':
    main()
