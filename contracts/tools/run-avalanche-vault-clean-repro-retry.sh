#!/usr/bin/env bash
# Isolated reproduction of ONE Pharaoh vault suite with the transient-only retry policy of tools/avalanche-repro-retry.sh.
# usage: AVALANCHE_MAINNET_RPC_URL=<archive RPC> tools/run-avalanche-vault-clean-repro-retry.sh <usdc|wavax> <outdir> [max_attempts]
# One isolated home (empty at the start) is reused across the retries of this run, so the RPC cache is populated across retries by values
# fetched from the chain. Each attempt has its own directory with a full log (<outdir>/attempt<N>/vault.txt). Test hook: REPRO_VAULT_CMD.
set -uo pipefail
cd "$(dirname "$0")/.."
V="$1"; OUT="$2"; MAX="${3:-8}"
if [ -z "${REPRO_VAULT_CMD:-}" ]; then
  : "${AVALANCHE_MAINNET_RPC_URL:?set AVALANCHE_MAINNET_RPC_URL}"
  H="$(mktemp -d /tmp/avalanche-vault-clean-home.XXXXXX)"
  CMD=(bash -c "tools/run-avalanche-vault-clean-repro.sh $V \"\$REPRO_ATTEMPT_DIR/vault.txt\" $H")
else
  CMD=(bash -c "$REPRO_VAULT_CMD")
fi
tools/avalanche-repro-retry.sh "$OUT" "$MAX" -- "${CMD[@]}"
rc=$?
[ -n "${H:-}" ] && rm -rf "$H"
exit $rc
