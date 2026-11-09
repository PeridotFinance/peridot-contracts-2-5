#!/usr/bin/env bash
# Runs the fork tests under the SHARED FORK LOCK (free-tier endpoint: parallel fork jobs cause 429s). Needs AVALANCHE_MAINNET_RPC_URL in the environment
# (never printed). To skip a 30+ minute compile of the ~370 contracts, seed the build directory once: cp -R contracts/out "$FOUNDRY_OUT"; mkdir -p "$FOUNDRY_CACHE_PATH"; cp contracts/cache_forge/solidity-files-cache.json "$FOUNDRY_CACHE_PATH/"
# The margin stack is compiled by the ceremony wrapper with FOUNDRY_OUT / FOUNDRY_CACHE_PATH below, so nothing is written into contracts/out.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PKG="$(cd "$HERE/../.." && pwd)"
: "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment}"
export FOUNDRY_OUT="${FOUNDRY_OUT:-${TMPDIR:-/tmp}/order-keeper-forge/out}"
export FOUNDRY_CACHE_PATH="${FOUNDRY_CACHE_PATH:-${TMPDIR:-/tmp}/order-keeper-forge/cache}"
# the settable Chainlink feed mock (contracts/test/helpers/MonitorForkMocks.sol) is NOT compiled by the ceremony wrapper: it comes from the operator's build (read only)
export ORDER_KEEPER_FORGE_OUT="${ORDER_KEEPER_FORGE_OUT:-$PKG/../operator/.forge-out}"
if [ ! -f "$ORDER_KEEPER_FORGE_OUT/MonitorForkMocks.sol/MonitorMockFeed.json" ]; then echo "missing $ORDER_KEEPER_FORGE_OUT/MonitorForkMocks.sol/MonitorMockFeed.json: run 'npm run build:contracts' in operator/ or set ORDER_KEEPER_FORGE_OUT" >&2; exit 2; fi
until mkdir /tmp/pilot-fork.lock 2>/dev/null; do sleep 20; done
trap 'rmdir /tmp/pilot-fork.lock 2>/dev/null' EXIT INT TERM
# pin the fork block (one eth_blockNumber call, URL never printed); a re-run reuses the pinned block from the file so anvil's upstream cache is hit
BLOCKFILE="${TMPDIR:-/tmp}/order-keeper-fork-block"
if [ -z "${ORDER_KEEPER_FORK_BLOCK:-}" ]; then
  if [ ! -s "$BLOCKFILE" ]; then
    HEX="$(curl -s -m 20 -X POST -H 'content-type: application/json' --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' "$AVALANCHE_MAINNET_RPC_URL" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"])' 2>/dev/null || true)"
    case "$HEX" in 0x*) echo $(( HEX - 4 )) > "$BLOCKFILE" ;; *) echo "could not read the head block (the endpoint did not answer with a block number): stopping, no fork job started" >&2; exit 3 ;; esac
  fi
  export ORDER_KEEPER_FORK_BLOCK="$(cat "$BLOCKFILE")"
fi
echo "fork pinned at block $ORDER_KEEPER_FORK_BLOCK"
cd "$PKG" && node --test --test-concurrency=1 --test-timeout=1500000 "${@:-dist/test/fork/orders.fork.test.js}"
