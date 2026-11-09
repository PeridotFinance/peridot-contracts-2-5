#!/usr/bin/env bash
# The keeper's anvil fork test under the shared fork lock (one fork job at a time). Needs the dumped fixture (contracts/range-tp/run-fork.sh
# --match-contract KeeperFixtureDump) and AVALANCHE_MAINNET_RPC_URL in the environment. Exits 42 on any sign of an HTTP 429 / rate limit.
set -u
cd "$(dirname "$0")"
: "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment}"
LOCK=/tmp/pilot-fork.lock
until mkdir "$LOCK" 2>/dev/null; do sleep 20; done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
OUT="${KEEPER_FORK_LOG:-/tmp/range-keeper-fork-last.txt}"
npm run test:fork 2>&1 | tee "$OUT"
status=${PIPESTATUS[0]}
if grep -qiE "(HTTP|status|code|error)[^a-z0-9]{0,4}429|429 too many|rate.?limit|too many requests|compute units" "$OUT"; then
  echo "RATE LIMIT SEEN - stop fork work and report" >&2
  exit 42
fi
exit "$status"
