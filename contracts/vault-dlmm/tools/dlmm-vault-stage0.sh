#!/usr/bin/env bash
# STAGE 0 of the DLMM vault ceremony: the READ-ONLY pre-flight with `cast`, check by check, with the expected value and PASS/FAIL. Sends nothing, signs nothing.
# It computes the REWARDER_IMPL_CODEHASH the operator then records and passes to the deploy as EXPECTED_REWARDER_IMPL_CODEHASH.
#   usage:  ETH_RPC_URL=<environment only, never an argument>  DEPLOYER=0x..  [KEEPER=0x..]  tools/dlmm-vault-stage0.sh
# Exit code 0 only if every check passes. Output never contains the endpoint.
set -uo pipefail
: "${ETH_RPC_URL:?set ETH_RPC_URL in the environment}"
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12
USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E; USDT=0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7
PAIR=0x16888EE58E706C253b821EAA637ae9b2cFeA255C; ROUTER=0xff2BEFC4ff86CB0f3e8D3d9D6200B7A05BF5D93d; FACTORY=0xEb480050b016f6c6d45203D2346B68bDDDa23D4D
REWARDER=0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC; FEED_A=0xF096872672F44d6EBA71458D74fe67F9a77a23B9; FEED_P=0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a
MULTISEND=0x9641d764fc13c8B624c04430C7356C1C7C8102e2
FAIL=0
lc() { echo "$1" | tr 'A-Z' 'a-z'; }
chk() { # label got expected
  if [ "$(lc "$2")" = "$(lc "$3")" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: got '$2' expected '$3'"; FAIL=1; fi
}
chk "1  chain id" "$(cast chain-id)" 43114
OW="$(cast call $SAFE 'getOwners()(address[])')"
chk "2  Safe owners" "$OW" "[$LEDGER]"
chk "2  Safe threshold" "$(cast call $SAFE 'getThreshold()(uint256)')" 1
chk "2  Safe version" "$(cast call $SAFE 'VERSION()(string)')" '"1.4.1"'
echo "INFO  2  Safe nonce (record it): $(cast call $SAFE 'nonce()(uint256)')"
echo "INFO  3  Ledger AVAX $(cast balance $LEDGER --ether)   Ledger USDC $(cast call $USDC 'balanceOf(address)(uint256)' $LEDGER | awk '{print $1}') raw   Safe USDC $(cast call $USDC 'balanceOf(address)(uint256)' $SAFE | awk '{print $1}') raw"
# MultiSendCallOnly v1.4.1 is a DELEGATECALL target of the Safe: presence of code is not identity, so its runtime-code hash is pinned to the value in safe-global/safe-deployments
# (src/assets/v1.4.1/multi_send_call_only.json, codeHash; chain 43114 listed as "canonical" at 0x9641d764...02e2)
chk "MultiSendCallOnly v1.4.1 codehash at $MULTISEND" "$(cast keccak "$(cast code $MULTISEND)")" 0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939
chk "4  pair tokenX (USDt)" "$(cast call $PAIR 'getTokenX()(address)')" $USDT
chk "4  pair tokenY (USDC)" "$(cast call $PAIR 'getTokenY()(address)')" $USDC
chk "5  bin step" "$(cast call $PAIR 'getBinStep()(uint16)')" 1
chk "5  pair factory" "$(cast call $PAIR 'getFactory()(address)')" $FACTORY
INFO="$(cast call $FACTORY 'getLBPairInformation(address,address,uint256)((uint16,address,bool,bool))' $USDT $USDC 1)"
echo "INFO  5  factory.getLBPairInformation(USDt, USDC, 1) = $INFO"
case "$(lc "$INFO")" in *"$(lc $PAIR)"*) echo "PASS  5  factory registers the pair";; *) echo "FAIL  5  factory does not list the pair"; FAIL=1;; esac
H="$(cast call $PAIR 'getLBHooksParameters()(bytes32)')"; HOOK="0x${H: -40}"
chk "6  pair hook (low 160 bits of getLBHooksParameters)" "$HOOK" $REWARDER
chk "6  rewarder.isLinked()" "$(cast call $REWARDER 'isLinked()(bool)')" true
VOTER="$(cast call $REWARDER 'owner()(address)')"; echo "INFO  7  voter = rewarder.owner() = $VOTER"
BEACON="$(cast call "$VOTER" 'dlmmRewarderFactory()(address)')"; echo "INFO  7  beacon = voter.dlmmRewarderFactory() = $BEACON"
chk "7  beacon lists the rewarder for the pair" "$(cast call "$BEACON" 'getRewarder(address)(address)' $PAIR)" $REWARDER
IMPL="$(cast call "$BEACON" 'implementation()(address)')"; echo "INFO  7  beacon implementation = $IMPL"
CH="$(cast keccak "$(cast code "$IMPL")")"
echo "INFO  7  REWARDER_IMPL_CODEHASH = $CH   <- record this value; it is the EXPECTED_REWARDER_IMPL_CODEHASH of the deploy (keccak256 of the implementation's runtime code = EXTCODEHASH)"
chk "8  router is an authorised DLMM manager" "$(cast call "$VOTER" 'isAuthorizedDLMMManager(address)(bool)' $ROUTER)" true
chk "8  router factory" "$(cast call $ROUTER 'getFactory()(address)')" $FACTORY
NOW="$(cast block latest --field timestamp)"
for F in "$FEED_A" "$FEED_P"; do
  chk "9  feed $F decimals" "$(cast call $F 'decimals()(uint8)')" 8
  R="$(cast call $F 'latestRoundData()(uint80,int256,uint256,uint256,uint80)')"; ANS="$(echo "$R" | sed -n 2p | awk '{print $1}')"; UPD="$(echo "$R" | sed -n 4p | awk '{print $1}')"
  AGE=$(( NOW - UPD ))
  if [ "$ANS" -ge 99500000 ] && [ "$ANS" -le 100500000 ] && [ "$AGE" -ge 0 ] && [ "$AGE" -le 93600 ]; then echo "PASS  9  feed $F answer $ANS (inside 1.00 +- 0.50 %) age ${AGE} s (<= 93600)"; else echo "FAIL  9  feed $F answer $ANS age ${AGE} s"; FAIL=1; fi
done
echo "INFO  10 pool active id: $(cast call $PAIR 'getActiveId()(uint24)')   (about 8388598 to 8388608 is normal; the peg bin is 8388608)"
if [ -n "${DEPLOYER:-}" ]; then
  chk "11 deployer nonce (fresh key)" "$(cast nonce "$DEPLOYER")" 0
  chk "11 deployer has no code" "$(cast code "$DEPLOYER")" 0x
  echo "INFO  11 deployer AVAX: $(cast balance "$DEPLOYER" --ether)"
  chk "12 planned implementation has no code" "$(cast code "$(cast compute-address "$DEPLOYER" --nonce 0 | awk '{print $NF}')")" 0x
  chk "12 planned proxy has no code" "$(cast code "$(cast compute-address "$DEPLOYER" --nonce 1 | awk '{print $NF}')")" 0x
  echo "INFO  12 planned implementation $(cast compute-address "$DEPLOYER" --nonce 0 | awk '{print $NF}')  planned proxy (the vault) $(cast compute-address "$DEPLOYER" --nonce 1 | awk '{print $NF}')"
fi
if [ -n "${KEEPER:-}" ]; then chk "11 keeper has no code" "$(cast code "$KEEPER")" 0x; fi
[ "$FAIL" = 0 ] && echo "STAGE 0: ALL CHECKS PASSED" || echo "STAGE 0: FAILED"
exit $FAIL
