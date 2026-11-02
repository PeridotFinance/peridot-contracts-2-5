#!/usr/bin/env bash
# Section 5 launch-gate runner (handoff 09). Tests only: nothing is signed or broadcast.
# Runs, in order: the section 5 fork suite (includes the funded-fallback ACCEPTANCE tests), the funded-fallback mechanism
# suite, and the strict capacity matrix. Collects every result, then exits 1 if ANY component failed or the matrix evidence
# is incomplete. A green exit means the TEST SUITES passed; it does NOT mean the launch gate is open: the matrix verdicts
# (docs/deployment-handoffs/avalanche-capacity-matrix.md) decide whether any cap can be derived.
#
# usage: AVALANCHE_MAINNET_RPC_URL=<archive RPC> contracts/tools/run-avalanche-section5-gate.sh [outdir]
set -uo pipefail
: "${AVALANCHE_MAINNET_RPC_URL:?set AVALANCHE_MAINNET_RPC_URL to an Avalanche C-Chain archive RPC}"
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/avalanche-section5-gate}"
mkdir -p "$OUT"; rm -f "$OUT"/*.txt
FAILED=0
python3 tools/avalanche-capacity-report.test.py > "$OUT/generator-fixtures.txt" 2>&1 && echo "ok: generator fixtures" || { echo "FAILED: generator fixtures"; FAILED=1; }
run_suite() {  # name, regex
  FOUNDRY_PROFILE=debt_accounting forge test --threads 1 --gas-limit 9000000000000000000 --match-contract "$2" -vv \
    --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol ${EXTRA_FORGE_ARGS:-} > "$OUT/$1.txt" 2>&1
  local rc=$?
  if [ $rc -ne 0 ] || ! grep -q "^Suite result: ok" "$OUT/$1.txt"; then echo "FAILED: $1"; FAILED=1; else echo "ok: $1 ($(grep -c '^\[PASS' "$OUT/$1.txt") tests)"; fi
}
run_suite section5 '^AvalanchePharaohSection5ForkTest$'
run_suite funded-fallback '^AvalancheFundedFallbackForkTest$'
tools/run-avalanche-capacity-matrix.sh "$OUT/matrix" > "$OUT/matrix.txt" 2>&1 || { echo "FAILED: capacity matrix (see $OUT/matrix.txt)"; FAILED=1; }
tail -2 "$OUT/matrix.txt"
if [ "$FAILED" -ne 0 ]; then echo "GATE RUN FAILED OR INCOMPLETE" >&2; exit 1; fi
echo "gate suites passed; read $OUT/matrix/report.md for the verdicts"
