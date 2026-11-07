#!/usr/bin/env bash
# CLEAN-HOME reproduction of the Avalanche gate: an isolated Foundry home that starts EMPTY (no RPC cache from any earlier run, proxy or
# agent; solc binaries only), a single public-or-archive RPC, no substituted values. Tests only: nothing is signed or broadcast.
#
# usage: AVALANCHE_MAINNET_RPC_URL=<archive RPC> tools/run-avalanche-clean-repro.sh [outdir] [max_attempts]
# Retry policy: ONLY positively identified transient RPC infrastructure failures (rate limits, RPC database errors, timeouts) are retried
# (tools/avalanche-repro-classify.py); assertion failures, incomplete evidence and unidentified failures STOP the run. Each attempt has its
# own directory (<outdir>/attempt<N>/, never reused) with the complete gate logs; <outdir>/summary.tsv lists every attempt.
# The isolated home is reused across the retries of ONE run, so the RPC cache is POPULATED ACROSS RETRIES by values fetched from the chain
# (never substituted); a run that passes on attempt N is therefore an "isolated-cache run populated across retries", not a single cold run.
# Test hook: REPRO_GATE_CMD overrides the gate command (used by tools/avalanche-repro-runner.test.sh with simulated outcomes).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-/tmp/avalanche-clean-repro}"; MAX="${2:-8}"
if [ -z "${REPRO_GATE_CMD:-}" ]; then
  : "${AVALANCHE_MAINNET_RPC_URL:?set AVALANCHE_MAINNET_RPC_URL}"
  REAL_HOME="$HOME"; CLEAN_HOME="$(mktemp -d /tmp/avalanche-clean-home.XXXXXX)"
  mkdir -p "$CLEAN_HOME/.foundry/cache/rpc"
  for d in "Library/Application Support/svm" ".svm"; do
    if [ -d "$REAL_HOME/$d" ]; then mkdir -p "$CLEAN_HOME/$(dirname "$d")"; ln -sfn "$REAL_HOME/$d" "$CLEAN_HOME/$d"; fi
  done
  echo "commit: $(git rev-parse HEAD)  (dirty files: $(git status --porcelain | wc -l))"
  echo "clean home: $CLEAN_HOME  (RPC cache starts empty)"
  export REPRO_HOME="$CLEAN_HOME"
  GATE=(env HOME="$CLEAN_HOME" bash -c 'tools/run-avalanche-section5-gate.sh "$REPRO_ATTEMPT_DIR/gate"')
else
  GATE=(bash -c "$REPRO_GATE_CMD")
fi
tools/avalanche-repro-retry.sh "$OUT" "$MAX" -- "${GATE[@]}"
rc=$?
[ -n "${CLEAN_HOME:-}" ] && rm -rf "$CLEAN_HOME"
exit $rc
