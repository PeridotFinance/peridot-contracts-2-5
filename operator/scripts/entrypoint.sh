#!/bin/sh
# Container entrypoint for an operator / keeper host. Secrets come ONLY from the environment (the host's encrypted environment / secret store):
#   KEYSTORE_JSON_B64        optional. The ENCRYPTED Foundry keystore file, base64. Written to $KEYSTORE_PATH (mode 600) so that a host with an ephemeral
#                            filesystem (DigitalOcean App Platform) still has its keystore after a restart. Without it the file at $KEYSTORE_PATH must exist.
#   <passwordEnv>            the keystore password (KEEPER_KEYSTORE_PASSWORD or OPERATOR_KEYSTORE_PASSWORD), read by the process itself, never by this script.
#   AVALANCHE_MAINNET_RPC_URL the RPC endpoint.
# This script prints no secret and no file content. "--materialize-only" writes the keystore and exits (used by the tests).
set -eu
KEYSTORE_PATH="${KEYSTORE_PATH:-/run/secrets/keystore.json}"
if [ -n "${KEYSTORE_JSON_B64:-}" ]; then
  umask 077
  mkdir -p "$(dirname "$KEYSTORE_PATH")"
  printf '%s' "$KEYSTORE_JSON_B64" | base64 -d > "$KEYSTORE_PATH"
  chmod 600 "$KEYSTORE_PATH"
  unset KEYSTORE_JSON_B64
  echo "keystore materialised at $KEYSTORE_PATH (mode 600)"
fi
if [ "${1:-}" = "--materialize-only" ]; then exit 0; fi
if [ ! -f "$KEYSTORE_PATH" ]; then echo "no keystore at $KEYSTORE_PATH (set KEYSTORE_JSON_B64 or mount the file)" >&2; exit 78; fi
exec node dist/src/main.js "${@:-run}"
