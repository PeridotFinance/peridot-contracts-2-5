#!/usr/bin/env bash
# ONE owner action on the DLMM vault through the Peridot Safe (1-of-1, owner = the Ledger, "approved by msg.sender" signature): ONE Ledger confirmation.
# `tools/safe-set-deposit-cap.sh` of the margin work refuses every vault but the two pilot proxies, so the DLMM vault has its own: this tool refuses every call but the
# brakes and settings the ceremony names.
#   usage:  tools/dlmm-safe-call.sh <simulate|send> <vault> '<function signature>' [args...]
#   e.g.    tools/dlmm-safe-call.sh simulate $V 'pause()'
#           tools/dlmm-safe-call.sh send     $V 'setDepositCap(uint256)' 1
#           tools/dlmm-safe-call.sh send     $V 'setRebalancer(address)' 0x...
#           tools/dlmm-safe-call.sh send     $V 'clearGuard()'
#   allowed: pause() unpause() clearGuard() setDepositCap(uint256) setRebalancer(address) setGuardParams((uint16,uint32,uint16,uint32,uint16,uint16,uint16))
#   environment: ETH_RPC_URL (read; never an argument), SEND_MODE=ledger (default, OPERATOR-ONLY) | unlocked (a LOCAL anvil fork only; refused unless anvil_nodeInfo answers),
#                GAS_LIMIT (default 1500000). `simulate` is an eth_call from the Ledger: it must print true (a failing inner call makes the Safe revert GS013).
set -euo pipefail
MODE_CMD="${1:-}"; V="${2:-}"; SIGN="${3:-}"; shift 3 || true
case "$MODE_CMD" in simulate|send) ;; *) echo "usage: $0 <simulate|send> <vault> '<signature>' [args...]" >&2; exit 2;; esac
[[ "$V" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "vault is not an address" >&2; exit 2; }
case "$SIGN" in
  'pause()'|'unpause()'|'clearGuard()'|'setDepositCap(uint256)'|'setRebalancer(address)'|'setGuardParams((uint16,uint32,uint16,uint32,uint16,uint16,uint16))') ;;
  *) echo "function not allowed here: $SIGN" >&2; exit 2;;
esac
: "${ETH_RPC_URL:?set ETH_RPC_URL in the environment}"
SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12; LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; Z=0x0000000000000000000000000000000000000000
SIG=0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001
EXEC='execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)'
[ "$(cast chain-id)" = 43114 ] || { echo "chain id is not 43114" >&2; exit 1; }
[ "$(cast call "$SAFE" 'getOwners()(address[])')" = "[$LEDGER]" ] || { echo "Safe owners are not exactly [the Ledger]" >&2; exit 1; }
[ "$(cast call "$V" 'owner()(address)' | tr A-Z a-z)" = "$(echo $SAFE | tr A-Z a-z)" ] || { echo "the vault's owner is not the Safe: wrong address?" >&2; exit 1; }
DATA="$(cast calldata "$SIGN" "$@")"
echo "DECODED CALL: vault $V  $SIGN $*"
echo "  calldata $DATA   (Safe execTransaction, operation 0 CALL, value 0, signer the Ledger via the Safe)"
echo "before: paused=$(cast call "$V" 'paused()(bool)')  depositCap=$(cast call "$V" 'depositCap()(uint256)' | awk '{print $1}')  rebalancer=$(cast call "$V" 'rebalancer()(address)')  guardState=$(cast call "$V" 'guardState()(bool,bool,uint256)' | tr '\n' ' ')  safe nonce=$(cast call $SAFE 'nonce()(uint256)')"
RES="$(cast call "$SAFE" "$EXEC(bool)" "$V" 0 "$DATA" 0 0 0 0 $Z $Z $SIG --from "$LEDGER" 2>&1)" || {
  echo "simulation FAILED: $RES" >&2
  echo "inner call as the Safe (the real revert reason; the Safe itself only says GS013): $(cast call "$V" "$DATA" --from "$SAFE" 2>&1 | tail -3 | tr '\n' ' ')" >&2
  exit 1
}
echo "SIMULATION (eth_call from the Ledger, MANDATORY before signing; must be true): $RES"
[ "$RES" = true ] || exit 1
[ "$MODE_CMD" = send ] || exit 0
GAS="${GAS_LIMIT:-1500000}"
echo "ABOUT TO SIGN: Safe nonce $(cast call "$SAFE" 'nonce()(uint256)'), $SIGN $*, mode ${SEND_MODE:-ledger}"
if [ "${SEND_MODE:-ledger}" = unlocked ]; then
  cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "SEND_MODE=unlocked is for a LOCAL anvil fork only" >&2; exit 3; }
  cast send "$SAFE" "$EXEC" "$V" 0 "$DATA" 0 0 0 0 $Z $Z $SIG --unlocked --from "$LEDGER" --gas-limit "$GAS"
else
  echo "OPERATOR-ONLY: one Ledger confirmation"
  cast send "$SAFE" "$EXEC" "$V" 0 "$DATA" 0 0 0 0 $Z $Z $SIG --ledger --from "$LEDGER" --gas-limit "$GAS"
fi
echo "after: paused=$(cast call "$V" 'paused()(bool)')  depositCap=$(cast call "$V" 'depositCap()(uint256)' | awk '{print $1}')  rebalancer=$(cast call "$V" 'rebalancer()(address)')  guardState=$(cast call "$V" 'guardState()(bool,bool,uint256)' | tr '\n' ' ')  safe nonce=$(cast call $SAFE 'nonce()(uint256)')"
