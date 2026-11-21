#!/usr/bin/env bash
# pSPY as plain lending collateral: the exact Ledger calls, phase by phase, each followed by a state check.
# Runs AFTER the SPY margin ceremony (tools/spy/ceremony.sh); preflight refuses otherwise.
#
#   tools/spy-collateral/ceremony.sh <spy-margin-journal.json> <spy-collateral-journal.json> <phase>
#   phases: preflight | t0 | demo-open | demo-close | closed-check | verify | rollback
#
# Signing: SIGN defaults to "--ledger" (the operator's Ledger 0x064eFE76...B2dD). The anvil rehearsal sets
# SIGN=--unlocked and RPC=http://127.0.0.1:<port>. Every call is a single direct `cast send` from the Ledger: the
# controller, pSPY and the router adapter are all Ledger-administered. No timelock operation, no mandatory delay.
# Nothing here reads a key. Re-run `verify` at any time.
#
# Operator parameters (env, defaults = proposal): SPY_LENDING_CAP_WEI=230000000000000000 (0.23 SPY)
# SPY_CF_MANTISSA=300000000000000000 (30 %) DEMO_SPY_WEI (default: the Ledger's whole SPY balance; buy ~0.045 SPY first)
# DEMO_BORROW_RAW=5000000 (5 USDG; refused above 60 % of the demo's borrowing power)
set -euo pipefail
MJ=${1:?spy-margin journal}; CJ=${2:?spy-collateral journal}; PHASE=${3:?phase}
RPC=${RPC:-https://rpc.mainnet.chain.robinhood.com}; SIGN=${SIGN:---ledger}
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
CONTROLLER=0x6148183676E304dbe63a85C350c208DA3cEAc39C; MORACLE=0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD
CONFIG=0x09F94fe0B79E000c8a26617c63E3427fdECB528b; RADAPTER=0xa32C34F100B4F1f36ECA09c427a098f99F4423F0
RISK=0xC8b178C3c74570472FF1eeE0DD559e61AF9f9678; EXECUTOR=0x6A45Ae86bD992d250580d08D340A06A04D478977
PUSDG=0x55aEd0569c8f0D166D71facE57B57C2f2624a563; PNVDA=0xa155ccCB986774AE818b3F10F07d01D1b7A47b26
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; SPY=0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
FEED=0x319724394D3A0e3669269846abE664Cd621f9f6A; POS6=0x8039391D9a706dB3FdD46602f735fB097E5D464B
NVDA_LENDER=0x12c1e2C33F63F897E0e4ac1969C29493136f2481; FLASH=0x79d33c9BbC1D0711e88C5602f86135Ab4C088b06
PSPY=$(jq -r .pSpy "$MJ"); ADAPTER3=$(jq -r .lendingAdapter "$MJ"); ROUTER=$(jq -r .router "$MJ")
SPYSRC=$(jq -r .spySource "$MJ"); PLAIN=$(jq -r .delegate "$MJ")
DELEGATE=$(jq -r .delegate "$CJ"); LIQ=$(jq -r .liquidator "$CJ")
CAP=${SPY_LENDING_CAP_WEI:-230000000000000000}; CF=${SPY_CF_MANTISSA:-300000000000000000}
POSSIG='(uint256,address,address,address,address,address,uint256,uint256,uint256,uint16,uint8,uint8)'
METSIG='(uint256,uint256,int256,uint256,uint256,uint256,uint256)'

exec 2> >(grep -v "Found unknown" >&2)
c(){ cast call "$@" --rpc-url "$RPC"; }
first(){ cut -d' ' -f1 | head -1; }
s(){ local label=$1; shift; echo "-- $label"; cast send "$@" --from $L $SIGN --rpc-url "$RPC" --rpc-timeout 600 --json \
       | python3 -c "import json,sys;r=json.load(sys.stdin);print('   status',r['status'],'gas',int(r['gasUsed'],16),'tx',r['transactionHash']);sys.exit(0 if r['status']=='0x1' else 1)"; }
need(){ if [ "$1" != "$2" ]; then echo "CHECK FAILED: $3 (got '$1', want '$2')"; exit 1; fi; echo "   ok: $3"; }
ge(){ python3 -c "import sys;sys.exit(0 if int('$1')>=int('$2') else 1)"; }

# Values the collateral ceremony must leave bit-identical: NVDA lending prices, the live NVDA lending account, NVDA
# position 6, pSPY supply / rate, and every active SPY margin position's metrics (margin accounts are gate-exempt).
untouched(){
  local o; o=$(c $CONTROLLER 'oracle()(address)')
  echo "$(c $o 'getUnderlyingPrice(address)(uint256)' $PNVDA | first) $(c $o 'getUnderlyingPrice(address)(uint256)' $PUSDG | first)" \
       "$(c $CONTROLLER 'getAccountLiquidity(address)(uint256,uint256,uint256)' $NVDA_LENDER | cut -d' ' -f1 | tr '\n' ,)" \
       "$(cast call $RISK "getMetrics(address)$METSIG" $POS6 --rpc-url "$RPC" 2>/dev/null || echo revert)" \
       "$(c $PSPY 'totalSupply()(uint256)' | first) $(c $PSPY 'exchangeRateStored()(uint256)' | first)"
  local n i p; n=$(c $EXECUTOR 'nextPositionId()(uint256)' | first)
  for i in $(seq 1 $((n - 1))); do
    p=$(c $EXECUTOR "positions(uint256)$POSSIG" $i | tr -d '()')
    if [ "$(echo "$p" | awk -F', ' '{print $4}')" = "$PSPY" ] && [ "$(echo "$p" | awk -F', ' '{print $12}')" = 2 ]; then
      echo "pos$i $(cast call $RISK "getMetrics(address)$METSIG" $(echo "$p" | awk -F', ' '{print $3}') --rpc-url "$RPC" 2>/dev/null || echo revert)"
    fi
  done
}

case $PHASE in
preflight)
  need "$(cast chain-id --rpc-url "$RPC")" 4663 "chain 4663"
  need "$(c $CONTROLLER 'admin()(address)')" $L "controller admin = Ledger (direct; no timelock)"
  need "$(c $PSPY 'admin()(address)')" $L "pSPY admin = Ledger"
  need "$(c $RADAPTER 'owner()(address)')" $L "router adapter owner = Ledger"
  # the SPY margin ceremony has run
  need "$(c $CONTROLLER 'oracle()(address)')" $ADAPTER3 "controller oracle = 3-market adapter (SPY margin t0 step 5 done)"
  need "$(c $CONTROLLER 'markets(address)(bool,uint256,bool)' $PSPY | head -2 | tr '\n' ' ' | cut -d' ' -f1,2)" "true 0" "pSPY listed at collateral factor 0"
  need "$(c $CONTROLLER 'borrowGuardianPaused(address)(bool)' $PSPY)" true "pSPY borrowing paused"
  need "$(c $MORACLE 'assetSource()(address)')" $ROUTER "margin assetSource = router (SPY margin t0 step 12 done)"
  need "$(c $CONFIG 'getPairRisk(address,address,address)((bool,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint128,uint128))' $PUSDG $PSPY $PUSDG | tr -d '()' | cut -d, -f1)" true "SPY long pair enabled (SPY margin t1 done)"
  need "$(c $PSPY 'implementation()(address)')" $PLAIN "pSPY still on the plain delegate"
  need "$(c $CONTROLLER 'isolatedMarginRiskHook()(address)')" $RISK "controller margin hook = risk engine"
  need "$(c $SPY 'paused()(bool)')/$(c $SPY 'oraclePaused()(bool)')" false/false "SPY not paused"
  UPD=$(c $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 4p | first); NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
  echo "   SPY feed age $((NOW - UPD)) s"
  need "$(c $SPYSRC 'stockPrice()(uint256,uint8,uint256)' | sed -n 2p)" 0 "SPY session source serves a price (reason 0)"
  need "$([ $((NOW - UPD)) -le 3600 ] && echo fresh)" fresh "SPY feed updated within the last hour (run in session)"
  FOUNDRY_PROFILE=robinhood_spy SPY_COLLATERAL_ACTION=verify SPY_MARGIN_JOURNAL=$(basename "$MJ" .json) SPY_COLLATERAL_JOURNAL=$(basename "$CJ" .json) \
    forge script script/spy/DeploySpyCollateral.s.sol:DeploySpyCollateral --rpc-url "$RPC" >/dev/null && echo "   ok: deployment verify (delegate source, liquidator wiring, beneficiary = Ledger)"
  need "$(c $DELEGATE 'spySource()(address)')" $SPYSRC "delegate gates on the SPY margin session source"
  need "$(ge $CAP $(c $PSPY 'totalSupply()(uint256)' | first) && echo ok)" ok "cap parameter is a sane SPY amount"
  need "$(c $RADAPTER 'poolFor(address,address)((address,address,uint24,int24,address))' $USDG 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC | tr -d '()' | cut -d, -f3 | tr -d ' ')" 3000 "router adapter has the NVDA/USDG pool (NVDA-debt liquidations)"
  need "$(c $RADAPTER 'poolFor(address,address)((address,address,uint24,int24,address))' $SPY $USDG | tr -d '()' | cut -d, -f3 | tr -d ' ')" 3000 "router adapter has the SPY/USDG pool (SPY margin t0 step 13 done)"
  echo "   flash vault USDG capacity $(c $FLASH 'maxFlashLoan(address)(uint256)' $USDG | first) raw (the liquidator flashes USDG for both debt kinds)"
  untouched > "${CJ%.json}.untouched-before.txt"; echo "   untouched-state snapshot saved ($(wc -l < "${CJ%.json}.untouched-before.txt") lines)"
  ;;
t0)
  BEFORE=$(untouched)
  s "1 pSPY implementation -> collateral delegate, lending cap $CAP" $PSPY '_setImplementation(address,bool,bytes)' $DELEGATE false $(cast abi-encode 'f(uint256)' $CAP)
  need "$(c $PSPY 'implementation()(address)')" $DELEGATE "pSPY implementation switched"
  need "$(c $PSPY 'lendingSupplyCap()(uint256)' | first)" $CAP "lending supply cap set"
  need "$(cast storage $PSPY 21 --rpc-url "$RPC" | cast to-dec)" $CAP "cap in appended storage slot 21"
  need "$(untouched)" "$BEFORE" "NVDA lending, position 6, pSPY supply/rate, SPY margin positions unchanged"
  s "2 router adapter: liquidator may swap (pulls only from itself)" $RADAPTER 'setOperator(address,bool)' $LIQ true
  need "$(c $RADAPTER 'operators(address)(bool)' $LIQ)" true "liquidator is an adapter operator"
  s "3 controller: pSPY collateral factor" $CONTROLLER '_setCollateralFactor(address,uint256)' $PSPY $CF
  need "$(c $CONTROLLER 'markets(address)(bool,uint256,bool)' $PSPY | head -2 | tr '\n' ' ' | cut -d' ' -f1,2)" "true $CF" "collateral factor set (Compound error codes do not revert)"
  need "$(untouched)" "$BEFORE" "still unchanged after the collateral factor"
  ;;
demo-open)
  AMT=${DEMO_SPY_WEI:-$(c $SPY 'balanceOf(address)(uint256)' $L | first)}
  need "$(ge $AMT 1000000000000 && echo yes)" yes "Ledger holds a demo SPY amount ($AMT wei)"
  s "D1 approve SPY" $SPY 'approve(address,uint256)' $PSPY $AMT
  s "D2 supply SPY to pSPY" $PSPY 'mint(uint256)' $AMT
  s "D3 use pSPY as collateral" $CONTROLLER 'enterMarkets(address[])' "[$PSPY]"
  LQ=$(c $CONTROLLER 'getAccountLiquidity(address)(uint256,uint256,uint256)' $L | sed -n 2p | first)
  B=${DEMO_BORROW_RAW:-5000000}
  echo "   borrowing power $LQ (1e18 USD), borrow $B raw USDG"
  need "$(python3 -c "print('yes' if 0 < $B*10**12 <= $LQ*6//10 else 'no')")" yes "demo borrow is at most 60 % of the borrowing power (SPY may fall ~40 % before shortfall)"
  s "D4 borrow USDG against pSPY" $PUSDG 'borrow(uint256)' $B
  echo "   Ledger pUSDG debt $(cast call $PUSDG 'borrowBalanceCurrent(address)(uint256)' $L --rpc-url "$RPC" | first)"
  ;;
demo-close)
  s "D5 approve USDG for the repay" $USDG 'approve(address,uint256)' $PUSDG $(cast max-uint)
  s "D6 repay the whole debt" $PUSDG 'repayBorrow(uint256)' $(cast max-uint)
  s "D7 reset the USDG approval" $USDG 'approve(address,uint256)' $PUSDG 0
  need "$(cast call $PUSDG 'borrowBalanceCurrent(address)(uint256)' $L --rpc-url "$RPC" | first)" 0 "Ledger debt repaid"
  s "D8 redeem the demo pSPY" $PSPY 'redeem(uint256)' $(c $PSPY 'balanceOf(address)(uint256)' $L | first)
  s "D9 leave the pSPY market (so the Ledger is never frozen at weekends)" $CONTROLLER 'exitMarket(address)' $PSPY
  need "$(c $CONTROLLER 'checkMembership(address,address)(bool)' $L $PSPY)" false "Ledger not in pSPY"
  ;;
closed-check)
  # Read-only: run with the chain (or fork) inside the weekend window / stale. ACCOUNT must hold pSPY and be entered.
  A=${ACCOUNT:?ACCOUNT}
  echo "   session reason $(c $PSPY 'sessionReason()(uint256)' | first) (0 = open)"
  need "$(c $CONTROLLER 'getAccountLiquidity(address)(uint256,uint256,uint256)' $A | head -1 | first)" 15 "liquidity = SNAPSHOT_ERROR"
  for t in "pUSDG.borrow:$PUSDG:borrow(uint256):1000" "pSPY.redeem:$PSPY:redeem(uint256):1" "pSPY.transfer:$PSPY:transfer(address,uint256):$L 1"; do
    IFS=: read -r name tgt sig args <<< "$t"
    if cast call $tgt "$sig" $args --from $A --rpc-url "$RPC" >/dev/null 2>&1; then echo "CHECK FAILED: $name allowed while closed"; exit 1; fi
    echo "   ok: $name refused"
  done
  need "$(cast call $LIQ 'liquidate(address,uint256)(uint256)' $A 1000 --from $L --rpc-url "$RPC" >/dev/null 2>&1 && echo allowed || echo refused)" refused "liquidation refused"
  if [ -n "${DEBTFREE_ACCOUNT:-}" ]; then
    need "$(c $PSPY 'hasDebt(address)(bool)' $DEBTFREE_ACCOUNT)" false "debt-free account has no debt"
    need "$(c $CONTROLLER 'getAccountLiquidity(address)(uint256,uint256,uint256)' $DEBTFREE_ACCOUNT | head -1 | first)" 0 "debt-free account: no snapshot error"
    B2=$(c $PSPY 'balanceOf(address)(uint256)' $DEBTFREE_ACCOUNT | first)
    need "$(cast call $PSPY 'redeem(uint256)(uint256)' $B2 --from $DEBTFREE_ACCOUNT --rpc-url "$RPC" 2>/dev/null | first)" 0 "debt-free account may redeem all its pSPY while closed"
    if cast call $PUSDG 'borrow(uint256)' 1000 --from $DEBTFREE_ACCOUNT --rpc-url "$RPC" >/dev/null 2>&1; then echo "CHECK FAILED: debt-free account borrowed against SPY while closed"; exit 1; fi
    echo "   ok: debt-free account cannot borrow against SPY while closed"
  fi
  ;;
verify)
  need "$(c $PSPY 'implementation()(address)')" $DELEGATE "pSPY implementation = collateral delegate"
  need "$(c $CONTROLLER 'markets(address)(bool,uint256,bool)' $PSPY | head -2 | tr '\n' ' ' | cut -d' ' -f1,2)" "true $CF" "pSPY collateral factor"
  need "$(c $CONTROLLER 'borrowGuardianPaused(address)(bool)' $PSPY)" true "pSPY borrowing still paused"
  need "$(c $RADAPTER 'operators(address)(bool)' $LIQ)" true "liquidator is an adapter operator"
  need "$(c $CONTROLLER 'oracle()(address)')" $ADAPTER3 "controller oracle unchanged"
  echo "   cap $(c $PSPY 'lendingSupplyCap()(uint256)' | first), total pSPY in SPY $(c $PSPY 'totalUnderlyingSupply()(uint256)' | first), session reason $(c $PSPY 'sessionReason()(uint256)' | first)"
  echo "   pUSDG cash $(c $PUSDG 'getCash()(uint256)' | first), totalBorrows $(c $PUSDG 'totalBorrows()(uint256)' | first), borrowCap $(c $CONTROLLER 'borrowCaps(address)(uint256)' $PUSDG | first)"
  ;;
rollback)
  # Instant, Ledger only. R1 stops new lending supply. R2 makes any SPY-backed borrower liquidatable (when fresh):
  # run it only once SPY-backed debt is repaid, or deliberately (ROLLBACK_CF=yes). R3 removes the liquidator's swap right.
  s "R1 close lending mints (cap 0; margin opens unaffected)" $PSPY '_setLendingSupplyCap(uint256)' 0
  if [ "${ROLLBACK_CF:-no}" = yes ]; then
    s "R2 pSPY collateral factor -> 0" $CONTROLLER '_setCollateralFactor(address,uint256)' $PSPY 0
    s "R3 router adapter: remove the liquidator" $RADAPTER 'setOperator(address,bool)' $LIQ false
  fi
  ;;
*) echo "unknown phase $PHASE"; exit 2;;
esac
