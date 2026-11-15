#!/bin/bash
# The Avalanche controller wrapper must add NO linear storage on top of the base Peridottroller (its borrow cash floor lives in a
# namespaced hash slot), so a future base that appends storage cannot collide with it and the proxy layout equals the base layout.
# Compares (label, slot, offset, type) of PeridottrollerAvalanche against Peridottroller from a dedicated build with storage-layout output
# (`forge inspect` cannot compile this repo alone because of the LayerZero sources), ignoring compiler AST ids and contract names.
# The frozen pre-floor wrapper (test/legacy) extends the same base with no state either; the differential/upgrade tests cover it at runtime.
# Exit 1 on any difference.
set -u
cd "$(dirname "$0")/.."
FOUNDRY_PROFILE=debt_accounting forge build --contracts contracts --out out_layout --cache-path cache_layout --extra-output storageLayout \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol > /tmp/controller-layout-build.log 2>&1
norm() { python3 - "$1" <<'PY'
import json,re,sys
d=json.load(open(f"out_layout/{sys.argv[1]}.sol/{sys.argv[1]}.json"))
L=d.get("storageLayout",{}).get("storage")
if not L: print(""); sys.exit(0)
print(re.sub(r'\)\d+(_storage)?',r')\1',re.sub(r'Peridottroller\w*','X',str([(x['label'],x['slot'],x['offset'],x['type']) for x in L]))))
PY
}
A="$(norm PeridottrollerAvalanche)"; B="$(norm Peridottroller)"
if [ -n "$A" ] && [ "$A" = "$B" ]; then echo "ok: PeridottrollerAvalanche adds no linear storage (layout identical to Peridottroller)"; else echo "FAILED: controller storage layout differs or is missing"; echo "avalanche: ${A:0:300}"; echo "base:      ${B:0:300}"; exit 1; fi
