#!/usr/bin/env bash
# The exact commands of the mainnet deployment ceremony (cash-only lending, PW30), as ONE wrapper so that the rehearsal on a fork and the live run
# differ only in the signer and the endpoint.   usage: tools/avalanche-ceremony.sh <check-env|deploy|verify|print-env> <rehearsal|live>
#
#   rehearsal : endpoint = a LOCAL anvil fork (RPC_LOCAL, default http://127.0.0.1:8545), accounts impersonated (--unlocked --sender), nothing real.
#   live      : endpoint = the private archive RPC from the ENVIRONMENT (AVALANCHE_MAINNET_RPC_URL; never an argument, never printed: the URL reaches
#               forge only through a generated config alias and all output passes through tools/avalanche-redact-rpc.py), signer = the LEDGER
#               (--ledger --sender 0x064e...B2dD). THE ASSISTANT NEVER RUNS "live": the operator does, with the device in hand.
#
# Inputs: the 20 deployment variables, read from the environment (a ceremony env file with PUBLIC values only is `source`d first).
set -uo pipefail
cd "$(dirname "$0")/.."
STEP="${1:-}"; MODE="${2:-}"
LEDGER="0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD"
VARS=(DEPLOYER PERIDOT_TOKEN LENDING_ALLOW_NO_REWARD_TOKEN PAUSE_GUARDIAN LENDING_WAVAX_SEED_AMOUNT LENDING_USDC_SEED_AMOUNT LENDING_WAVAX_BORROW_CAP LENDING_USDC_BORROW_CAP LENDING_RESERVE_FACTOR LENDING_CLOSE_FACTOR LENDING_LIQUIDATION_INCENTIVE LENDING_BLOCKS_PER_YEAR LENDING_BASE_RATE_PER_YEAR LENDING_MULTIPLIER_PER_YEAR LENDING_JUMP_MULTIPLIER_PER_YEAR LENDING_KINK AVAX_FEED_MAX_AGE USDC_FEED_MAX_AGE LENDING_WAVAX_BORROW_CASH_FLOOR LENDING_USDC_BORROW_CASH_FLOOR)
SKIP=(--skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol)
usage() { echo "usage: $0 <check-env|print-env|deploy|verify> <rehearsal|live>" >&2; exit 2; }
[ -n "$STEP" ] && [ -n "$MODE" ] || usage
case "$MODE" in rehearsal|live) ;; *) usage ;; esac

check_env() {
  local bad=0
  for v in "${VARS[@]}"; do if [ -z "${!v:-}" ]; then echo "UNSET: $v" >&2; bad=1; fi; done
  if [ "${DEPLOYER:-}" != "$LEDGER" ]; then echo "DEPLOYER must be the Ledger $LEDGER (got '${DEPLOYER:-}')" >&2; bad=1; fi
  [ "$bad" = 0 ] || exit 1
}
print_env() { for v in "${VARS[@]}"; do printf '%s=%s\n' "$v" "${!v:-}"; done; }

# live: a generated Foundry config that defines the endpoint alias as an ENVIRONMENT REFERENCE (forge 1.7 ignores aliases defined in the environment)
if [ "$MODE" = "live" ]; then
  : "${AVALANCHE_MAINNET_RPC_URL:?AVALANCHE_MAINNET_RPC_URL must be set in the environment (never as an argument)}"
  CFGDIR="$(mktemp -d /tmp/avalanche-ceremony.XXXXXX)"; trap 'rm -rf "$CFGDIR"' EXIT
  git show HEAD:./foundry.toml > "$CFGDIR/foundry-ceremony.toml"
  if grep -q "^\[rpc_endpoints\]" "$CFGDIR/foundry-ceremony.toml"; then echo "committed foundry.toml already has [rpc_endpoints]; alias injection not supported" >&2; exit 2; fi
  printf '\n[rpc_endpoints]\navalanche_ceremony = "${AVALANCHE_MAINNET_RPC_URL}"\n' >> "$CFGDIR/foundry-ceremony.toml"
  export FOUNDRY_CONFIG="$CFGDIR/foundry-ceremony.toml"
  RPC=(--rpc-url avalanche_ceremony)
  SIGN=(--ledger --sender "$LEDGER")
  FILTER() { python3 -I tools/avalanche-redact-rpc.py AVALANCHE_MAINNET_RPC_URL; }
else
  RPC=(--rpc-url "${RPC_LOCAL:-http://127.0.0.1:8545}")
  SIGN=(--unlocked --sender "$LEDGER")
  FILTER() { cat; }
fi

case "$STEP" in
  check-env) check_env; echo "all 20 inputs set; DEPLOYER is the Ledger" ;;
  print-env) check_env; print_env ;;
  deploy)
    check_env
    echo "== deploy ($MODE): the script prints the addresses at the end; the broadcast file lists every transaction"
    FOUNDRY_PROFILE=debt_accounting forge script script/DeployAvalancheCashOnlyLending.s.sol:DeployAvalancheCashOnlyLending "${RPC[@]}" "${SIGN[@]}" --broadcast --slow --timeout 300 --retries 10 -vvv "${SKIP[@]}" 2>&1 | FILTER ;;
  verify)
    : "${CONTROLLER:?}" "${PWAVAX:?}" "${PUSDC:?}" "${EXPECTED_ADMIN:?}"
    check_env
    FOUNDRY_PROFILE=debt_accounting forge script script/DeployAvalancheCashOnlyLending.s.sol:VerifyAvalancheCashOnlyLending "${RPC[@]}" -vv "${SKIP[@]}" 2>&1 | FILTER ;;
  *) usage ;;
esac
