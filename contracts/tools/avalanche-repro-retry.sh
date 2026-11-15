#!/usr/bin/env bash
# Generic retry driver for the Avalanche reproduction wrappers.
#   usage: tools/avalanche-repro-retry.sh <outdir> <max_attempts> -- <command> [args...]
# Runs <command> once per attempt with REPRO_ATTEMPT=<N> and REPRO_ATTEMPT_DIR=<outdir>/attempt<N> (a NEW directory per attempt, never reused
# or overwritten; the command must write all of its logs there; its stdout/stderr go to run.log in it). After each attempt the outcome is
# classified by tools/avalanche-repro-classify.py:
#   PASS        -> stop, exit 0
#   TRANSIENT   -> retry (after REPRO_SLEEP seconds, default 120) until <max_attempts>, then stop with exit 11 (exhausted)
#   ASSERTION / INCOMPLETE / UNKNOWN -> STOP at once; exit 20 / 30 / 40 (never retried)
# <outdir>/summary.tsv gets one line per attempt (attempt, exit code, class, reason). Nothing is deleted.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$1"; MAX="$2"; shift 2; [ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "usage: $0 <outdir> <max_attempts> -- <command...>" >&2; exit 2; }
mkdir -p "$OUT"
SLEEP="${REPRO_SLEEP:-120}"
printf 'attempt\texit\tclass\treason\n' >> "$OUT/summary.tsv"
rc_final=1
for N in $(seq 1 "$MAX"); do
  D="$OUT/attempt$N"
  if [ -e "$D" ]; then echo "refusing to reuse existing attempt directory $D" >&2; exit 2; fi
  mkdir -p "$D"
  echo "=== attempt $N/$MAX $(date -u +%FT%TZ) (logs: $D) ==="
  REPRO_ATTEMPT="$N" REPRO_ATTEMPT_DIR="$D" "$@" > "$D/run.log" 2>&1
  rc=$?
  RES="$(python3 "$HERE/avalanche-repro-classify.py" "$rc" "$D")"
  CLASS="${RES%%:*}"; REASON="${RES#*: }"
  printf '%s\t%s\t%s\t%s\n' "$N" "$rc" "$CLASS" "$REASON" >> "$OUT/summary.tsv"
  echo "attempt $N: exit $rc, $CLASS: $REASON"
  case "$CLASS" in
    PASS) echo "REPRODUCTION PASSED on attempt $N"; exit 0 ;;
    TRANSIENT) if [ "$N" -lt "$MAX" ]; then echo "transient infrastructure failure; retrying after ${SLEEP}s"; sleep "$SLEEP"; else echo "transient failures exhausted $MAX attempts"; rc_final=11; fi ;;
    ASSERTION) echo "STOP: a test failed for a non-infrastructure reason; not retrying"; exit 20 ;;
    INCOMPLETE) echo "STOP: evidence incomplete for a non-transient reason; not retrying"; exit 30 ;;
    *) echo "STOP: failure not positively identified as transient; not retrying"; exit 40 ;;
  esac
done
exit "$rc_final"
