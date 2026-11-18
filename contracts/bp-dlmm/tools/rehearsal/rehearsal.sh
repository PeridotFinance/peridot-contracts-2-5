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

# ---- 1. the forge artifacts of the market contracts (subagent A's worktree by default) and ethers v5
if [ -z "${BP_OUT:-}" ]; then
  for c in /Users/joshua/Peridot/.wt-bp-core/contracts/out "$REPO/contracts/out"; do [ -f "$c/PErc20Delegator.sol/PErc20Delegator.json" ] && { BP_OUT="$c"; break; }; done
fi
BP_OUT="${BP_OUT:-/Users/joshua/Peridot/.wt-bp-core/contracts/out}"
export BP_OUT
# A's ceremony tool (deploy / verify-deployed / verify-listing / print-ledger-calls are run THROUGH it when it and its pin file exist; BP_USE_TOOL=0 forces the built-in deployment)
if [ -z "${BP_TOOL:-}" ]; then
  for c in /Users/joshua/Peridot/.wt-bp-core/contracts/tools/bp-dlmm-ceremony.sh "$REPO/contracts/tools/bp-dlmm-ceremony.sh"; do [ -f "$c" ] && { BP_TOOL="$c"; break; }; done
fi
BP_TOOL="${BP_TOOL:-}"; BP_USE_TOOL="${BP_USE_TOOL:-auto}"
WRAPPER="${BP_WRAPPER_NAME:-PharaohDlmmShareOracle}"; DELEGATE="${BP_DELEGATE_NAME:-PharaohBoostedDelegate}"
if [ "${BP_BUILD:-0}" = 1 ]; then ( cd "$(dirname "$BP_OUT")" && forge build --skip test 2>&1 | REDACT | tail -3 ); fi
if [ "$SELFTEST" != 1 ]; then
  for n in PErc20Delegator "$WRAPPER" "$DELEGATE"; do
    [ -f "$BP_OUT/$n.sol/$n.json" ] || { echo "artifact $BP_OUT/$n.sol/$n.json missing: run 'forge build --skip test' in the forge project that owns $BP_OUT (or set BP_OUT, BP_WRAPPER_NAME, BP_DELEGATE_NAME, or BP_BUILD=1)"; exit 2; }
  done
fi
ETHERS=""
COMMON="$(cd "$(git -C "$HERE" rev-parse --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd || echo "$REPO")"
for d in "${BP_ETHERS_DIR:-}" "$REPO/operator" "$REPO/order-keeper" "$REPO/range-tp-keeper" "$COMMON/operator" "$COMMON/order-keeper" "$COMMON/range-tp-keeper"; do
  [ -n "$d" ] && [ -f "$d/node_modules/ethers/package.json" ] && grep -q '"version": "5\.' "$d/node_modules/ethers/package.json" && { ETHERS="$d"; break; }
done
[ -n "$ETHERS" ] || { echo "no ethers v5 found (looked in operator, order-keeper, range-tp-keeper of $REPO and $COMMON): run 'cd $REPO/operator && npm ci' or set BP_ETHERS_DIR"; exit 2; }
export REH_ETHERS_DIR="$ETHERS"
for f in lib.mjs rehearsal.mjs readback.mjs rpc-proxy.mjs selftest/selftest.mjs; do node --check "$HERE/$f" || { echo "syntax error in $f"; exit 2; }; done

# ---- DRY mode: everything that needs no chain
if [ "$DRY" = 1 ]; then
  echo "DRY: out dir $OUT, artifacts $BP_OUT, ethers $ETHERS (version $(grep -m1 '"version"' "$ETHERS/node_modules/ethers/package.json" | tr -d ' ,"' ))"
  for t in anvil cast forge node; do command -v "$t" >/dev/null && echo "DRY ok   $t: $($t --version 2>&1 | head -1)" || echo "DRY FAIL $t not found"; done
  REH_RPC="http://127.0.0.1:1" node "$HERE/rehearsal.mjs" --dry 2>&1 | REDACT; RC=${PIPESTATUS[0]}
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
env -i ${CTORENV[@]+"${CTORENV[@]}"} PATH="$PATH" HOME="$HOME" REH_ETHERS_DIR="$ETHERS" REH_RPC="$LOCAL_URL" REH_SCRATCH="$SCRATCH" REH_RESULTS="$OUT/results.json" REH_PIN="$PIN" REH_CHAIN_ID="$CHAIN_ID_WANT" BP_OUT="$BP_OUT" \
  REH_SELFTEST="$SELFTEST" REH_FIXTURE_OUT="${REH_FIXTURE_OUT:-}" REH_SELFTEST_FAIL="${REH_SELFTEST_FAIL:-0}" \
  BP_SEED_SHARES="${BP_SEED_SHARES:-}" BP_MIN_VAULT_SUPPLY="${BP_MIN_VAULT_SUPPLY:-}" BP_INITIAL_EXCHANGE_RATE="${BP_INITIAL_EXCHANGE_RATE:-}" BP_PTOKEN_DECIMALS="${BP_PTOKEN_DECIMALS:-}" BP_PTOKEN_NAME="${BP_PTOKEN_NAME:-}" BP_PTOKEN_SYMBOL="${BP_PTOKEN_SYMBOL:-}" \
  BP_WRAPPER_NAME="$WRAPPER" BP_DELEGATE_NAME="$DELEGATE" BP_CF="${BP_CF:-}" BP_SHARE_BORROW_CAP="${BP_SHARE_BORROW_CAP:-}" \
  BP_TOOL="$BP_TOOL" BP_USE_TOOL="$BP_USE_TOOL" BP_ADDRESSES_FILE="${BP_ADDRESSES_FILE:-}" BP_DEPLOY_CMD="${BP_DEPLOY_CMD:-}" BP_DEPLOY_CWD="${BP_DEPLOY_CWD:-}"\
  node "$ENTRY" 2>&1 | REDACT | tee "$LOG"
RC=${PIPESTATUS[0]}
kill "$PPID_X" 2>/dev/null; sleep 1; PPID_X=""   # SIGTERM makes the proxy write its status counts
echo "upstream HTTP status counts seen by the proxy: $(cat "$OUT/upstream-status.json" 2>/dev/null)" | tee -a "$LOG"
if rate_limited; then echo "RATE LIMIT SEEN - stop fork work and report" >&2; RC=42; fi
exit "$RC"
