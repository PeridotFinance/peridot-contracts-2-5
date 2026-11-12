#!/bin/bash
# Storage-layout compatibility of the risk engine against the FROZEN pre-change copy (test/legacy). Ignores compiler AST ids in type
# names and the contract name; compares (label, slot, offset, type). Exit 1 on any difference.
set -u
cd "$(dirname "$0")/.."
norm() { FOUNDRY_PROFILE=debt_accounting forge inspect "$1" storage-layout --json 2>/dev/null | python3 -c "
import json,re,sys
d=json.load(sys.stdin)
print(re.sub(r'\)\d+(_storage)?',r')\1',re.sub(r'IsolatedMarginRiskEngine(Legacy|Upgradeable)','X',str([(x['label'],x['slot'],x['offset'],x['type']) for x in d['storage']]))))"; }
A="$(norm IsolatedMarginRiskEngineUpgradeable)"; B="$(norm IsolatedMarginRiskEngineLegacy)"
if [ -n "$A" ] && [ "$A" = "$B" ]; then echo "ok: risk engine storage layout identical to the pre-change copy"; else echo "FAILED: risk engine storage layout differs from the pre-change copy"; echo "$A"; echo "$B"; exit 1; fi
