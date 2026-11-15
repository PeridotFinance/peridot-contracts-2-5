#!/bin/sh
# Container entrypoint. Secrets come ONLY from the environment / mounted files:
#   AVALANCHE_MAINNET_RPC_URL                 the state endpoint (read by the process itself, never printed)
#   DLMM_KEEPER_KEYSTORE_PATH                 path of the encrypted keystore (default /data/keystore/dlmm-keeper.json), needed in live mode only
#   DLMM_KEEPER_KEYSTORE_PASSWORD_FILE        path of the file holding the keystore password (default /run/secrets/dlmm-keeper-password), live mode only
# Commands: run (default; dry-run unless the configuration says "live"), check, status, resume, validate-config. This script prints no secret and no file content.
set -eu
export DLMM_KEEPER_KEYSTORE_PATH="${DLMM_KEEPER_KEYSTORE_PATH:-/data/keystore/dlmm-keeper.json}"
export DLMM_KEEPER_KEYSTORE_PASSWORD_FILE="${DLMM_KEEPER_KEYSTORE_PASSWORD_FILE:-/run/secrets/dlmm-keeper-password}"
exec node dist/src/main.js "${@:-run}"
