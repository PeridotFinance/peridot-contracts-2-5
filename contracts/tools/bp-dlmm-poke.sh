#!/usr/bin/env bash
# Manual view/poke of the bpPHAR-USDC wrapper's "last good vault leg" (PharaohDlmmShareOracle v2). The recurring poke belongs to the operator build
# (operator/docs/bp-share-market-rollout.md); this is the by-hand version for the ceremony day and for incidents.
#   usage: tools/bp-dlmm-poke.sh <state|simulate|send>
#   environment: ETH_RPC_URL (the ENVIRONMENT only, never an argument), BP_ORACLE (the wrapper; default: read from ceremony/bp-dlmm-addresses.env)
#   send: signer = the Ledger (default, `--ledger`), or a Foundry keystore account when BP_POKER_ACCOUNT is set (password prompted by cast).
# `poke()` is permissionless: it only ever stores the vault's OWN live answer, at most +2% per accepted poke and once per hour upward (lower values at once), and does
# nothing while the vault cannot answer. state/simulate sign nothing. send runs the simulation first and refuses to send when it returns false (a refused poke would only burn gas).
set -uo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-}"; case "$MODE" in state|simulate|send) ;; *) echo "usage: $0 <state|simulate|send>" >&2; exit 2;; esac
[ -n "${ETH_RPC_URL:-}" ] || { echo "ETH_RPC_URL must be set in the ENVIRONMENT" >&2; exit 1; }
ADDR_FILE="${BP_ADDRESSES_FILE:-ceremony/bp-dlmm-addresses.env}"
[ -z "${BP_ORACLE:-}" ] && [ -f "$ADDR_FILE" ] && . "$ADDR_FILE"
[ -n "${BP_ORACLE:-}" ] || { echo "BP_ORACLE is unset (written by 'bp-dlmm-ceremony.sh deploy' to $ADDR_FILE)" >&2; exit 1; }
LEDGER="0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD"
REDACT() { python3 -I tools/avalanche-redact-rpc.py ETH_RPC_URL; }
u() { awk '{print $1}'; }
[ "$(cast chain-id 2>/dev/null)" = 43114 ] || { echo "chain id is not 43114" >&2; exit 1; }

state() {
  local live stored at fb left now
  read -r live stored at fb left < <(cast call "$BP_ORACLE" 'shareState()(uint256,uint256,uint64,bool,uint256)' 2>&1 | REDACT | u | tr '\n' ' ')
  now="$(cast block latest --field timestamp 2>/dev/null)"
  echo "wrapper $BP_ORACLE"
  echo "live vault leg (assets per whole share, 6 dp; 0 = the vault cannot answer): $live"
  echo "stored last-good leg: $stored   stored at: $at (age $(( now - at )) s)   block time: $now"
  echo "serving the FALLBACK now: $fb   fallback seconds left: $left"
  echo "share USD price (1e18): $(cast call "$BP_ORACLE" 'getShareUsdPrice()(uint256)' 2>&1 | REDACT | u)"
}
sender() { if [ -n "${BP_POKER_ACCOUNT:-}" ]; then cast wallet address --account "$BP_POKER_ACCOUNT" 2>&1; else echo "$LEDGER"; fi; }

state
[ "$MODE" = state ] && exit 0
FROM="$(sender)"
SIM="$(cast call --from "$FROM" "$BP_ORACLE" 'poke()(bool)' 2>&1 | REDACT | u)"
echo "SIMULATION (poke() from $FROM): $SIM   (true = a value would be stored; false = the vault cannot answer, or an upward move came inside 1 h of the last store)"
[ "$MODE" = simulate ] && exit 0
[ "$SIM" = true ] || { echo "refusing to send: the simulation did not return true" >&2; exit 1; }
if [ -n "${BP_POKER_ACCOUNT:-}" ]; then cast send --account "$BP_POKER_ACCOUNT" "$BP_ORACLE" 'poke()' 2>&1 | REDACT
else cast send --ledger --from "$LEDGER" "$BP_ORACLE" 'poke()' 2>&1 | REDACT; fi
echo "--- read-back"; state
