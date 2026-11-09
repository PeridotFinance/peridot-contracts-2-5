#!/usr/bin/env bash
# The exact commands of the mainnet MARGIN 2x ceremony (long WAVAX / USDC on top of PW30) as ONE wrapper, so that the rehearsal on a fork and the live run
# differ only in the signers and the endpoint.
#   usage: tools/avalanche-margin-ceremony.sh <check-env|deploy|wire|execute|enable|verify> <rehearsal|live>
#
#   STAGE 1  deploy   signer: the THROWAWAY DEPLOYER (an unprivileged key; live: a Foundry keystore named by MARGIN_DEPLOYER_ACCOUNT, password prompted by forge)
#   STAGE 2  wire     signer: the LEDGER   (role grants, hooks, seeds, queues every timelocked action)
#   STAGE 3  execute  signer: the LEDGER   (>= MARGIN_ACTION_DELAY after wire: pair risk + funded liquidators; opens stay paused)
#   STAGE 4  enable   signer: the LEDGER   (only after `verify` at STAGE=3 passes; executes the queued unpause)
#   verify            read-only; STAGE=1..4 in the environment (the deployer-holds-nothing rule is checked at every stage)
#
#   rehearsal : endpoint = a LOCAL anvil fork (RPC_LOCAL, default http://127.0.0.1:8545), accounts impersonated, nothing real.
#   live      : endpoint = AVALANCHE_MAINNET_RPC_URL from the ENVIRONMENT (never an argument, never printed: it reaches forge only through a generated config
#               alias and all output passes through tools/avalanche-redact-rpc.py). THE ASSISTANT NEVER RUNS "live": the operator does, with the device in hand.
set -uo pipefail
cd "$(dirname "$0")/.."
STEP="${1:-}"; MODE="${2:-}"
LEDGER="0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD"
COMMON=(MARGIN_DEPLOYER MARGIN_OWNER CONTROLLER PWAVAX PUSDC MARGIN_CAP_USD MARGIN_FLASH_SEED_USDC MARGIN_INSURANCE_SEED_USDC MARGIN_FUNDERS)
DEPLOYED=(M_ORACLE M_INSURANCE_FUND M_CONFIG M_FEE_DISTRIBUTOR M_VAULT M_RISK_ENGINE M_QUOTER M_SWAP_MODULE M_ACCOUNT_FACTORY M_EXECUTOR_IMPL M_EXECUTOR M_LIQUIDATOR M_FLASH_VAULT M_CL_ADAPTER M_REGISTRY_IMPL M_REGISTRY M_CLOSE_ADAPTER)
LABELS=("oracle \(PW30 guarded, reused\)" insuranceFund config feeDistributor vault riskEngine quoter swapModule accountFactory executorImpl executor liquidator flashVault clAdapter registryImpl registry closeAdapter)
SKIP=(--skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol)
SCRIPT=script/DeployAvalancheMarginMainnet.s.sol
usage() { echo "usage: $0 <check-env|deploy|wire|execute|enable|verify> <rehearsal|live>" >&2; exit 2; }
[ -n "$STEP" ] && [ -n "$MODE" ] || usage
case "$MODE" in rehearsal|live) ;; *) usage ;; esac

check_env() {
  local bad=0 v
  for v in "${COMMON[@]}"; do if [ -z "${!v:-}" ]; then echo "UNSET: $v" >&2; bad=1; fi; done
  if [ "${MARGIN_OWNER:-}" != "$LEDGER" ]; then echo "MARGIN_OWNER must be the Ledger $LEDGER (got '${MARGIN_OWNER:-}')" >&2; bad=1; fi
  if [ "${MARGIN_DEPLOYER:-}" = "$LEDGER" ]; then echo "MARGIN_DEPLOYER must NOT be the Ledger: it is a throwaway, unprivileged key" >&2; bad=1; fi
  case "$STEP" in wire|execute|enable|verify)
    for v in "${DEPLOYED[@]}"; do if [ -z "${!v:-}" ]; then echo "UNSET: $v (the addresses printed by the deploy step)" >&2; bad=1; fi; done ;;
  esac
  [ "$bad" = 0 ] || exit 1
}

if [ "$MODE" = "live" ]; then
  : "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment (never as an argument)}"
  CFGDIR="$(mktemp -d /tmp/avalanche-margin-ceremony.XXXXXX)"; trap 'rm -rf "$CFGDIR"' EXIT
  git show HEAD:./foundry.toml > "$CFGDIR/foundry-ceremony.toml"
  if grep -q "^\[rpc_endpoints\]" "$CFGDIR/foundry-ceremony.toml"; then echo "committed foundry.toml already has [rpc_endpoints]; alias injection not supported" >&2; exit 2; fi
  printf '\n[rpc_endpoints]\navalanche_ceremony = "${AVALANCHE_MAINNET_RPC_URL}"\n' >> "$CFGDIR/foundry-ceremony.toml"
  export FOUNDRY_CONFIG="$CFGDIR/foundry-ceremony.toml"
  RPC=(--rpc-url avalanche_ceremony)
  : "${MARGIN_DEPLOYER_ACCOUNT:=}"
  DEPLOYER_SIGN=(--account "${MARGIN_DEPLOYER_ACCOUNT:-unset}" --sender "${MARGIN_DEPLOYER:-}")
  LEDGER_SIGN=(--ledger --sender "$LEDGER")
  FILTER() { python3 -I tools/avalanche-redact-rpc.py AVALANCHE_MAINNET_RPC_URL; }
else
  RPC=(--rpc-url "${RPC_LOCAL:-http://127.0.0.1:8545}")
  DEPLOYER_SIGN=(--unlocked --sender "${MARGIN_DEPLOYER:-}")
  LEDGER_SIGN=(--unlocked --sender "$LEDGER")
  FILTER() { cat; }
fi

FS() { FOUNDRY_PROFILE=debt_accounting forge script "$SCRIPT:$1" "${RPC[@]}" "${@:2}" "${SKIP[@]}" 2>&1 | FILTER; }

case "$STEP" in
  check-env) check_env; echo "all inputs set; the owner is the Ledger and the deployer is not" ;;
  deploy)
    check_env
    echo "== STAGE 1 deploy ($MODE): signer = the throwaway deployer ${MARGIN_DEPLOYER}"
    OUT="$(FS DeployAvalancheMarginMainnet "${DEPLOYER_SIGN[@]}" --broadcast --slow --timeout 300 --retries 10 -vvv)"; RC=$?
    echo "$OUT"
    # write the addresses file the later stages source (PUBLIC values only)
    FILE="${MARGIN_ADDRESSES_FILE:-ceremony/margin-addresses.env}"
    { for i in "${!DEPLOYED[@]}"; do
        a="$(echo "$OUT" | grep -E "^\s*${LABELS[$i]}[: ]+0x[0-9a-fA-F]{40}" | tail -1 | grep -oE "0x[0-9a-fA-F]{40}")"
        echo "export ${DEPLOYED[$i]}=$a"
      done; } > "$FILE"
    echo "addresses written to $FILE"; grep -c "=0x" "$FILE" | sed 's/^/addresses found: /'
    exit $RC ;;
  wire)    check_env; echo "== STAGE 2 wire ($MODE): signer = the Ledger"; FS OperateAvalancheMarginMainnet --sig 'wire()' "${LEDGER_SIGN[@]}" --broadcast --slow --timeout 300 --retries 10 -vvv ;;
  execute) check_env; echo "== STAGE 3 execute ($MODE): signer = the Ledger"; FS OperateAvalancheMarginMainnet --sig 'execute()' "${LEDGER_SIGN[@]}" --broadcast --slow --timeout 300 --retries 10 -vvv ;;
  enable)  check_env; echo "== STAGE 4 enable ($MODE): signer = the Ledger (verify STAGE=3 first)"; FS OperateAvalancheMarginMainnet --sig 'enable()' "${LEDGER_SIGN[@]}" --broadcast --slow --timeout 300 --retries 10 -vvv ;;
  verify)  check_env; : "${STAGE:?STAGE=1..4}"; FS OperateAvalancheMarginMainnet -vv ;;
  *) usage ;;
esac
