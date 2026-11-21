#!/usr/bin/env bash
# SELF-TEST of the rehearsal harness WITHOUT a mainnet fork and without any endpoint: a local anvil (chain id 43114) plays the "upstream", rehearsal.sh forks it through the real proxy path and runs
# selftest/selftest.mjs (helpers, tracing, results writer). It also exercises: the lock (held by someone else -> we wait and never remove it), the argv check (a process carrying the upstream string ->
# exit 3), the 429 path (exit 42), a failing check (exit 1), DRY=1. It tests NO product logic and uses its own lock path (never /tmp/pilot-fork.lock).
#   usage: contracts/bp-dlmm/tools/rehearsal/selftest.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; W="$(mktemp -d "${TMPDIR:-/tmp}/bp-selftest.XXXXXX")"; FAIL=0
UPPORT=18990; STUB=18992; UP="http://127.0.0.1:$UPPORT"
export REH_PORT=18945 REH_PROXY_PORT=18947 REH_LOCK="$W/test.lock" REH_SELFTEST=1 REH_CHAIN_ID=43114
export REH_WRAPPER=0   # the PHAR step is DEFAULT ON in the real run; the plumbing runs below never reach it (case 7 and the DRY cases switch it on explicitly)
APIDS=""; cleanup() { for p in $APIDS; do kill "$p" 2>/dev/null; done; rm -rf "$W"; }; trap cleanup EXIT
ok() { echo "SELFTEST PASS $1"; }; bad() { echo "SELFTEST FAIL $1"; FAIL=1; }
anvil --chain-id 43114 --port $UPPORT --silent >/dev/null 2>&1 & APIDS="$APIDS $!"
for i in $(seq 1 30); do ETH_RPC_URL="$UP" cast chain-id >/dev/null 2>&1 && break; sleep 0.5; done
[ "$(ETH_RPC_URL="$UP" cast chain-id 2>/dev/null)" = 43114 ] || { echo "SELFTEST could not start the fake upstream anvil"; exit 1; }
for i in 1 2 3 4 5 6; do ETH_RPC_URL="$UP" cast rpc anvil_mine >/dev/null 2>&1; done   # a few blocks so that head-4 exists

# 1. the happy path: lock, proxy, fork, argv check, the plumbing checks, results, lock released
AVALANCHE_RPC="$UP" "$HERE/rehearsal.sh" "$W/out1" > "$W/run1.txt" 2>&1; RC=$?
[ "$RC" = 0 ] && ok "rehearsal.sh -> selftest.mjs through the proxy and the fork: exit 0" || { bad "exit $RC (expected 0)"; tail -30 "$W/run1.txt"; }
grep -q "argv check: 0 of" "$W/run1.txt" && ok "argv check printed 0 processes carrying the upstream" || bad "argv check line missing"
[ -f "$W/out1/results.json" ] && grep -q '"fail": 0' "$W/out1/results.json" && ok "results.json written with fail 0" || bad "results.json"
grep -q "REHEARSAL PASSED" "$W/run1.txt" && grep -qE "^PASS P2.1" "$W/run1.txt" && ok "PASS lines and the final line" || bad "final lines"
[ -d "$REH_LOCK" ] && bad "lock directory still exists after the run" || ok "lock released (directory gone)"
grep -q acquire "$W/out1/lock-minutes.log" && grep -q release "$W/out1/lock-minutes.log" && ok "lock-minutes.log has acquire and release" || bad "lock-minutes.log"
[ -f "$W/out1/upstream-status.json" ] && ok "upstream-status.json written by the proxy: $(cat "$W/out1/upstream-status.json" | head -c 120)" || bad "upstream-status.json"
grep -E "https?://" "$W/run1.txt" | grep -v "<url-redacted>" | grep -q . && bad "an unredacted URL is in the output" || ok "no unredacted URL in the output"

# 2. a failing check -> exit 1
AVALANCHE_RPC="$UP" REH_SELFTEST_FAIL=1 "$HERE/rehearsal.sh" "$W/out2" > "$W/run2.txt" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q "FAIL P2.2" "$W/run2.txt" && ok "a failing check gives exit 1 and a FAIL line" || { bad "failing-check run exit $RC"; tail -5 "$W/run2.txt"; }

# 3. the lock held by someone else: we must wait and must NOT remove it
mkdir "$REH_LOCK"; ( AVALANCHE_RPC="$UP" "$HERE/rehearsal.sh" "$W/out3" > "$W/run3.txt" 2>&1 & P=$!; sleep 6; kill $P 2>/dev/null; wait $P 2>/dev/null )
[ -d "$REH_LOCK" ] && ! grep -q "fork pin block" "$W/run3.txt" 2>/dev/null && ok "lock held by another job: the run waited (no fork started) and left the lock in place" || bad "lock contention behaviour"
rmdir "$REH_LOCK" 2>/dev/null

# 4. the argv check: a process whose argument vector carries the upstream string -> exit 3
bash -c 'sleep 300; true' _ "$UP" & SP=$!; APIDS="$APIDS $SP"
AVALANCHE_RPC="$UP" "$HERE/rehearsal.sh" "$W/out4" > "$W/run4.txt" 2>&1; RC=$?; kill $SP 2>/dev/null
[ "$RC" = 3 ] && grep -q "ARGV CHECK FAILED" "$W/run4.txt" && ok "argv check catches a process carrying the endpoint: exit 3" || { bad "argv check negative test exit $RC"; tail -4 "$W/run4.txt"; }
[ -d "$REH_LOCK" ] && bad "lock left behind after the argv failure" || ok "lock released after the argv failure"

# 5. HTTP 429 from the upstream -> exit 42
node "$HERE/selftest/stub429.mjs" $STUB & APIDS="$APIDS $!"; sleep 1
AVALANCHE_RPC="http://127.0.0.1:$STUB" "$HERE/rehearsal.sh" "$W/out5" > "$W/run5.txt" 2>&1; RC=$?
[ "$RC" = 42 ] && grep -q "RATE LIMIT SEEN" "$W/run5.txt" && ok "an upstream HTTP 429 gives exit 42" || { bad "429 test exit $RC"; tail -4 "$W/run5.txt"; }
[ -d "$REH_LOCK" ] && bad "lock left behind after the 429" || ok "lock released after the 429"

# 6. DRY=1 (needs the forge artifacts of the market contracts: this tree's out_bpdlmm, written by 'tools/bp-dlmm-ceremony.sh pin rehearsal'; skipped when they do not exist yet)
unset REH_SELFTEST; BPO="${BP_OUT:-$HERE/../../../out_bpdlmm}"
if [ -f "$BPO/PErc20Delegator.sol/PErc20Delegator.json" ]; then
  DRY=1 REH_WRAPPER=0 BP_OUT="$BPO" "$HERE/rehearsal.sh" "$W/out6" > "$W/run6.txt" 2>&1; RC=$?
  [ "$RC" = 0 ] && grep -q "DRY PASSED" "$W/run6.txt" && grep -q "PHAR step skipped (REH_WRAPPER=0)" "$W/run6.txt" && ok "DRY=1 REH_WRAPPER=0: static checks pass, the PHAR step is skipped, nothing forked" || { bad "DRY=1 REH_WRAPPER=0 exit $RC"; tail -8 "$W/run6.txt"; }
  DRY=1 REH_WRAPPER=1 REH_SCAN_FROM=100468395 BP_OUT="$BPO" "$HERE/rehearsal.sh" "$W/out6b" > "$W/run6b.txt" 2>&1; RC=$?
  [ "$RC" = 0 ] && grep -q "DRY PASSED" "$W/run6b.txt" && grep -q "expected-split model equals the generator" "$W/run6b.txt" && ok "DRY=1 REH_WRAPPER=1 (the default): static checks pass and the PHAR model equals the generator's on random histories" || { bad "DRY=1 REH_WRAPPER=1 exit $RC"; tail -8 "$W/run6b.txt"; }
  DRY=1 REH_WRAPPER=0 BP_WRAPPER_RUNTIME=9999 BP_OUT="$BPO" "$HERE/rehearsal.sh" "$W/out6c" > "$W/run6c.txt" 2>&1; RC=$?
  [ "$RC" = 2 ] && grep -q "GUARD: the pin says the wrapper runtime" "$W/run6c.txt" && ok "pre-lock guard: a pin for another wrapper version (runtime size mismatch) stops the run with exit 2" || { bad "pin guard exit $RC"; tail -4 "$W/run6c.txt"; }
else echo "SELFTEST SKIP DRY=1 (no artifacts in $BPO)"; fi

# 7. REH_WRAPPER on (the default) without REH_SCAN_FROM: refused BEFORE any endpoint, lock or fork (exit 2, no lock taken)
env -u REH_SCAN_FROM REH_SELFTEST=1 REH_WRAPPER=1 AVALANCHE_RPC="$UP" "$HERE/rehearsal.sh" "$W/out7" > "$W/run7.txt" 2>&1; RC=$?
[ "$RC" = 2 ] && grep -q "REH_SCAN_FROM is not set" "$W/run7.txt" && [ ! -d "$REH_LOCK" ] && ! grep -q "fork pin block" "$W/run7.txt" && ok "REH_WRAPPER=1 without REH_SCAN_FROM: exit 2 before the lock and the fork" || { bad "scan-from guard exit $RC"; tail -4 "$W/run7.txt"; }


# 8. run-2 hardening against a BLACK-HOLE server (accepts connections, never answers): per-RPC timeout names the call, the group watchdog ends a hung group with the calls in flight, the heartbeat prints,
#    a child process gets stdin closed and its own timeout, the process writes its own redacted log file. (Run 1 went silent for an hour after the oracle swap: this is the instrumentation for that.)
COMMON="$(cd "$(git -C "$HERE" rev-parse --git-common-dir)/.." && pwd)"; EDIR=""
for d in "${BP_ETHERS_DIR:-}" "$(cd "$HERE/../../../.." && pwd)/operator" "$COMMON/operator" "$COMMON/order-keeper"; do [ -n "$d" ] && [ -f "$d/node_modules/ethers/package.json" ] && { EDIR="$d"; break; }; done
BH=18995; node -e "require('net').createServer(()=>{}).listen($BH,'127.0.0.1')" & APIDS="$APIDS $!"; sleep 1
HENV="REH_ETHERS_DIR=$EDIR REH_RPC=http://127.0.0.1:$BH REH_RESULTS=$W/hang-results.json"
env -i PATH="$PATH" HOME="$HOME" $HENV HANG_MODE=rpc REH_RPC_TIMEOUT_MS=1500 REH_LOGFILE="$W/hang.log" REH_HEARTBEAT_MS=400 node "$HERE/selftest/hang.mjs" > "$W/hang1.txt" 2>&1
grep -q "RPC_RESULT TIMED_OUT_WITH_NAME" "$W/hang1.txt" && grep -q "TRACK_RESULT REH_TIMEOUT" "$W/hang1.txt" && ok "a JSON-RPC call that never answers fails after REH_RPC_TIMEOUT_MS with the call's name (rpc eth_blockNumber)" || { bad "rpc timeout"; cat "$W/hang1.txt" | head -5; }
grep -q "HEARTBEAT" "$W/hang1.txt" && grep -q "in flight: rpc eth_blockNumber" "$W/hang1.txt" && ok "the heartbeat line names the call in flight" || { bad "heartbeat"; head -5 "$W/hang1.txt"; }
grep -q "TIMEOUT after" "$W/hang.log" && ok "the process wrote its own log file while running (REH_LOGFILE), no pipeline needed" || bad "log file"
env -i PATH="$PATH" HOME="$HOME" $HENV HANG_MODE=watchdog REH_RPC_TIMEOUT_MS=60000 node "$HERE/selftest/hang.mjs" > "$W/hang2.txt" 2>&1; RC=$?
[ "$RC" = 1 ] && grep -q "FAIL H0.watchdog" "$W/hang2.txt" && grep -q "calls in flight: rpc eth_chainId" "$W/hang2.txt" && ! grep -q WATCHDOG_NOT_FIRED "$W/hang2.txt" && grep -q '"aborted"' "$W/hang-results.json" && ok "the group watchdog ends a hung group (exit 1) naming the call in flight, and the results are saved" || { bad "watchdog exit $RC"; head -6 "$W/hang2.txt"; }
env -i PATH="$PATH" HOME="$HOME" $HENV HANG_MODE=proc node "$HERE/selftest/hang.mjs" > "$W/hang3.txt" 2>&1
grep -q "PROC_RESULT cat=0 sleep=124 grandchild=3 redacted=true true" "$W/hang3.txt" && ok "child processes: stdin is closed (cat exits 0), a timeout kills (exit 124), a grandchild holding the pipe does not block, urls are redacted" || { bad "proc"; head -5 "$W/hang3.txt"; }

[ "$FAIL" = 0 ] && echo "SELFTEST ALL PASSED" || echo "SELFTEST FAILED"
exit "$FAIL"
