#!/usr/bin/env bash
# COLD single-run reproduction of one fork-test suite. EVERY attempt gets a FRESH, EMPTY isolated Foundry home (no RPC cache from any earlier
# attempt, run, proxy or agent; only the solc binaries are linked in) which is removed afterwards. A retry (only for positively identified
# transient RPC failures, see avalanche-repro-classify.py) therefore starts cold again: a home populated across retries is NOT used, so a pass
# here is a pass of one cold run. Per-attempt directory with the full forge log; summary.tsv lists every attempt.
#
# RPC endpoint (may be a PRIVATE, key-bearing URL): read from the environment ONLY, never from a file or an argument.
#   AVALANCHE_MAINNET_RPC_URL  is the variable the fork suites (vm.envOr) and this runner read;
#   AVALANCHE_RPC             is accepted as an alias (used when the former is unset).
# The URL is NEVER written to a log, header or command line: forge gets only a config ALIAS ("--rpc-url avalanche_cold", the alias being defined
# through FOUNDRY_RPC_ENDPOINTS__avalanche_cold in the environment), the whole forge output passes through tools/avalanche-redact-rpc.py (forge's
# own errors contain the URL), the header says only "private endpoint, masked", and after each attempt the attempt directory is SCANNED for the
# URL, its host and its key-like path/query tokens (a hit is recorded in the log and makes the attempt exit 97).
#
# usage: tools/run-avalanche-suite-cold.sh <name> <contract-regex> <outdir> [max_attempts]
# Optional pacing: COLD_CUPS (client-side compute units per second, default 10), COLD_BACKOFF_MS (default 2000).
# Test hook: REPRO_COLD_CMD replaces the forge command (it runs with HOME set to the fresh home; its output is masked the same way).
set -uo pipefail
cd "$(dirname "$0")/.."
NAME="$1"; REGEX="$2"; OUT="$3"; MAX="${4:-6}"
if [ -z "${AVALANCHE_MAINNET_RPC_URL:-}" ]; then AVALANCHE_MAINNET_RPC_URL="${AVALANCHE_RPC:-simulated}"; fi
export AVALANCHE_MAINNET_RPC_URL
export FOUNDRY_RPC_ENDPOINTS__avalanche_cold="$AVALANCHE_MAINNET_RPC_URL"
unset AVALANCHE_RPC
export COLD_NAME="$NAME" COLD_REGEX="$REGEX" COLD_CUPS="${COLD_CUPS:-10}" COLD_BACKOFF_MS="${COLD_BACKOFF_MS:-2000}"
ATTEMPT_CMD='
set -u
REDACT="python3 -I tools/avalanche-redact-rpc.py"
H="$(mktemp -d /tmp/avalanche-cold-home.XXXXXX)"
mkdir -p "$H/.foundry/cache/rpc"
for d in "Library/Application Support/svm" ".svm"; do
  if [ -d "$REAL_HOME/$d" ]; then mkdir -p "$H/$(dirname "$d")"; ln -sfn "$REAL_HOME/$d" "$H/$d"; fi
done
LOG="$REPRO_ATTEMPT_DIR/suite.txt"
CMD="forge test --threads 1 --gas-limit 9000000000000000000 --match-contract $COLD_REGEX -vv --rpc-url avalanche_cold --compute-units-per-second ${COLD_CUPS:-10} --fork-retries 20 --fork-retry-backoff ${COLD_BACKOFF_MS:-2000} --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol"
{
  echo "COLD SINGLE-RUN suite=$COLD_NAME attempt=$REPRO_ATTEMPT"
  echo "UTC start: $(date -u +%FT%TZ)"
  echo "git HEAD: $(git rev-parse HEAD)"
  echo "git status --short (contracts/): $(git status --short . | wc -l | tr -d " ") entries"
  echo "RPC endpoint: private (URL and host masked; supplied through the environment, direct, no proxy)"
  echo "isolated home: $H (fresh; RPC cache entries at start: $(find "$H/.foundry/cache/rpc" -type f | wc -l | tr -d " "))"
  echo "command: HOME=$H FOUNDRY_PROFILE=debt_accounting $CMD   (endpoint alias resolved from the environment)"
  echo "-----"
} > "$LOG"
if [ -n "${REPRO_COLD_CMD:-}" ]; then HOME="$H" bash -c "$REPRO_COLD_CMD" 2>&1 | $REDACT AVALANCHE_MAINNET_RPC_URL >> "$LOG"; rc=${PIPESTATUS[0]}
else HOME="$H" FOUNDRY_PROFILE=debt_accounting $CMD 2>&1 | $REDACT AVALANCHE_MAINNET_RPC_URL >> "$LOG"; rc=${PIPESTATUS[0]}; fi
echo "-----" >> "$LOG"; echo "UTC end: $(date -u +%FT%TZ)  exit: $rc" >> "$LOG"
rm -rf "$H"
if $REDACT --scan "$REPRO_ATTEMPT_DIR" AVALANCHE_MAINNET_RPC_URL > "$REPRO_ATTEMPT_DIR/mask-scan.txt" 2>&1; then
  echo "mask scan: attempt directory contains no trace of the RPC URL, host or key tokens" >> "$LOG"
else
  echo "mask scan: LEAK DETECTED (see mask-scan.txt for file names; do NOT publish this directory)" >> "$LOG"; exit 97
fi
exit $rc
'
export REAL_HOME="$HOME"
tools/avalanche-repro-retry.sh "$OUT" "$MAX" -- bash -c "$ATTEMPT_CMD"
