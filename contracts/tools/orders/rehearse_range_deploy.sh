#!/usr/bin/env bash
# Anvil fork rehearsal of the range take-profit PRODUCTION path with --broadcast: the 15-17 Nov ceremony first
# (DeployRobinhoodOrders + its Ledger pair), then DeployRangeTakeProfit (throwaway key) and its Ledger batch through the
# real timelock, `check` before both signatures and `verify` after. Ledger and timelock unlocked on anvil only.
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=${TMPDIR:-/tmp}; P=8681; F=http://127.0.0.1:$P
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; T=0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498
D=0x00000000000000000000000000000000DEC0DE06; D2=0x00000000000000000000000000000000DEC0DE07
export FOUNDRY_PROFILE=robinhood_orders
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port $P --silent --auto-impersonate >/dev/null 2>&1 &
AP=$!
for i in $(seq 1 80); do cast block-number --rpc-url $F >/dev/null 2>&1 && break; sleep 0.5; done
echo "fork block $(cast rpc anvil_nodeInfo --rpc-url $F | python3 -c 'import json,sys;print(json.load(sys.stdin)["forkConfig"]["forkBlockNumber"])')"
for a in $D $D2 $L; do cast rpc anvil_setBalance $a 0x16345785D8A0000 --rpc-url $F >/dev/null; done
st(){ python3 -c "import json,sys;r=json.load(sys.stdin);print('  $1',r['status'],int(r['gasUsed'],16));sys.exit(0 if r['status']=='0x1' else 1)" || { echo "STOPPED at $1"; kill $AP; exit 1; }; }
OJ=deployments/orders-rehearsal-range.json; RJ=deployments/range-rehearsal.json; rm -f $OJ $RJ
rm -rf broadcast/DeployRobinhoodOrders.s.sol broadcast/DeployRangeTakeProfit.s.sol

echo "== the ceremony (DeployRobinhoodOrders, then the Ledger pair)"
ORDERS_PUBLIC_SENDER=$D ORDERS_JOURNAL=$OJ forge script script/orders/DeployRobinhoodOrders.s.sol:DeployRobinhoodOrders \
  --rpc-url $F --sender $D --unlocked --broadcast --slow 2>&1 | grep -E "ONCHAIN EXECUTION|rror" | grep -v metadata | head -2
cast send $T $(jq -r .scheduleCalldata $OJ) --from $L --unlocked --gas-limit 1000000 --rpc-url $F --json | st "Ledger: orders schedule"
cast rpc evm_increaseTime 3601 --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null
cast send $T $(jq -r .executeCalldata $OJ) --from $L --unlocked --gas-limit 1000000 --rpc-url $F --json | st "Ledger: orders execute"

echo "== DeployRangeTakeProfit (throwaway key)"
B0=$(cast balance $D2 --rpc-url $F)
RANGE_PUBLIC_SENDER=$D2 RANGE_JOURNAL=$RJ ORDERS_JOURNAL=$OJ RANGE_PROTOCOL_RECIPIENT=$L \
RANGE_SOURCE_COMMIT=$(git rev-parse HEAD) \
  forge script script/orders/DeployRangeTakeProfit.s.sol:DeployRangeTakeProfit --rpc-url $F --sender $D2 --unlocked --broadcast --slow \
  > $TMP/range-deploy.log 2>&1
grep -E "ONCHAIN EXECUTION|rror" $TMP/range-deploy.log | grep -v metadata | head -3
echo "  creations: $(python3 -c "import json;print(len(json.load(open('broadcast/DeployRangeTakeProfit.s.sol/4663/run-latest.json'))['receipts']))"), gas ETH $(cast from-wei $((B0 - $(cast balance $D2 --rpc-url $F))))"
ck(){ forge script script/orders/DeployRangeTakeProfit.s.sol:DeployRangeTakeProfit --sig "$1(string)" $RJ --rpc-url $F 2>&1 | grep -E "check ok|verified|Error|revert" | head -2; }
ck check
cast send $T $(jq -r .scheduleCalldata $RJ) --from $L --unlocked --gas-limit 3000000 --rpc-url $F --json | st "Ledger 1: range scheduleBatch"
ck check
echo "  early execute: $(cast call $T $(jq -r .executeCalldata $RJ) --from $L --rpc-url $F 2>&1 | grep -o 'execution reverted' | head -1)"
cast rpc evm_increaseTime 3601 --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null
cast send $T $(jq -r .executeCalldata $RJ) --from $L --unlocked --gas-limit 10000000 --rpc-url $F --json | st "Ledger 2: range executeBatch"
ck verify
python3 -c "import json;d=json.load(open('$RJ'));print('  keeper journal fields:', {k:d[k] for k in ('registry','rangeCustodian','executor')})"
kill $AP
