#!/usr/bin/env bash
# COLD single-run reproduction of one fork-test suite. EVERY attempt gets a FRESH, EMPTY isolated Foundry home (no RPC cache from any earlier
# attempt, run, proxy or agent; only the solc binaries are linked in) which is removed afterwards. A retry (only for positively identified
# transient RPC failures, see avalanche-repro-classify.py) therefore starts cold again: a home populated across retries is NOT used, so a pass
# here is a pass of one cold run. Per-attempt directory with the full forge log; summary.tsv lists every attempt.
#
# usage: AVALANCHE_MAINNET_RPC_URL=<archive RPC> tools/run-avalanche-suite-cold.sh <name> <contract-regex> <outdir> [max_attempts]
# Test hook: REPRO_COLD_CMD replaces the forge command (it runs with HOME set to the fresh home).
set -uo pipefail
cd "$(dirname "$0")/.."
NAME="$1"; REGEX="$2"; OUT="$3"; MAX="${4:-6}"
: "${AVALANCHE_MAINNET_RPC_URL:=simulated}"; export AVALANCHE_MAINNET_RPC_URL
export COLD_NAME="$NAME" COLD_REGEX="$REGEX"
ATTEMPT_CMD='
set -u
H="$(mktemp -d /tmp/avalanche-cold-home.XXXXXX)"
mkdir -p "$H/.foundry/cache/rpc"
for d in "Library/Application Support/svm" ".svm"; do
  if [ -d "$REAL_HOME/$d" ]; then mkdir -p "$H/$(dirname "$d")"; ln -sfn "$REAL_HOME/$d" "$H/$d"; fi
done
LOG="$REPRO_ATTEMPT_DIR/suite.txt"
RPCHOST="$(echo "$AVALANCHE_MAINNET_RPC_URL" | sed -E "s#^(https?://[^/]+).*#\1#")"
CMD="forge test --threads 1 --gas-limit 9000000000000000000 --match-contract $COLD_REGEX -vv --rpc-url $AVALANCHE_MAINNET_RPC_URL --compute-units-per-second 10 --fork-retries 20 --fork-retry-backoff 2000 --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol"
{
  echo "COLD SINGLE-RUN suite=$COLD_NAME attempt=$REPRO_ATTEMPT"
  echo "UTC start: $(date -u +%FT%TZ)"
  echo "git HEAD: $(git rev-parse HEAD)"
  echo "git status --short (contracts/): $(git status --short . | wc -l | tr -d " ") entries"
  echo "RPC host: $RPCHOST (direct, no proxy)"
  echo "isolated home: $H (fresh; RPC cache entries at start: $(find "$H/.foundry/cache/rpc" -type f | wc -l | tr -d " "))"
  echo "command: HOME=$H $CMD"
  echo "-----"
} > "$LOG"
if [ -n "${REPRO_COLD_CMD:-}" ]; then HOME="$H" bash -c "$REPRO_COLD_CMD" >> "$LOG" 2>&1; rc=$?
else HOME="$H" FOUNDRY_PROFILE=debt_accounting $CMD >> "$LOG" 2>&1; rc=$?; fi
echo "-----" >> "$LOG"; echo "UTC end: $(date -u +%FT%TZ)  exit: $rc" >> "$LOG"
rm -rf "$H"
exit $rc
'
export REAL_HOME="$HOME"
tools/avalanche-repro-retry.sh "$OUT" "$MAX" -- bash -c "$ATTEMPT_CMD"
