#!/usr/bin/env bash
# The exact commands of the mainnet Pharaoh DLMM USDC/USDt vault DEPLOYMENT as one wrapper, so that the fork rehearsal and the live run differ only in the
# signer and the endpoint (same discipline as contracts/tools/avalanche-margin-ceremony.sh).
#   usage: tools/dlmm-vault-ceremony.sh <check-env|deploy|deploy-resume|verify> <rehearsal|live>      (run from contracts/vault-dlmm)
#
#   check-env       every input is set; the deployer is not the Ledger / the Safe / the keeper. Pure, no RPC.
#   deploy          STAGE 1, signer = the THROWAWAY DEPLOYER: forge script script/DeployPharaohDlmmVault.s.sol (pre-flight on chain first, then 2 transactions).
#   deploy-resume   ONLY after a deploy that stopped half-way: broadcasts the saved transactions that were not sent (forge --resume); redeploys nothing.
#   verify          read-only: forge script script/ReadBackPharaohDlmmVault.s.sol (STAGE=1 after the deploy, STAGE=2 after the Safe MultiSend).
#
#   rehearsal : endpoint = a LOCAL anvil fork (RPC_LOCAL, default http://127.0.0.1:8545); the deployer is an unlocked (impersonated) fresh address; the tool refuses
#               to run unless the endpoint answers the anvil-only method anvil_nodeInfo. Nothing real.
#   live      : endpoint = the foundry.toml alias `avalanche` = ${AVALANCHE_MAINNET_RPC_URL} (the ENVIRONMENT; never an argument, never printed: every line of output
#               passes through a redaction of http(s) URLs). The deployer is a Foundry keystore named by DLMM_DEPLOYER_ACCOUNT (forge prompts for the password).
#               AGENTS NEVER RUN "live": the operator does.
#
# Environment (public values): DEPLOYER, REBALANCER, EXPECTED_REWARDER_IMPL_CODEHASH [, VAULT_NAME, VAULT_SYMBOL]; verify also VAULT, STAGE, SEED, EXPECTED_DEPLOYER_NONCE.
set -uo pipefail
cd "$(dirname "$0")/.."
STEP="${1:-}"; MODE="${2:-}"
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12
usage() { echo "usage: $0 <check-env|deploy|deploy-resume|verify> <rehearsal|live>" >&2; exit 2; }
[ -n "$STEP" ] && [ -n "$MODE" ] || usage
case "$MODE" in rehearsal|live) ;; *) usage ;; esac
REDACT() { sed -E 's#https?://[^[:space:]"]+#<url-redacted>#g'; }
lc() { echo "$1" | tr 'A-Z' 'a-z'; }

check_env() {
  local bad=0 v
  for v in DEPLOYER REBALANCER EXPECTED_REWARDER_IMPL_CODEHASH; do if [ -z "${!v:-}" ]; then echo "UNSET: $v" >&2; bad=1; fi; done
  for v in DEPLOYER REBALANCER; do [[ "${!v:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "$v is not an address" >&2; bad=1; }; done
  [[ "${EXPECTED_REWARDER_IMPL_CODEHASH:-}" =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo "EXPECTED_REWARDER_IMPL_CODEHASH is not a bytes32" >&2; bad=1; }
  for v in DEPLOYER REBALANCER; do
    if [ "$(lc "${!v:-x}")" = "$(lc $LEDGER)" ] || [ "$(lc "${!v:-x}")" = "$(lc $SAFE)" ]; then echo "$v must not be the Ledger or the Safe" >&2; bad=1; fi
  done
  [ "$(lc "${DEPLOYER:-a}")" != "$(lc "${REBALANCER:-b}")" ] || { echo "DEPLOYER must not be the REBALANCER (the deployer holds no role)" >&2; bad=1; }
  if [ "$STEP" = verify ]; then [[ "${VAULT:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "VAULT (the proxy) is not set / not an address" >&2; bad=1; }; fi
  if [ "$MODE" = live ] && [ "$STEP" != verify ] && [ "$STEP" != check-env ]; then [ -n "${DLMM_DEPLOYER_ACCOUNT:-}" ] || { echo "UNSET: DLMM_DEPLOYER_ACCOUNT (the Foundry keystore name of the throwaway deployer)" >&2; bad=1; }; fi
  [ "$bad" = 0 ] || exit 1
}

if [ "$MODE" = live ]; then
  : "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment (never as an argument)}"
  RPC=(--rpc-url avalanche)
  DEPLOYER_SIGN=(--account "${DLMM_DEPLOYER_ACCOUNT:-unset}" --sender "${DEPLOYER:-}")
else
  LOCAL="${RPC_LOCAL:-http://127.0.0.1:8545}"
  if [ "$STEP" != check-env ]; then
    cast rpc --rpc-url "$LOCAL" anvil_nodeInfo >/dev/null 2>&1 || { echo "rehearsal mode needs a LOCAL anvil fork at the local endpoint (it answers anvil_nodeInfo): refusing" >&2; exit 3; }
  fi
  RPC=(--rpc-url "$LOCAL")
  DEPLOYER_SIGN=(--unlocked --sender "${DEPLOYER:-}")
fi

FS() { forge script "$1" "${RPC[@]}" "${@:2}" 2>&1 | REDACT; return "${PIPESTATUS[0]}"; }

case "$STEP" in
  check-env) check_env; echo "all inputs set; the deployer is not the Ledger, the Safe or the keeper" ;;
  deploy)
    check_env
    echo "== STAGE 1 deploy ($MODE): signer = the throwaway deployer ${DEPLOYER}"
    OUT="$(FS script/DeployPharaohDlmmVault.s.sol:DeployPharaohDlmmVault "${DEPLOYER_SIGN[@]}" --broadcast --slow --timeout 300 --retries 10 -vv)"; RC=$?
    echo "$OUT"
    FILE="${DLMM_ADDRESSES_FILE:-ceremony/dlmm-vault-addresses.$MODE.env}"
    mkdir -p "$(dirname "$FILE")"
    { for k in DLMM_IMPLEMENTATION DLMM_VALIDATOR DLMM_VAULT DLMM_PROXY_ADMIN DLMM_REWARDER_IMPL_CODEHASH; do
        a="$(echo "$OUT" | grep -E "^[[:space:]]*$k=0x[0-9a-fA-F]+" | tail -1 | sed -E "s/^[[:space:]]*//")"
        echo "export ${a:-$k=MISSING}"
      done; } > "$FILE"
    echo "addresses written to $FILE (PUBLIC values only)"; grep -c "=0x" "$FILE" | sed 's/^/addresses found: /'
    exit $RC ;;
  deploy-resume)
    check_env
    echo "== STAGE 1 RESUME ($MODE): sends only the saved transactions that were not sent"
    FS script/DeployPharaohDlmmVault.s.sol:DeployPharaohDlmmVault "${DEPLOYER_SIGN[@]}" --broadcast --resume --slow --timeout 300 --retries 10 -vv ;;
  verify)
    check_env
    echo "== read-back ($MODE), stage ${STAGE:-1}: read-only, no broadcast"
    FS script/ReadBackPharaohDlmmVault.s.sol:ReadBackPharaohDlmmVault -vv ;;
  *) usage ;;
esac
