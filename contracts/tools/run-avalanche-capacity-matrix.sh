#!/usr/bin/env bash
# Reproduce the Avalanche capacity matrix (handoff 09 section 5 / handoff 00 section 4). Tests only: nothing is signed or broadcast.
# usage: AVALANCHE_MAINNET_RPC_URL=<archive RPC> contracts/tools/run-avalanche-capacity-matrix.sh [outdir]
set -euo pipefail
: "${AVALANCHE_MAINNET_RPC_URL:?set AVALANCHE_MAINNET_RPC_URL to an Avalanche C-Chain archive RPC}"
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/avalanche-capacity-matrix}"
mkdir -p "$OUT"
for t in testMatrix_A testMatrix_B testMatrix_C1 testMatrix_C2 testMatrix_C3 testMatrix_C4 testMatrix_C5 testMatrix_D \
         testMatrix_E testMatrix_F1 testMatrix_F2 testMatrix_F3 testMatrix_G testSwapGuard; do
  FOUNDRY_PROFILE=debt_accounting forge test --threads 1 --gas-limit 9000000000000000000 \
    --match-contract AvalancheCapacityMatrixForkTest --match-test "$t" -vv \
    --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol > "$OUT/$t.txt" 2>&1 || true
  echo "$t: $(grep -E '^\[(PASS|FAIL)' "$OUT/$t.txt" | head -1 | cut -c1-110)"
done
python3 tools/avalanche-capacity-report.py "$OUT"/test*.txt > "$OUT/report.md"
echo "report: $OUT/report.md"
