#!/usr/bin/env bash
# Runs the range take-profit FORK tests under the shared fork lock (one fork job at a time on the free-tier endpoint).
#   AVALANCHE_MAINNET_RPC_URL must be in the environment (never printed, never written); RANGE_FORK_BLOCK pins the block.
#   ./run-fork.sh [forge test args...]      e.g.  ./run-fork.sh --match-contract RangeLifecycleForkTest -vv
# On any HTTP 429 / rate-limit message in the output the run is reported and the script exits 42: STOP, do not switch providers.
set -u
cd "$(dirname "$0")"
: "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment}"
export RANGE_FORK_BLOCK="${RANGE_FORK_BLOCK:-99859291}"
LOCK=/tmp/pilot-fork.lock
until mkdir "$LOCK" 2>/dev/null; do sleep 20; done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
OUT="${RANGE_TEST_LOG:-/tmp/range-tp-fork-last.txt}"
forge test --threads 1 "$@" 2>&1 | tee "$OUT"
status=${PIPESTATUS[0]}
if grep -qiE "(HTTP|status|code|error)[^a-z0-9]{0,4}429|429 too many|rate.?limit|too many requests|compute units" "$OUT"; then
  echo "RATE LIMIT SEEN (HTTP 429 or rate-limit text) - stop fork work and report" >&2
  exit 42
fi
exit "$status"
