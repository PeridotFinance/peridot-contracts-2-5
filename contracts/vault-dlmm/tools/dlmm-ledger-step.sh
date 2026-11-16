#!/usr/bin/env bash
# The PLAIN (non-Safe) transactions of the DLMM ceremony, each with a MANDATORY eth_call simulation first, the decoded call and the signer's nonce printed before the signer is invoked.
#   usage:  tools/dlmm-ledger-step.sh <simulate|send> <step>
#   steps (signer in brackets):
#     fund-safe-usdc   [Ledger]    USDC.transfer(Safe, USDC_TOTAL * 1e6), USDC_TOTAL default 200: the Safe pays the MultiSend, so it must hold the whole amount first
#     fund-deployer    [Ledger]    AVAX transfer to $DEPLOYER, DEPLOYER_AVAX default 0.3 (the gas of the two deploy transactions plus margin, see the ceremony)
#     fund-keeper      [Ledger]    AVAX transfer to $KEEPER_WALLET, KEEPER_AVAX default 1 (the keeper's gas runway; proposed amount, the operator decides)
#     sweep-deployer   [deployer]  the deployer's leftover AVAX back to the Ledger (keeps a gas reserve of 3 x 21000 x gas price)
#   environment: ETH_RPC_URL (environment only, never an argument, never printed); DEPLOYER, KEEPER_WALLET as the step needs;
#     SEND_MODE=ledger (default, OPERATOR-ONLY) | unlocked (LOCAL anvil fork only; refused unless anvil_nodeInfo answers);
#     for sweep-deployer in ledger mode: DLMM_DEPLOYER_ACCOUNT (the Foundry keystore name of the throwaway deployer; forge/cast prompts for its password).
# `send` always runs the simulation first and stops unless it passes. Nothing is signed by `simulate`.
set -euo pipefail
CMD="${1:-}"; STEP="${2:-}"
case "$CMD" in simulate|send) ;; *) echo "usage: $0 <simulate|send> <fund-safe-usdc|fund-deployer|fund-keeper|sweep-deployer>" >&2; exit 2;; esac
: "${ETH_RPC_URL:?set ETH_RPC_URL in the environment}"
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12; USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
[ "$(cast chain-id)" = 43114 ] || { echo "chain id is not 43114" >&2; exit 1; }
isaddr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
lc() { echo "$1" | tr A-Z a-z; }
case "$STEP" in
  fund-safe-usdc)
    FROM=$LEDGER; TO=$USDC; SIGN='transfer(address,uint256)'; AMT=$(( ${USDC_TOTAL:-200} * 1000000 )); VALUE=0
    DATA="$(cast calldata "$SIGN" "$SAFE" "$AMT")"
    DECODED="USDC.transfer(to = the Safe $SAFE, amount = $AMT raw = USD $(( AMT / 1000000 )))"
    echo "Ledger USDC balance: $(cast call $USDC 'balanceOf(address)(uint256)' $LEDGER | awk '{print $1}') raw   Safe USDC balance: $(cast call $USDC 'balanceOf(address)(uint256)' $SAFE | awk '{print $1}') raw" ;;
  fund-deployer|fund-keeper)
    FROM=$LEDGER; DATA=0x; SIGN=
    if [ "$STEP" = fund-deployer ]; then TO="${DEPLOYER:?DEPLOYER}"; AMT_E="${DEPLOYER_AVAX:-0.3}"; else TO="${KEEPER_WALLET:?KEEPER_WALLET}"; AMT_E="${KEEPER_AVAX:-1}"; fi
    isaddr "$TO" || { echo "recipient is not an address" >&2; exit 2; }
    [ "$(lc "$TO")" != "$(lc $LEDGER)" ] && [ "$(lc "$TO")" != "$(lc $SAFE)" ] || { echo "recipient must not be the Ledger or the Safe" >&2; exit 2; }
    VALUE="$(cast to-wei "$AMT_E")"; DECODED="plain AVAX transfer of $AMT_E AVAX ($VALUE wei) to $TO (code at the recipient: $(cast code "$TO" | wc -c | awk '{print ($1>3?"HAS CODE":"none (an EOA)")}'))"
    echo "Ledger AVAX balance: $(cast balance $LEDGER --ether)   recipient AVAX balance: $(cast balance "$TO" --ether)" ;;
  sweep-deployer)
    FROM="${DEPLOYER:?DEPLOYER}"; TO=$LEDGER; DATA=0x; SIGN=
    isaddr "$FROM" || { echo "DEPLOYER is not an address" >&2; exit 2; }
    GP="$(cast gas-price)"; BAL="$(cast balance "$FROM")"; RES=$(( 3 * 21000 * GP * 2 ))
    [ "$BAL" -gt "$RES" ] || { echo "the deployer balance ($BAL wei) is below the gas reserve ($RES wei): nothing to sweep" >&2; exit 1; }
    VALUE=$(( BAL - RES )); DECODED="plain AVAX transfer of $VALUE wei (balance $BAL minus a reserve of $RES) from the deployer to the Ledger $LEDGER"
    echo "deployer AVAX balance: $(cast balance "$FROM" --ether)" ;;
  *) echo "unknown step $STEP" >&2; exit 2;;
esac
NONCE="$(cast nonce "$FROM")"
echo "STEP $STEP"
echo "  signer             $FROM   (nonce $NONCE)"
echo "  to                 $TO"
echo "  decoded call       $DECODED"
echo "  calldata           $DATA"
# MANDATORY SIMULATION (eth_call from the signer, with the value)
if [ "$DATA" = 0x ]; then SIMOUT="$(cast call "$TO" --from "$FROM" --value "$VALUE" 2>&1)" || { echo "SIMULATION FAILED: $SIMOUT" >&2; exit 1; }
else SIMOUT="$(cast call "$TO" 'transfer(address,uint256)(bool)' "$SAFE" "$AMT" --from "$FROM" 2>&1)" || { echo "SIMULATION FAILED: $SIMOUT" >&2; exit 1; }
  [ "$SIMOUT" = true ] || { echo "SIMULATION did not return true: '$SIMOUT'" >&2; exit 1; }; fi
echo "  simulation         passed (eth_call from the signer)"
[ "$CMD" = send ] || exit 0
echo "ABOUT TO SIGN: $STEP, nonce $NONCE, $DECODED"
MODE="${SEND_MODE:-ledger}"
if [ "$MODE" = unlocked ]; then
  cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "SEND_MODE=unlocked is for a LOCAL anvil fork only" >&2; exit 3; }
  SIGNARGS="--unlocked --from $FROM"
elif [ "$STEP" = sweep-deployer ]; then
  : "${DLMM_DEPLOYER_ACCOUNT:?DLMM_DEPLOYER_ACCOUNT (the Foundry keystore name of the deployer)}"; echo "OPERATOR-ONLY: the deployer keystore password prompt follows"
  SIGNARGS="--account $DLMM_DEPLOYER_ACCOUNT --from $FROM"
else
  echo "OPERATOR-ONLY: one Ledger confirmation"; SIGNARGS="--ledger --from $FROM"
fi
if [ "$DATA" = 0x ]; then cast send "$TO" --value "$VALUE" $SIGNARGS
else cast send "$TO" "$SIGN" "$SAFE" "$AMT" $SIGNARGS; fi
echo "after: signer nonce $(cast nonce "$FROM")"
if [ "$STEP" = fund-safe-usdc ]; then echo "Safe USDC now: $(cast call $USDC 'balanceOf(address)(uint256)' $SAFE | awk '{print $1}') raw"; else echo "recipient AVAX now: $(cast balance "$TO" --ether)"; fi
