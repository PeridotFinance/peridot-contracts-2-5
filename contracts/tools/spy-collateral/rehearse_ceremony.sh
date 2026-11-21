#!/usr/bin/env bash
# Anvil rehearsal: SPY margin ceremony (tools/spy/ceremony.sh, the DEPLOYED SPY margin contracts from
# deployments/spy-margin/spy-margin-mainnet.json), then the pSPY-collateral rollout with the SAME scripts the operator
# runs: throwaway deploy (DeploySpyCollateral --broadcast) -> ceremony.sh preflight / t0 / demo-open (5 USDG against
# 0.045 SPY) / demo-close -> lending keeper (lending.py, loopback signer) on a pUSDG-debt and a pNVDA-debt SPY-collateral
# borrower before and after a -20 % SPY print -> weekend: indebted account frozen (closed-check), debt-free account
# withdraws, repay works, keeper reports spy_closed -> verify -> rollback. Only the signer differs (SIGN=--unlocked).
# Logs: ../.scratch/rehearsal/.
#
# Rehearsal-only adjustments (as in tools/spy/rehearse_ceremony.sh): (1) pUSDG / pNVDA accrual aligned to anvil's block
# number; (2) the RHSPY and NVDA (24/7) feeds are etched with fixed-answer, always-fresh mocks (so warps keep them fresh
# and the -20 % print can be set); (3) a fork started inside the SPY closed window (weekend) is first warped to the next
# Monday 02:00 UTC; (4) the Ledger is given 0.045 SPY from the v4 PoolManager, standing in for the operator's SPY purchase
# before the demo. The weekend check warps into Saturday; the session window then withholds the price whatever the feed.
set -euo pipefail
cd "$(dirname "$0")/../.."; exec 2> >(grep -v "Found unknown" >&2)
KEEPER_REPO=${KEEPER_REPO:-/Users/joshua/Peridot/RobinhoodVaults/.wt-margin-keeper-collateral}
P=${ANVIL_PORT:-8681}; F=http://127.0.0.1:$P; LOG=../.scratch/rehearsal; mkdir -p $LOG
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; D=0x00000000000000000000000000000000DEC0DE5c; K=0x1976117e9EA3FEC9fb82aBef12fcB95fFc9A3cf7
B=0x000000000000000000000000000000000000B0B5; C=0x000000000000000000000000000000000000C0C5; E=0x000000000000000000000000000000000000E0E5
WHALE=0x8366a39CC670B4001A1121B8F6A443A643e40951; NFEED=0x321A36e441DfBadA01Aa6f9884F14a344E133D1F
PNVDA=0xa155ccCB986774AE818b3F10F07d01D1b7A47b26
FEED=0x319724394D3A0e3669269846abE664Cd621f9f6A; SPY=0x117cc2133c37B721F49dE2A7a74833232B3B4C0C
USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168; PUSDG=0x55aEd0569c8f0D166D71facE57B57C2f2624a563
CONTROLLER=0x6148183676E304dbe63a85C350c208DA3cEAc39C
MJ=deployments/spy-margin/spy-margin-mainnet.json; CJ=deployments/spy-collateral/spy-collateral-rehearsal.json
PSPY=$(jq -r .pSpy $MJ)
anvil --fork-url https://rpc.mainnet.chain.robinhood.com ${FORK_BLOCK:+--fork-block-number $FORK_BLOCK} --port $P --silent \
  --auto-impersonate --timeout 300000 --retries 20 --fork-retry-backoff 2000 --compute-units-per-second 40 >/dev/null 2>&1 &
AP=$!; trap 'kill $AP 2>/dev/null' EXIT
for i in $(seq 1 120); do cast block-number --rpc-url $F >/dev/null 2>&1 && break; sleep 0.5; done
FB=$(cast rpc anvil_nodeInfo --rpc-url $F | python3 -c 'import json,sys;print(json.load(sys.stdin)["forkConfig"]["forkBlockNumber"])')
echo "fork block $FB, time $(date -u -r $(cast block latest --field timestamp --rpc-url $F))"
for a in $D $L $K $B $C $E; do cast rpc anvil_setBalance $a 0x16345785D8A0000 --rpc-url $F >/dev/null; done

# (1) rehearsal-only: accrual alignment (slot 9 = accrualBlockNumber)
BN=$(cast block-number --rpc-url $F)
for m in $PUSDG 0xa155ccCB986774AE818b3F10F07d01D1b7A47b26; do
  cast rpc anvil_setStorageAt $m 0x0000000000000000000000000000000000000000000000000000000000000009 $(cast to-uint256 $BN) --rpc-url $F >/dev/null; done
# (2) rehearsal-only: RHSPY held at its real last answer, updatedAt = block time
ANS=$(cast call $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $F | sed -n 2p | cut -d' ' -f1)
FOUNDRY_PROFILE=robinhood_spy forge build >/dev/null 2>&1
cast rpc anvil_setCode $FEED $(python3 -c "import json;print(json.load(open('out-spy/SpyFreshFeedMock.sol/SpyFreshFeedMock.json'))['deployedBytecode']['object'])") --rpc-url $F >/dev/null
setspy(){ cast rpc anvil_setStorageAt $FEED 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast to-uint256 $1) --rpc-url $F >/dev/null; }
setspy $ANS; echo "   SPY feed held at $ANS"
NANS=$(cast call $NFEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $F | sed -n 2p | cut -d' ' -f1)
cast rpc anvil_setCode $NFEED $(python3 -c "import json;print(json.load(open('out-spy/SpyFreshFeedMock.sol/SpyFreshFeedMock.json'))['deployedBytecode']['object'])") --rpc-url $F >/dev/null
cast rpc anvil_setStorageAt $NFEED 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast to-uint256 $NANS) --rpc-url $F >/dev/null
echo "   NVDA (24/7) feed held at $NANS"
# (3) rehearsal-only: a weekend fork starts on the next Monday 02:00 UTC
NOW=$(cast block latest --field timestamp --rpc-url $F)
MON=$(python3 -c "n=$NOW;s=(n+3*86400)%(7*86400);print(n+(7*86400-s)%(7*86400)+7200 if (s>=5*86400 or s<3600) else 0)")
if [ "$MON" != 0 ]; then cast rpc evm_setNextBlockTimestamp $MON --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null
  echo "   fork was in the SPY closed window: warped to $(date -u -r $MON)"; fi

export RPC=$F SIGN=--unlocked
mrun(){ echo "== SPY margin ceremony $1"; tools/spy/ceremony.sh $MJ "$1" > $LOG/margin-$1.log 2>&1 || { cat $LOG/margin-$1.log; exit 1; }; grep -c "status 0x1" $LOG/margin-$1.log | sed 's/^/   Ledger txs: /' || true; }
mrun preflight; mrun t0
cast rpc evm_increaseTime 3601 --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null; echo "== (warp 1 h)"
mrun gate; mrun t1

echo "== deploy (throwaway sender)"
rm -f $CJ; B0=$(cast balance $D --rpc-url $F)
FOUNDRY_PROFILE=robinhood_spy SPY_COLLATERAL_JOURNAL=spy-collateral-rehearsal forge script script/spy/DeploySpyCollateral.s.sol:DeploySpyCollateral \
  --rpc-url $F --sender $D --unlocked --broadcast --slow > $LOG/deploy.log 2>&1 || { tail -30 $LOG/deploy.log; exit 1; }
echo "   txs $(python3 -c "import json;print(len(json.load(open('broadcast/DeploySpyCollateral.s.sol/4663/run-latest.json'))['receipts']))"), deployer gas $(cast from-wei $((B0 - $(cast balance $D --rpc-url $F)))) ETH"
jq -c '{delegate,liquidator}' $CJ

run(){ echo "== collateral ceremony $1"; tools/spy-collateral/ceremony.sh $MJ $CJ "$1" 2>&1 | tee $LOG/$1.log; }
run preflight
run t0
# (4) rehearsal-only: the operator buys ~0.045 SPY before the demo (see deployments/spy-collateral/README.md, demo sizing)
cast send $SPY 'transfer(address,uint256)' $L 45000000000000000 --from $WHALE --unlocked --rpc-url $F >/dev/null
DEMO_BORROW_RAW=5000000 run demo-open

echo "== lending keeper: SPY-collateral borrower $B"
cast send $SPY 'transfer(address,uint256)' $B 100000000000000000 --from $WHALE --unlocked --rpc-url $F >/dev/null
cast send $SPY 'approve(address,uint256)' $PSPY 100000000000000000 --from $B --unlocked --rpc-url $F >/dev/null
cast send $PSPY 'mint(uint256)' 100000000000000000 --from $B --unlocked --rpc-url $F >/dev/null
cast send $CONTROLLER 'enterMarkets(address[])' "[$PSPY]" --from $B --unlocked --rpc-url $F >/dev/null
LQ=$(cast call $CONTROLLER 'getAccountLiquidity(address)(uint256,uint256,uint256)' $B --rpc-url $F | sed -n 2p | cut -d' ' -f1)
BOR=$(python3 -c "print($LQ*99//100//10**12)")
cast send $PUSDG 'borrow(uint256)' $BOR --from $B --unlocked --rpc-url $F >/dev/null
echo "   0.1 SPY supplied, borrowing power $LQ, borrowed $BOR raw USDG"
echo "== lending keeper: SPY-collateral NVDA borrower $C"
cast send $SPY 'transfer(address,uint256)' $C 50000000000000000 --from $WHALE --unlocked --rpc-url $F >/dev/null
cast send $SPY 'approve(address,uint256)' $PSPY 50000000000000000 --from $C --unlocked --rpc-url $F >/dev/null
cast send $PSPY 'mint(uint256)' 50000000000000000 --from $C --unlocked --rpc-url $F >/dev/null
cast send $CONTROLLER 'enterMarkets(address[])' "[$PSPY]" --from $C --unlocked --rpc-url $F >/dev/null
LQC=$(cast call $CONTROLLER 'getAccountLiquidity(address)(uint256,uint256,uint256)' $C --rpc-url $F | sed -n 2p | cut -d' ' -f1)
PN=$(cast call $(cast call $CONTROLLER 'oracle()(address)' --rpc-url $F) 'getUnderlyingPrice(address)(uint256)' $PNVDA --rpc-url $F | cut -d' ' -f1)
NB=$(python3 -c "print($LQC*95//100*10**18//$PN)")
cast send $PNVDA 'borrow(uint256)' $NB --from $C --unlocked --rpc-url $F >/dev/null
echo "   0.05 SPY supplied, borrowed $NB NVDA wei"
LIQ=$(jq -r .liquidator $CJ); DEL=$(jq -r .delegate $CJ)
KC=$LOG/keeper.json; KS=$LOG/keeper-state; rm -rf $KS
python3 - <<EOF > $KC
import json
print(json.dumps({"chainId": 4663, "controller": "$CONTROLLER", "pUSDG": "$PUSDG", "pSPY": "$PSPY", "liquidator": "$LIQ",
  "liquidatorRuntimeHash": "$(cast keccak $(cast code $LIQ --rpc-url $F))", "delegate": "$DEL",
  "delegateRuntimeHash": "$(cast keccak $(cast code $DEL --rpc-url $F))", "fromBlock": $FB, "maxRepayUsdg": 100000000,
  "pNVDA": "$PNVDA", "maxRepayNvda": 1000000000000000000}, indent=1))
EOF
kr(){ python3 $KEEPER_REPO/margin-mainnet/keeper-service/rehearse_lending.py --rpc-url $F --config $KC --state $KS --sender $K "$@"; }
kr > $LOG/keeper-1.log; echo "   keeper (healthy): $(jq -c '[.status, .accounts]' $LOG/keeper-1.log)"
setspy $(python3 -c "print($ANS*80//100)"); echo "   SPY print -20 %"
kr > $LOG/keeper-2.log; echo "   keeper (plan): $(jq -c '[.status, .accounts]' $LOG/keeper-2.log)"
LB=$(cast call $USDG 'balanceOf(address)(uint256)' $L --rpc-url $F | cut -d' ' -f1)
kr --execute > $LOG/keeper-3.log; echo "   keeper (execute): $(jq -c '[.status, .journals]' $LOG/keeper-3.log)"
echo "   Ledger USDG profit $(( $(cast call $USDG 'balanceOf(address)(uint256)' $L --rpc-url $F | cut -d' ' -f1) - LB )) raw; USDG borrower debt now $(cast call $PUSDG 'borrowBalanceStored(address)(uint256)' $B --rpc-url $F | cut -d' ' -f1), NVDA borrower debt $NB -> $(cast call $PNVDA 'borrowBalanceStored(address)(uint256)' $C --rpc-url $F | cut -d' ' -f1)"
setspy $ANS

echo "== debt-free SPY supplier $E (enters pSPY, borrows nothing)"
cast send $SPY 'transfer(address,uint256)' $E 10000000000000000 --from $WHALE --unlocked --rpc-url $F >/dev/null
cast send $SPY 'approve(address,uint256)' $PSPY 10000000000000000 --from $E --unlocked --rpc-url $F >/dev/null
cast send $PSPY 'mint(uint256)' 10000000000000000 --from $E --unlocked --rpc-url $F >/dev/null
cast send $CONTROLLER 'enterMarkets(address[])' "[$PSPY]" --from $E --unlocked --rpc-url $F >/dev/null
run demo-close
run verify

echo "== weekend: warp into Saturday 12:00 UTC"
NOW=$(cast block latest --field timestamp --rpc-url $F)
SAT=$(python3 -c "n=$NOW;s=(n+3*86400)%(7*86400);t=5*86400+12*3600;print(n+(t-s if s<t else 7*86400-s+t))")
cast rpc evm_setNextBlockTimestamp $SAT --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null
echo "   time $(date -u -r $(cast block latest --field timestamp --rpc-url $F))"
ACCOUNT=$B DEBTFREE_ACCOUNT=$E run closed-check
EB=$(cast call $PSPY 'balanceOf(address)(uint256)' $E --rpc-url $F | cut -d' ' -f1)
cast send $PSPY 'redeem(uint256)' $EB --from $E --unlocked --rpc-url $F --json | jq -r '"   debt-free supplier redeems all pSPY while closed: status \(.status)"'
cast send $CONTROLLER 'exitMarket(address)' $PSPY --from $E --unlocked --rpc-url $F --json | jq -r '"   debt-free supplier exitMarket while closed: status \(.status)"'
DEBT=$(cast call $PUSDG 'borrowBalanceStored(address)(uint256)' $B --rpc-url $F | cut -d' ' -f1)
cast send $USDG 'transfer(address,uint256)' $B 1000000 --from $WHALE --unlocked --rpc-url $F >/dev/null
cast send $USDG 'approve(address,uint256)' $PUSDG 1000000 --from $B --unlocked --rpc-url $F >/dev/null
cast send $PUSDG 'repayBorrow(uint256)' 1000000 --from $B --unlocked --rpc-url $F --json | jq -r '"   repay while closed: status \(.status)"'
echo "   borrower debt $DEBT -> $(cast call $PUSDG 'borrowBalanceStored(address)(uint256)' $B --rpc-url $F | cut -d' ' -f1)"
kr > $LOG/keeper-4.log; echo "   keeper (weekend): $(jq -c '[.status, .accounts]' $LOG/keeper-4.log)"
ROLLBACK_CF=yes run rollback
echo "== Ledger transactions sent (collateral ceremony incl. demo + rollback): $(cat $LOG/t0.log $LOG/demo-open.log $LOG/demo-close.log $LOG/rollback.log | grep -c '^   status 0x1')"
echo "REHEARSAL COMPLETE"
