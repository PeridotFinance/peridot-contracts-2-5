#!/usr/bin/env bash
# Runs the DLMM vault fork tests while holding the shared fork lock /tmp/pilot-fork.lock (one fork job at a time).
# Usage:  AVALANCHE_MAINNET_RPC_URL=<set in your environment, never in a file>  ./run-locked.sh [forge test args, e.g. --match-contract DlmmDepegFork]
# The endpoint is read from the environment only; it is never printed or passed as an argument. Output is redacted of any URL before it is shown.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"
LOCK=/tmp/pilot-fork.lock
LOG="${DLMM_FORK_LOG:-${TMPDIR:-/tmp}/dlmm-fork-run.log}"
STAMPS="${DLMM_FORK_STAMPS:-${TMPDIR:-/tmp}/dlmm-fork-lock-minutes.log}"
: "${DLMM_FORK_BLOCK:=100420249}"   # pinned block (see RUN.md); override with the env var
export DLMM_FORK_BLOCK
export ETH_RPC_URL="${ETH_RPC_URL:-${AVALANCHE_MAINNET_RPC_URL:-}}"
[ -n "$ETH_RPC_URL" ] || { echo "no endpoint in the environment (AVALANCHE_MAINNET_RPC_URL)"; exit 2; }
export AVALANCHE_MAINNET_RPC_URL="$ETH_RPC_URL"

cd "$PROJ" || exit 2
forge build >/dev/null 2>&1 || { echo "forge build failed (compile is done BEFORE taking the lock)"; exit 2; }

HELD=0
release() { if [ "$HELD" = 1 ]; then rmdir "$LOCK" 2>/dev/null; HELD=0; echo "release $(date -u +%FT%TZ) epoch=$(date +%s)" >> "$STAMPS"; fi; }
until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
HELD=1
trap release EXIT INT TERM HUP
echo "acquire $(date -u +%FT%TZ) epoch=$(date +%s)" >> "$STAMPS"

forge test "$@" > "$LOG" 2>&1
RC=$?
release
sed -E 's#https?://[^[:space:]"]+#<url-redacted>#g' "$LOG" > "$LOG.redacted"
cat "$LOG.redacted"
exit $RC
