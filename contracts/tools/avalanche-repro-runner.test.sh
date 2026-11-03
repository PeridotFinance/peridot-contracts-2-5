#!/usr/bin/env bash
# Regression tests for the reproduction runners with SIMULATED outcomes (no forge, no RPC): the retry policy must retry only positively
# identified transient infrastructure failures, never reuse an attempt directory, and keep a full log per attempt.
# Run: tools/avalanche-repro-runner.test.sh
set -u
cd "$(dirname "$0")/.."
T="$(mktemp -d /tmp/avalanche-repro-runner-test.XXXXXX)"; trap 'rm -rf "$T"' EXIT
export REPRO_SLEEP=0
FAILS=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; FAILS=$((FAILS+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

# simulated attempt behaviours, selected per attempt number through SIM (space separated list of outcomes)
cat > "$T/sim.sh" <<'SIMEOF'
#!/usr/bin/env bash
# writes a simulated forge-like log into $REPRO_ATTEMPT_DIR and exits like forge would
set -u
read -ra OUTS <<< "$SIM"
O="${OUTS[$((REPRO_ATTEMPT-1))]:-pass}"
D="$REPRO_ATTEMPT_DIR"
case "$O" in
  pass)      echo "[PASS] testA() (gas: 1)"; echo "Suite result: ok. 1 passed; 0 failed; 0 skipped" > "$D/suite.txt"; exit 0 ;;
  t429)      { echo "[FAIL: EVM error; database error: failed to get storage for 0xabc at 1: Max retries exceeded HTTP error 429 with body: error code: 1015] testA() (gas: 0)"; echo "Suite result: FAILED. 0 passed; 1 failed"; } > "$D/suite.txt"; exit 1 ;;
  assert)    { echo "[FAIL: assertion failed: 5 != 6] testA() (gas: 9)"; echo "Suite result: FAILED. 0 passed; 1 failed"; } > "$D/suite.txt"; exit 1 ;;
  mixed)     { echo "[FAIL: EVM error; database error: failed to get storage Max retries exceeded HTTP error 429] testA() (gas: 0)"; echo "[FAIL: assertion failed: 1 != 2] testB() (gas: 9)"; } > "$D/suite.txt"; exit 1 ;;
  incomplete)  echo "Manifest scenarios: 168; fallback scenarios: 64; NOT-RUN: 3; conflicting records: 0; incomplete fallback scenarios: 0" > "$D/matrix.txt"; echo "MATRIX INCOMPLETE OR FAILED" >> "$D/matrix.txt"; exit 1 ;;
  compile)   echo "Error (7576): Undeclared identifier." > "$D/build.txt"; exit 1 ;;
  usage)     echo "error: the following required arguments were not provided: --rpc-url <URL>" > "$D/usage.txt"; exit 2 ;;
  empty)     : > "$D/empty.txt"; exit 1 ;;
  gatefail)  { echo "FAILED: capacity matrix (see x)"; echo "GATE RUN FAILED OR INCOMPLETE"; } > "$D/gate.txt"; exit 1 ;;
esac
SIMEOF
chmod +x "$T/sim.sh"

run() { # name, SIM, max -> sets RC, OUTDIR
  OUTDIR="$T/$1"; SIM="$2" tools/avalanche-repro-retry.sh "$OUTDIR" "$3" -- "$T/sim.sh" > "$T/$1.out" 2>&1; RC=$?
}
attempts() { ls -d "$OUTDIR"/attempt* 2>/dev/null | wc -l | tr -d ' '; }

run pass1 "pass" 5;                         check "pass on the first attempt: exit 0, 1 attempt" "$RC/$(attempts)" "0/1"
run t2 "t429 t429 pass" 5;                  check "two rate-limit failures then pass: exit 0, 3 attempts" "$RC/$(attempts)" "0/3"
check "every attempt keeps its own full log (suite.txt + run.log)" "$(ls "$OUTDIR"/attempt*/suite.txt "$OUTDIR"/attempt*/run.log | wc -l | tr -d ' ')" "6"
check "the failed attempts' logs still contain the 429 text" "$(grep -l '429' "$OUTDIR"/attempt1/suite.txt "$OUTDIR"/attempt2/suite.txt | wc -l | tr -d ' ')" "2"
check "summary.tsv has a line per attempt with the class" "$(cut -f3 "$OUTDIR/summary.tsv" | tail -n +2 | tr '\n' ',')" "TRANSIENT,TRANSIENT,PASS,"
run exh "t429 t429 t429" 3;                 check "transient failures exhaust the attempts: exit 11" "$RC/$(attempts)" "11/3"
run as1 "assert pass" 5;                    check "assertion failure stops at once (exit 20, 1 attempt), never retried to green" "$RC/$(attempts)" "20/1"
run as2 "t429 assert pass" 5;               check "an assertion failure after a transient one stops (exit 20, 2 attempts)" "$RC/$(attempts)" "20/2"
run mix "mixed pass" 5;                     check "transient + assertion failure in the SAME attempt is an assertion failure (exit 20, 1 attempt)" "$RC/$(attempts)" "20/1"
run inc "incomplete pass" 5;                check "incomplete evidence stops (exit 30, 1 attempt)" "$RC/$(attempts)" "30/1"
run cmp "compile pass" 5;                   check "compile error is unknown: stops (exit 40, 1 attempt)" "$RC/$(attempts)" "40/1"
run use "usage pass" 5;                     check "usage error (exit 2) is unknown: stops (exit 40, 1 attempt)" "$RC/$(attempts)" "40/1"
run emp "empty pass" 5;                     check "non-zero exit with an empty log is unknown: stops (exit 40, 1 attempt)" "$RC/$(attempts)" "40/1"
run gf "gatefail pass" 5;                   check "a bare gate 'FAILED:' summary with no cause is unknown, not transient (exit 40)" "$RC/$(attempts)" "40/1"
# never reuse an attempt directory
mkdir -p "$T/reuse/attempt1"; SIM="pass" tools/avalanche-repro-retry.sh "$T/reuse" 3 -- "$T/sim.sh" > "$T/reuse.out" 2>&1; check "an existing attempt directory is never reused (exit 2)" "$?" "2"

# classifier on real excerpts (the retained 429 logs of the vault reproduction)
R=../docs/deployment-handoffs/avalanche-clean-repro-final
if [ -f "$R/vault-attempt16-usdc.txt" ]; then echo "(real retained logs found)"
  python3 tools/avalanche-repro-classify.py 1 "$R/vault-attempt16-usdc.txt" > "$T/c1.out"; check "real log: attempt 16 (RPC errors only) is TRANSIENT" "$(cut -d: -f1 "$T/c1.out")" "TRANSIENT"
  python3 tools/avalanche-repro-classify.py 0 "$R/vault-attempt18-usdc.txt" > "$T/c2.out"; check "real log: attempt 18 (40 passed) is PASS" "$(cut -d: -f1 "$T/c2.out")" "PASS"
  python3 tools/avalanche-repro-classify.py 2 "$R/vault-attempt9-usdc.txt" > "$T/c3.out"; check "real log: attempt 9 (usage error) is UNKNOWN" "$(cut -d: -f1 "$T/c3.out")" "UNKNOWN"
fi
# wrapper integration with simulated gate/vault commands
OUT="$T/wrap1"; REPRO_GATE_CMD='[ "$REPRO_ATTEMPT" -ge 2 ] && { echo "Suite result: ok. 1 passed; 0 failed" > "$REPRO_ATTEMPT_DIR/s.txt"; exit 0; } || { echo "[FAIL: database error: failed to get storage HTTP error 429] t()" > "$REPRO_ATTEMPT_DIR/s.txt"; exit 1; }' tools/run-avalanche-clean-repro.sh "$OUT" 4 > "$T/wrap1.out" 2>&1; check "gate wrapper: transient then pass (exit 0, 2 attempt dirs)" "$?/$(ls -d "$OUT"/attempt* | wc -l | tr -d ' ')" "0/2"
OUT="$T/wrap2"; REPRO_VAULT_CMD='echo "[FAIL: assertion failed: x] t()" > "$REPRO_ATTEMPT_DIR/vault.txt"; exit 1' tools/run-avalanche-vault-clean-repro-retry.sh usdc "$OUT" 4 > "$T/wrap2.out" 2>&1; check "vault wrapper: assertion failure stops (exit 20, 1 attempt dir)" "$?/$(ls -d "$OUT"/attempt* | wc -l | tr -d ' ')" "20/1"

if [ "$FAILS" -ne 0 ]; then echo "$FAILS runner test(s) FAILED"; exit 1; fi
echo "all runner tests passed"
