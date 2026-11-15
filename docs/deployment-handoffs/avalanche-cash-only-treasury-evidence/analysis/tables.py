#!/usr/bin/env python3
"""Render the TRP| lines of the treasury-repayment fork suite as markdown tables.

usage: tables.py LOG [section]    section in: base evt dly sup orders orders_all truth all (default all)
All amounts in the log are raw USDC units (6 decimals); tables print USDC with 2 decimals.
"""
import sys, collections

def kv(tokens):
    d = {}
    for t in tokens:
        if '=' in t:
            k, v = t.split('=', 1)
            d[k] = v
    return d

def usd(x, dec=2):
    return f"{int(x) / 1e6:,.{dec}f}"

def pct(num, den, dec=2):
    return "n/a" if int(den) == 0 else f"{100 * int(num) / int(den):.{dec}f}%"

def load(path):
    rows = collections.defaultdict(list)
    seen = set()
    for line in open(path, errors='replace'):
        line = line.strip()
        if not line.startswith('TRP|') or line in seen:
            continue
        seen.add(line)
        parts = line.split('|')
        rows[parts[1]].append((parts, kv(parts)))
    return rows

CAPS = ['1000', '5000', '10000']
CANDS = ['PW30', 'PW40']
FUNDS = ['F100', 'F50', 'F25', 'F0', 'FLD']
FLAB = {'F100': '100% of L0', 'F50': '50% of L0', 'F25': '25% of L0', 'F0': '0% (nothing)', 'FLD': '100% of L(delay)'}

def key(d, *ks):
    return tuple(d.get(k) for k in ks)

def base(rows):
    out = ["| cap | cand | supplies (S) | borrowed | cash at borrow | floor | power used (min of 3 borrowers) | borrow APR at borrow | debt after 30 d | growth in 30 d | borrow APR after | reserves after 30 d |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    acc = {}
    for _, d in rows['BASE']:
        if 'debt30' in d:
            acc[(d['cap'], d['cand'])] = d
    for _, d in rows['BASE']:
        if 'debt30' in d:
            continue
        a = acc.get((d['cap'], d['cand']), {})
        out.append(f"| {d['cap']} | {d['cand']} | {usd(d['supply'])} | {usd(d['borrowed'])} | {usd(d['cashAtBorrow'])} | {usd(d['floor'])} | {int(d['minPowerPpm'])/1e4:.4f}% | {int(d['aprPpmAtBorrow'])/1e4:.2f}% | {usd(a.get('debt30',0))} | {int(a.get('growthPpm',0))/1e4:.3f}% | {int(a.get('aprPpmAfter',0))/1e4:.2f}% | {usd(a.get('reserves',0))} |")
    return '\n'.join(out)

def evt(rows):
    out = ["| cap | cand | AVAX gap | debt at gap D | u (debt / borrowing power at the pre-gap price) | collateral after gap C | repaid by liquidator | unrecoverable debt L0 | closed form D - C/LI | L0 / D | residual collateral (max per account) |", "|---|---|---|---|---|---|---|---|---|---|---|"]
    for _, d in rows['EVT']:
        out.append(f"| {d['cap']} | {d['cand']} | -{int(d['fall'])/100:.1f}% | {usd(d['dGap'])} | {int(d['uEffPpm'])/1e4:.3f}% | {usd(d['cAfter'])} | {usd(d['repaid'])} | **{usd(d['l0'])}** | {usd(d['closedForm'])} | {pct(d['l0'], d['dGap'])} | {usd(d['residualMaxUsdc6'],4)} |")
    return '\n'.join(out)

def dly(rows):
    ev = {key(d, 'cap', 'cand', 'fall'): d for _, d in rows['EVT']}
    out = ["| cap | cand | gap | delay | debt L(delay) | phantom interest (L(delay) - L0) | phantom as % of L0 | reserves | market cash | sum of claims | borrow APR (post-event) | utilisation (post-event) |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for _, d in rows['DLY']:
        e = ev[key(d, 'cap', 'cand', 'fall')]
        out.append(f"| {d['cap']} | {d['cand']} | -{int(d['fall'])/100:.1f}% | {d['delay']} d | {usd(d['ld'])} | {usd(d['phantom'])} | {pct(d['phantom'], e['l0'], 3)} | {usd(d['reserves'])} | {usd(d['cash'])} | {usd(d['claims'])} | {int(d['aprPpm'])/1e4:.2f}% | {int(d['utilPpm'])/1e4:.2f}% |")
    return '\n'.join(out)

def tabs(rows):
    t = {}
    for parts, d in rows['TAB']:
        t[key(d, 'cap', 'cand', 'fall', 'delay', 'fund')] = dict(d)
    for parts, d in rows['TAB2']:
        t[key(d, 'cap', 'cand', 'fall', 'delay', 'fund')].update(d)
    fnd = {key(d, 'cap', 'cand', 'fall', 'delay', 'fund'): d for _, d in rows['FND']}
    return t, fnd

def sup(rows, cap, cand):
    t, fnd = tabs(rows)
    ev = {key(d, 'cap', 'cand', 'fall'): d for _, d in rows['EVT']}
    falls = sorted({k[2] for k in t if k[0] == cap and k[1] == cand}, key=int)
    out = []
    for fall in falls:
        e = ev[(cap, cand, fall)]
        out.append(f"\n**cap USD {cap}, {cand}, AVAX gap -{int(fall)/100:.1f}%**: D = {usd(e['dGap'])}, L0 = {usd(e['l0'])} ({pct(e['l0'], e['dGap'])} of D)\n")
        out.append("| delay | funding (budget) | unpaid debt | total exit shortfall (every order) | A min..max recovery | B min..max | C min..max | D min..max | worst single recovery | orders (of 24) with a short supplier | worst shortfall of the LAST supplier | worst shortfall of the FIRST supplier |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for delay in ['0', '1', '7', '30']:
            for f in FUNDS:
                k = (cap, cand, fall, delay, f)
                if k not in t:
                    continue
                r = t[k]; fd = fnd[k]
                cells = []
                for L in 'ABCD':
                    c = int(r['c' + L])
                    cells.append(f"{pct(r['min' + L], c)}..{pct(r['max' + L], c)}" if c else 'n/a')
                out.append(f"| {delay} d | {FLAB[f]} ({usd(fd['budget'])}) | {usd(fd['unpaid'])} | **{usd(r['shortTot'])}** | " + " | ".join(cells) + f" | {int(r['worstPpm'])/1e4:.2f}% | {r['nShortOrders']} | {usd(r['lastShortMax'])} | {usd(r['firstShortMax'])} |")
    return '\n'.join(out)

def orders(rows, cap, cand, fall, delay, funds):
    perms = collections.OrderedDict()
    for _, d in rows['ORD']:
        if (d['cap'], d['cand'], d['fall'], d['delay']) == (cap, cand, fall, delay) and d['fund'] in funds:
            perms.setdefault(d['perm'], {})[d['fund']] = d
    out = [f"\n**All 24 withdrawal orders, cap USD {cap}, {cand}, gap -{int(fall)/100:.1f}%, delay {delay} d.** Shortfall of each supplier A (50% of S), B (25%), C (15%), D (10%) in USDC; order = who withdraws first..last.\n"]
    out.append("| order (first..last) | " + " | ".join(f"{FLAB[f]}: A / B / C / D" for f in funds) + " |")
    out.append("|---|" + "---|" * len(funds))
    for p, byf in perms.items():
        cells = []
        for f in funds:
            d = byf.get(f)
            cells.append("n/a" if not d else " / ".join(usd(d['s' + L]) for L in 'ABCD'))
        out.append(f"| {p} | " + " | ".join(cells) + " |")
    return '\n'.join(out)

def fund(rows):
    """Funding the treasury must hold per cap and candidate: measured L0 (and L at +30 d), the closed form on the measured position, and the
    decision table's closed form (u = 99%, no interest) scaled to the cap."""
    LI = 1.08
    cfs = {'PW30': 0.30, 'PW40': 0.40}
    dly = {}
    for _, d in rows['DLY']:
        dly[(d['cap'], d['cand'], d['fall'], d['delay'])] = d
    out = ["| candidate | AVAX gap | cap (USD) | measured L0 (unrecoverable debt at the event) | closed form on the measured position, D - C/LI | decision-table closed form, u = 99% and no interest, x cap | measured L(7 d) | measured L(30 d) | L0 per USD 100,000 of cap |", "|---|---|---|---|---|---|---|---|---|"]
    for cand in ['PW40', 'PW30']:
        for fall in (['6000', '6760', '7500'] if cand == 'PW40' else ['7500', '8000']):
            for cap in CAPS:
                e = [d for _, d in rows['EVT'] if d['cap'] == cap and d['cand'] == cand and d['fall'] == fall]
                if not e:
                    continue
                e = e[0]
                x = int(fall) / 1e4
                rho = (1 - x) / (cfs[cand] * 0.99)
                share = max(0.0, 1 - rho / LI)
                l7 = dly[(cap, cand, fall, '7')]['ld']; l30 = dly[(cap, cand, fall, '30')]['ld']
                out.append(f"| {cand} | -{x*100:.1f}% | {int(cap):,} | **{usd(e['l0'])}** | {usd(e['closedForm'])} | {share*int(cap):,.2f} | {usd(l7)} | {usd(l30)} | {int(e['l0'])/1e6/int(cap)*1e5:,.0f} |")
    return '\n'.join(out)

def compact(rows, cand):
    """One table per candidate: percentages are identical for every cap (everything scales with the cap; asserted to 0.01 pp), USD columns for each cap."""
    t, fnd = tabs(rows)
    S = {'1000': 1250e6, '5000': 6250e6, '10000': 12500e6}
    ev = {key(d, 'cap', 'cand', 'fall'): d for _, d in rows['EVT']}
    falls = ['6000', '6760', '7500'] if cand == 'PW40' else ['7500', '8000']
    out = []
    for fall in falls:
        out.append(f"\n**{cand}, AVAX gap -{int(fall)/100:.1f}%** (L0 = " + " / ".join(f"{usd(ev[(c, cand, fall)]['l0'])}" for c in CAPS) + " USDC for caps 1,000 / 5,000 / 10,000)\n")
        out.append("| delay | funding | unpaid debt, USD (cap 1k / 5k / 10k) | **exit shortfall, USD (1k / 5k / 10k)** | shortfall as % of supply | supplier A (50%) recovery min..max | B (25%) | C (15%) | D (10%) | worst single recovery | orders (of 24) with a short supplier | last-in-queue worst shortfall, % of supply |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for delay in ['0', '1', '7', '30']:
            for f in FUNDS:
                ks = [(c, cand, fall, delay, f) for c in CAPS]
                if ks[0] not in t:
                    continue
                pcts = []
                cells = []
                for L in 'ABCD':
                    mins = [int(t[k]['min' + L]) / int(t[k]['c' + L]) * 100 for k in ks]
                    maxs = [int(t[k]['max' + L]) / int(t[k]['c' + L]) * 100 for k in ks]
                    assert max(mins) - min(mins) < 0.01 and max(maxs) - min(maxs) < 0.01, (cand, fall, delay, f, L, mins)
                    cells.append(f"{mins[0]:.2f}%..{maxs[0]:.2f}%")
                st = [int(t[k]['shortTot']) / S[k[0]] * 100 for k in ks]
                assert max(st) - min(st) < 0.01, st
                ls = [int(t[k]['lastShortMax']) / S[k[0]] * 100 for k in ks]
                assert max(ls) - min(ls) < 0.01, ls
                w = [int(t[k]['worstPpm']) / 1e4 for k in ks]
                assert max(w) - min(w) < 0.05, w
                assert len({t[k]['nShortOrders'] for k in ks}) == 1
                out.append(f"| {delay} d | {FLAB[f]} | " + " / ".join(usd(fnd[k]['unpaid']) for k in ks) + " | **" + " / ".join(usd(t[k]['shortTot']) for k in ks) + f"** | {st[0]:.2f}% | " + " | ".join(cells) + f" | {w[0]:.2f}% | {t[ks[0]]['nShortOrders']} | {ls[0]:.2f}% |")
    return '\n'.join(out)

def window(rows):
    out = ["| candidate | AVAX gap | delay | market cash | sum of claims | share of claims that can exit whole (FCFS) while nothing is repaid |", "|---|---|---|---|---|---|"]
    for _, d in rows['DLY']:
        if d['delay'] in ('0', '30'):
            out.append(f"| {d['cand']} | -{int(d['fall'])/100:.1f}% | {d['delay']} d | {int(d['cash'])/int(d['claims'])*100:.1f}% of S-scaled: {usd(d['cash'])} / {usd(d['claims'])} | | {int(d['cash'])/int(d['claims'])*100:.1f}% |" if False else f"| {d['cand']} | -{int(d['fall'])/100:.1f}% | {d['delay']} d | {usd(d['cash'])} | {usd(d['claims'])} | {int(d['cash'])/int(d['claims'])*100:.1f}% (cap {d['cap']}) |")
    return '\n'.join(out)

def truth(rows):
    out = ["| case | verdict | debt (USDC units) | debt value (USD) | collateral value (USD) | max recovery C/LI (USD) | shortfall (USD) |", "|---|---|---|---|---|---|---|"]
    for parts, d in rows['TRUTH']:
        case = parts[2]
        out.append(f"| {case} | {d['verdict']} | {usd(d['debtUnits'])} | {int(d['debtUsd'])/1e18:,.4f} | {int(d['collUsd'])/1e18:,.4f} | {int(d['maxRecoveryUsd'])/1e18:,.4f} | {int(d['shortfallUsd'])/1e18:,.4f} |")
    return '\n'.join(out)

if __name__ == '__main__':
    rows = load(sys.argv[1])
    what = sys.argv[2] if len(sys.argv) > 2 else 'all'
    if what in ('base', 'all'):
        print("### Fixture\n"); print(base(rows)); print()
    if what in ('evt', 'all'):
        print("### Events\n"); print(evt(rows)); print()
    if what in ('dly', 'all'):
        print("### Delay\n"); print(dly(rows)); print()
    if what in ('sup', 'all'):
        for cap in CAPS:
            for cand in CANDS:
                print(f"### Supplier outcomes cap {cap} {cand}"); print(sup(rows, cap, cand)); print()
    if what in ('orders', 'all'):
        print(orders(rows, '10000', 'PW40', '7500', '0', ['F0', 'F25', 'F50', 'F100']))
    if what == 'orders_all':
        for cap in CAPS:
            for cand, falls in (('PW40', ['6000', '6760', '7500']), ('PW30', ['7500', '8000'])):
                for fall in falls:
                    for delay in ['0', '1', '7', '30']:
                        print(orders(rows, cap, cand, fall, delay, ['F0', 'F25', 'F50', 'F100'] + (['FLD'] if delay != '0' else [])))
    if what == 'compact':
        for cand in ('PW40', 'PW30'):
            print(f"### {cand}"); print(compact(rows, cand)); print()
    if what == 'window':
        print(window(rows))
    if what in ('fund', 'all'):
        print("### Funding\n"); print(fund(rows)); print()
    if what in ('truth', 'all'):
        print("### Truth table\n"); print(truth(rows))
