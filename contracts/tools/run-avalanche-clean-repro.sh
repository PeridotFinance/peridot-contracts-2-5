#!/usr/bin/env bash
# CLEAN reproduction of the Avalanche section 5 gate: an isolated empty Foundry home (empty RPC cache, nothing written by any earlier
# run, proxy or other agent), a single public-or-archive RPC, no substituted values. Tests only: nothing is signed or broadcast.
#
# usage: AVALANCHE_MAINNET_RPC_URL=<archive RPC> contracts/tools/run-avalanche-clean-repro.sh [outdir] [max_attempts]
# Public RPCs rate-limit a cold cache; each attempt fills the isolated cache, so the script retries (default 8) with a pause.
# Success = an attempt where every suite passed AND the matrix evidence is complete (same exit rule as run-avalanche-section5-gate.sh).
set -uo pipefail
: "${AVALANCHE_MAINNET_RPC_URL:?set AVALANCHE_MAINNET_RPC_URL}"
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/avalanche-clean-repro}"; MAX="${2:-8}"
REAL_HOME="$HOME"; CLEAN_HOME="$(mktemp -d /tmp/avalanche-clean-home.XXXXXX)"
mkdir -p "$CLEAN_HOME/.foundry/cache/rpc"
# toolchain only (solc binaries); NOT the RPC cache
for d in "Library/Application Support/svm" ".svm"; do
  if [ -d "$REAL_HOME/$d" ]; then mkdir -p "$CLEAN_HOME/$(dirname "$d")"; ln -sfn "$REAL_HOME/$d" "$CLEAN_HOME/$d"; fi
done
echo "commit: $(git rev-parse HEAD)  (dirty files: $(git status --porcelain | wc -l))"
echo "clean home: $CLEAN_HOME  (RPC cache starts empty)"
rc=1
for i in $(seq 1 "$MAX"); do
  echo "=== attempt $i/$MAX $(date +%T) ==="
  HOME="$CLEAN_HOME" tools/run-avalanche-section5-gate.sh "$OUT"; rc=$?
  [ $rc -eq 0 ] && { echo "CLEAN REPRODUCTION PASSED on attempt $i"; break; }
  [ "$i" -lt "$MAX" ] && sleep 120
done
exit $rc
