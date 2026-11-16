#!/usr/bin/env bash
# The exact commands of the PHAR rewards DISTRIBUTOR deployment (design A) as one wrapper, in the style of tools/dlmm-vault-ceremony.sh: the local-fork rehearsal and the
# live run differ only in the signer and the endpoint. NOT RUN by the agent that wrote it.
#   usage: tools/dlmm-rewards-ceremony.sh <list|check-env|deploy|verify> <rehearsal|live>      (run from contracts/vault-dlmm)
#
#   list            prints the ordered ceremony (deployment + the first epoch) as text; pure, no RPC.
#   check-env       every input is set; the deployer is not the Ledger / the Safe. Pure, no RPC.
#   deploy          signer = a THROWAWAY DEPLOYER: forge script script/DeployPharRewardsDistributor.s.sol (pre-flight on chain first, then ONE transaction).
#   verify          read-only: forge script ReadBackPharRewardsDistributor (DISTRIBUTOR=<address>).
#
#   rehearsal : endpoint = a LOCAL anvil fork (RPC_LOCAL, default http://127.0.0.1:8545); the deployer is an unlocked (impersonated) fresh address; refuses to run unless the
#               endpoint answers the anvil-only method anvil_nodeInfo. Nothing real. NOTE: the pre-flight requires chain id 43114, i.e. an anvil fork of Avalanche.
#   live      : endpoint = the foundry.toml alias `avalanche` = ${AVALANCHE_MAINNET_RPC_URL} (the ENVIRONMENT; never an argument, never printed: every line of output passes
#               through a redaction of http(s) URLs). The deployer is a Foundry keystore named by DLMM_DEPLOYER_ACCOUNT (forge prompts for the password).
#               AGENTS NEVER RUN "live": the operator does.
#
# Environment (public values): DEPLOYER [, CLAIM_DELAY (default 86400), CLAIM_DEADLINE (default 15552000)]; verify also DISTRIBUTOR [, EXPECT_DELAY, EXPECT_DEADLINE, EXPECT_OWNER_SAFE=true].
set -uo pipefail
cd "$(dirname "$0")/.."
STEP="${1:-}"; MODE="${2:-}"
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12
usage() { echo "usage: $0 <list|check-env|deploy|verify> <rehearsal|live>" >&2; exit 2; }
[ -n "$STEP" ] || usage
if [ "$STEP" = list ]; then
  cat <<'LIST'
CEREMONY: PHAR rewards distributor (design A). Every Safe step = ONE Ledger confirmation through the Peridot Safe; read-backs are `cast call` on the live endpoint.
 A. DEPLOY (once)
   A1  operator: make a throwaway deployer key (Foundry keystore), fund it with gas, export DEPLOYER (public address) and DLMM_DEPLOYER_ACCOUNT
   A2  tools/dlmm-rewards-ceremony.sh check-env live
   A3  tools/dlmm-rewards-ceremony.sh deploy live            (pre-flight: chain, Safe 1-of-1, vault owner = Safe, vault.rewardToken() == PHAR; ONE tx; writes ceremony/dlmm-rewards-addresses.live.env)
   A4  DISTRIBUTOR=<address> EXPECT_OWNER_SAFE=true tools/dlmm-rewards-ceremony.sh verify live      (owner = Safe, PHAR, 1 day, 180 days, epochCount 0)
   A5  record the address, the runtime codehash and the source sha256 in the handoff; delete the deployer key
 B. EACH EPOCH (see docs/deployment-handoffs/avalanche-dlmm-vault-rewards-distribution.md section 6, the exact order)
   B1  Safe: vault.harvestRewards()                          tools/dlmm-safe-call.sh send $VAULT 'harvestRewards()'   (read back PharHarvested, PHAR balance of the Safe)
   B2  off chain: cast call $DIST 'epochCount()(uint256)'  ->  node tools/dlmm-rewards-root.mjs ...  ->  publish report + proofs publicly; a second person re-runs it
   B3  Safe: PHAR.approve(distributor, total)   (exact)       tools/dlmm-rewards-safe-call.sh send approve ...
   B4  Safe: distributor.publishEpoch(root, total)            tools/dlmm-rewards-safe-call.sh send publish ...         (read back epochInfo, balances, allowance 0)
   B5  inside 24 h only, if anything is wrong: Safe: cancelEpoch(id), then regenerate for the NEW id
   B6  after claimOpensAt: claims are open (anyone can submit; PHAR goes to the account in the leaf)
   B7  after publishedAt + 180 days: Safe: sweepUnclaimed(id)  tools/dlmm-rewards-safe-call.sh send sweep ...
LIST
  exit 0
fi
[ -n "$MODE" ] || usage
case "$MODE" in rehearsal|live) ;; *) usage ;; esac
REDACT() { sed -E 's#https?://[^[:space:]"]+#<url-redacted>#g'; }
lc() { echo "$1" | tr 'A-Z' 'a-z'; }

check_env() {
  local bad=0
  [ -n "${DEPLOYER:-}" ] || { echo "UNSET: DEPLOYER" >&2; bad=1; }
  [[ "${DEPLOYER:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "DEPLOYER is not an address" >&2; bad=1; }
  if [ "$(lc "${DEPLOYER:-x}")" = "$(lc $LEDGER)" ] || [ "$(lc "${DEPLOYER:-x}")" = "$(lc $SAFE)" ]; then echo "DEPLOYER must not be the Ledger or the Safe" >&2; bad=1; fi
  [[ "${CLAIM_DELAY:-86400}" =~ ^[0-9]+$ && "${CLAIM_DEADLINE:-15552000}" =~ ^[0-9]+$ ]] || { echo "CLAIM_DELAY / CLAIM_DEADLINE must be integers (seconds)" >&2; bad=1; }
  if [ "$STEP" = verify ]; then [[ "${DISTRIBUTOR:-}" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "DISTRIBUTOR is not set / not an address" >&2; bad=1; }; fi
  if [ "$MODE" = live ] && [ "$STEP" = deploy ]; then [ -n "${DLMM_DEPLOYER_ACCOUNT:-}" ] || { echo "UNSET: DLMM_DEPLOYER_ACCOUNT (the Foundry keystore name of the throwaway deployer)" >&2; bad=1; }; fi
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
  check-env) check_env; echo "all inputs set; the deployer is neither the Ledger nor the Safe" ;;
  deploy)
    check_env
    echo "== deploy ($MODE): signer = the throwaway deployer ${DEPLOYER}"
    OUT="$(FS script/DeployPharRewardsDistributor.s.sol:DeployPharRewardsDistributor "${DEPLOYER_SIGN[@]}" --broadcast --slow --timeout 300 --retries 10 -vv)"; RC=$?
    echo "$OUT"
    FILE="${DLMM_REWARDS_ADDRESSES_FILE:-ceremony/dlmm-rewards-addresses.$MODE.env}"
    mkdir -p "$(dirname "$FILE")"
    { for k in PHAR_DISTRIBUTOR PHAR_DISTRIBUTOR_CODEHASH; do
        a="$(echo "$OUT" | grep -E "^[[:space:]]*$k=0x[0-9a-fA-F]+" | tail -1 | sed -E "s/^[[:space:]]*//")"
        echo "export ${a:-$k=MISSING}"
      done; } > "$FILE"
    echo "addresses written to $FILE (PUBLIC values only)"; grep -c "=0x" "$FILE" | sed 's/^/values found: /'
    exit $RC ;;
  verify)
    check_env
    echo "== read-back ($MODE): read-only, no broadcast"
    FS script/DeployPharRewardsDistributor.s.sol:ReadBackPharRewardsDistributor -vv ;;
  *) usage ;;
esac
