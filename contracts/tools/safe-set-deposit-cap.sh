#!/usr/bin/env bash
# Sets a Pharaoh vault's deposit cap through the pilot Safe (1-of-1, owner = the Ledger): ONE Ledger confirmation. Usage:
#   tools/safe-set-deposit-cap.sh <vault proxy> <cap units> [--send]
# Without --send it only simulates (eth_call from the Ledger) and prints the calldata; with --send it signs on the Ledger.
# ETH_RPC_URL must be set in the environment. Prints no secret.
set -euo pipefail
V="${1:?vault proxy}"; CAP="${2:?cap units}"; MODE="${3:-}"
: "${ETH_RPC_URL:?set ETH_RPC_URL}"
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12; Z=0x0000000000000000000000000000000000000000
SIG=0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001
VL="$(echo "$V" | tr A-Z a-z)"; USDC_V="0x855bF832f26a294d28500db59eE941dE3d654129"; WAVAX_V="0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8"
if [ "$VL" != "$(echo "$USDC_V" | tr A-Z a-z)" ] && [ "$VL" != "$(echo "$WAVAX_V" | tr A-Z a-z)" ]; then echo "not one of the two pilot vault proxies" >&2; exit 2; fi
DATA="$(cast calldata 'setDepositCap(uint256)' "$CAP")"
SIGN='execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)'
echo "vault $V  new cap $CAP  calldata $DATA"
echo "before: depositCap=$(cast call "$V" 'depositCap()(uint256)')  totalAssets=$(cast call "$V" 'totalAssets()(uint256)')  safe nonce=$(cast call $SAFE 'nonce()(uint256)')"
echo "simulation (must be true): $(cast call $SAFE "$SIGN" "$V" 0 "$DATA" 0 0 0 0 $Z $Z $SIG --from $LEDGER)"
if [ "$MODE" = "--send" ]; then
  cast send $SAFE "$SIGN" "$V" 0 "$DATA" 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER
  echo "after: depositCap=$(cast call "$V" 'depositCap()(uint256)')  maxDeposit=$(cast call "$V" 'maxDeposit(address)(uint256)' $LEDGER)  safe nonce=$(cast call $SAFE 'nonce()(uint256)')"
fi
