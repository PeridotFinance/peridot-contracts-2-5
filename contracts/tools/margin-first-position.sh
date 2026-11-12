#!/usr/bin/env bash
# First 2x isolated-margin position on Avalanche (long WAVAX, USDC margin), then its TP and SL orders. Usage:
#   tools/margin-first-position.sh plan   [margin_usdc]            reads only: balances, quote, what each step will do
#   tools/margin-first-position.sh open   [margin_usdc] --send     approve USDC, mint pUSDC, approve shares, vault deposit, openPosition (5 Ledger confirmations)
#   tools/margin-first-position.sh openfree --send                 retry only the open with the free vault balance (after a reverted open; nothing minted)
#   tools/margin-first-position.sh orders <positionId>  --send     TP (+TP_PCT %) and SL (-SL_PCT %) on the full position (2 Ledger confirmations)
#   tools/margin-first-position.sh status <positionId>             reads only: position, health, orders, canExecute
#   tools/margin-first-position.sh close  <positionId>  --send     full close; proceeds land in the vault free balance (then: tools/... withdraw not scripted, see handoff 4.4)
# Env: ETH_RPC_URL (required, never printed). SIGNER_ARGS default "--ledger"; on a fork use "--unlocked". TP_PCT default 10, SL_PCT default 10.
# Only the pUSDC shares MINTED BY THIS SCRIPT (balance delta) are deposited: the seed pTokens held by the Ledger are never touched.
set -euo pipefail
MODE="${1:?plan|open|orders|status|close}"; ARG="${2:-}"; SEND="${3:-}"
: "${ETH_RPC_URL:?set ETH_RPC_URL}"
SIGNER_ARGS="${SIGNER_ARGS:---ledger}"; TP_PCT="${TP_PCT:-10}"; SL_PCT="${SL_PCT:-10}"
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; WAVAX=0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7
PU=0x0f7849CD9E54ffb027aacaEec82007cca9470098; PW=0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1
EXE=0x445D51c8A684139e0Ec215C3Ed827D94Ee8b53af; VAULT=0x64DD15BD97aA41AAb46B963AFcBd2120f54fe0Ce; QUOTER=0x066328FDCB526F57E69b2Ee2C196dE7a8465023E
CFG=0x5d59C647CC4bD6C05b4E9205c23062d490699631; REG=0x4676C8Cf50CEd18683d255faEC4DaA882cbef440; ORC=0x7BAB5406Cb4929f9b9492e1b2a43b65BF93AaFC0
BUMP_BPS="${BUMP_BPS:-30}"   # raise the swap minimum 0.30% above the quote: the quote sits right at the oracle floor and a tiny price move reverts with SwapError(5)
do_open() {  # $1 = pUSDC shares in the vault free balance; re-quote immediately before the open
  local SHARES="$1" XR MU2 MIN PARAMS SIG2
  XR="$(cast call $PU 'exchangeRateCurrent()(uint256)' | num)"; MU2="$(python3 -c "print($SHARES*$XR//10**18)")"
  read -r FLASH MIN <<<"$(cast call $QUOTER 'quoteOpen(address,address,address,uint256,uint16)(uint256,uint256)' $PU $PW $PU "$MU2" 200 | num | tr '\n' ' ')"
  MIN="$(python3 -c "print($MIN*(10000+$BUMP_BPS)//10000)")"
  PARAMS="($PU,$PW,$PU,$SHARES,200,0,$MIN,0,0x)"; SIG2='openPosition((address,address,address,uint256,uint16,uint256,uint256,uint8,bytes))(uint256)'
  echo "open: debt $FLASH units, swap minimum $MIN wei (quote +$BUMP_BPS bp); simulated id: $(cast call $EXE "$SIG2" "$PARAMS" --from $L | num)"
  send $EXE "$SIG2" "$PARAMS"
  local PID2; PID2="$(python3 -c "print(int('$(cast call $EXE 'nextPositionId()(uint256)' | num)')-1)")"
  echo "opened. position $PID2 (id, owner): $(cast call $EXE 'positions(uint256)(uint256,address)' "$PID2" | tr '\n' ' ')"; echo "next: tools/margin-first-position.sh orders $PID2 --send"
}
num() { awk '{print $1}'; }
send() { local R; R="$(cast send "$@" $SIGNER_ARGS --from $L --json 2>/dev/null)" || { echo "send failed or was rejected" >&2; exit 7; }
         case "$R" in *'"status":"0x1"'*) ;; *) echo "TRANSACTION REVERTED on chain: $(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("transactionHash"))')" >&2; exit 8;; esac; }  # one confirmation each; never prints the RPC URL
price() { cast call $ORC 'getPrice(address)(uint256)' $WAVAX | num; }  # USD per WAVAX, 1e18

case "$MODE" in
plan|open)
  M="${ARG:-5}"; MU="$(python3 -c "print(int(round(float('$M')*1e6)))")"
  [ "$MU" -ge 1000000 ] || { echo "margin below 1 USDC refused" >&2; exit 2; }
  [ "$(cast call $CFG 'opensPaused()(bool)')" = "false" ] || { echo "opens are paused" >&2; exit 3; }
  BAL="$(cast call $USDC 'balanceOf(address)(uint256)' $L | num)"
  [ "$BAL" -ge "$MU" ] || { echo "Ledger holds $BAL USDC units, needs $MU" >&2; exit 4; }
  read -r FLASH MINPOS <<<"$(cast call $QUOTER 'quoteOpen(address,address,address,uint256,uint16)(uint256,uint256)' $PU $PW $PU "$MU" 200 | num | tr '\n' ' ')"
  PID="$(cast call $EXE 'nextPositionId()(uint256)' | num)"
  echo "margin $M USDC ($MU units)  quote: debt/flash $FLASH units, min WAVAX $MINPOS wei   next position id $PID   WAVAX oracle price $(cast call $ORC 'getPrice(address)(uint256)' $WAVAX | num) (1e18)"
  echo "Ledger USDC $BAL units; AVAX $(cast balance $L --ether)"
  if [ "$MODE" = "plan" ] || [ "$SEND" != "--send" ]; then echo "plan only (no --send): nothing signed"; exit 0; fi
  B0="$(cast call $PU 'balanceOf(address)(uint256)' $L | num)"
  send $USDC 'approve(address,uint256)' $PU "$MU"
  send $PU 'mint(uint256)' "$MU"
  B1="$(cast call $PU 'balanceOf(address)(uint256)' $L | num)"; SH=$(python3 -c "print($B1-$B0)")
  [ "$SH" -gt 0 ] || { echo "no pUSDC minted" >&2; exit 5; }
  echo "minted shares: $SH"
  send $PU 'approve(address,uint256)' $VAULT "$SH"
  send $VAULT 'deposit(address,uint256)' $PU "$SH"
  do_open "$SH"
  ;;
openfree)
  # retry only the last step: open with the Ledger's whole FREE vault balance of pUSDC (after a reverted open; nothing is minted)
  SH="$(cast call $VAULT 'freeBalance(address,address)(uint256)' $L $PU | num)"; [ "$SH" -gt 0 ] || { echo "no free vault balance" >&2; exit 5; }
  PID="$(cast call $EXE 'nextPositionId()(uint256)' | num)"; echo "free vault shares $SH, next position id $PID"
  [ "$ARG" = "--send" ] || { echo "no --send: nothing signed"; exit 0; }
  do_open "$SH"
  ;;
orders)
  PID="${ARG:?positionId}"
  OWN="$(cast call $EXE 'positions(uint256)(uint256,address)' "$PID" | sed -n 2p | tr A-Z a-z)"; [ "$OWN" = "$(echo $L | tr A-Z a-z)" ] || { echo "position $PID is not the Ledger's (owner $OWN)" >&2; exit 6; }
  P="$(price)"; TP="$(python3 -c "print($P*(100+$TP_PCT)//100)")"; SL="$(python3 -c "print($P*(100-$SL_PCT)//100)")"
  EXP="$(python3 -c "import time;print(int(time.time())+29*86400)")"
  SIG='createOrder(uint256,uint8,bool,uint256,uint16,uint16,uint64)(uint256)'
  echo "price $P  TP trigger $TP (above, +$TP_PCT%)  SL trigger $SL (below, -$SL_PCT%)  closeBps 10000  maxSlippage 100  expiry $EXP (29 days)"
  echo "simulation TP id: $(cast call $REG "$SIG" "$PID" 0 true "$TP" 10000 100 "$EXP" --from $L | num)   SL id: $(cast call $REG "$SIG" "$PID" 1 false "$SL" 10000 100 "$EXP" --from $L | num)"
  [ "$SEND" = "--send" ] || { echo "no --send: nothing signed"; exit 0; }
  # stop-loss FIRST: a take-profit that is already reachable is executed by the keeper within seconds, which would close the position before a later SL could be created
  send $REG "$SIG" "$PID" 1 false "$SL" 10000 100 "$EXP"
  send $REG "$SIG" "$PID" 0 true "$TP" 10000 100 "$EXP"
  echo "open orders: $(cast call $REG 'openOrdersOf(uint256)(uint256[])' "$PID")"
  ;;
status)
  PID="${ARG:?positionId}"
  echo "position: $(cast call $EXE 'positions(uint256)(uint256,address,address)' "$PID" | tr '\n' ' ')"
  OO="$(cast call $REG 'openOrdersOf(uint256)(uint256[])' "$PID")"; echo "open orders: $OO"
  for id in $(echo "$OO" | tr -d '[],'); do echo " order $id canExecute: $(cast call $REG 'canExecute(uint256)(bool,uint256,uint8)' "$id" | tr '\n' ' ')"; done
  echo "oracle price $(price)  vault free pUSDC $(cast call $VAULT 'freeBalance(address,address)(uint256)' $L $PU | num)"
  ;;
close)
  PID="${ARG:?positionId}"
  SIG='closePosition((uint256,uint16,uint256,uint256,uint256,bytes,bytes))(uint256)'
  PARAMS="($PID,10000,$(python3 -c 'print(2**256-1)'),0,0,0x,0x)"
  echo "simulation of the full close (returned pUSDC): $(cast call $EXE "$SIG" "$PARAMS" --from $L | num)"
  [ "$SEND" = "--send" ] || { echo "no --send: nothing signed"; exit 0; }
  send $EXE "$SIG" "$PARAMS"
  echo "closed. vault free pUSDC $(cast call $VAULT 'freeBalance(address,address)(uint256)' $L $PU | num); withdraw with vault.withdraw(pUSDC, amount) then pUSDC.redeem (handoff 4.4)"
  ;;
*) echo "bad mode" >&2; exit 2 ;;
esac
