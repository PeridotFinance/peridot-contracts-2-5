#!/usr/bin/env bash
# FORK REHEARSAL wrapper (W8). Runs tools/rehearsal/rehearsal.mjs against a LOCAL anvil fork of Avalanche mainnet, under the SHARED FORK LOCK /tmp/pilot-fork.lock.
#   usage:  AVALANCHE_RPC=<in your shell, never in a file>  [DLMM_FORK_BLOCK=<block>]  tools/rehearsal/rehearsal.sh <out-dir>
# - the endpoint is read from the environment variable AVALANCHE_RPC (fallback AVALANCHE_MAINNET_RPC_URL) and reaches ONLY `anvil --fork-url` (and one `cast block-number`
#   when DLMM_FORK_BLOCK is unset: pin = head - 4); it is never echoed, never written, and the node process, forge, cast and the keeper get a clean environment
#   in which AVALANCHE_MAINNET_RPC_URL / ETH_RPC_URL point at the LOCAL anvil. All output passes through a redaction of http(s) URLs.
# - compile first (no lock), take the lock (mkdir, retry every 30 s), release it in EVERY exit path (trap); lock minutes go to <out-dir>/lock-minutes.log.
# - kills only the anvil and keeper PIDs it started; removes the scratch dir (it holds a throwaway keystore, mode 600).
# - exit 42 on any sign of an HTTP 429 / rate limit that reaches the harness (stop, report, do not switch providers). anvil runs --silent with its output discarded and retries
#   rate limits internally, so a 429 it absorbs is NOT visible here.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; PROJ="$(cd "$HERE/../.." && pwd)"
OUT="${1:?usage: rehearsal.sh <out-dir>}"; mkdir -p "$OUT"
UP="${AVALANCHE_RPC:-${AVALANCHE_MAINNET_RPC_URL:-}}"
[ -n "$UP" ] || { echo "no endpoint in the environment (AVALANCHE_RPC)"; exit 2; }
KEEPER_SRC="${DLMM_KEEPER_DIR:-/Users/joshua/Peridot/.wt-dlmm-keeper/dlmm-keeper}"
LOCK=/tmp/pilot-fork.lock; STAMPS="$OUT/lock-minutes.log"; LOG="$OUT/rehearsal-run.log"; PORT="${REH_PORT:-18545}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dlmm-reh.XXXXXX")"; chmod 700 "$SCRATCH"
REDACT() { sed -E 's#https?://[^[:space:]"]+#<url-redacted>#g'; }

cd "$PROJ" || exit 2
forge build --skip test 2>&1 | REDACT | tail -3
[ -f out/FixedFeed.sol/FixedFeed.json ] || { echo "FixedFeed artifact missing (forge build)"; exit 2; }
cp -R "$KEEPER_SRC" "$SCRATCH/dlmm-keeper" || exit 2   # copy: the keeper checkout stays untouched

HELD=0; APID=""; T0=0
cleanup() {
  [ -n "$APID" ] && kill "$APID" 2>/dev/null
  [ -f "$SCRATCH/keeper.pid" ] && kill "$(cat "$SCRATCH/keeper.pid")" 2>/dev/null
  sleep 1
  rm -rf "$SCRATCH"
  if [ "$HELD" = 1 ]; then rmdir "$LOCK" 2>/dev/null; HELD=0; echo "release $(date -u +%FT%TZ) epoch=$(date +%s) held_seconds=$(( $(date +%s) - T0 ))" >> "$STAMPS"; fi
}
trap cleanup EXIT INT TERM HUP

until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
HELD=1; T0=$(date +%s); echo "acquire $(date -u +%FT%TZ) epoch=$T0" >> "$STAMPS"

PIN="${DLMM_FORK_BLOCK:-}"
if [ -z "$PIN" ]; then
  HEAD="$(ETH_RPC_URL="$UP" cast block-number 2>/dev/null || true)"
  case "$HEAD" in ''|*[!0-9]*) echo "could not read the head block: stopping (check the endpoint; if it is HTTP 429 stop and report)"; exit 3;; esac
  PIN=$((HEAD - 4))
fi
echo "fork pin block: $PIN" | tee "$OUT/pin-block.txt"
anvil --fork-url "$UP" --fork-block-number "$PIN" --block-time 1 --silent --port "$PORT" --host 127.0.0.1 >/dev/null 2>&1 &
APID=$!
export LOCAL_URL="http://127.0.0.1:$PORT"
for i in $(seq 1 90); do ETH_RPC_URL="$LOCAL_URL" cast chain-id >/dev/null 2>&1 && break; sleep 1; done
[ "$(ETH_RPC_URL="$LOCAL_URL" cast chain-id 2>/dev/null)" = 43114 ] || { echo "anvil did not come up with chain id 43114"; exit 3; }
ETH_RPC_URL="$LOCAL_URL" cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "the endpoint is not anvil: refusing"; exit 3; }

env -i PATH="$PATH" HOME="$HOME" REH_KEEPER_DIR="$SCRATCH/dlmm-keeper" REH_PROJ="$PROJ" REH_SCRATCH="$SCRATCH" REH_RPC="$LOCAL_URL" REH_RESULTS="$OUT/results.json" \
  REH_SEED="${REH_SEED:-1000000}" node "$HERE/rehearsal.mjs" 2>&1 | REDACT | tee "$LOG"
RC=${PIPESTATUS[0]}
if grep -qiE "(HTTP|status|code|error)[^a-z0-9]{0,4}429|429 too many|rate.?limit|too many requests|compute units" "$LOG"; then echo "RATE LIMIT SEEN - stop fork work and report" >&2; RC=42; fi
exit "$RC"
