#!/usr/bin/env bash
# CLEAN (isolated, empty RPC cache, direct archive RPC, no proxy) reproduction of ONE Pharaoh vault fork suite. Tests only.
# usage: AVALANCHE_MAINNET_RPC_URL=<archive RPC> tools/run-avalanche-vault-clean-repro.sh <usdc|wavax> <logfile>
# The log gets a header (UTC time, git HEAD, git status, command, env); the forge output follows. Exit code = forge exit code.
set -uo pipefail
: "${AVALANCHE_MAINNET_RPC_URL:?set AVALANCHE_MAINNET_RPC_URL}"
cd "$(dirname "$0")/.."
V="$1"; LOG="$2"
case "$V" in usdc) SUITE=AvalancheTrackAUsdcVaultForkTest; PIN=99216397;; wavax) SUITE=AvalancheTrackAWavaxVaultForkTest; PIN=99216312;; *) echo "usdc|wavax"; exit 2;; esac
REAL_HOME="$HOME"; CLEAN_HOME="$(mktemp -d /tmp/avalanche-vault-clean-home.XXXXXX)"
mkdir -p "$CLEAN_HOME/.foundry/cache/rpc"
for d in "Library/Application Support/svm" ".svm"; do
  if [ -d "$REAL_HOME/$d" ]; then mkdir -p "$CLEAN_HOME/$(dirname "$d")"; ln -sfn "$REAL_HOME/$d" "$CLEAN_HOME/$d"; fi
done
CMD="forge test --threads 1 --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol --skip test/[!A]* --skip test/A[!v]* --skip test/Av[!a]* --skip test/Avalanche[!T]* --match-contract $SUITE -vv"
{
  echo "VAULT CLEAN REPRODUCTION vault=$V suite=$SUITE"
  echo "UTC start: $(date -u +%FT%TZ)"
  echo "git HEAD: $(git rev-parse HEAD)"
  echo "git status --short (contracts/):"; git status --short . | sed 's/^/  /'
  echo "RPC host: $(echo "$AVALANCHE_MAINNET_RPC_URL" | sed -E 's#^(https?://[^/]+).*#\1#')  (direct, no proxy)"
  echo "env: HOME=$CLEAN_HOME (isolated, empty .foundry/cache/rpc; svm symlinked for solc only) FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_vault_repro FOUNDRY_CACHE_PATH=cache_vault_repro TRACKA_PIN_BLOCK=$PIN"
  echo "forge: $(forge --version | head -1)"
  echo "command: HOME=$CLEAN_HOME $CMD"
  echo "-----"
} > "$LOG"
HOME="$CLEAN_HOME" FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_vault_repro FOUNDRY_CACHE_PATH=cache_vault_repro TRACKA_PIN_BLOCK="$PIN" $CMD >> "$LOG" 2>&1
rc=$?
echo "-----" >> "$LOG"; echo "UTC end: $(date -u +%FT%TZ)  forge exit: $rc" >> "$LOG"
rm -rf "$CLEAN_HOME"
exit $rc
