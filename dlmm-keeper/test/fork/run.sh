#!/usr/bin/env bash
# Runs the fork tests. DO NOT run this directly: use ../../run-fork-test.sh, which holds the shared fork lock. Needs AVALANCHE_MAINNET_RPC_URL in the environment.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; PKG="$(cd "$HERE/../.." && pwd)"
: "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment}"
cd "$PKG" && node --test --test-concurrency=1 --test-timeout=1500000 "${@:-dist/test/fork/pair.fork.test.js}"
