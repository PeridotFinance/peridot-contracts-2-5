#!/usr/bin/env bash
# Anvil rehearsal of the full SPY-margin rollout on a fork of the live chain, using the SAME scripts the operator runs:
#   throwaway deploy (DeploySpyMargin --broadcast) -> ceremony.sh preflight / t0 / (1 h) gate / t1 / demo-open /
#   demo-orders -> orders keeper executes the SPY stop-loss -> demo-open + demo-close -> verify -> rollback.
# Only the signer differs (SIGN=--unlocked, Ledger impersonated). Logs go to .scratch/ (git-ignored).
#
# Rehearsal-only adjustments, all marked below: (1) market accrual aligned to anvil's block number (anvil reports the
# L2 height, the chain accrues on the native L1 number); (2) the RHSPY feed is etched with a fixed-answer mock so the
# 1 h warp keeps it fresh and the stop-loss can be triggered. The real ceremony runs in session with the live feed.
set -euo pipefail
cd "$(dirname "$0")/../.."; exec 2> >(grep -v "Found unknown" >&2)
P=${ANVIL_PORT:-8679}; F=http://127.0.0.1:$P; LOG=.scratch/rehearsal; mkdir -p $LOG
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; D=0x00000000000000000000000000000000DEC0DE5b; K=0x00000000000000000000000000000000000Ce05b
FEED=0x319724394D3A0e3669269846abE664Cd621f9f6A; MORACLE=0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD
J=deployments/spy-margin/spy-margin-rehearsal.json
anvil --fork-url https://rpc.mainnet.chain.robinhood.com ${FORK_BLOCK:+--fork-block-number $FORK_BLOCK} --port $P --silent \
  --auto-impersonate --timeout 300000 --retries 12 >/dev/null 2>&1 &
AP=$!; trap 'kill $AP 2>/dev/null' EXIT
for i in $(seq 1 120); do cast block-number --rpc-url $F >/dev/null 2>&1 && break; sleep 0.5; done
echo "fork block $(cast rpc anvil_nodeInfo --rpc-url $F | python3 -c 'import json,sys;print(json.load(sys.stdin)["forkConfig"]["forkBlockNumber"])'), time $(date -u -r $(cast block latest --field timestamp --rpc-url $F))"
for a in $D $L $K; do cast rpc anvil_setBalance $a 0x16345785D8A0000 --rpc-url $F >/dev/null; done

echo "== deploy (throwaway sender)"
rm -f $J; B0=$(cast balance $D --rpc-url $F)
FOUNDRY_PROFILE=robinhood_spy SPY_MARGIN_JOURNAL=spy-margin-rehearsal forge script script/spy/DeploySpyMargin.s.sol:DeploySpyMargin \
  --rpc-url $F --sender $D --unlocked --broadcast --slow > $LOG/deploy.log 2>&1 || { tail -20 $LOG/deploy.log; exit 1; }
echo "   txs $(python3 -c "import json;print(len(json.load(open('broadcast/DeploySpyMargin.s.sol/4663/run-latest.json'))['receipts']))"), deployer gas $(cast from-wei $((B0 - $(cast balance $D --rpc-url $F)))) ETH"
jq -c '{pSpy,delegate,lendingAdapter,spySource,router}' $J

# (1) rehearsal-only: align pUSDG / pNVDA accrual to anvil's block number (slot 9 = accrualBlockNumber)
BN=$(cast block-number --rpc-url $F)
for m in 0x55aEd0569c8f0D166D71facE57B57C2f2624a563 0xa155ccCB986774AE818b3F10F07d01D1b7A47b26; do
  cast rpc anvil_setStorageAt $m 0x0000000000000000000000000000000000000000000000000000000000000009 $(cast to-uint256 $BN) --rpc-url $F >/dev/null; done
# (2) rehearsal-only: hold the RHSPY feed at its real last answer, updatedAt = block time
ANS=$(cast call $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $F | sed -n 2p | cut -d' ' -f1)
FOUNDRY_PROFILE=robinhood_spy forge build >/dev/null 2>&1
cast rpc anvil_setCode $FEED $(python3 -c "import json;print(json.load(open('out-spy/SpyFreshFeedMock.sol/SpyFreshFeedMock.json'))['deployedBytecode']['object'])") --rpc-url $F >/dev/null
cast rpc anvil_setStorageAt $FEED 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast to-uint256 $ANS) --rpc-url $F >/dev/null
echo "   SPY feed held at $ANS"

export RPC=$F SIGN=--unlocked
run(){ echo "== ceremony $1"; tools/spy/ceremony.sh $J "$1" 2>&1 | tee $LOG/$1.log; }
run preflight
run t0
cast rpc evm_increaseTime 3601 --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null
echo "== (warp 1 h)"
run gate
run t1
run demo-open
ID=$(( $(cast call 0x6A45Ae86bD992d250580d08D340A06A04D478977 'nextPositionId()(uint256)' --rpc-url $F | cut -d' ' -f1) - 1 ))
POSITION_ID=$ID run demo-orders

echo "== orders keeper on the SPY position $ID (dry run, then a -6 % SPY print, then --execute)"
KS=$LOG/orders-keeper-state.json; rm -f $KS
( cd tools/orders && MAX_GAS_PRICE_WEI=1000000000000 RH_RPC=$F python3 orders_keeper.py --journal ../../deployments/range-mainnet.json --sender $K --state ../../$KS --once ) 2>&1 | tee $LOG/keeper-1.log | sed -E 's/, "time": [0-9]+//' | tail -3
cast rpc anvil_setStorageAt $FEED 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast to-uint256 $(python3 -c "print($ANS*94//100)")) --rpc-url $F >/dev/null
( cd tools/orders && MAX_GAS_PRICE_WEI=1000000000000 RH_RPC=$F python3 orders_keeper.py --journal ../../deployments/range-mainnet.json --sender $K --unlocked --state ../../$KS --execute --once ) 2>&1 | tee $LOG/keeper-2.log | sed -E 's/"tx": "0x[0-9a-f]+", //;s/, "time": [0-9]+//' | tail -3
echo "   position $ID status after the keeper: $(cast call 0x6A45Ae86bD992d250580d08D340A06A04D478977 'positions(uint256)((uint256,address,address,address,address,address,uint256,uint256,uint256,uint16,uint8,uint8))' $ID --rpc-url $F | tr -d '()' | awk -F', ' '{print $12}') (5 = CLOSED)"

cast rpc anvil_setStorageAt $FEED 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast to-uint256 $ANS) --rpc-url $F >/dev/null
run demo-open
ID2=$(( $(cast call 0x6A45Ae86bD992d250580d08D340A06A04D478977 'nextPositionId()(uint256)' --rpc-url $F | cut -d' ' -f1) - 1 ))
POSITION_ID=$ID2 run demo-close
run verify
ROLLBACK_PRICES=yes run rollback
echo "   after rollback: SPY margin price $(cast call $MORACLE 'getPrice(address)(uint256)' 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C --rpc-url $F | cut -d' ' -f1) (0 expected), NVDA $(cast call $MORACLE 'getPrice(address)(uint256)' 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC --rpc-url $F | cut -d' ' -f1)"
echo "== Ledger transactions sent: $(grep -h -c '^   status 0x1' $LOG/*.log | paste -sd+ - | bc)"
echo "REHEARSAL COMPLETE"
