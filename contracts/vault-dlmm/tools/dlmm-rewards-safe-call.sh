#!/usr/bin/env bash
# ONE owner action on the PHAR rewards DISTRIBUTOR through the Peridot Safe (1-of-1, owner = the Ledger, "approved by msg.sender" signature): ONE Ledger confirmation.
# Sibling of tools/dlmm-safe-call.sh (which only knows the VAULT's calls): this tool refuses every call but the four the distributor procedure names.
#   usage:  tools/dlmm-rewards-safe-call.sh <simulate|send> approve <total-wei>
#           tools/dlmm-rewards-safe-call.sh <simulate|send> publish <root> <total-wei> <fromBlock> <toBlock> <dataHash>
#           tools/dlmm-rewards-safe-call.sh <simulate|send> cancel  <epochId>
#           tools/dlmm-rewards-safe-call.sh <simulate|send> sweep   <epochId>
#   approve : PHAR.approve(DIST, total)   (EXACT amount, never max: refused above 10^30 wei)
#   publish : DIST.publishEpoch(root, total, fromBlock, toBlock, dataHash); requires EXPECT_EPOCH_ID == DIST.epochCount() (the id inside every leaf), the Safe's PHAR balance
#             and allowance >= total; prints the manifest-style arguments before anything is signed.
#   cancel  : DIST.cancelEpoch(id), refused when the challenge window is over (claimOpensAt reached).   sweep: DIST.sweepUnclaimed(id), refused before the deadline.
#   environment: DIST (the distributor, required), ETH_RPC_URL (read; never an argument, never printed), EXPECT_EPOCH_ID (publish), SEND_MODE=ledger (default, OPERATOR-ONLY) |
#                unlocked (a LOCAL anvil fork only; refused unless anvil_nodeInfo answers), GAS_LIMIT (default 1500000).
#                `simulate` is an eth_call from the Ledger: it must print true (a failing inner call makes the Safe revert GS013). NOT RUN by the agent that wrote it.
set -euo pipefail
MODE_CMD="${1:-}"; WHAT="${2:-}"; shift 2 || true
case "$MODE_CMD" in simulate|send) ;; *) echo "usage: $0 <simulate|send> <approve|publish|cancel|sweep> args..." >&2; exit 2;; esac
: "${DIST:?set DIST (the distributor address) in the environment}"
[[ "$DIST" =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "DIST is not an address" >&2; exit 2; }
: "${ETH_RPC_URL:?set ETH_RPC_URL in the environment}"
SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12; LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; Z=0x0000000000000000000000000000000000000000
PHAR=0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7
SIG=0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001
EXEC='execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)'
lc() { echo "$1" | tr 'A-Z' 'a-z'; }
num() { [[ "${1:-}" =~ ^[0-9]+$ ]] || { echo "not an integer: ${1:-}" >&2; exit 2; }; }
[ "$(cast chain-id)" = 43114 ] || { echo "chain id is not 43114" >&2; exit 1; }
[ "$(cast call "$SAFE" 'getOwners()(address[])')" = "[$LEDGER]" ] || { echo "Safe owners are not exactly [the Ledger]" >&2; exit 1; }
[ "$(lc "$(cast call "$DIST" 'owner()(address)')")" = "$(lc $SAFE)" ] || { echo "the distributor's owner is not the Safe: wrong address?" >&2; exit 1; }
[ "$(lc "$(cast call "$DIST" 'PHAR()(address)')")" = "$(lc $PHAR)" ] || { echo "the distributor's PHAR is not the PHAR constant" >&2; exit 1; }
NOW="$(cast block latest --field timestamp)"
case "$WHAT" in
  approve)
    TOTAL="${1:?total wei}"; num "$TOTAL"
    [ "$(echo "$TOTAL" | wc -c)" -le 32 ] || { echo "refusing an approval above 10^30 wei (approve the exact epoch total)" >&2; exit 2; }
    TARGET=$PHAR; SIGN='approve(address,uint256)'; ARGS=("$DIST" "$TOTAL") ;;
  publish)
    ROOT="${1:?root}"; TOTAL="${2:?total wei}"; FROM="${3:?fromBlock}"; TO="${4:?toBlock}"; DH="${5:?dataHash}"
    [[ "$ROOT" =~ ^0x[0-9a-fA-F]{64}$ && "$DH" =~ ^0x[0-9a-fA-F]{64}$ ]] || { echo "root / dataHash must be bytes32" >&2; exit 2; }
    num "$TOTAL"; num "$FROM"; num "$TO"
    : "${EXPECT_EPOCH_ID:?set EXPECT_EPOCH_ID: the --epoch-id the root was generated for}"; num "$EXPECT_EPOCH_ID"
    NEXT="$(cast call "$DIST" 'epochCount()(uint256)' | awk '{print $1}')"
    [ "$NEXT" = "$EXPECT_EPOCH_ID" ] || { echo "epochCount() is $NEXT but the root was generated for id $EXPECT_EPOCH_ID: regenerate (the id is inside every leaf)" >&2; exit 1; }
    BAL="$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$SAFE" | awk '{print $1}')"; ALW="$(cast call "$PHAR" 'allowance(address,address)(uint256)' "$SAFE" "$DIST" | awk '{print $1}')"
    [ "$(echo "$BAL >= $TOTAL" | bc)" = 1 ] || { echo "the Safe holds $BAL PHAR wei, less than the total $TOTAL" >&2; exit 1; }
    [ "$(echo "$ALW >= $TOTAL" | bc)" = 1 ] || { echo "the Safe's allowance to the distributor is $ALW, less than the total $TOTAL: run the approve step first" >&2; exit 1; }
    [ "$TO" -le "$(cast block-number)" ] || { echo "toBlock is above the chain head" >&2; exit 1; }
    TARGET=$DIST; SIGN='publishEpoch(bytes32,uint256,uint64,uint64,bytes32)'; ARGS=("$ROOT" "$TOTAL" "$FROM" "$TO" "$DH")
    echo "PUBLISH epoch id $NEXT: root $ROOT total $TOTAL blocks ($FROM, $TO] dataHash $DH   (Safe PHAR $BAL, allowance $ALW)" ;;
  cancel)
    ID="${1:?epoch id}"; num "$ID"
    OPENS="$(cast call "$DIST" 'epochInfo(uint256)((bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint8))' "$ID" | tr -d '()' | awk -F', ' '{print $5}' | awk '{print $1}')"
    [ "$NOW" -lt "$OPENS" ] || { echo "the challenge window of epoch $ID is over (claimOpensAt $OPENS <= now $NOW): cancel is no longer possible" >&2; exit 1; }
    TARGET=$DIST; SIGN='cancelEpoch(uint256)'; ARGS=("$ID") ;;
  sweep)
    ID="${1:?epoch id}"; num "$ID"
    DL="$(cast call "$DIST" 'epochInfo(uint256)((bytes32,uint256,uint256,uint256,uint256,uint256,uint256,uint256,bytes32,uint8))' "$ID" | tr -d '()' | awk -F', ' '{print $6}' | awk '{print $1}')"
    [ "$NOW" -ge "$DL" ] || { echo "the claim deadline of epoch $ID is $DL, now is $NOW: sweep is not possible yet" >&2; exit 1; }
    TARGET=$DIST; SIGN='sweepUnclaimed(uint256)'; ARGS=("$ID") ;;
  *) echo "unknown action: $WHAT (approve|publish|cancel|sweep)" >&2; exit 2 ;;
esac
DATA="$(cast calldata "$SIGN" "${ARGS[@]}")"
echo "DECODED CALL: $TARGET  $SIGN ${ARGS[*]}"
echo "  calldata $DATA   (Safe execTransaction, operation 0 CALL, value 0, signer the Ledger via the Safe)"
echo "before: distributor epochCount=$(cast call "$DIST" 'epochCount()(uint256)')  distributor PHAR=$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$DIST" | awk '{print $1}')  Safe PHAR=$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$SAFE" | awk '{print $1}')  allowance=$(cast call "$PHAR" 'allowance(address,address)(uint256)' "$SAFE" "$DIST" | awk '{print $1}')  safe nonce=$(cast call "$SAFE" 'nonce()(uint256)')"
RES="$(cast call "$SAFE" "$EXEC(bool)" "$TARGET" 0 "$DATA" 0 0 0 0 $Z $Z $SIG --from "$LEDGER" 2>&1)" || {
  echo "simulation FAILED: $RES" >&2
  echo "inner call as the Safe (the real revert reason; the Safe itself only says GS013): $(cast call "$TARGET" "$DATA" --from "$SAFE" 2>&1 | tail -3 | tr '\n' ' ')" >&2
  exit 1
}
echo "SIMULATION (eth_call from the Ledger, MANDATORY before signing; must be true): $RES"
[ "$RES" = true ] || exit 1
[ "$MODE_CMD" = send ] || exit 0
GAS="${GAS_LIMIT:-1500000}"
echo "ABOUT TO SIGN: Safe nonce $(cast call "$SAFE" 'nonce()(uint256)'), $SIGN ${ARGS[*]}, mode ${SEND_MODE:-ledger}"
if [ "${SEND_MODE:-ledger}" = unlocked ]; then
  cast rpc anvil_nodeInfo >/dev/null 2>&1 || { echo "SEND_MODE=unlocked is for a LOCAL anvil fork only" >&2; exit 3; }
  cast send "$SAFE" "$EXEC" "$TARGET" 0 "$DATA" 0 0 0 0 $Z $Z $SIG --unlocked --from "$LEDGER" --gas-limit "$GAS"
else
  echo "OPERATOR-ONLY: one Ledger confirmation"
  cast send "$SAFE" "$EXEC" "$TARGET" 0 "$DATA" 0 0 0 0 $Z $Z $SIG --ledger --from "$LEDGER" --gas-limit "$GAS"
fi
echo "after: distributor epochCount=$(cast call "$DIST" 'epochCount()(uint256)')  distributor PHAR=$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$DIST" | awk '{print $1}')  Safe PHAR=$(cast call "$PHAR" 'balanceOf(address)(uint256)' "$SAFE" | awk '{print $1}')  allowance=$(cast call "$PHAR" 'allowance(address,address)(uint256)' "$SAFE" "$DIST" | awk '{print $1}')  safe nonce=$(cast call "$SAFE" 'nonce()(uint256)')"
