#!/usr/bin/env bash
# Reproduce the Avalanche capacity matrix (handoff 09 section 5 / handoff 00 section 4). Tests only: nothing is signed or broadcast.
#
# usage: AVALANCHE_MAINNET_RPC_URL=<archive RPC> contracts/tools/run-avalanche-capacity-matrix.sh [outdir]
# env:   EXTRA_FORGE_ARGS  extra forge arguments (e.g. extra --skip patterns)
#
# Collects every test, then FAILS (exit 1) if any manifest test did not pass or any expected scenario/test output is missing
# (the report generator runs with --strict). Old output files in outdir are removed first so they can never enter a new report.
set -uo pipefail
: "${AVALANCHE_MAINNET_RPC_URL:?set AVALANCHE_MAINNET_RPC_URL to an Avalanche C-Chain archive RPC}"
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/avalanche-capacity-matrix}"
mkdir -p "$OUT"
rm -f "$OUT"/test*.txt "$OUT"/report.md "$OUT"/status.txt
TESTS=()
while IFS= read -r line; do TESTS+=("$line"); done < <(python3 -c "import json;print('\n'.join(json.load(open('tools/avalanche-capacity-manifest.json'))['tests']))")
[ "${#TESTS[@]}" -gt 0 ] || { echo "manifest has no tests" >&2; exit 1; }
FAILED=0
for t in "${TESTS[@]}"; do
  # shellcheck disable=SC2086
  FOUNDRY_PROFILE=debt_accounting forge test --threads 1 --gas-limit 9000000000000000000 \
    --match-contract AvalancheCapacityMatrixForkTest --match-test "$t" -vv \
    --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol ${EXTRA_FORGE_ARGS:-} > "$OUT/$t.txt" 2>&1
  rc=$?
  if [ $rc -ne 0 ] || ! grep -q "^\[PASS\] $t" "$OUT/$t.txt"; then
    echo "FAILED: $t (forge exit $rc)" | tee -a "$OUT/status.txt"; FAILED=1
  else
    echo "ok: $t" | tee -a "$OUT/status.txt"
  fi
done
python3 tools/avalanche-capacity-report.py --strict "$OUT"/test*.txt > "$OUT/report.md" || FAILED=1
echo "report: $OUT/report.md"
if [ "$FAILED" -ne 0 ]; then echo "MATRIX INCOMPLETE OR FAILED" >&2; exit 1; fi
echo "matrix complete"
