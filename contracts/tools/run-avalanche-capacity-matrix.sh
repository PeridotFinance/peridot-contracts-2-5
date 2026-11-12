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
N=${#TESTS[@]}; I=0; T0=$(date +%s)
stamp() { date +%H:%M:%S; }
for t in "${TESTS[@]}"; do
  I=$((I+1)); S0=$(date +%s)
  echo "[$(stamp)] START $I/$N $t  (log: $OUT/$t.txt)"
  case "$t" in testFallback_*) CONTRACT=AvalancheFallbackMatrixForkTest ;; *) CONTRACT=AvalancheCapacityMatrixForkTest ;; esac
  # shellcheck disable=SC2086
  FOUNDRY_PROFILE=debt_accounting forge test --threads 1 --gas-limit 9000000000000000000 \
    --match-contract "$CONTRACT" --match-test "$t" -vv \
    --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol ${EXTRA_FORGE_ARGS:-} > "$OUT/$t.txt" 2>&1
  rc=$?
  EL=$(( $(date +%s) - S0 ))
  if [ $rc -ne 0 ] || ! grep -q "^\[PASS\] $t" "$OUT/$t.txt"; then
    echo "[$(stamp)] DONE  $I/$N $t FAILED (forge exit $rc, ${EL}s)" ; echo "FAILED: $t (forge exit $rc)" >> "$OUT/status.txt"; FAILED=1
  else
    echo "[$(stamp)] DONE  $I/$N $t ok (${EL}s)"; echo "ok: $t" >> "$OUT/status.txt"
  fi
done
python3 tools/avalanche-capacity-report.py --strict --status "$OUT/status.txt" "$OUT"/test*.txt > "$OUT/report.md" || FAILED=1
echo "[$(stamp)] all $N tests finished in $(( $(date +%s) - T0 ))s"
echo "report: $OUT/report.md"
if [ "$FAILED" -ne 0 ]; then echo "MATRIX INCOMPLETE OR FAILED" >&2; exit 1; fi
echo "matrix complete"
