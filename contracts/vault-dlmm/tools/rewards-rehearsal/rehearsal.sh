#!/usr/bin/env bash
# FORK REHEARSAL of ONE FULL EPOCH of the PHAR distribution (design A), run by the OPERATOR (an agent has no endpoint and never runs it). Wrapper around rehearsal.mjs, modelled on
# tools/rehearsal/rehearsal.sh of the vault rehearsal (same lock, same proxy, same argv check, same exit 42 on a 429).
#
#   usage:  AVALANCHE_RPC=<in your shell, never in a file>  REH_SCAN_FROM=<vault deployment block>  [DLMM_FORK_BLOCK=<block>]  tools/rewards-rehearsal/rehearsal.sh <out-dir>
#           REH_SCAN_FROM=<block>  tools/rewards-rehearsal/rehearsal.sh --dry [<out-dir>]          (checks the INPUTS only: no endpoint, no chain, no lock, no anvil)
#   run from contracts/vault-dlmm (or anywhere: the script finds its own project).
#
# Scenario (rehearsal.mjs): a local anvil fork of the LIVE chain at head-4 with the REAL vault and the REAL Safe (the Ledger impersonated, SEND_MODE=unlocked of the integration tools);
# shares moved to an EOA and to a contract; 1 day of chain time; harvestRewards through the Safe; the generator (tools/dlmm-rewards-root.mjs, --local-rpc = the live RpcSource path)
# twice; a fresh throwaway deployer deploys the distributor; Safe approve + publishEpoch with the manifest's exact arguments; claims refused in the 24 h window; a second epoch
# published and cancelled; +24 h +1 s; claims, double claim, exclusions; sweep refused, +180 days, sweep. Prints PASS / FAIL lines, a final RESULTS json and one verdict line.
#
# - the endpoint is read from AVALANCHE_RPC (fallback AVALANCHE_MAINNET_RPC_URL). It is NEVER in an argument vector: a local pass-through proxy (rpc-proxy.mjs, upstream from ITS
#   environment only) is the only holder, and anvil's --fork-url is the proxy's 127.0.0.1 address. The proxy counts the upstream HTTP status codes (a 429 that anvil's own retries
#   would hide is visible in <out-dir>/upstream-status.json). The node process, forge, cast and the generator get a clean environment in which every RPC variable points at the LOCAL
#   anvil. All output passes through a redaction of http(s) URLs.
# - ARGV CHECK: after anvil is up the wrapper counts the processes of this machine whose argument vector contains the exact upstream string (grep -F with the pattern read from a file
#   descriptor, so the check does not put it in its own argv) and aborts unless the count is 0; the count is printed, the string never is.
# - compile first (no lock), take the SHARED FORK LOCK /tmp/pilot-fork.lock (mkdir, retry every 30 s), release it in EVERY exit path (trap); lock minutes go to <out-dir>/lock-minutes.log.
# - kills only the anvil and proxy PIDs it started; removes the throwaway scratch dir (it holds the scan caches and the epoch folders of the rehearsal: NOT publishable, never committed).
#
# EXIT CODES:  0 = REHEARSAL PASSED (every check PASS)   1 = the scenario ran to the end and at least one FAIL line was printed   2 = a fatal error or a bad input (see the last lines)
#              3 = the sandbox refused (anvil/proxy did not come up, not chain 43114, the argv check found the endpoint)   42 = a 429 / rate limit was seen: STOP and report, do not switch
#              provider   43 = the fork harvest paid 0 PHAR (nothing accrued in the warped day): the scenario cannot continue; REH_WARP_SECONDS=172800 and run again
#              (--dry: 0 = inputs fine, 2 = something is missing)
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; PROJ="$(cd "$HERE/../.." && pwd)"
REDACT() { sed -E 's#https?://[^[:space:]"]+#<url-redacted>#g'; }
DRY=0; if [ "${1:-}" = "--dry" ]; then DRY=1; shift; fi
OUT="${1:-}"
if [ "$DRY" = 0 ]; then [ -n "$OUT" ] || { echo "usage: rehearsal.sh <out-dir>   |   rehearsal.sh --dry [<out-dir>]"; exit 2; }; mkdir -p "$OUT"; fi
INT_TOOLS="${REH_INT_TOOLS:-/Users/joshua/Peridot/.wt-dlmm-int/contracts/vault-dlmm/tools}"
EXPECT_FIRST_START=100488395

# ---------------------------------------------------------------------------------------------------------------------------- inputs (the --dry mode checks exactly these)
problems=0
bad() { echo "INPUT PROBLEM: $*"; problems=$((problems + 1)); }
need_tool() { command -v "$1" >/dev/null 2>&1 || bad "tool not found on PATH: $1"; }
for t in anvil forge cast node curl bc python3 mktemp; do need_tool "$t"; done
case "${REH_SCAN_FROM:-}" in
  ''|*[!0-9]*) bad "REH_SCAN_FROM is not set to an integer: the vault's DEPLOYMENT block (it must be at or before its first share mint; the generator aborts with 'negative balance' otherwise)" ;;
  *) if [ "$REH_SCAN_FROM" -gt "$EXPECT_FIRST_START" ] || [ "$REH_SCAN_FROM" -lt 100000000 ]; then bad "REH_SCAN_FROM=$REH_SCAN_FROM is outside 100000000 .. $EXPECT_FIRST_START (the first epoch starts at block $EXPECT_FIRST_START)"; fi ;;
esac
[ -f "$PROJ/tools/dlmm-rewards-root.mjs" ] || bad "tools/dlmm-rewards-root.mjs not found in $PROJ"
for f in rehearsal.mjs rpc-proxy.mjs; do [ -f "$HERE/$f" ] || bad "missing $HERE/$f"; done
for f in dlmm-rewards-ceremony.sh dlmm-rewards-safe-call.sh; do [ -f "$PROJ/tools/$f" ] || bad "missing $PROJ/tools/$f"; bash -n "$PROJ/tools/$f" 2>/dev/null || bad "bash -n fails on tools/$f"; done
for f in dlmm-safe-call.sh dlmm-harvest.sh; do [ -f "$INT_TOOLS/$f" ] || bad "missing integration tool $INT_TOOLS/$f (REH_INT_TOOLS)"; bash -n "$INT_TOOLS/$f" 2>/dev/null || bad "bash -n fails on $INT_TOOLS/$f"; done
[ -f "$PROJ/script/DeployPharRewardsDistributor.s.sol" ] || bad "script/DeployPharRewardsDistributor.s.sol missing"
# ethers v5: ETHERS_DIR, else the keeper checkouts next to this one
ETHERS="${ETHERS_DIR:-}"
if [ -z "$ETHERS" ]; then for c in "$PROJ/../../dlmm-keeper/node_modules/ethers" "/Users/joshua/Peridot/.wt-dlmm-keeper/dlmm-keeper/node_modules/ethers"; do [ -d "$c" ] && { ETHERS="$c"; break; }; done; fi
if [ -z "$ETHERS" ] || ! node -e "const e=require(process.argv[1]); const v=(e.ethers||e).version; if(!/^ethers\//.test(v)) process.exit(1)" "$ETHERS" 2>/dev/null; then bad "ethers v5 not found: run 'npm ci' in dlmm-keeper/ or set ETHERS_DIR=<...>/node_modules/ethers"; fi
if [ "$DRY" = 1 ]; then
  [ -n "${AVALANCHE_RPC:-${AVALANCHE_MAINNET_RPC_URL:-}}" ] && echo "endpoint: present in the environment (not used, not printed)" || echo "endpoint: not set (not needed for --dry; needed for the real run)"
  [ -n "$(ls "$PROJ"/lib 2>/dev/null)" ] || bad "lib/ (forge-std, openzeppelin) missing in $PROJ"
  if [ "$problems" = 0 ]; then
    if ! ( cd "$PROJ" && forge build --skip test 2>&1 | REDACT | tail -3 ); then bad "forge build failed"; fi
    [ -f "$PROJ/out/FixedFeed.sol/FixedFeed.json" ] || bad "out/FixedFeed.sol/FixedFeed.json missing after forge build (the contract-holder stand-in)"
    [ -f "$PROJ/out/PharRewardsDistributor.sol/PharRewardsDistributor.json" ] || bad "out/PharRewardsDistributor.sol/PharRewardsDistributor.json missing after forge build"
    node --check "$HERE/rehearsal.mjs" 2>/dev/null || bad "node --check rehearsal.mjs fails"
    node --check "$HERE/rpc-proxy.mjs" 2>/dev/null || bad "node --check rpc-proxy.mjs fails"
    ETHERS_DIR="$ETHERS" node "$PROJ/tools/dlmm-rewards-root.mjs" --help >/dev/null 2>&1 || bad "the generator does not start (node tools/dlmm-rewards-root.mjs --help)"
  fi
  if [ "$problems" = 0 ]; then echo "DRY: all inputs OK (scan-from $REH_SCAN_FROM, ethers resolved, tools present and syntax-checked, forge build passes). Nothing was run against any chain."; exit 0; fi
  echo "DRY: $problems input problem(s): fix them and run --dry again"; exit 2
fi
UP="${AVALANCHE_RPC:-${AVALANCHE_MAINNET_RPC_URL:-}}"
[ -n "$UP" ] || bad "no endpoint in the environment (AVALANCHE_RPC)"
if [ "$problems" != 0 ]; then echo "$problems input problem(s): nothing was started (run with --dry to check the inputs without an endpoint)"; exit 2; fi

# ---------------------------------------------------------------------------------------------------------------------------- the sandbox
LOCK=/tmp/pilot-fork.lock; STAMPS="$OUT/lock-minutes.log"; LOG="$OUT/rehearsal-run.log"; PORT="${REH_PORT:-18545}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dlmm-rewards-reh.XXXXXX")"; chmod 700 "$SCRATCH"

cd "$PROJ" || exit 2
forge build --skip test 2>&1 | REDACT | tail -3
[ -f out/FixedFeed.sol/FixedFeed.json ] || { echo "FixedFeed artifact missing (forge build)"; rm -rf "$SCRATCH"; exit 2; }
[ -f out/PharRewardsDistributor.sol/PharRewardsDistributor.json ] || { echo "PharRewardsDistributor artifact missing (forge build)"; rm -rf "$SCRATCH"; exit 2; }

HELD=0; APID=""; PPID_X=""; T0=0
cleanup() {
  [ -n "$APID" ] && kill "$APID" 2>/dev/null
  [ -n "$PPID_X" ] && kill "$PPID_X" 2>/dev/null
  sleep 1
  rm -rf "$SCRATCH"
  if [ "$HELD" = 1 ]; then rmdir "$LOCK" 2>/dev/null; HELD=0; echo "release $(date -u +%FT%TZ) epoch=$(date +%s) held_seconds=$(( $(date +%s) - T0 ))" >> "$STAMPS"; fi
}
trap cleanup EXIT INT TERM HUP

until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
HELD=1; T0=$(date +%s); echo "acquire $(date -u +%FT%TZ) epoch=$T0" >> "$STAMPS"

# the proxy holds the upstream in ITS ENVIRONMENT only
PPORT="${REH_PROXY_PORT:-18547}"
REH_UPSTREAM="$UP" REH_PROXY_PORT="$PPORT" REH_PROXY_STATS="$OUT/upstream-status.json" node "$HERE/rpc-proxy.mjs" >/dev/null 2>&1 &
PPID_X=$!
PROXY_URL="http://127.0.0.1:$PPORT"
for i in $(seq 1 20); do (exec 3<>"/dev/tcp/127.0.0.1/$PPORT") 2>/dev/null && break; sleep 0.5; done
PIN="${DLMM_FORK_BLOCK:-}"
if [ -z "$PIN" ]; then
  HEAD="$(cast block-number --rpc-url "$PROXY_URL" 2>/dev/null || true)"
  case "$HEAD" in ''|*[!0-9]*) echo "could not read the head block through the proxy: stopping (if the upstream says HTTP 429 stop and report)"; exit 3;; esac
  PIN=$((HEAD - 4))
fi
echo "fork pin block: $PIN" | tee "$OUT/pin-block.txt"
anvil --fork-url "$PROXY_URL" --fork-block-number "$PIN" --block-time 1 --silent --port "$PORT" --host 127.0.0.1 >/dev/null 2>&1 &
APID=$!
export LOCAL_URL="http://127.0.0.1:$PORT"
for i in $(seq 1 90); do ETH_RPC_URL="$LOCAL_URL" cast chain-id >/dev/null 2>&1 && break; sleep 1; done
[ "$(ETH_RPC_URL="$LOCAL_URL" cast chain-id 2>/dev/null)" = 43114 ] || { echo "anvil did not come up with chain id 43114"; exit 3; }
ETH_RPC_URL="$LOCAL_URL" cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "the endpoint is not anvil: refusing"; exit 3; }
# ARGV CHECK (see the header): how many processes carry the exact upstream string in their argument vector? must be 0
NURL="$(ps -axo command= | grep -cF -f <(printf '%s' "$UP") || true)"
NPROC="$(ps -axo command= | wc -l | tr -d ' ')"
echo "argv check: $NURL of $NPROC processes carry the upstream endpoint in their argument vector (must be 0); anvil argv has a URL: $(ps -o command= -p "$APID" | grep -cE 'https?://' | tr -d ' ') (the proxy's 127.0.0.1 address only: $(ps -o command= -p "$APID" | grep -c '127.0.0.1:'))" | tee -a "$OUT/argv-check.txt"
[ "$NURL" = 0 ] || { echo "ARGV CHECK FAILED: stopping"; exit 3; }

env -i PATH="$PATH" HOME="$HOME" ETHERS_DIR="$ETHERS" REH_PROJ="$PROJ" REH_SCRATCH="$SCRATCH" REH_RPC="$LOCAL_URL" REH_RESULTS="$OUT/results.json" REH_INT_TOOLS="$INT_TOOLS" \
  REH_SCAN_FROM="$REH_SCAN_FROM" REH_WARP_SECONDS="${REH_WARP_SECONDS:-86400}" REH_CHUNK="${REH_CHUNK:-100}" REH_SLEEP_MS="${REH_SLEEP_MS:-0}" REH_KEEP_EPOCH_DIR="${REH_KEEP_EPOCH_DIR:-}" REH_EPOCH_OUT="$OUT" \
  node "$HERE/rehearsal.mjs" 2>&1 | REDACT | tee "$LOG"
RC=${PIPESTATUS[0]}
kill "$PPID_X" 2>/dev/null; sleep 1; PPID_X=""   # SIGTERM makes the proxy write its status counts
echo "upstream HTTP status counts seen by the proxy: $(cat "$OUT/upstream-status.json" 2>/dev/null)" | tee -a "$LOG"
if grep -qE '"429"' "$OUT/upstream-status.json" 2>/dev/null || grep -qiE "(HTTP|status|code|error)[^a-z0-9]{0,4}429|429 too many|rate.?limit|too many requests|compute units" "$LOG"; then echo "RATE LIMIT SEEN - stop fork work and report" >&2; RC=42; fi
exit "$RC"
