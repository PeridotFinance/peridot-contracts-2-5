#!/usr/bin/env bash
# SPY 2x margin rollout: the exact Ledger calls, phase by phase, each followed by a state check.
#
#   tools/spy/ceremony.sh <journal.json> <phase>
#   phases: preflight | t0 | gate | t1 | demo-open | demo-orders | demo-close | verify | rollback
#
# Signing: SIGN defaults to "--ledger" (the operator's Ledger 0x064eFE76...B2dD). The anvil rehearsal sets
# SIGN=--unlocked and RPC=http://127.0.0.1:<port>. RPC defaults to the public Robinhood endpoint.
# Every call is a single `cast send` from the Ledger. Nothing here reads a key. Re-run `verify` at any time.
#
# LIVE-NVDA-TOUCHING calls are marked [LIVE-NVDA]: t0 step 5 (controller price oracle) and t0 step 12 (margin price
# source). Their rollback is in the `rollback` phase.
#
# Operator parameters (env, defaults = proposal): SPY_MAX_POSITION_USD=250 SPY_MAX_DEBT_USD=125 SPY_SEED_WEI=100000000000000
# (0.0001 SPY) LEDGER_LIQUIDITY_USDG_RAW=80000000 (80 USDG) DEMO_MARGIN_USDG_RAW=50000000 (50 USDG of existing pUSDG)
set -euo pipefail
J=${1:?journal}; PHASE=${2:?phase}
RPC=${RPC:-https://rpc.mainnet.chain.robinhood.com}; SIGN=${SIGN:---ledger}
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
CONTROLLER=0x6148183676E304dbe63a85C350c208DA3cEAc39C; LIVE_ADAPTER=0xe4e03C2FdaeF915ACe705D106b2660B1E342A2E4
LENDING=0x266F014d1325774F1190f963Df4369E07dDA1d33; MORACLE=0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD
NVDA_SRC=0x25E02b142E0785a59D85a6CA820c400e601a9E8E; CONFIG=0x09F94fe0B79E000c8a26617c63E3427fdECB528b
RADAPTER=0xa32C34F100B4F1f36ECA09c427a098f99F4423F0; EXECUTOR=0x6A45Ae86bD992d250580d08D340A06A04D478977
RISK=0xC8b178C3c74570472FF1eeE0DD559e61AF9f9678; QUOTER=0xeD3c353Ab237329BD53CC7eB24E66B370155FE6e
MVAULT=0x04D4A5555b7a37017A67B4D21A1Da5838de28B9e; REGISTRY=0xeb7DD1635b5c22672bE469ce112f78DE2Dc62f96
PUSDG=0x55aEd0569c8f0D166D71facE57B57C2f2624a563; PNVDA=0xa155ccCB986774AE818b3F10F07d01D1b7A47b26
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; SPY=0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
NVDA=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; FEED=0x319724394D3A0e3669269846abE664Cd621f9f6A
DEAD=0x000000000000000000000000000000000000dEaD; POS6=0x8039391D9a706dB3FdD46602f735fB097E5D464B
PSPY=$(jq -r .pSpy "$J"); ADAPTER3=$(jq -r .lendingAdapter "$J"); ROUTER=$(jq -r .router "$J"); SPYSRC=$(jq -r .spySource "$J")
MAXPOS=$(cast to-wei "${SPY_MAX_POSITION_USD:-250}"); MAXDEBT=$(cast to-wei "${SPY_MAX_DEBT_USD:-125}")
SEED=${SPY_SEED_WEI:-100000000000000}; SEED_SHARES=$(python3 -c "print($SEED*10**18//(2*10**26))")
LIQ=${LEDGER_LIQUIDITY_USDG_RAW:-80000000}; DEMO=${DEMO_MARGIN_USDG_RAW:-50000000}
TUPLE="(true,200,5000,2500,12500,5000,5000,500,100,100,$MAXPOS,$MAXDEBT)"
RISKSIG='(bool,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint128,uint128)'

exec 2> >(grep -v "Found unknown" >&2)
c(){ cast call "$@" --rpc-url "$RPC"; }
ge(){ python3 -c "import sys;sys.exit(0 if int('$1')>=int('$2') else 1)"; } # big integers (bash is 64-bit signed)
s(){ local label=$1; shift; echo "-- $label"; cast send "$@" --from $L $SIGN --rpc-url "$RPC" --rpc-timeout 600 --json \
       | python3 -c "import json,sys;r=json.load(sys.stdin);print('   status',r['status'],'gas',int(r['gasUsed'],16),'tx',r['transactionHash']);sys.exit(0 if r['status']=='0x1' else 1)"; }
need(){ if [ "$1" != "$2" ]; then echo "CHECK FAILED: $3 (got '$1', want '$2')"; exit 1; fi; echo "   ok: $3"; }
first(){ cut -d' ' -f1 | head -1; }

nvda_snapshot(){ # the values the two LIVE-NVDA calls must leave bit-identical
  echo "$(c $MORACLE 'getPrice(address)(uint256)' $NVDA | first) $(c $MORACLE 'getPrice(address)(uint256)' $USDG | first)" \
       "$(cast call $RISK 'getMetrics(address)' $POS6 --rpc-url "$RPC" 2>/dev/null || echo revert)" \
       "$(c $(c $CONTROLLER 'oracle()(address)') 'getUnderlyingPrice(address)(uint256)' $PNVDA | first)" \
       "$(c $(c $CONTROLLER 'oracle()(address)') 'getUnderlyingPrice(address)(uint256)' $PUSDG | first)"; }

case $PHASE in
preflight)
  need "$(cast chain-id --rpc-url "$RPC")" 4663 "chain 4663"
  need "$(c $CONTROLLER 'admin()(address)')" $L "controller admin = Ledger"
  need "$(c $CONTROLLER 'oracle()(address)')" $LIVE_ADAPTER "controller oracle is still the live 2-market adapter"
  need "$(c $MORACLE 'assetSource()(address)')" $NVDA_SRC "margin assetSource is still the NVDA guarded source"
  need "$(c $CONFIG 'owner()(address)')" $L "config owner = Ledger"
  need "$(c $RADAPTER 'owner()(address)')" $L "router adapter owner = Ledger"
  need "$(c $MORACLE 'owner()(address)')" $L "margin oracle owner = Ledger"
  need "$(c $LENDING 'admin(address)(bool)' $L)" true "Ledger is a lending-oracle admin"
  need "$(c $PSPY 'admin()(address)')" $L "pSPY admin = Ledger"
  need "$(c $PSPY 'totalSupply()(uint256)' | first)" 0 "pSPY empty"
  need "$(c $SPY 'paused()(bool)')/$(c $SPY 'oraclePaused()(bool)')" false/false "SPY not paused"
  UPD=$(c $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' | sed -n 4p | first); NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
  echo "   SPY feed age $((NOW - UPD)) s; window closed now: $(c $SPYSRC 'inClosedWindow(uint256)(bool)' $NOW)"
  need "$(c $SPYSRC 'inClosedWindow(uint256)(bool)' $NOW)" false "outside the weekend window"
  need "$([ $((NOW - UPD)) -le 3600 ] && echo fresh)" fresh "SPY feed updated within the last hour (run in session)"
  need "$(ge $(c $SPY 'balanceOf(address)(uint256)' $L | first) $SEED && echo yes)" yes "Ledger holds the SPY seed"
  need "$(ge $(c $USDG 'balanceOf(address)(uint256)' $L | first) $LIQ && echo yes)" yes "Ledger holds the USDG liquidity"
  FOUNDRY_PROFILE=robinhood_spy SPY_MARGIN_ACTION=verify SPY_MARGIN_JOURNAL=$(basename "$J" .json) \
    forge script script/spy/DeploySpyMargin.s.sol:DeploySpyMargin --rpc-url "$RPC" >/dev/null && echo "   ok: deployment verify"
  nvda_snapshot > "${J%.json}.nvda-before.txt"; echo "   NVDA snapshot saved"
  ;;
t0)
  s "1 queue the SPY long pair risk (1 h delay starts)" $CONFIG "queuePairRisk(address,address,address,$RISKSIG)" $PUSDG $PSPY $PUSDG "$TUPLE"
  s "2 lending oracle: register the SPY feed" $LENDING 'registerChainlinkFeed(address,address)' $SPY $FEED
  s "3 lending oracle: SPY is a stock asset (72 h threshold, cached fallback)" $LENDING 'setStockAsset(address,bool)' $SPY true
  s "4 lending oracle: seed the cached SPY price" $LENDING 'updateChainlinkPrices(address[])' "[$SPY]"
  need "$(ge $(c $LENDING 'assetPrices(address)(uint256)' $SPY | first) 1 && echo priced)" priced "lending oracle prices SPY"
  BEFORE=$(nvda_snapshot)
  s "5 [LIVE-NVDA] controller price oracle -> 3-market adapter" $CONTROLLER '_setPriceOracle(address)' $ADAPTER3
  need "$(c $CONTROLLER 'oracle()(address)')" $ADAPTER3 "controller oracle switched (Compound error codes do not revert)"
  need "$(nvda_snapshot)" "$BEFORE" "[LIVE-NVDA] pNVDA/pUSDG lending prices and position 6 unchanged"
  s "6 list pSPY" $CONTROLLER '_supportMarket(address)' $PSPY
  need "$(c $CONTROLLER 'markets(address)(bool,uint256,bool)' $PSPY | head -2 | tr '\n' ' ' | cut -d' ' -f1,2)" "true 0" "pSPY listed, collateral factor 0"
  s "7 pause pSPY borrowing (long only)" $CONTROLLER '_setBorrowPaused(address,bool)' $PSPY true
  need "$(c $CONTROLLER 'borrowGuardianPaused(address)(bool)' $PSPY)" true "pSPY borrow paused"
  s "8 approve the SPY seed" $SPY 'approve(address,uint256)' $PSPY $SEED
  s "9 mint the pSPY seed" $PSPY 'mint(uint256)' $SEED
  need "$(c $PSPY 'balanceOf(address)(uint256)' $L | first)" $SEED_SHARES "seed shares at the initial rate"
  s "10 send the seed shares to the dead address" $PSPY 'transfer(address,uint256)' $DEAD $SEED_SHARES
  s "11 margin oracle: register pSPY (plain market)" $MORACLE 'registerMarket(address,address,bool)' $PSPY $SPY false
  s "12 [LIVE-NVDA] margin oracle source -> router" $MORACLE 'setAssetSource(address)' $ROUTER
  need "$(nvda_snapshot)" "$BEFORE" "[LIVE-NVDA] NVDA/USDG margin prices and position 6 metrics unchanged"
  need "$(ge $(c $MORACLE 'getPrice(address)(uint256)' $SPY | first) 1 && echo priced)" priced "margin oracle prices SPY"
  s "13 router adapter: register the v4 SPY/USDG pool (0.30 %, spacing 60)" $RADAPTER 'registerPool(address,address,uint24,int24)' $SPY $USDG 3000 60
  ;;
gate)
  need "$(c $PSPY 'totalSupply()(uint256)' | first)" $SEED_SHARES "seed front-run gate: pSPY supply is only the seed"
  need "$(c $PSPY 'balanceOf(address)(uint256)' $DEAD | first)" $SEED_SHARES "seed front-run gate: seed at the dead address"
  need "$(c $PSPY 'exchangeRateStored()(uint256)' | first)" 200000000000000000000000000 "seed front-run gate: initial exchange rate"
  ID=$(cast keccak $(cast abi-encode "f(string,bytes32,$RISKSIG)" pairRisk $(c $CONFIG 'pairKey(address,address,address)(bytes32)' $PUSDG $PSPY $PUSDG) "$TUPLE"))
  ETA=$(c $CONFIG 'queuedActions(bytes32)(uint256)' $ID | first); NOW=$(cast block latest --field timestamp --rpc-url "$RPC")
  echo "   pair risk executable at $ETA (now $NOW)"; need "$([ $ETA -gt 0 ] && [ $NOW -ge $ETA ] && echo ready)" ready "1 h delay elapsed"
  ;;
t1)
  s "14 enable the SPY long pair" $CONFIG "setPairRisk(address,address,address,$RISKSIG)" $PUSDG $PSPY $PUSDG "$TUPLE"
  GOT=$(c $CONFIG "getPairRisk(address,address,address)($RISKSIG)" $PUSDG $PSPY $PUSDG | tr -d '() ' | sed -E 's/\[[^]]*\]//g')
  need "$GOT" "$(echo "$TUPLE" | tr -d '() ')" "pair risk set exactly as queued"
  s "15 approve USDG liquidity" $USDG 'approve(address,uint256)' $PUSDG $LIQ
  s "16 supply USDG liquidity to pUSDG" $PUSDG 'mint(uint256)' $LIQ
  echo "   pUSDG cash now $(c $PUSDG 'getCash()(uint256)' | first) raw USDG"
  ;;
demo-open)
  RATE=$(cast call $PUSDG 'exchangeRateCurrent()(uint256)' --rpc-url "$RPC" | first)
  SH=$(python3 -c "print($DEMO*10**18//$RATE)"); M=$(python3 -c "print($SH*$RATE//10**18)")
  MIN=$(c $QUOTER 'quoteOpen(address,address,address,uint256,uint16)(uint256,uint256)' $PUSDG $PSPY $PUSDG $M 200 | sed -n 2p | first)
  # The swap module refuses a caller minimum BELOW its own floor (SwapError 5), and the executor recomputes that floor
  # from the margin it actually redeems, which accrues a few wei between this quote and the mined open. Quote 5 bp
  # above the floor (the fill is ~0.5 % above it: 1 % slippage bound minus the 0.30 % pool fee and the pool offset).
  MIN=$(python3 -c "print($MIN*10005//10000)")
  echo "   margin $SH pUSDG shares (~$M raw USDG), min SPY out $MIN"
  s "D1 approve margin" $PUSDG 'approve(address,uint256)' $MVAULT $SH
  s "D2 deposit margin" $MVAULT 'deposit(address,uint256)' $PUSDG $SH
  s "D3 open the 2x SPY long" $EXECUTOR 'openPosition((address,address,address,uint256,uint16,uint256,uint256,uint8,bytes))' \
     "($PUSDG,$PSPY,$PUSDG,$SH,200,0,$MIN,0,0x)"
  ID=$(( $(c $EXECUTOR 'nextPositionId()(uint256)' | first) - 1 )); echo "   position $ID"
  cast call $RISK 'getMetrics(address)((uint256,uint256,int256,uint256,uint256,uint256,uint256))' $(c $EXECUTOR 'positions(uint256)((uint256,address,address,address,address,address,uint256,uint256,uint256,uint16,uint8,uint8))' $ID | tr -d '()' | cut -d, -f3 | tr -d ' ') --rpc-url "$RPC"
  ;;
demo-orders)
  ID=${POSITION_ID:?POSITION_ID}; P=$(c $MORACLE 'getPrice(address)(uint256)' $SPY | first); EXP=$(( $(cast block latest --field timestamp --rpc-url "$RPC") + 7*86400 ))
  SL=$(python3 -c "print($P*95//100)"); TP=$(python3 -c "print($P*105//100)")
  s "D4 stop-loss at -5 %" $REGISTRY 'createOrder(uint256,uint8,bool,uint256,uint16,uint16,uint64)' $ID 1 false $SL 10000 100 $EXP
  s "D5 take-profit at +5 %" $REGISTRY 'createOrder(uint256,uint8,bool,uint256,uint16,uint16,uint64)' $ID 0 true $TP 10000 100 $EXP
  ;;
demo-close)
  ID=${POSITION_ID:?POSITION_ID}; ACC=$(c $EXECUTOR 'positions(uint256)((uint256,address,address,address,address,address,uint256,uint256,uint256,uint16,uint8,uint8))' $ID | tr -d '()' | cut -d, -f3 | tr -d ' ')
  R=$(cast call $PSPY 'exchangeRateCurrent()(uint256)' --rpc-url "$RPC" | first); B=$(c $PSPY 'balanceOf(address)(uint256)' $ACC | first)
  DEBT=$(cast call $PUSDG 'borrowBalanceCurrent(address)(uint256)' $ACC --rpc-url "$RPC" | first)
  Q=$(c $QUOTER 'expectedOut(address,address,uint256)(uint256)' $SPY $USDG $(python3 -c "print($B*$R//10**18)") | first)
  FEE=$(c 0x79d33c9BbC1D0711e88C5602f86135Ab4C088b06 'flashFee(address,uint256)(uint256)' $USDG $DEBT | first)
  MIN=$(python3 -c "print(max($Q*9900//10000, $DEBT+$FEE))"); echo "   debt $DEBT, min debt-leg out $MIN"
  s "D6 close the SPY long" $EXECUTOR 'closePosition((uint256,uint16,uint256,uint256,uint256,bytes,bytes))' "($ID,10000,$(cast max-uint),$MIN,0,0x,0x)"
  F=$(c $MVAULT 'freeBalance(address,address)(uint256)' $L $PUSDG | first)
  s "D7 withdraw the margin" $MVAULT 'withdraw(address,uint256)' $PUSDG $F
  ;;
verify)
  need "$(c $CONTROLLER 'oracle()(address)')" $ADAPTER3 "controller oracle = 3-market adapter"
  need "$(c $MORACLE 'assetSource()(address)')" $ROUTER "margin assetSource = router"
  need "$(c $MORACLE 'marketAsset(address)(address)' $PSPY)" $SPY "pSPY registered in the margin oracle"
  need "$(c $CONTROLLER 'borrowGuardianPaused(address)(bool)' $PSPY)" true "pSPY borrow paused"
  need "$(c $CONFIG "getPairRisk(address,address,address)($RISKSIG)" $PUSDG $PUSDG $PSPY | tr -d '()' | cut -d, -f1)" false "short not configured"
  echo "   long pair: $(c $CONFIG "getPairRisk(address,address,address)($RISKSIG)" $PUSDG $PSPY $PUSDG)"
  echo "   SPY price $(c $MORACLE 'getPrice(address)(uint256)' $SPY | first); source reason $(c $SPYSRC 'stockPrice()(uint256,uint8,uint256)' | sed -n 2p)"
  ;;
rollback)
  # Instant, Ledger only. Order: stop new SPY positions, then restore the NVDA-only price paths once SPY positions are closed.
  s "R1 disable the SPY long pair (opens refused immediately; closes unaffected)" $CONFIG 'disablePair(address,address,address)' $PUSDG $PSPY $PUSDG
  if [ "${ROLLBACK_PRICES:-no}" = yes ]; then
    s "R2 [LIVE-NVDA] margin oracle source -> NVDA guarded source" $MORACLE 'setAssetSource(address)' $NVDA_SRC
    echo "   R3 (controller oracle back to $LIVE_ADAPTER) is NOT automatic: only safe while no account has entered pSPY."
  fi
  ;;
*) echo "unknown phase $PHASE"; exit 2;;
esac
