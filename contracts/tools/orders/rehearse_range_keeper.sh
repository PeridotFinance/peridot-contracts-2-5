#!/usr/bin/env bash
# Anvil fork rehearsal of the range finalisation keeper (orders_keeper.py range phase) on the LIVE margin stack, upgraded
# on the fork to the range take-profit prototype through its real ProxyAdmins (timelock and Ledger unlocked on anvil).
# Scenarios from one snapshot after the order is created on live position 4: partial fill (wait), reversal (wait),
# full fill (keeper finalises), liquidation (band removed by the liquidator, keeper only records it), stop-loss (order
# phase executes it, the adapter removes the band, the range phase records it). Nothing is sent to mainnet.
set -uo pipefail
cd "$(dirname "$0")/../.."
TMP=${TMPDIR:-/tmp}; P=8667; F=http://127.0.0.1:$P
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; T=0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498
D=0x00000000000000000000000000000000DEC0DE05; K=0x00000000000000000000000000000000000Ce003
EX=0x6A45Ae86bD992d250580d08D340A06A04D478977; RISK=0xC8b178C3c74570472FF1eeE0DD559e61AF9f9678; LIQ=0x1434CDa56d0Aeac4d5abC16F91ca76a8A989083c
ORACLE=0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD; QUOTER=0xeD3c353Ab237329BD53CC7eB24E66B370155FE6e; CONFIG=0x09F94fe0B79E000c8a26617c63E3427fdECB528b
FEED=0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15; POOL=0xdac1904D823F7d6bcAaF431ceEe40c934fEd321b; NFP=0x2eBd7B85a4E08D5B508b04BA147976C94afE6590
GAUGE=0x93c6A733FB3165D94774B3A5Fc4319D29bd7b6ce; NVDA=0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC; USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
PU=0x55aEd0569c8f0D166D71facE57B57C2f2624a563; PN=0xa155ccCB986774AE818b3F10F07d01D1b7A47b26
ADMIN_SLOT=0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103; ID=4
export FOUNDRY_PROFILE=robinhood_orders
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port $P --silent --auto-impersonate --timeout 60000 --retries 8 >/dev/null 2>&1 &
AP=$!
for i in $(seq 1 80); do cast block-number --rpc-url $F >/dev/null 2>&1 && break; sleep 0.5; done
echo "fork block $(cast rpc anvil_nodeInfo --rpc-url $F | python3 -c 'import json,sys;print(json.load(sys.stdin)["forkConfig"]["forkBlockNumber"])')"
OWNER=$(cast call $EX 'positions(uint256)((uint256,address,address,address,address,address,uint256,uint256,uint256,uint16,uint8,uint8))' $ID --rpc-url $F | python3 -c 'import sys;print(sys.stdin.read().strip("()\n").split(",")[1].strip())')
for a in $D $K $T $L $OWNER $POOL; do cast rpc anvil_setBalance $a 0x16345785D8A0000 --rpc-url $F >/dev/null; done
st(){ python3 -c "import json,sys;r=json.load(sys.stdin);print('  $1',r['status']);sys.exit(0 if r['status']=='0x1' else 1)" || { echo "STOPPED at $1"; exit 1; }; }
create(){ forge create --rpc-url $F --unlocked --from $D --broadcast --json "$@" > $TMP/create.out 2>&1  # --constructor-args is greedy: keep it last
  python3 -c 'import json,sys;t=open(sys.argv[1]).read();i=t.find("{");print(json.loads(t[i:t.rfind("}")+1])["deployedTo"])' $TMP/create.out \
    || { echo "STOPPED: forge create $1" >&2; grep -v '^Warning' $TMP/create.out | head -20 >&2; kill $AP; exit 1; }; }

# Accrual on the native block number (anvil reports the L2 height) and a feed held fresh at its real answer.
BN=$(cast block-number --rpc-url $F)
for m in $PU $PN; do cast rpc anvil_setStorageAt $m 0x0000000000000000000000000000000000000000000000000000000000000009 $(cast to-uint256 $BN) --rpc-url $F >/dev/null; done
ANS=$(cast call $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $F | sed -n 2p | cut -d' ' -f1)
cast rpc anvil_setCode $FEED $(python3 -c "import json;print(json.load(open('out-orders/FreshFeedMock.sol/FreshFeedMock.json'))['deployedBytecode']['object'])") --rpc-url $F >/dev/null
setfeed(){ cast rpc anvil_setStorageAt $FEED 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast to-uint256 $1) --rpc-url $F >/dev/null; }
setfeed $ANS

# Deploy: registry impl, registry proxy (initialised with the predicted adapter), custodian, adapter, trader.
N0=$(cast nonce $D --rpc-url $F)
PROXY=lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy
# Ceremony first (registry V1 + adapter v1, executor initializeOrderExecutor(v1)), then the range wiring.
V1_P=$(cast compute-address $D --nonce $((N0 + 2)) | awk '{print $NF}')
RIMPL=$(create contracts/margin/orders/MarginOrderRegistry.sol:MarginOrderRegistry)
REG=$(create $PROXY --constructor-args $RIMPL $T $(cast calldata 'initialize(address,address)' $V1_P $T))
AD1=$(create contracts/margin/orders/RobinhoodMarginCloseAdapter.sol:RobinhoodMarginCloseAdapter --constructor-args $EX $REG $ORACLE $QUOTER $CONFIG 0x0000000000000000000000000000000000000000)
[ "$AD1" = "$V1_P" ] || { echo "STOPPED: predicted adapter v1 differs"; kill $AP; exit 1; }
RTPIMPL=$(create contracts/margin/orders/range/RangeTakeProfit.sol:RangeTakeProfit)
RTP=$(create $PROXY --constructor-args $RTPIMPL $T $(cast calldata 'initialize((address,address,address,address,address,address,address,address,address,address,address))' "($EX,$RISK,$NFP,$POOL,$GAUGE,$ORACLE,$CONFIG,$REG,$NVDA,$USDG,$D)"))
AD=$(create contracts/margin/orders/RobinhoodMarginCloseAdapter.sol:RobinhoodMarginCloseAdapter --constructor-args $EX $REG $ORACLE $QUOTER $CONFIG $RTP)
TR=$(create test/orders/RangeTakeProfitFork.t.sol:RtpTrader --constructor-args $POOL $USDG $NVDA)
echo "registry $REG custodian $RTP adapter $AD"

# Upgrades exactly as the timelock would, then the Ledger's risk-engine setting.
up(){ PA=0x$(cast storage $1 $ADMIN_SLOT --rpc-url $F | cut -c27-); cast send $PA 'upgradeAndCall(address,address,bytes)' $1 $2 $3 --from $T --unlocked --gas-limit 3000000 --rpc-url $F --json | st "$4"; }
EIMPL=$(create contracts/margin/IsolatedMarginExecutorUpgradeable.sol:IsolatedMarginExecutorUpgradeable)
up $EX $EIMPL $(cast calldata 'initializeOrderExecutor(address)' $AD1) "timelock (ceremony): executor upgrade + orderExecutor v1"
up $EX $EIMPL $(cast calldata 'initializeRange(address,address)' $RTP $AD) "timelock (range): executor custodian + orderExecutor v2"
up $REG $(create contracts/margin/orders/MarginOrderRegistryV2.sol:MarginOrderRegistryV2) $(cast calldata 'initializeV2(address,address)' $AD $RTP) "timelock (range): registry V2 + adapter v2"
up $RISK $(create contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol:IsolatedMarginRiskEngineUpgradeable) $(cast calldata 'initializeRangeCustodian(address)' $RTP) "timelock (range): risk engine + custodian"
up $LIQ $(create contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol:IsolatedMarginLiquidatorUpgradeable) $(cast calldata 'initializeRangeCustodian(address)' $RTP) "timelock (range): liquidator + custodian"
for args in "1 true 100 200" "2 true 300 200" "3 true 490 200"; do cast send $RTP 'setPreset(uint8,bool,int24,int24)' $args --from $D --unlocked --rpc-url $F --json | st "preset $args"; done
cast send $RTP 'setFeeSplit(uint16,uint16,uint16,address,address)' 7000 2000 1000 0x0000000000000000000000000000000000BeEF01 0x0000000000000000000000000000000000BeEF02 --from $D --unlocked --rpc-url $F --json | st "fee split 70/20/10"
cast send $RTP 'setUnwinders(address,address)' $LIQ $AD --from $D --unlocked --rpc-url $F --json | st "unwinders"
cast send $USDG 'transfer(address,uint256)' $TR 20000000000 --from $POOL --unlocked --rpc-url $F >/dev/null
cast send $NVDA 'transfer(address,uint256)' $TR 50000000000000000000 --from $POOL --unlocked --rpc-url $F >/dev/null

J=$TMP/range-keeper-journal.json; S=$TMP/range-keeper-state.json
printf '{"registry":"%s","rangeCustodian":"%s","executor":"%s"}\n' $REG $RTP $EX > $J
keeper(){ rm -f $S; MAX_GAS_PRICE_WEI=1000000000000 RH_RPC=$F python3 tools/orders/orders_keeper.py --journal $J --sender $K --unlocked --state $S --execute --once | sed -E 's/"tx": "0x[0-9a-f]+", //;s/, "time": [0-9]+//;s/^/  keeper: /'; }
keeper_keep(){ MAX_GAS_PRICE_WEI=1000000000000 RH_RPC=$F python3 tools/orders/orders_keeper.py --journal $J --sender $K --unlocked --state $S --execute --once | sed -E 's/"tx": "0x[0-9a-f]+", //;s/, "time": [0-9]+//;s/^/  keeper: /'; }
status(){ echo "  order status $(cast call $RTP 'getOrder(uint256)((address,address,uint8,uint8,int24,int24,uint128,uint256,uint256,uint256,uint16,uint16,uint16,uint64))' $ID --rpc-url $F | python3 -c 'import sys;print({0:"none",1:"ACTIVE",2:"SETTLED",3:"UNWOUND"}[int(sys.stdin.read().strip("()\n").split(",")[2])])'), position status $(cast call $EX 'positions(uint256)((uint256,address,address,address,address,address,uint256,uint256,uint256,uint16,uint8,uint8))' $ID --rpc-url $F | python3 -c 'import sys;print({2:"ACTIVE",5:"CLOSED",6:"LIQUIDATED"}.get(int(sys.stdin.read().strip("()\n").split(",")[11].split()[0]),"?"))'), debt $(cast call $PU 'borrowBalanceStored(address)(uint256)' $(cast call $EX 'positions(uint256)((uint256,address,address,address,address,address,uint256,uint256,uint256,uint16,uint8,uint8))' $ID --rpc-url $F | python3 -c 'import sys;print(sys.stdin.read().strip("()\n").split(",")[2].strip())') --rpc-url $F | cut -d' ' -f1)"; }
# Move the pool to a tick and set the feed to the matching NVDA price (NVDA = token1: USD = 1e12 / 1.0001^tick).
market(){ cast send $TR 'moveTo(uint160)' $(python3 -c "print(int(1.0001**($1/2)*2**96))") --from $D --unlocked --gas-limit 30000000 --rpc-url $F >/dev/null; setfeed $(python3 -c "print(int(1e12/1.0001**$1*1e8))"); }

echo "== create the range order on live position $ID (owner $OWNER), preset 1"
cast send $RTP 'createRangeOrder(uint256,uint8,uint256)' $ID 1 0 --from $OWNER --unlocked --gas-limit 3000000 --rpc-url $F --json | st "owner: createRangeOrder"
read LO HI < <(cast call $RTP 'getOrder(uint256)((address,address,uint8,uint8,int24,int24,uint128,uint256,uint256,uint256,uint16,uint16,uint16,uint64))' $ID --rpc-url $F | python3 -c 'import re,sys;f=re.sub(r"\s*\[[^]]*\]","",sys.stdin.read()).strip("()\n").split(",");print(f[4].strip(),f[5].strip())')
TICK=$(cast call $POOL 'slot0()(uint160,int24,uint16,uint16,uint16,uint24,bool)' --rpc-url $F | sed -n 2p | cut -d' ' -f1)
echo "  tick $TICK band [$LO, $HI]"; status
SNAP=$(cast rpc evm_snapshot --rpc-url $F | tr -d '"')

echo "== not reached"; keeper
hold(){ echo "  band holdings at the oracle (NVDA raw, USDG raw): $(cast call $RTP 'holdings(address)(uint256,uint256)' $(cast call $EX 'positions(uint256)((uint256,address,address,address,address,address,uint256,uint256,uint256,uint16,uint8,uint8))' $ID --rpc-url $F | python3 -c 'import sys;print(sys.stdin.read().strip("()\n").split(",")[2].strip())') --rpc-url $F | cut -d' ' -f1 | tr '\n' ' ')"; }
alarm(){ ALARM_STALL_WINDOW=3 RH_RPC=$F python3 tools/orders/orders_alarm.py --journal $J --keeper $K | tail -1 | sed 's/^/  alarm: /'; }
hold
echo "== partial fill (middle of the band)"; market $(( (LO + HI) / 2 )); hold; keeper; status
echo "== reversal (back below the band)"; market $TICK; keeper; status
echo "== full fill (through the band)"; market $(( LO - 20 )); hold; alarm; keeper; status; alarm

cast rpc evm_revert $SNAP --rpc-url $F >/dev/null; SNAP=$(cast rpc evm_snapshot --rpc-url $F | tr -d '"')
echo "== liquidation while the band is active"
rm -f $S; keeper_keep >/dev/null  # the keeper has seen the band active
RISKT=$(cast call $CONFIG 'getPairRisk(address,address,address)((bool,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint128,uint128))' $PU $PN $PU --rpc-url $F | python3 -c 'import sys;f=[x.split()[0] for x in sys.stdin.read().strip("()\n").split(",")];f[2]="9000";f[3]="8900";print("("+",".join(f)+")")')
SIG='(address,address,address,(bool,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint16,uint128,uint128))'
cast send $CONFIG "queuePairRisk$SIG" $PU $PN $PU "$RISKT" --from $L --unlocked --rpc-url $F --json | st "Ledger: queue stricter margin (fixture)"
cast rpc evm_increaseTime 3601 --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null
cast send $CONFIG "setPairRisk$SIG" $PU $PN $PU "$RISKT" --from $L --unlocked --rpc-url $F --json | st "Ledger: apply (position now liquidatable)"
cast send $LIQ 'liquidate((uint256,address,uint256,uint256,bytes,bytes))' "($ID,$D,0,0,0x,0x)" --from $D --unlocked --gas-limit 8000000 --rpc-url $F --json | st "liquidator: liquidate"
keeper_keep; status

cast rpc evm_revert $SNAP --rpc-url $F >/dev/null
echo "== stop-loss while the band is active"
rm -f $S; keeper_keep >/dev/null
PRICE=$(cast call $ORACLE 'getPrice(address)(uint256)' $NVDA --rpc-url $F | cut -d' ' -f1)
NOW=$(cast block latest --field timestamp --rpc-url $F)
cast send $REG 'createOrder(uint256,uint8,bool,uint256,uint16,uint16,uint64)' $ID 1 false $PRICE 10000 100 $((NOW + 86400)) --from $OWNER --unlocked --rpc-url $F --json | st "owner: stop-loss at the oracle price"
keeper_keep; status
kill $AP
