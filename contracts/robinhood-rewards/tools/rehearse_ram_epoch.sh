#!/usr/bin/env bash
# Anvil fork rehearsal of ONE full RAM epoch on Robinhood Chain mainnet state, in the order of COMMANDS.md:
#   a test user mints rpSPY + rpUSDGs (funded by the SPY/USDG Ramses pool, fork only) -> time passes -> the Ramses keeper
#   harvests -> throwaway deploy of the distributor -> root generation from the fork's events -> Ledger schedules
#   forwardExternalReward on the timelock -> early execute refused -> 3,601 s -> Ledger executes -> Ledger publishes ->
#   claim refused inside the 24 h window -> 86,401 s -> the user claims with the proof -> double / invalid claims refused ->
#   the protocol leaf is claimed for the Ledger by a third party -> the distributor is empty.
# The Ledger, the timelock, the keeper, the pool and the throwaway deployer are unlocked ON ANVIL ONLY. No key is read.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd); cd "$HERE"
P=${PORT:-8731}; F=http://127.0.0.1:$P
OUT=${OUT:-$HERE/deployments/rehearsal}; rm -rf "$OUT/cache"; mkdir -p "$OUT"   # a scan cache of an earlier fork must never be reused
INK=/Users/joshua/Peridot/RobinhoodVaults/.wt-inkind/ramses-vaults
export ETHERS_DIR=${ETHERS_DIR:-/Users/joshua/Peridot/peridot-contracts-2-5/contracts/node_modules/ethers}
L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; T=0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498
OLD=0x94696d767e65a75581145646960FA0eC886cE5d2
K=0x9eaF3552449c26b95a55CcDc363258345DEA031E; V=0x67e7742922f4CC88C545e5aB5Df402b22DB4830b
PAIR=0x8f81f5d84aa85b29b5114b8ca1a75266c4dc18785b703e8257ca66ecb4ba5435; RAM=0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802
RPSPY=0x14CC6fE0AE856B736fAb6678619cEd3d4738EA8B; RPUSD=0x2117c202F356399C9aE2D395D4e155785015ac6B
SPY=0x117cc2133c37B721F49dE2A7a74833232B3B4C0C; USDG=0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168
POOL=0x38453c115607463Ac284820Ce959831042f3Df4E; FEED=0x319724394D3A0e3669269846abE664Cd621f9f6A
USER=0x00000000000000000000000000000000FEED1111; RANDO=0x00000000000000000000000000000000FEED2222
DEPLOYER=0x00000000000000000000000000000000DEC0DE21
SPY_IN=${SPY_IN:-20000000000000000}; USDG_IN=${USDG_IN:-100000000}; ACCRUE=${ACCRUE:-21600}
SIGS=0
export ETH_RPC_TIMEOUT=900   # first touches of a forked contract fetch remote state slowly (cast default 45 s)
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port $P --silent --auto-impersonate --timeout 60000 --retries 8 >/dev/null 2>&1 &
AP=$!
trap '[ -n "${KEEP:-}" ] || kill $AP 2>/dev/null' EXIT
for i in $(seq 1 80); do cast block-number --rpc-url $F >/dev/null 2>&1 && break; sleep 0.5; done
grep -qi anvil <<< "$(cast client --rpc-url $F)" || { echo "STOPPED: not anvil"; exit 1; }
[ "$(cast chain-id --rpc-url $F)" = 4663 ] || { echo "STOPPED: not chain 4663"; exit 1; }
FORK=$(cast rpc anvil_nodeInfo --rpc-url $F | python3 -c 'import json,sys;print(json.load(sys.stdin)["forkConfig"]["forkBlockNumber"])')
echo "fork block $FORK"
stop(){ echo "STOPPED at $1"; exit 1; }
st(){ python3 -c "import json,sys;r=json.load(sys.stdin);print('  $1',r['status'],int(r['gasUsed'],16));sys.exit(0 if r['status']=='0x1' else 1)"; }
# the pipeline runs in a subshell: stop is called HERE, in the main shell, so a failed send ends the rehearsal
send(){ local who=$1 name=$2; shift 2; cast send "$@" --from $who --unlocked --rpc-url $F --timeout 900 --rpc-timeout 900 --json | st "$name" || stop "$name"; }
led(){ local name=$1; shift; SIGS=$((SIGS+1)); send $L "Ledger $SIGS: $name" "$@"; }
# reverts 'ErrorName(types)' <cast call args>: the call must revert with that error (matched by name or by selector)
reverts(){ local want=$1; shift; local o sel; sel=$(cast sig "$want"); o=$(cast call "$@" --rpc-url $F 2>&1) && stop "expected revert $want, the call succeeded"
  { grep -q "${want%%(*}" <<< "$o" || grep -qi "$sel" <<< "$o"; } && echo "  refused as expected: ${want%%(*} ($sel)" || stop "expected revert $want, got: $(tail -1 <<< "$o" | cut -c1-200)"; }
warp(){ cast rpc evm_increaseTime $1 --rpc-url $F >/dev/null; cast rpc evm_mine --rpc-url $F >/dev/null; }
num(){ cut -d' ' -f1; }
bal(){ cast call $1 'balanceOf(address)(uint256)' $2 --rpc-url $F | num; }
MOCK=$(find $INK/out-v3 -path '*FreshFeedMock.sol/FreshFeedMock.json' | head -1)
hold(){ local a; a=$(cast call $FEED 'latestRoundData()(uint80,int256,uint256,uint256,uint80)' --rpc-url $F | sed -n 2p | num)
  cast rpc anvil_setCode $FEED $(python3 -c "import json;print(json.load(open('$MOCK'))['deployedBytecode']['object'])") --rpc-url $F >/dev/null
  cast rpc anvil_setStorageAt $FEED 0x0000000000000000000000000000000000000000000000000000000000000000 $(cast to-uint256 $a) --rpc-url $F >/dev/null
  echo "  (fork only) SPY feed held at its real last answer $a across the warps"; }
align(){ local bn; bn=$(cast block-number --rpc-url $F)
  for m in $RPSPY $RPUSD; do cast rpc anvil_setStorageAt $m 0x0000000000000000000000000000000000000000000000000000000000000009 $(cast to-uint256 $bn) --rpc-url $F >/dev/null; done
  echo "  (fork only) accrualBlockNumber (slot 9) of both markets set to the anvil block $bn"; }

echo "== pre-flight reads"
ER0=$(cast call $V 'externalRewards(bytes32,address)(uint256)' $PAIR $RAM --rpc-url $F | num)
echo "  externalRewards[pair][RAM] $ER0; vault RAM balance $(bal $RAM $V)"
echo "  rpSPY supply $(cast call $RPSPY 'totalSupply()(uint256)' --rpc-url $F | num) (dead $(bal $RPSPY 0x000000000000000000000000000000000000dEaD), timelock $(bal $RPSPY $T))"
echo "  rpUSDGs supply $(cast call $RPUSD 'totalSupply()(uint256)' --rpc-url $F | num) (dead $(bal $RPUSD 0x000000000000000000000000000000000000dEaD), timelock $(bal $RPUSD $T))"
echo "  timelock CONFIG_ROLE $(cast call $V 'hasRole(bytes32,address)(bool)' $(cast keccak CONFIG_ROLE) $T --rpc-url $F), min delay $(cast call $T 'getMinDelay()(uint256)' --rpc-url $F | num), Ledger proposer $(cast call $T 'hasRole(bytes32,address)(bool)' $(cast keccak PROPOSER_ROLE) $L --rpc-url $F)"

echo "== test user deposits (fork only: funded by the Ramses SPY/USDG pool)"
cast rpc anvil_setBalance $USER 0x16345785D8A0000 --rpc-url $F >/dev/null; cast rpc anvil_setBalance $POOL 0x16345785D8A0000 --rpc-url $F >/dev/null
send $POOL "donor SPY -> user" $SPY 'transfer(address,uint256)' $USER $SPY_IN
send $POOL "donor USDG -> user" $USDG 'transfer(address,uint256)' $USER $USDG_IN
hold; align
send $USER "user approve SPY" $SPY 'approve(address,uint256)' $RPSPY $SPY_IN
send $USER "user mint rpSPY" $RPSPY 'mint(uint256)' $SPY_IN --gas-limit 3000000
send $USER "user approve USDG" $USDG 'approve(address,uint256)' $RPUSD $USDG_IN
send $USER "user mint rpUSDGs" $RPUSD 'mint(uint256)' $USDG_IN --gas-limit 3000000
echo "  user rpSPY $(bal $RPSPY $USER), rpUSDGs $(bal $RPUSD $USER)"
[ "$(bal $RPSPY $USER)" != 0 ] && [ "$(bal $RPUSD $USER)" != 0 ] || stop "user mint"

echo "== $ACCRUE s pass, then the Ramses keeper harvests"
warp $ACCRUE
cast rpc anvil_setBalance $K 0x16345785D8A0000 --rpc-url $F >/dev/null
DL=$(( $(cast block --rpc-url $F -f timestamp) + 120 ))   # maxDeadlineDelay of the pair is below 600 s
send $K "keeper harvest" $V 'harvest(bytes32,uint256)' $PAIR $DL --gas-limit 8000000
ER1=$(cast call $V 'externalRewards(bytes32,address)(uint256)' $PAIR $RAM --rpc-url $F | num)
HARVESTED=$((ER1 - ER0)); echo "  externalRewards $ER0 -> $ER1 (+$HARVESTED wei RAM)"
[ "$HARVESTED" -gt 0 ] || stop "harvest produced no RAM"
END=$(cast block-number --rpc-url $F)

echo "== throwaway deploy (forge script, one creation)"
cast rpc anvil_setBalance $DEPLOYER 0x38D7EA4C68000 --rpc-url $F >/dev/null
JOURNAL=$OUT/ram-distributor-rehearsal.json; rm -f $JOURNAL
RAM_DEPLOYER=$DEPLOYER RAM_DISTRIBUTOR_JOURNAL=$JOURNAL forge script script/DeployRamRewardsDistributor.s.sol:DeployRamRewardsDistributor \
  --rpc-url $F --sender $DEPLOYER --unlocked --broadcast --slow > $OUT/deploy.log 2>&1 || { tail -20 $OUT/deploy.log; stop "deploy"; }
DIST=$(python3 -c "import json;print(json.load(open('$JOURNAL'))['distributor'])"); echo "  distributor $DIST (owner $(cast call $DIST 'owner()(address)' --rpc-url $F))"
echo "  deployer spent $(cast from-wei $((0x38D7EA4C68000 - $(cast balance $DEPLOYER --rpc-url $F)))) ETH"
forge script script/DeployRamRewardsDistributor.s.sol:DeployRamRewardsDistributor --sig 'verify(string)' $JOURNAL --rpc-url $F 2>&1 | grep -E "verified|Error|revert" | head -2
OLDOUT=$(RAM_DEPLOYER=$OLD forge script script/DeployRamRewardsDistributor.s.sol:DeployRamRewardsDistributor --rpc-url $F --sender $OLD 2>&1)
grep -q OLD_SIGNER_REFUSED <<< "$OLDOUT" && echo "  old signer as deployer: refused (OLD_SIGNER_REFUSED)" || stop "old signer not refused"

echo "== root generation from the fork's events (epoch 0: vault creation .. this harvest)"
ID=$(cast call $DIST 'epochCount()(uint256)' --rpc-url $F | num)
node tools/robinhood-ram-root.mjs --rpc-url $F --epoch-id $ID --first-epoch --to-harvest last --scan-to $END \
  --cache-dir $OUT/cache --out-dir $OUT/epoch-$ID --force > $OUT/generate.log 2> $OUT/generate.err || { cat $OUT/generate.err | tail; stop "generate"; }
sed 's/^/  /' $OUT/generate.log | grep -v "^  wrote"
M=$OUT/epoch-$ID/manifest.json; E=$OUT/epoch-$ID/epoch.json
j(){ jq -r "$2" "$1"; }
AMOUNT=$(j $M .forwardExternalRewardArguments.amount); TOTAL=$(j $M .publishTotal)
[ "$AMOUNT" = "$ER1" ] || stop "forward amount $AMOUNT != externalRewards $ER1"
python3 -c "import json;e=json.load(open('$E'));assert not any(l['account'].lower()=='$OLD'.lower() for l in e['leaves']),'old signer has a leaf'" || stop "old signer leaf"
[ "$(cast keccak "0x$(xxd -p $E | tr -d '\n')")" = "$(j $M .dataHash)" ] && echo "  dataHash == keccak256(epoch.json)" || stop "dataHash"

echo "== timelock: Ledger schedules forwardExternalReward, early execute refused, 3,601 s, Ledger executes"
DATA=$(cast calldata 'forwardExternalReward(bytes32,address,address,uint256)' $PAIR $RAM $DIST $AMOUNT)
SALT=$(cast keccak "peridot-ram-forward-epoch-$ID")
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
led "timelock schedule forwardExternalReward($AMOUNT)" $T 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $V 0 $DATA $ZERO32 $SALT 3600
reverts "TimelockUnexpectedOperationState(bytes32,bytes32)" $T 'execute(address,uint256,bytes,bytes32,bytes32)' $V 0 $DATA $ZERO32 $SALT --from $L
reverts "AccessControlUnauthorizedAccount(address,bytes32)" $V 'forwardExternalReward(bytes32,address,address,uint256)' $PAIR $RAM $DIST $AMOUNT --from $L
warp 3601
led "timelock execute" $T 'execute(address,uint256,bytes,bytes32,bytes32)' $V 0 $DATA $ZERO32 $SALT --gas-limit 1000000
echo "  distributor RAM $(bal $RAM $DIST), unallocated $(cast call $DIST 'unallocated()(uint256)' --rpc-url $F | num), externalRewards $(cast call $V 'externalRewards(bytes32,address)(uint256)' $PAIR $RAM --rpc-url $F | num)"

echo "== Ledger publishes"
ROOT=$(j $M .publishEpochArguments.root); FB=$(j $M .publishEpochArguments.fromBlock); TB=$(j $M .publishEpochArguments.toBlock); DH=$(j $M .dataHash)
reverts "OwnableUnauthorizedAccount(address)" $DIST 'publishEpoch(bytes32,uint256,uint64,uint64,bytes32)' $ROOT $TOTAL $FB $TB $DH --from $RANDO
led "publishEpoch" $DIST 'publishEpoch(bytes32,uint256,uint64,uint64,bytes32)' $ROOT $TOTAL $FB $TB $DH
echo "  reserved $(cast call $DIST 'reserved()(uint256)' --rpc-url $F | num), unallocated $(cast call $DIST 'unallocated()(uint256)' --rpc-url $F | num)"

leaf(){ python3 -c "
import json;e=json.load(open('$E'))
l=[x for x in e['leaves'] if x['account'].lower()=='$1'.lower()]
print((l[0]['amount']+' ['+','.join(l[0]['proof'])+']') if l else 'none')"; }
read UAMT UPROOF <<< "$(leaf $USER)"; read PAMT PPROOF <<< "$(leaf $L)"
echo "  user leaf $UAMT, protocol (Ledger) leaf $PAMT"
[ "$UAMT" != none ] || stop "the user has no leaf"
reverts "ClaimsNotOpen(uint256)" $DIST 'claim(uint256,address,uint256,bytes32[])' $ID $USER $UAMT "$UPROOF"
echo "== 86,401 s (challenge window), claims"
warp 86401
EXPECTED=$(python3 tools/rehearsal_expected.py $F $FB $TB $USER 9000) || stop "independent recomputation"
echo "  independent recomputation (Python, raw logs): user should get $EXPECTED"
[ "$EXPECTED" = "$UAMT" ] || stop "user leaf $UAMT != independent $EXPECTED"
U0=$(bal $RAM $USER)
send $USER "user claim" $DIST 'claim(uint256,address,uint256,bytes32[])' $ID $USER $UAMT "$UPROOF"
U1=$(bal $RAM $USER); echo "  user RAM $U0 -> $U1"; [ $((U1 - U0)) = "$UAMT" ] || stop "user paid amount"
reverts "AlreadyClaimed()" $DIST 'claim(uint256,address,uint256,bytes32[])' $ID $USER $UAMT "$UPROOF" --from $USER
reverts "InvalidProof()" $DIST 'claim(uint256,address,uint256,bytes32[])' $ID $RANDO $UAMT "$UPROOF" --from $RANDO
reverts "EpochNotOpen(uint8)" $DIST 'claim(uint256,address,uint256,bytes32[])' $((ID+1)) $USER $UAMT "$UPROOF"
L0=$(bal $RAM $L)
cast rpc anvil_setBalance $RANDO 0x16345785D8A0000 --rpc-url $F >/dev/null
send $RANDO "third party claims the protocol leaf for the Ledger" $DIST 'claim(uint256,address,uint256,bytes32[])' $ID $L $PAMT "$PPROOF"
L1=$(bal $RAM $L); echo "  Ledger RAM $L0 -> $L1"; [ $((L1 - L0)) = "$PAMT" ] || stop "protocol paid amount"
python3 - "$E" "$TOTAL" "$UAMT" "$PAMT" <<'EOF' || stop "split arithmetic"
import json, sys
e = json.load(open(sys.argv[1])); total, u, p = map(int, sys.argv[2:5])
assert u + p == total, 'user + protocol != total (more leaves than expected?)'
pools = sum(int(m['pool']) for m in e['markets']); rewards = sum(int(m['reward']) for m in e['markets'])
assert pools * 10000 <= rewards * 9000 and pools * 10000 >= rewards * 9000 - 20000, '90% pools'
print(f"  user {u} = {u*1e4/total:.2f} bps of total; protocol {p} = 10% part {e['totals']['protocol']['bpsPart']} + excluded {e['totals']['protocol']['excludedHolders']} + rounding {e['totals']['protocol']['roundingAndDust']}")
print(f"  depositor pools (90% of each market's RAM): {pools} of {rewards}")
EOF
[ "$(bal $RAM $DIST)" = 0 ] && [ "$(cast call $DIST 'reserved()(uint256)' --rpc-url $F | num)" = 0 ] && echo "  distributor empty, reserved 0" || stop "distributor not empty"
echo "REHEARSAL PASSED: Ledger signatures $SIGS (schedule, execute, publish); claims by the user and a third party"
