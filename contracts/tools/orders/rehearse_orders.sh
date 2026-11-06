#!/usr/bin/env bash
# Anvil rehearsal: DeployRobinhoodOrders (real registry) -> Ledger pair -> verify -> orders on position 4 -> keeper loop.
set -uo pipefail
cd "$(dirname "$0")/../.."; TMP=${TMPDIR:-/tmp}
P=8666; F=http://127.0.0.1:$P
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; T=0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498
D=0x00000000000000000000000000000000DEC0DE03; K=0x00000000000000000000000000000000000Ce002
FEED=0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port $P --silent --auto-impersonate --timeout 60000 --retries 8 >/dev/null 2>&1 &
AP=$!
for i in $(seq 1 80); do cast block-number --rpc-url $F >/dev/null 2>&1 && break; sleep 0.5; done
echo "fork block $(cast rpc anvil_nodeInfo --rpc-url $F | python3 -c 'import json,sys;print(json.load(sys.stdin)["forkConfig"]["forkBlockNumber"])')"
for a in $D $L $K; do cast rpc anvil_setBalance $a 0x16345785D8A0000 --rpc-url $F >/dev/null; done
J=deployments/orders-rehearsal.json; rm -f $J; rm -rf broadcast/DeployRobinhoodOrders.s.sol
export ORDERS_PUBLIC_SENDER=$D ORDERS_JOURNAL=$J ORDERS_SOURCE_COMMIT=$(git rev-parse HEAD)
B0=$(cast balance $D --rpc-url $F)
FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRobinhoodOrders.s.sol:DeployRobinhoodOrders --rpc-url $F --sender $D --unlocked --broadcast --slow > "$TMP/orders-deploy2.log" 2>&1
grep -E "ONCHAIN EXECUTION|rror" "$TMP/orders-deploy2.log" | grep -v metadata | head -3
echo "deploy txs: $(python3 -c "import json;print(len(json.load(open('broadcast/DeployRobinhoodOrders.s.sol/4663/run-latest.json'))['receipts']))"), gas ETH $(cast from-wei $((B0 - $(cast balance $D --rpc-url $F))))"
REG=$(jq -r .registry $J); AD=$(jq -r .adapter $J)
ck(){ FOUNDRY_PROFILE=robinhood_orders forge script script/orders/DeployRobinhoodOrders.s.sol:DeployRobinhoodOrders --sig "$1(string)" $J --rpc-url $F 2>&1 | grep -E "check ok|verified|Error|revert" | head -2; }
st(){ python3 -c "import json,sys;r=json.load(sys.stdin);print('$1',r['status'],int(r['gasUsed'],16))"; }
ck check
cast send $T $(jq -r .scheduleCalldata $J) --from $L --unlocked --gas-limit 1000000 --rpc-url $F --json | st "Ledger 1 schedule"
cast rpc evm_increaseTime 3601 --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null
ck check
cast send $T $(jq -r .executeCalldata $J) --from $L --unlocked --gas-limit 1000000 --rpc-url $F --json | st "Ledger 2 execute"
ck verify
# Anvil reports the L2 height as block.number while the markets accrue on the native L1 number: align accrual so the
# fork does not charge ~81M blocks of interest (forge tests use vm.roll to the native number instead).
BN=$(cast block-number --rpc-url $F)
for m in 0x55aEd0569c8f0D166D71facE57B57C2f2624a563 0xa155ccCB986774AE818b3F10F07d01D1b7A47b26; do cast rpc anvil_setStorageAt $m 0x0000000000000000000000000000000000000000000000000000000000000009 $(cast to-uint256 $BN) --rpc-url $F >/dev/null; done
# Hold the NVDA feed fresh at its real last answer (the warp and the weekend would make it stale on the fork).
ANS=$(cast call $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $F | sed -n 2p | cut -d' ' -f1)
MOCK=out-orders/FreshFeedMock.sol/FreshFeedMock.json
cast rpc anvil_setCode $FEED $(python3 -c "import json;print(json.load(open('$MOCK'))['deployedBytecode']['object'])") --rpc-url $F >/dev/null
cast rpc anvil_setStorageAt $FEED 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast to-uint256 $ANS) --rpc-url $F >/dev/null
OWNER=$(cast call $AD 'positionOwner(uint256)(address)' 4 --rpc-url $F); LONG=$(cast call $AD 'isLong(uint256)(bool)' 4 --rpc-url $F)
PRICE=$(cast call $AD 'oraclePriceE18(uint256)(uint256,bool)' 4 --rpc-url $F | head -1 | cut -d' ' -f1)
echo "position 4: owner $OWNER long=$LONG oracle $PRICE"
cast rpc anvil_setBalance $OWNER 0x16345785D8A0000 --rpc-url $F >/dev/null
NOW=$(cast block latest --field timestamp --rpc-url $F); EXP=$((NOW + 86400))
if [ "$LONG" = true ]; then SLT=$((PRICE / 2)); SLA=false; TPA=true; else SLT=$(python3 -c "print($PRICE*2)"); SLA=true; TPA=false; fi
cast send $REG 'createOrder(uint256,uint8,bool,uint256,uint16,uint16,uint64)' 4 1 $SLA $SLT 10000 100 $EXP --from $OWNER --unlocked --rpc-url $F --json | st "owner: stop-loss (far)"
cast send $REG 'createOrder(uint256,uint8,bool,uint256,uint16,uint16,uint64)' 4 0 $TPA $PRICE 10000 100 $EXP --from $OWNER --unlocked --rpc-url $F --json | st "owner: take-profit (at the oracle price)"
echo "canExecute 1: $(cast call $REG 'canExecute(uint256)(bool,uint256,uint8)' 1 --rpc-url $F | tr '\n' ' ')| 2: $(cast call $REG 'canExecute(uint256)(bool,uint256,uint8)' 2 --rpc-url $F | tr '\n' ' ')"
cd tools/orders; S="$TMP/orders-keeper-state.json"; rm -f "$S"
echo "== keeper dry run"; MAX_GAS_PRICE_WEI=1000000000000 RH_RPC=$F python3 orders_keeper.py --journal ../../$J --sender $K --state "$S" --once | sed -E 's/, "time": [0-9]+//'
echo "== keeper --execute"; MAX_GAS_PRICE_WEI=1000000000000 RH_RPC=$F python3 orders_keeper.py --journal ../../$J --sender $K --unlocked --state "$S" --execute --once | sed -E 's/"tx": "0x[0-9a-f]+", //;s/, "time": [0-9]+//'
echo "== keeper again"; MAX_GAS_PRICE_WEI=1000000000000 RH_RPC=$F python3 orders_keeper.py --journal ../../$J --sender $K --unlocked --state "$S" --execute --once | sed -E 's/, "time": [0-9]+//'; echo "(state: $(cat "$S" | tr -d ' \n'))"
cd ../..
echo "position 4 active after: $(cast call $AD 'isActive(uint256)(bool)' 4 --rpc-url $F); order 1 status / order 2 status: $(cast call $REG 'canExecute(uint256)(bool,uint256,uint8)' 1 --rpc-url $F | tail -1) / $(cast call $REG 'canExecute(uint256)(bool,uint256,uint8)' 2 --rpc-url $F | tail -1) (1 = final)"
kill $AP
