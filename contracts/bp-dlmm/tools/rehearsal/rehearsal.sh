#!/usr/bin/env bash
# FORK REHEARSAL of the bpPHAR-USDC listing on the LIVE Avalanche pilot, on a LOCAL anvil fork of Avalanche mainnet at head-4, under the SHARED FORK LOCK /tmp/pilot-fork.lock.
# THE ASSISTANT HAS NOT RUN THIS (it has no endpoint): the user runs it.
#   usage:  AVALANCHE_RPC=<in your shell, never in a file>  [BP_OUT=<forge out dir>]  [BP_FORK_BLOCK=<block>]  contracts/bp-dlmm/tools/rehearsal/rehearsal.sh <out-dir>
#           DRY=1 contracts/bp-dlmm/tools/rehearsal/rehearsal.sh <out-dir>     (no endpoint, no fork, no lock: static checks only; see README.md)
# Same discipline as the range-tp and DLMM-vault rehearsals:
# - the endpoint is read from the environment (AVALANCHE_RPC, fallback AVALANCHE_MAINNET_RPC_URL) and is NEVER in an argument vector: a local pass-through proxy (rpc-proxy.mjs, upstream in ITS
#   environment only) is the only holder; anvil's --fork-url is the proxy's 127.0.0.1 address. The proxy counts upstream HTTP status codes (<out-dir>/upstream-status.json). node, forge and cast get a clean
#   environment in which every endpoint variable names the LOCAL anvil. All output passes through a redaction of http(s) URLs.
# - ARGV CHECK after anvil is up: the number of processes whose argument vector contains the exact upstream string (grep -F, pattern read from a file descriptor) must be 0.
# - INSTANT MINING (no --block-time): a block per transaction; the harness pins timestamps (1 s per block) and warps explicitly. 50 % gas headroom on every harness transaction (lib.mjs).
# - the lock is taken with mkdir (retry every 30 s) and released in EVERY exit path; lock minutes go to <out-dir>/lock-minutes.log. The lock path can be overridden with REH_LOCK (the self-test does).
# - kills only the anvil and proxy PIDs it started; removes the scratch dir.
# - exit codes: 0 every check PASSED; 1 at least one check FAILED (see results.json); 2 usage / no endpoint / missing artifacts; 3 the fork did not come up or the argv check failed;
#   42 a 429 / rate limit was seen (STOP, report, do not switch providers).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; PROJ="$(cd "$HERE/../.." && pwd)"; REPO="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || (cd "$PROJ/../.." && pwd))"
OUT="${1:?usage: rehearsal.sh <out-dir>}"; mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
DRY="${DRY:-0}"; SELFTEST="${REH_SELFTEST:-0}"
REDACT() { sed -E 's#https?://[^[:space:]"]+#<url-redacted>#g'; }
REDACT_LIVE() { awk '{ gsub(/https?:\/\/[^ \t"]+/, "<url-redacted>"); print; fflush() }'; }   # line-buffered (BSD sed buffers 4 KB blocks to a pipe: run 1's log stayed empty)

# ---- 1. ONE TREE: the harness, the ceremony tool, its pin file and the forge artifacts come from THIS checkout (run 2 = the v2 wrapper). Nothing falls back to another worktree: BP_OUT / BP_TOOL must be set explicitly to use a foreign one.
CONTRACTS="$(cd "$PROJ/.." && pwd)"   # <repo>/contracts (PROJ = contracts/bp-dlmm)
if [ -z "${BP_OUT:-}" ]; then BP_OUT="$CONTRACTS/out_bpdlmm"; fi   # the CEREMONY build ('tools/bp-dlmm-ceremony.sh pin rehearsal' writes it: profile debt_accounting, the one the pin hashes)
export BP_OUT
if [ -z "${BP_TOOL:-}" ]; then BP_TOOL="$CONTRACTS/tools/bp-dlmm-ceremony.sh"; fi
[ -f "$BP_TOOL" ] || BP_TOOL=""
BP_USE_TOOL="${BP_USE_TOOL:-auto}"; export BP_TOOL BP_USE_TOOL
WRAPPER="${BP_WRAPPER_NAME:-PharaohDlmmShareOracle}"; DELEGATE="${BP_DELEGATE_NAME:-PharaohBoostedDelegate}"
if [ "${BP_BUILD:-0}" = 1 ]; then ( cd "$(dirname "$BP_OUT")" && forge build --skip test 2>&1 | REDACT | tail -3 ); fi
if [ "$SELFTEST" != 1 ]; then
  for n in PErc20Delegator "$WRAPPER" "$DELEGATE"; do
    [ -f "$BP_OUT/$n.sol/$n.json" ] || { echo "artifact $BP_OUT/$n.sol/$n.json missing: run 'tools/bp-dlmm-ceremony.sh pin rehearsal' in $CONTRACTS (it builds out_bpdlmm), or set BP_OUT"; exit 2; }
  done
fi
# the PHAR step (REH_WRAPPER, DEFAULT ON in run 2; REH_WRAPPER=0 skips it and everything it needs)
REH_WRAPPER="${REH_WRAPPER:-1}"; export REH_WRAPPER
REWARDS_PROJ="${REH_REWARDS_PROJ:-/Users/joshua/Peridot/.wt-bp-rewards/contracts/vault-dlmm}"   # branch feat/dlmm-rewards-boosted (READ ONLY: the generator and the distributor deploy / Safe tools are run from there, build outputs go to a scratch dir)
INT_TOOLS="${REH_INT_TOOLS:-/Users/joshua/Peridot/.wt-dlmm-int/contracts/vault-dlmm/tools}"                  # dlmm-harvest.sh + dlmm-safe-call.sh (the harvest through the Safe)
ETHERS=""
COMMON="$(cd "$(git -C "$HERE" rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd || echo "$REPO")"
for d in "${BP_ETHERS_DIR:-}" "$REPO/operator" "$REPO/order-keeper" "$REPO/range-tp-keeper" "$COMMON/operator" "$COMMON/order-keeper" "$COMMON/range-tp-keeper"; do
  [ -n "$d" ] && [ -f "$d/node_modules/ethers/package.json" ] && grep -q '"version": "5\.' "$d/node_modules/ethers/package.json" && { ETHERS="$d"; break; }
done
[ -n "$ETHERS" ] || { echo "no ethers v5 found (looked in operator, order-keeper, range-tp-keeper of $REPO and $COMMON): run 'cd $REPO/operator && npm ci' or set BP_ETHERS_DIR"; exit 2; }
export REH_ETHERS_DIR="$ETHERS"
for f in lib.mjs rehearsal.mjs outage.mjs phar.mjs readback.mjs rpc-proxy.mjs selftest/selftest.mjs; do node --check "$HERE/$f" || { echo "syntax error in $f"; exit 2; }; done

# ---- PRE-LOCK GUARDS (exit 2 before any endpoint, lock or fork is touched). They exist because run 1 used the v1 wrapper and a stale tree is the easiest mistake to make.
GUARD_PROBLEMS=0
gbad() { echo "GUARD: $*"; GUARD_PROBLEMS=$((GUARD_PROBLEMS + 1)); }
if [ "$SELFTEST" != 1 ] && [ "$BP_USE_TOOL" != 0 ]; then
  WANT_RUNTIME="${BP_WRAPPER_RUNTIME:-3472}"   # the v2 wrapper's runtime size (BRIEF-v2)
  if [ -z "$BP_TOOL" ]; then gbad "no ceremony tool (expected $CONTRACTS/tools/bp-dlmm-ceremony.sh)"; else
    case "$(cd "$(dirname "$BP_TOOL")" && pwd)/" in "$CONTRACTS"/*) ;; *) [ "${BP_ALLOW_FOREIGN_TREE:-0}" = 1 ] || gbad "the ceremony tool $BP_TOOL is not inside THIS tree ($CONTRACTS): run 2 must use one tree (BP_ALLOW_FOREIGN_TREE=1 to override)";; esac
    PIN="$(cd "$(dirname "$BP_TOOL")/.." && pwd)/ceremony/bp-dlmm-pin.json"
    if [ ! -f "$PIN" ]; then gbad "no pin file $PIN: run 'tools/bp-dlmm-ceremony.sh pin rehearsal' in $CONTRACTS first (it also builds out_bpdlmm)"; else
      PSIZE="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["sizes"]["oracle"])' "$PIN" 2>/dev/null || echo "?")"
      [ "$PSIZE" = "$WANT_RUNTIME" ] || gbad "the pin says the wrapper runtime is $PSIZE bytes, not $WANT_RUNTIME (BP_WRAPPER_RUNTIME): the pin is for another wrapper version; re-pin in $CONTRACTS"
      PSHA="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["sourcesSha256"])' "$PIN" 2>/dev/null || echo "?")"
      CSHA="$( cd "$(dirname "$BP_TOOL")/.." && { find contracts -name '*.sol' -type f; echo script/DeployPharaohBoostedMarketsAvalanche.s.sol; echo foundry.toml; } | sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1 )"
      [ "$PSHA" = "$CSHA" ] || gbad "the pin's sources sha256 ($PSHA) is not the sources of this tree now ($CSHA): re-pin ('tools/bp-dlmm-ceremony.sh pin rehearsal') after any source change"
    fi
  fi
  python3 -I - "$BP_OUT/$WRAPPER.sol/$WRAPPER.json" <<'PYEOF' || gbad "the wrapper artifact in BP_OUT is not the v2 wrapper (no poke()/shareState() in its ABI) or is unreadable"
import json, sys
names = {x.get("name") for x in json.load(open(sys.argv[1]))["abi"] if x.get("type") == "function"}
sys.exit(0 if {"poke", "shareState", "lastGoodAssetsPerShare", "lastGoodTime", "FALLBACK_WINDOW"} <= names else 1)
PYEOF
fi
if [ "$REH_WRAPPER" != 0 ]; then
  [ -f "$REWARDS_PROJ/tools/dlmm-rewards-root.mjs" ] || gbad "REH_WRAPPER is on but the PHAR generator is missing: $REWARDS_PROJ/tools/dlmm-rewards-root.mjs (REH_REWARDS_PROJ; REH_WRAPPER=0 skips the PHAR step)"
  for f in dlmm-rewards-ceremony.sh dlmm-rewards-safe-call.sh; do [ -f "$REWARDS_PROJ/tools/$f" ] && bash -n "$REWARDS_PROJ/tools/$f" 2>/dev/null || gbad "REH_WRAPPER: $REWARDS_PROJ/tools/$f missing or fails bash -n"; done
  [ -f "$REWARDS_PROJ/script/DeployPharRewardsDistributor.s.sol" ] || gbad "REH_WRAPPER: $REWARDS_PROJ/script/DeployPharRewardsDistributor.s.sol missing"
  [ -n "$(ls "$REWARDS_PROJ"/lib 2>/dev/null)" ] || gbad "REH_WRAPPER: $REWARDS_PROJ/lib (forge-std, openzeppelin) missing"
  for f in dlmm-harvest.sh dlmm-safe-call.sh; do [ -f "$INT_TOOLS/$f" ] && bash -n "$INT_TOOLS/$f" 2>/dev/null || gbad "REH_WRAPPER: $INT_TOOLS/$f missing or fails bash -n (REH_INT_TOOLS)"; done
  case "${REH_SCAN_FROM:-}" in
    ''|*[!0-9]*) if [ "$DRY" = 1 ]; then echo "DRY WARN: REH_SCAN_FROM is not set: the REAL run refuses to start without it (the vault's DEPLOYMENT block, at or before its first share mint; not recorded anywhere), or set REH_WRAPPER=0"; else gbad "REH_SCAN_FROM is not set to an integer: the vault's DEPLOYMENT block (the PHAR step scans the vault's logs from it); or run with REH_WRAPPER=0"; fi ;;
    *) { [ "$REH_SCAN_FROM" -gt 100488395 ] || [ "$REH_SCAN_FROM" -lt 100000000 ]; } && gbad "REH_SCAN_FROM=$REH_SCAN_FROM is outside 100000000 .. 100488395 (the first epoch starts at block 100488395)";;
  esac
  case "${REH_CHUNK:-100}${REH_SLEEP_MS:-0}${REH_WARP_SECONDS:-86400}" in *[!0-9]*) gbad "REH_CHUNK / REH_SLEEP_MS / REH_WARP_SECONDS must be integers";; esac
fi
[ "$GUARD_PROBLEMS" = 0 ] || { echo "$GUARD_PROBLEMS pre-lock guard problem(s): nothing was started"; exit 2; }

# ---- DRY mode: everything that needs no chain
if [ "$DRY" = 1 ]; then
  echo "DRY: tree $CONTRACTS, ceremony tool ${BP_TOOL:-none}, pin file $(cd "$(dirname "${BP_TOOL:-$CONTRACTS/tools/x}")/.." 2>/dev/null && pwd)/ceremony/bp-dlmm-pin.json"
  echo "DRY: PHAR step REH_WRAPPER=$REH_WRAPPER (rewards project $REWARDS_PROJ @ $(git -C "$REWARDS_PROJ" rev-parse --short HEAD 2>/dev/null || echo unknown), harvest tools $INT_TOOLS, REH_SCAN_FROM=${REH_SCAN_FROM:-unset})"
  echo "DRY: out dir $OUT, artifacts $BP_OUT, ethers $ETHERS (version $(grep -m1 '"version"' "$ETHERS/node_modules/ethers/package.json" | tr -d ' ,"' ))"
  for t in anvil cast forge node; do command -v "$t" >/dev/null && echo "DRY ok   $t: $($t --version 2>&1 | head -1)" || echo "DRY FAIL $t not found"; done
  REH_RPC="http://127.0.0.1:1" REH_RESULTS="$OUT/dry-results.json" REH_REWARDS_PROJ="$REWARDS_PROJ" REH_INT_TOOLS="$INT_TOOLS" node "$HERE/rehearsal.mjs" --dry 2>&1 | REDACT; RC=${PIPESTATUS[0]}
  [ "$RC" = 0 ] && echo "DRY PASSED (nothing was forked, no lock taken, no endpoint used)" || echo "DRY FAILED"
  exit "$RC"
fi

# ---- 2. the endpoint (real run) or the fake upstream (self-test)
UP="${AVALANCHE_RPC:-${AVALANCHE_MAINNET_RPC_URL:-}}"
[ -n "$UP" ] || { echo "no endpoint in the environment (AVALANCHE_RPC)"; exit 2; }
LOCK="${REH_LOCK:-/tmp/pilot-fork.lock}"; STAMPS="$OUT/lock-minutes.log"; LOG="$OUT/rehearsal-run.log"; PORT="${REH_PORT:-18545}"; PPORT="${REH_PROXY_PORT:-18547}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bp-reh.XXXXXX")"; chmod 700 "$SCRATCH"
HELD=0; APID=""; PPID_X=""; T0=0
rate_limited() {
  grep -qE '"429"' "$OUT/upstream-status.json" 2>/dev/null && return 0
  [ -f "$LOG" ] && grep -qiE "(HTTP|status|code|error)[^a-z0-9]{0,4}429|429 too many|rate.?limit|too many requests|compute units" "$LOG" && return 0
  return 1
}
cleanup() {
  [ -n "$APID" ] && kill "$APID" 2>/dev/null
  [ -n "$PPID_X" ] && kill "$PPID_X" 2>/dev/null
  sleep 1
  rm -rf "$SCRATCH"
  if [ "$HELD" = 1 ]; then rmdir "$LOCK" 2>/dev/null; HELD=0; echo "release $(date -u +%FT%TZ) epoch=$(date +%s) held_seconds=$(( $(date +%s) - T0 ))" >> "$STAMPS"; fi
}
trap cleanup EXIT; trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP   # a signal must END the script (a trap handler alone would resume it); the EXIT trap releases the lock
if [ "$REH_WRAPPER" != 0 ] && [ "$SELFTEST" != 1 ]; then
  # compile the rewards project (the distributor deploy script) BEFORE the lock, into scratch dirs: the other worktree is not written to, and the deploy step inside the lock finds a warm cache. Clean environment: no endpoint variable reaches forge.
  mkdir -p "$SCRATCH/forge-out" "$SCRATCH/forge-cache"
  ( cd "$REWARDS_PROJ" && env -i PATH="$PATH" HOME="$HOME" FOUNDRY_DISABLE_NIGHTLY_WARNING=1 FOUNDRY_OUT="$SCRATCH/forge-out" FOUNDRY_CACHE_PATH="$SCRATCH/forge-cache" forge build --skip test 2>&1 | REDACT | tail -3 )
  [ -f "$SCRATCH/forge-out/PharRewardsDistributor.sol/PharRewardsDistributor.json" ] || { echo "forge build of the rewards project failed (no PharRewardsDistributor artifact): nothing was started; REH_WRAPPER=0 skips the PHAR step"; exit 2; }
fi
if [ "$SELFTEST" = 1 ]; then "$HERE/selftest/build-fixtures.sh" "$SCRATCH/fixtures" >/dev/null || { echo "fixture build failed"; exit 2; }; export REH_FIXTURE_OUT="$SCRATCH/fixtures"; fi

until mkdir "$LOCK" 2>/dev/null; do sleep 30; done
HELD=1; T0=$(date +%s); echo "acquire $(date -u +%FT%TZ) epoch=$T0" >> "$STAMPS"

REH_UPSTREAM="$UP" REH_PROXY_PORT="$PPORT" REH_PROXY_STATS="$OUT/upstream-status.json" node "$HERE/rpc-proxy.mjs" >/dev/null 2>&1 &
PPID_X=$!
PROXY_URL="http://127.0.0.1:$PPORT"
for i in $(seq 1 20); do (exec 3<>"/dev/tcp/127.0.0.1/$PPORT") 2>/dev/null && break; sleep 0.5; done
PIN="${BP_FORK_BLOCK:-}"
if [ -z "$PIN" ]; then
  HEAD="$(cast block-number --rpc-url "$PROXY_URL" 2>/dev/null || true)"
  case "$HEAD" in ''|*[!0-9]*)
    kill "$PPID_X" 2>/dev/null; sleep 1; PPID_X=""   # SIGTERM makes the proxy write its status counts
    if rate_limited; then echo "RATE LIMIT SEEN (HTTP 429) while reading the head block - stop fork work and report" >&2; exit 42; fi
    echo "could not read the head block through the proxy: stopping (if the upstream says HTTP 429 stop and report)"; exit 3;;
  esac
  PIN=$((HEAD - 4))
fi
echo "fork pin block: $PIN" | tee "$OUT/pin-block.txt"
CHAIN_ID_WANT="${REH_CHAIN_ID:-43114}"
anvil --fork-url "$PROXY_URL" --fork-block-number "$PIN" --silent --port "$PORT" --host 127.0.0.1 --retries 3 --timeout 60000 >/dev/null 2>&1 &
APID=$!
export LOCAL_URL="http://127.0.0.1:$PORT"
for i in $(seq 1 90); do ETH_RPC_URL="$LOCAL_URL" cast chain-id >/dev/null 2>&1 && break; sleep 1; done
if [ "$(ETH_RPC_URL="$LOCAL_URL" cast chain-id 2>/dev/null)" != "$CHAIN_ID_WANT" ]; then
  kill "$PPID_X" 2>/dev/null; sleep 1; PPID_X=""
  if rate_limited; then echo "RATE LIMIT SEEN (HTTP 429) while starting the fork - stop fork work and report" >&2; exit 42; fi
  echo "anvil did not come up with chain id $CHAIN_ID_WANT"; exit 3
fi
ETH_RPC_URL="$LOCAL_URL" cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "the endpoint is not anvil: refusing"; exit 3; }
NURL="$(ps -axo command= | grep -cF -f <(printf '%s' "$UP") || true)"
NPROC="$(ps -axo command= | wc -l | tr -d ' ')"
echo "argv check: $NURL of $NPROC processes carry the upstream endpoint in their argument vector (must be 0); anvil argv has a URL: $(ps -o command= -p "$APID" | grep -cE 'https?://' | tr -d ' ') (the proxy's 127.0.0.1 address only: $(ps -o command= -p "$APID" | grep -c '127.0.0.1:'))" | tee -a "$OUT/argv-check.txt"
[ "$NURL" = 0 ] || { echo "ARGV CHECK FAILED: stopping"; exit 3; }

ENTRY="$HERE/rehearsal.mjs"; [ "$SELFTEST" = 1 ] && ENTRY="$HERE/selftest/selftest.mjs"
CTORENV=(); while IFS= read -r l; do [ -n "$l" ] && CTORENV+=("$l"); done < <(env | grep '^BP_CTOR_' || true)   # constructor-argument overrides BP_CTOR_<CONTRACT>='[...]' pass through
# the harness writes $LOG ITSELF (every line, redacted, appended synchronously: lib.mjs REH_LOGFILE); the pipe only shows it on the terminal
: > "$LOG"
env -i ${CTORENV[@]+"${CTORENV[@]}"} REH_LOGFILE="$LOG" PATH="$PATH" HOME="$HOME" REH_ETHERS_DIR="$ETHERS" REH_RPC="$LOCAL_URL" REH_SCRATCH="$SCRATCH" REH_RESULTS="$OUT/results.json" REH_PIN="$PIN" REH_CHAIN_ID="$CHAIN_ID_WANT" BP_OUT="$BP_OUT" \
  REH_SELFTEST="$SELFTEST" REH_FIXTURE_OUT="${REH_FIXTURE_OUT:-}" REH_SELFTEST_FAIL="${REH_SELFTEST_FAIL:-0}" \
  BP_SEED_SHARES="${BP_SEED_SHARES:-}" BP_MIN_VAULT_SUPPLY="${BP_MIN_VAULT_SUPPLY:-}" BP_INITIAL_EXCHANGE_RATE="${BP_INITIAL_EXCHANGE_RATE:-}" BP_PTOKEN_DECIMALS="${BP_PTOKEN_DECIMALS:-}" BP_PTOKEN_NAME="${BP_PTOKEN_NAME:-}" BP_PTOKEN_SYMBOL="${BP_PTOKEN_SYMBOL:-}" \
  BP_WRAPPER_NAME="$WRAPPER" BP_DELEGATE_NAME="$DELEGATE" BP_CF="${BP_CF:-}" BP_SHARE_BORROW_CAP="${BP_SHARE_BORROW_CAP:-}" \
  BP_TOOL="$BP_TOOL" BP_USE_TOOL="$BP_USE_TOOL" BP_ADDRESSES_FILE="${BP_ADDRESSES_FILE:-}" BP_DEPLOY_CMD="${BP_DEPLOY_CMD:-}" BP_DEPLOY_CWD="${BP_DEPLOY_CWD:-}" BP_WRAPPER_RUNTIME="${BP_WRAPPER_RUNTIME:-3472}" \
  REH_WRAPPER="$REH_WRAPPER" REH_REWARDS_PROJ="$REWARDS_PROJ" REH_INT_TOOLS="$INT_TOOLS" REH_SCAN_FROM="${REH_SCAN_FROM:-}" REH_CHUNK="${REH_CHUNK:-100}" REH_SLEEP_MS="${REH_SLEEP_MS:-0}" REH_WARP_SECONDS="${REH_WARP_SECONDS:-86400}" REH_RERUN="${REH_RERUN:-1}" REH_EPOCH_OUT="$OUT" REH_RPC_TIMEOUT_MS="${REH_RPC_TIMEOUT_MS:-}" REH_GROUP_TIMEOUT_MS="${REH_GROUP_TIMEOUT_MS:-}" REH_TOOL_TIMEOUT_MS="${REH_TOOL_TIMEOUT_MS:-}" REH_GEN_TIMEOUT_MS="${REH_GEN_TIMEOUT_MS:-}" REH_PHAR_TIMEOUT_MS="${REH_PHAR_TIMEOUT_MS:-}" REH_HEARTBEAT_MS="${REH_HEARTBEAT_MS:-}" \
  node "$ENTRY" 2>&1 | REDACT_LIVE
RC=${PIPESTATUS[0]}
kill "$PPID_X" 2>/dev/null; sleep 1; PPID_X=""   # SIGTERM makes the proxy write its status counts
echo "upstream HTTP status counts seen by the proxy: $(cat "$OUT/upstream-status.json" 2>/dev/null)" | tee -a "$LOG"
if rate_limited; then echo "RATE LIMIT SEEN - stop fork work and report" >&2; RC=42; fi
exit "$RC"
