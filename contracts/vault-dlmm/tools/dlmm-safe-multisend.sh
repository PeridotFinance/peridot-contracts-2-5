#!/usr/bin/env bash
# Builds, simulates and (operator only) sends the ONE atomic Safe MultiSend that opens the Pharaoh DLMM vault:
#     [ vault.unpause() , USDC.approve(vault, SEED) , vault.deposit(SEED, SEED_RECEIVER) ]
# in a single Safe transaction (W10 finding F1: the vault starts PAUSED; unpause, the approval and the seed deposit must land in ONE transaction, so that no
# block exists in which the vault is open with a supply below the seed, and the seed shares are never redeemed).
#
#   usage:  tools/dlmm-safe-multisend.sh <build|simulate|send>          environment, all public values:
#     VAULT           the proxy (required)
#     SEED            raw USDC units, default 1000000 (USD 1); must be >= 1000000 and <= 200000000
#     SEED_RECEIVER   who receives the seed shares, default 0x000000000000000000000000000000000000dEaD  (see the ceremony, section 6, for why)
#     ETH_RPC_URL     read-only endpoint for `simulate`/`send` (environment only, never an argument, never printed)
#     SEND_MODE       send only: `ledger` (default; the Ledger signs: OPERATOR-ONLY) or `unlocked` (a LOCAL anvil fork only: the tool refuses it
#                     unless the endpoint answers the anvil-only method anvil_nodeInfo)
#     GAS_LIMIT       send only, default 1500000 (set from the rehearsal)
#
# WHO PAYS: the Safe delegatecalls MultiSendCallOnly, so msg.sender of all three inner calls is the SAFE. The USDC must therefore SIT IN THE SAFE first
# (step 0 of the ceremony: the Ledger transfers SEED USDC to the Safe). `simulate` refuses to go on if the Safe holds less than SEED.
# `build` is pure (no RPC); it prints the exact calldata. Nothing in `build` and `simulate` signs or sends.
set -euo pipefail
CMD="${1:-}"
case "$CMD" in build|simulate|send) ;; *) echo "usage: $0 <build|simulate|send>" >&2; exit 2;; esac

SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
MULTISEND=0x9641d764fc13c8B624c04430C7356C1C7C8102e2   # Safe MultiSendCallOnly v1.4.1 (canonical; code presence re-checked by `simulate`)
DEAD=0x000000000000000000000000000000000000dEaD
Z=0x0000000000000000000000000000000000000000
SIG=0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001
EXEC='execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)'
EXEC_CALL='execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)(bool)'

V="${VAULT:?VAULT (the proxy address) is required}"
SEED="${SEED:-1000000}"
RECV="${SEED_RECEIVER:-$DEAD}"
[[ "$V" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "VAULT is not an address" >&2; exit 2; }
[[ "$RECV" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "SEED_RECEIVER is not an address" >&2; exit 2; }
[[ "$SEED" =~ ^[0-9]+$ ]] || { echo "SEED is not a number" >&2; exit 2; }
[ "$SEED" -ge 1000000 ] || { echo "SEED < 1000000 (USD 1): refused (W10 F1, the first-depositor window needs a seed of at least 1 USDC)" >&2; exit 2; }
[ "$SEED" -le 200000000 ] || { echo "SEED above the cap 200000000: refused" >&2; exit 2; }
[ "$(echo "$RECV" | tr A-Z a-z)" != "$(echo $Z)" ] || { echo "SEED_RECEIVER is the zero address" >&2; exit 2; }

# ---- the three inner calls
D1="$(cast calldata 'unpause()')"
D2="$(cast calldata 'approve(address,uint256)' "$V" "$SEED")"
D3="$(cast calldata 'deposit(uint256,address)' "$SEED" "$RECV")"
# MultiSend packing: operation (1 byte, 0 = CALL) | to (20) | value (32) | data length (32) | data
pack() { local to="$1" data="$2"; local len=$(( (${#data} - 2) / 2 )); printf '00%s%064x%064x%s' "${to#0x}" 0 "$len" "${data#0x}"; }
PACKED="0x$(pack "$V" "$D1")$(pack "$USDC" "$D2")$(pack "$V" "$D3")"
MS="$(cast calldata 'multiSend(bytes)' "$PACKED")"

if [ "$CMD" = build ]; then
  echo "Safe                 $SAFE   (execTransaction operation = 1 DELEGATECALL to MultiSendCallOnly)"
  echo "MultiSendCallOnly    $MULTISEND"
  echo "vault                $V"
  echo "seed                 $SEED raw USDC (USD $(( SEED / 1000000 )).$(printf '%06d' $(( SEED % 1000000 ))))   seed shares go to $RECV"
  echo "inner 1  unpause()                    to $V      data $D1"
  echo "inner 2  USDC.approve(vault, seed)    to $USDC   data $D2"
  echo "inner 3  vault.deposit(seed, receiver) to $V     data $D3"
  echo "packed transactions  $PACKED"
  echo "multiSend calldata   $MS"
  echo
  echo "# 0. OPERATOR-ONLY, before the MultiSend: the Ledger puts the seed USDC in the Safe (the Safe is msg.sender of the inner calls)"
  echo "cast send $USDC 'transfer(address,uint256)' $SAFE $SEED --ledger --from $LEDGER"
  echo "# 1. read-only simulation from the Ledger (must print true):"
  echo "cast call $SAFE '$EXEC_CALL' $MULTISEND 0 $MS 1 0 0 0 $Z $Z $SIG --from $LEDGER"
  echo "# 2. OPERATOR-ONLY (one Ledger confirmation), explicit gas limit:"
  echo "cast send $SAFE '$EXEC' $MULTISEND 0 $MS 1 0 0 0 $Z $Z $SIG --ledger --from $LEDGER --gas-limit 1500000"
  exit 0
fi

: "${ETH_RPC_URL:?ETH_RPC_URL must be set in the environment (read-only endpoint; never an argument)}"
# ---- preconditions (read-only)
[ "$(cast chain-id)" = 43114 ] || { echo "chain id is not 43114" >&2; exit 1; }
[ "$(cast code "$MULTISEND" | wc -c)" -gt 10 ] || { echo "no code at MultiSendCallOnly $MULTISEND" >&2; exit 1; }
[ "$(cast call "$SAFE" 'getOwners()(address[])')" = "[$LEDGER]" ] || { echo "Safe owners are not exactly [the Ledger]" >&2; exit 1; }
echo "Safe nonce before: $(cast call "$SAFE" 'nonce()(uint256)')"
PAUSED="$(cast call "$V" 'paused()(bool)')"; SUPPLY="$(cast call "$V" 'totalSupply()(uint256)' | awk '{print $1}')"
echo "vault paused: $PAUSED   totalSupply: $SUPPLY   Safe USDC: $(cast call "$USDC" 'balanceOf(address)(uint256)' "$SAFE" | awk '{print $1}')"
[ "$PAUSED" = true ] || { echo "the vault is not paused: the MultiSend is the opening step (unpause first inside it); stop and read the vault" >&2; exit 1; }
[ "$SUPPLY" = 0 ] || { echo "totalSupply is not 0: this MultiSend is the FIRST funding only" >&2; exit 1; }
[ "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$SAFE" | awk '{print $1}')" -ge "$SEED" ] || { echo "the Safe holds less USDC than SEED: do step 0 (Ledger -> Safe transfer) first" >&2; exit 1; }
RES="$(cast call "$SAFE" "$EXEC_CALL" "$MULTISEND" 0 "$MS" 1 0 0 0 $Z $Z $SIG --from "$LEDGER")"
echo "simulation of execTransaction from the Ledger: $RES   (must be true)"
[ "$RES" = true ] || { echo "simulation did not return true: stop" >&2; exit 1; }
[ "$CMD" = simulate ] && exit 0

# ---- send
MODE="${SEND_MODE:-ledger}"; GAS="${GAS_LIMIT:-1500000}"
if [ "$MODE" = unlocked ]; then
  cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "SEND_MODE=unlocked is for a LOCAL anvil fork only: the endpoint does not answer anvil_nodeInfo" >&2; exit 3; }
  cast send "$SAFE" "$EXEC" "$MULTISEND" 0 "$MS" 1 0 0 0 $Z $Z $SIG --unlocked --from "$LEDGER" --gas-limit "$GAS"
else
  echo "OPERATOR-ONLY: the Ledger will ask for ONE confirmation"
  cast send "$SAFE" "$EXEC" "$MULTISEND" 0 "$MS" 1 0 0 0 $Z $Z $SIG --ledger --from "$LEDGER" --gas-limit "$GAS"
fi
echo "Safe nonce after: $(cast call "$SAFE" 'nonce()(uint256)')   paused: $(cast call "$V" 'paused()(bool)')   seed shares of $RECV: $(cast call "$V" 'balanceOf(address)(uint256)' "$RECV" | awk '{print $1}')"
