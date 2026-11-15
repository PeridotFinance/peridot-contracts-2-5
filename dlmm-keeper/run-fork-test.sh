#!/usr/bin/env bash
# The keeper's fork test under the SHARED FORK LOCK (one fork job at a time on the shared endpoint). The endpoint comes from AVALANCHE_MAINNET_RPC_URL in the
# environment ONLY (never an argument: the fork harness reaches it through a local pass-through proxy; the block number is read with `cast` using ETH_RPC_URL set in
# the child's environment). Retries the lock every 30 s, releases it on every exit path. Exits 42 on any sign of an HTTP 429 / rate limit (stop, do not switch providers).
# A non-fork local anvil (npm run test:anvil) needs no lock.
set -u
cd "$(dirname "$0")"
: "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment}"
LOCK=/tmp/pilot-fork.lock
until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
OUT="${DLMM_FORK_LOG:-/tmp/dlmm-keeper-fork-last.txt}"
BLOCKFILE="${TMPDIR:-/tmp}/dlmm-keeper-fork-block"
if [ -z "${DLMM_FORK_BLOCK:-}" ]; then
  if [ ! -s "$BLOCKFILE" ]; then
    HEAD="$(ETH_RPC_URL="$AVALANCHE_MAINNET_RPC_URL" cast block-number 2>/dev/null || true)"
    case "$HEAD" in ''|*[!0-9]*) echo "could not read the head block: stopping, no fork job started" >&2; exit 3 ;; *) echo $(( HEAD - 4 )) > "$BLOCKFILE" ;; esac
  fi
  export DLMM_FORK_BLOCK="$(cat "$BLOCKFILE")"
fi
echo "fork pinned at block $DLMM_FORK_BLOCK"
npm run test:fork 2>&1 | tee "$OUT"
status=${PIPESTATUS[0]}
if grep -qiE "(HTTP|status|code|error)[^a-z0-9]{0,4}429|429 too many|rate.?limit|too many requests|compute units" "$OUT"; then
  echo "RATE LIMIT SEEN - stop fork work and report" >&2
  exit 42
fi
exit "$status"
