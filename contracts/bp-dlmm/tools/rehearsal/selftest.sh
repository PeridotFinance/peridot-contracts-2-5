#!/usr/bin/env bash
# SELF-TEST of the rehearsal harness WITHOUT a mainnet fork and without any endpoint: a local anvil (chain id 43114) plays the "upstream", rehearsal.sh forks it through the real proxy path and runs
# selftest/selftest.mjs (helpers, tracing, results writer). It also exercises: the lock (held by someone else -> we wait and never remove it), the argv check (a process carrying the upstream string ->
# exit 3), the 429 path (exit 42), a failing check (exit 1), DRY=1. It tests NO product logic and uses its own lock path (never /tmp/pilot-fork.lock).
#   usage: contracts/bp-dlmm/tools/rehearsal/selftest.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; W="$(mktemp -d "${TMPDIR:-/tmp}/bp-selftest.XXXXXX")"; FAIL=0
UPPORT=18990; STUB=18992; UP="http://127.0.0.1:$UPPORT"
export REH_PORT=18945 REH_PROXY_PORT=18947 REH_LOCK="$W/test.lock" REH_SELFTEST=1 REH_CHAIN_ID=43114
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

# 6. DRY=1 (needs the forge artifacts of the market contracts; skipped when they do not exist yet)
unset REH_SELFTEST; BPO="${BP_OUT:-/Users/joshua/Peridot/.wt-bp-core/contracts/out}"
if [ -f "$BPO/PErc20Delegator.sol/PErc20Delegator.json" ]; then
  DRY=1 BP_OUT="$BPO" "$HERE/rehearsal.sh" "$W/out6" > "$W/run6.txt" 2>&1; RC=$?
  [ "$RC" = 0 ] && grep -q "DRY PASSED" "$W/run6.txt" && ok "DRY=1: static checks pass, nothing forked" || { bad "DRY=1 exit $RC"; tail -8 "$W/run6.txt"; }
else echo "SELFTEST SKIP DRY=1 (no artifacts in $BPO)"; fi

[ "$FAIL" = 0 ] && echo "SELFTEST ALL PASSED" || echo "SELFTEST FAILED"
exit "$FAIL"
