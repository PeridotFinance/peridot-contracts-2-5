#!/usr/bin/env python3
"""Fails unless MarginOrderRegistry's storage layout only APPENDS to the recorded one (and the gap shrinks to match).

Run from contracts/:  python3 tools/orders/check_registry_layout.py [--record]
Compares label, slot, offset and a type name without AST ids. `--record` writes the snapshot (first deployment only).
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SNAPSHOT = Path('tools/orders/registry-layout.json')
TARGET = 'contracts/margin/orders/MarginOrderRegistry.sol:MarginOrderRegistry'
if '--target' in sys.argv:  # e.g. the prepared V2: contracts/margin/orders/MarginOrderRegistryV2.sol:MarginOrderRegistryV2
    TARGET = sys.argv[sys.argv.index('--target') + 1]
TOTAL_SLOTS = 50  # the contract's own variables plus __gap always cover slots 0..49


def current():
    env = dict(os.environ, FOUNDRY_PROFILE='robinhood_orders')
    subprocess.run(['forge', 'build', '--extra-output', 'storageLayout'], capture_output=True, text=True, env=env, check=True)
    out = subprocess.run(['forge', 'inspect', TARGET, 'storageLayout', '--json'], capture_output=True, text=True,
                         env=env, check=True).stdout
    layout = json.loads(out[out.index('{'):])
    types = layout['types']
    rows = []
    for s in layout['storage']:
        label = types[s['type']]['label']
        rows.append({'label': s['label'], 'slot': int(s['slot']), 'offset': s['offset'],
                     'type': re.sub(r'\)\d+', ')', label)})
    # Struct members, so reordering fields inside a mapped struct (Order) is caught too.
    for t in sorted(types):
        members = types[t].get('members')
        if members:
            name = re.sub(r'\)\d+', ')', types[t]['label']).replace('MarginOrderRegistryV2', 'MarginOrderRegistry')
            for m in members:
                rows.append({'struct': name, 'label': m['label'], 'slot': int(m['slot']), 'offset': m['offset'],
                             'type': re.sub(r'\)\d+', ')', types[m['type']]['label'])})
    return rows


def main():
    rows = current()
    if '--record' in sys.argv:
        SNAPSHOT.write_text(json.dumps(rows, indent=1) + '\n')
        print('recorded', len(rows), 'variables')
        return 0
    old_all = json.loads(SNAPSHOT.read_text())
    old_structs = [r for r in old_all if 'struct' in r]
    new_structs = [r for r in rows if 'struct' in r]
    for name in {r['struct'] for r in old_structs}:
        before = [r for r in old_structs if r['struct'] == name]
        after = [r for r in new_structs if r['struct'] == name]
        if after[:len(before)] != before:
            sys.exit(f'FAIL: struct {name} members changed or reordered')
    old = [r for r in old_all if 'struct' not in r]
    rows = [r for r in rows if 'struct' not in r]
    gap_old, gap_new = old[-1], rows[-1]
    if gap_old['label'] != '__gap' or gap_new['label'] != '__gap':
        sys.exit('FAIL: __gap must stay the last variable')
    kept = old[:-1]
    if rows[:len(kept)] != kept:
        for a, b in zip(kept, rows):
            if a != b:
                sys.exit(f'FAIL: recorded variable changed: {a} -> {b}')
    appended = rows[len(kept):-1]
    size = int(re.search(r'\[(\d+)\]', gap_new['type']).group(1))
    if gap_new['slot'] + size != TOTAL_SLOTS:
        sys.exit(f'FAIL: __gap ends at slot {gap_new["slot"] + size}, expected {TOTAL_SLOTS}')
    print(f'ok: {len(kept)} recorded variables unchanged, {len(appended)} appended, __gap {size} slots from slot {gap_new["slot"]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
