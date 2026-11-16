#!/usr/bin/env bash
# Builds, simulates and (operator only) sends the ONE atomic Safe MultiSend that opens the Pharaoh DLMM vault AND fills its whole cap:
#     [ vault.unpause() , USDC.approve(vault, SEED+REST) , vault.deposit(SEED, SEED_RECEIVER) , vault.deposit(REST, REST_RECEIVER) ]
# in a single Safe transaction (W10 finding F1: the vault starts PAUSED; unpause, the approval, the seed deposit and the rest must land in ONE transaction, so that no block exists in
# which the vault is open with a supply below the seed; the seed is never redeemed). Operator decision 16 Nov: SEED_USDC=1 to the dead address, REST_USDC=199 to the Ledger,
# total 200 = the cap, so no outside deposit fits.
#
#   usage:  tools/dlmm-safe-multisend.sh <build|simulate|send>          environment, all public values:
#     VAULT             the proxy (required)
#     SEED_USDC         whole USDC, default 1 (must be >= 1, and <= 5 unless OVERRIDE_DEAD_ALLOW=yes)
#     REST_USDC         whole USDC, default 199; SEED_USDC + REST_USDC must be <= 200 (the cap)
#     SEED_RECEIVER     default 0x000000000000000000000000000000000000dEaD
#     REST_RECEIVER     default the Ledger 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
#     OVERRIDE_DEAD_ALLOW=yes   needed only to send more than SEED_USDC (or more than 5) to the dead address; refused otherwise
#     ETH_RPC_URL       read-only endpoint for `simulate`/`send` (environment only, never an argument, never printed)
#     SEND_MODE         send only: `ledger` (default; the Ledger signs: OPERATOR-ONLY) or `unlocked` (a LOCAL anvil fork only: refused unless the endpoint answers anvil_nodeInfo)
#     GAS_LIMIT         send only, default 1500000
#
# WHO PAYS: the Safe delegatecalls MultiSendCallOnly, so msg.sender of all inner calls is the SAFE. The Safe must therefore HOLD SEED+REST USDC first (step 2a: the Ledger
# transfers it, tools/dlmm-ledger-step.sh). `simulate` refuses to go on if the Safe holds less. `build` is pure (no RPC). EVERY run prints, before anything is signed, the table of
# who receives what, the decoded inner calls and the Safe nonce, and `send` runs the eth_call simulation first and stops unless it returns true.
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
SEED_USDC="${SEED_USDC:-1}"; REST_USDC="${REST_USDC:-199}"
RECV="${SEED_RECEIVER:-$DEAD}"; RRECV="${REST_RECEIVER:-$LEDGER}"
[[ "$V" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "VAULT is not an address" >&2; exit 2; }
[[ "$RECV" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "SEED_RECEIVER is not an address" >&2; exit 2; }
[[ "$RRECV" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "REST_RECEIVER is not an address" >&2; exit 2; }
[[ "$SEED_USDC" =~ ^[0-9]+$ && "$REST_USDC" =~ ^[0-9]+$ ]] || { echo "SEED_USDC / REST_USDC must be whole numbers of USDC" >&2; exit 2; }
SEED=$(( SEED_USDC * 1000000 )); REST=$(( REST_USDC * 1000000 )); TOTAL=$(( SEED + REST ))
[ "$SEED_USDC" -ge 1 ] || { echo "SEED_USDC < 1 (USD 1): refused (W10 F1, the first-depositor window needs a seed of at least 1 USDC)" >&2; exit 2; }
[ "$TOTAL" -le 200000000 ] || { echo "SEED_USDC + REST_USDC above the cap 200: refused" >&2; exit 2; }
for r in "$RECV" "$RRECV"; do [ "$(echo "$r" | tr A-Z a-z)" != "$(echo $Z)" ] || { echo "a receiver is the zero address" >&2; exit 2; }; done
# DEAD-ADDRESS LIMIT: what goes to the dead address (it can never be withdrawn) may not exceed SEED_USDC, and SEED_USDC may not exceed 5, unless the operator says so explicitly
is_dead() { [ "$(echo "$1" | tr A-Z a-z)" = "$(echo $DEAD | tr A-Z a-z)" ]; }
DEAD_USDC=0; is_dead "$RECV" && DEAD_USDC=$(( DEAD_USDC + SEED_USDC )); is_dead "$RRECV" && DEAD_USDC=$(( DEAD_USDC + REST_USDC ))
if [ "$DEAD_USDC" -gt "$SEED_USDC" ] || [ "$DEAD_USDC" -gt 5 ]; then
  [ "${OVERRIDE_DEAD_ALLOW:-}" = yes ] || { echo "REFUSED: USD $DEAD_USDC would go to the dead address (limit: SEED_USDC=$SEED_USDC and at most 5). Set OVERRIDE_DEAD_ALLOW=yes only if that is intended." >&2; exit 2; }
  echo "WARNING: OVERRIDE_DEAD_ALLOW=yes: USD $DEAD_USDC goes to the dead address and can never be withdrawn" >&2
fi

# ---- the four inner calls
D1="$(cast calldata 'unpause()')"
D2="$(cast calldata 'approve(address,uint256)' "$V" "$TOTAL")"
D3="$(cast calldata 'deposit(uint256,address)' "$SEED" "$RECV")"
D4="$(cast calldata 'deposit(uint256,address)' "$REST" "$RRECV")"
# MultiSend packing: operation (1 byte, 0 = CALL) | to (20) | value (32) | data length (32) | data
pack() { local to="$1" data="$2"; local len=$(( (${#data} - 2) / 2 )); printf '00%s%064x%064x%s' "${to#0x}" 0 "$len" "${data#0x}"; }
PACKED="0x$(pack "$V" "$D1")$(pack "$USDC" "$D2")$(pack "$V" "$D3")$(pack "$V" "$D4")"
MS="$(cast calldata 'multiSend(bytes)' "$PACKED")"
table() {
  echo "WHO GETS WHAT (read this before anything is signed):"
  echo "  paid by            the Safe $SAFE (it must hold USD $(( TOTAL / 1000000 )) USDC first)"
  echo "  seed               USD $SEED_USDC  -> shares to $RECV$(is_dead "$RECV" && echo '   (DEAD address: never withdrawable)')"
  echo "  rest               USD $REST_USDC -> shares to $RRECV$(is_dead "$RRECV" && echo '   (DEAD address: never withdrawable)')"
  echo "  total              USD $(( TOTAL / 1000000 ))  (the cap is USD 200: $( [ "$TOTAL" -eq 200000000 ] && echo 'the cap is FULL, no outside deposit fits' || echo "USD $(( 200 - TOTAL / 1000000 )) of headroom stays" ))"
  echo "DECODED CALLS (one Safe transaction, operation 1 DELEGATECALL to MultiSendCallOnly $MULTISEND):"
  echo "  1  $V  unpause()                                   $D1"
  echo "  2  $USDC  approve($V, $TOTAL)   $D2"
  echo "  3  $V  deposit($SEED, $RECV)   $D3"
  echo "  4  $V  deposit($REST, $RRECV)  $D4"
}

if [ "$CMD" = build ]; then
  table
  echo "packed transactions  $PACKED"
  echo "multiSend calldata   $MS"
  echo
  echo "# 0. OPERATOR-ONLY, before the MultiSend: the Ledger puts the USDC in the Safe (the Safe is msg.sender of the inner calls): tools/dlmm-ledger-step.sh simulate|send fund-safe-usdc"
  echo "# 1. read-only simulation from the Ledger (must print true):"
  echo "cast call $SAFE '$EXEC_CALL' $MULTISEND 0 $MS 1 0 0 0 $Z $Z $SIG --from $LEDGER"
  echo "# 2. OPERATOR-ONLY (one Ledger confirmation), explicit gas limit:"
  echo "cast send $SAFE '$EXEC' $MULTISEND 0 $MS 1 0 0 0 $Z $Z $SIG --ledger --from $LEDGER --gas-limit 1500000"
  exit 0
fi

: "${ETH_RPC_URL:?ETH_RPC_URL must be set in the environment (read-only endpoint; never an argument)}"
# ---- preconditions (read-only)
[ "$(cast chain-id)" = 43114 ] || { echo "chain id is not 43114" >&2; exit 1; }
# a delegatecall target: its identity is pinned by runtime-code hash (safe-global/safe-deployments v1.4.1 multi_send_call_only.json codeHash), not just by presence
[ "$(cast keccak "$(cast code "$MULTISEND")")" = 0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939 ] || { echo "MultiSendCallOnly $MULTISEND is not the pinned v1.4.1 code: STOP" >&2; exit 1; }
[ "$(cast call "$SAFE" 'getOwners()(address[])')" = "[$LEDGER]" ] || { echo "Safe owners are not exactly [the Ledger]" >&2; exit 1; }
table
echo "SAFE NONCE (the transaction to be signed uses it): $(cast call "$SAFE" 'nonce()(uint256)')"
PAUSED="$(cast call "$V" 'paused()(bool)')"; SUPPLY="$(cast call "$V" 'totalSupply()(uint256)' | awk '{print $1}')"
echo "vault paused: $PAUSED   totalSupply: $SUPPLY   Safe USDC: $(cast call "$USDC" 'balanceOf(address)(uint256)' "$SAFE" | awk '{print $1}')"
[ "$PAUSED" = true ] || { echo "the vault is not paused: the MultiSend is the opening step (unpause first inside it); stop and read the vault" >&2; exit 1; }
[ "$SUPPLY" = 0 ] || { echo "totalSupply is not 0: this MultiSend is the FIRST funding only" >&2; exit 1; }
[ "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$SAFE" | awk '{print $1}')" -ge "$TOTAL" ] || { echo "the Safe holds less USDC than SEED+REST ($TOTAL): do step 2a (Ledger -> Safe transfer) first" >&2; exit 1; }
RES="$(cast call "$SAFE" "$EXEC_CALL" "$MULTISEND" 0 "$MS" 1 0 0 0 $Z $Z $SIG --from "$LEDGER")"
echo "SIMULATION (eth_call of execTransaction from the Ledger, MANDATORY before signing): $RES   (must be true)"
[ "$RES" = true ] || { echo "simulation did not return true: stop" >&2; exit 1; }
[ "$CMD" = simulate ] && exit 0

# ---- send
MODE="${SEND_MODE:-ledger}"; GAS="${GAS_LIMIT:-1500000}"
echo "ABOUT TO SIGN: Safe tx nonce $(cast call "$SAFE" 'nonce()(uint256)'), operation 1 DELEGATECALL to $MULTISEND, the four calls above, signer mode $MODE"
if [ "$MODE" = unlocked ]; then
  cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "SEND_MODE=unlocked is for a LOCAL anvil fork only: the endpoint does not answer anvil_nodeInfo" >&2; exit 3; }
  cast send "$SAFE" "$EXEC" "$MULTISEND" 0 "$MS" 1 0 0 0 $Z $Z $SIG --unlocked --from "$LEDGER" --gas-limit "$GAS"
else
  echo "OPERATOR-ONLY: the Ledger will ask for ONE confirmation"
  cast send "$SAFE" "$EXEC" "$MULTISEND" 0 "$MS" 1 0 0 0 $Z $Z $SIG --ledger --from "$LEDGER" --gas-limit "$GAS"
fi
echo "Safe nonce after: $(cast call "$SAFE" 'nonce()(uint256)')   paused: $(cast call "$V" 'paused()(bool)')   shares of $RECV: $(cast call "$V" 'balanceOf(address)(uint256)' "$RECV" | awk '{print $1}')   shares of $RRECV: $(cast call "$V" 'balanceOf(address)(uint256)' "$RRECV" | awk '{print $1}')   totalAssets: $(cast call "$V" 'totalAssets()(uint256)' | awk '{print $1}')"
