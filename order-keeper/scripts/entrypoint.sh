#!/bin/sh
# Container entrypoint (the operator's pattern). Secrets come ONLY from the environment:
#   AVALANCHE_MAINNET_RPC_URL  state endpoint (free-tier node is enough: the keeper reads at the head only)
#   AVALANCHE_LOGS_RPC_URL     optional separate log endpoint (cross-check only)
#   ORDER_KEEPER_KEYSTORE_PASSWORD  the keystore password (read by the process itself, never by this script)
# The encrypted keystore file is at KEYSTORE_PATH (default /data/keystore/order-keeper.json, mode 600). This script prints no secret and no file content.
set -eu
KEYSTORE_PATH="${KEYSTORE_PATH:-/data/keystore/order-keeper.json}"
if [ "${1:-run}" = "run" ] && [ ! -f "$KEYSTORE_PATH" ]; then echo "no keystore at $KEYSTORE_PATH" >&2; exit 78; fi
exec node dist/src/main.js "${@:-run}"
