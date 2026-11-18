#!/usr/bin/env bash
# THE COMMANDS of the bpPHAR-USDC listing (the share token of the Peridot Pharaoh DLMM USDC/USDt vault, listed on the LIVE Avalanche pilot controller),
# as ONE wrapper: the fork rehearsal and the live run differ only in the signers and the endpoint. NOTHING here is run by the assistant against
# mainnet: the operator runs it, and the Ledger signs. Design, ordering, windows and rollback analysis: contracts/avalanche_bp_dlmm_ceremony_calls.md.
#
#   usage: tools/bp-dlmm-ceremony.sh <pin|check|deploy|verify-deployed|verify-listing|print-ledger-calls|members> <rehearsal|live> [stage|from-block]
#   run it from anywhere inside contracts/ (the script finds its own directory). bash 3.2 compatible.
#
#   pin                NO network. Refuses a dirty source tree; builds the CEREMONY profile into its own out/cache (out_bpdlmm, cache_bpdlmm); prints
#                      the git commit, the SHA-256 of the sources, the runtime sizes (limit 24,576) and the code hashes of every deployable artifact;
#                      writes ceremony/bp-dlmm-pin.json. THE OPERATOR SIGNS NOTHING until these lines are the ones in the ceremony document.
#   check              read-only: the live facts (controller admin = Ledger, oracle = the guarded oracle, vault owner/ProxyAdmin = Safe, not paused,
#                      asset USDC, vault price available, Ledger holds the seed shares)
#   deploy             signer: the THROWAWAY DEPLOYER (live: Foundry keystore BP_DEPLOYER_ACCOUNT, password prompted by forge; rehearsal: --unlocked).
#                      Three contracts, no role kept (the market admin is the Ledger from the constructor). Writes ceremony/bp-dlmm-addresses.env
#                      (public values), then runs verify-deployed
#   verify-deployed    read-only, stage 0: code against the pinned build (immutables zeroed), every pin, wrapper == guarded oracle for every market
#   verify-listing N   read-only, N = 1..4: the cumulative controller state after each Ledger stage (see print-ledger-calls)
#   print-ledger-calls PRINTS (executes nothing) every Ledger transaction as a cast command, each preceded by the mandatory eth_call simulation FROM THE
#                      LEDGER, with the calldata (compare it with the device screen) and the expected read-back. Optional 3rd argument: a stage 1..4
#                      to print only that stage; no argument prints all, plus the rollback.
#   members            read-only, best effort: accounts that entered the new market (MarketEntered logs from <from-block>); needed before a rollback
#
#   ENDPOINT. ONLY through the ETH_RPC_URL environment variable (cast and forge read it natively). It is never an argument, is never printed, and
#   every line this wrapper prints from a network command passes through tools/avalanche-redact-rpc.py. rehearsal: point ETH_RPC_URL at the LOCAL
#   anvil fork; the accounts are impersonated (--unlocked). live: the real endpoint; the Ledger device signs (--ledger).
set -uo pipefail
cd "$(dirname "$0")/.."
STEP="${1:-}"; MODE="${2:-}"; ARG3="${3:-}"
usage() { echo "usage: $0 <pin|check|deploy|verify-deployed|verify-listing|print-ledger-calls|members> <rehearsal|live> [stage|from-block]" >&2; exit 2; }
[ -n "$STEP" ] && [ -n "$MODE" ] || usage
case "$MODE" in rehearsal|live) ;; *) usage ;; esac

# ------------------------------------------------------------------------------------------------------------------------ pinned LIVE facts
LEDGER="0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD"
SAFE="0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12"
CONTROLLER="0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A"
GUARDED_ORACLE="0x7BAB5406Cb4929f9b9492e1b2a43b65BF93AaFC0"
VAULT="0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D"
DEAD="0x000000000000000000000000000000000000dEaD"
SEED_SHARES=1000000          # 1,000,000 share-wei = 1 whole share (6 decimals)
SEED_PTOKENS=5000000000      # SEED_SHARES x 5000 (initial exchange rate 2e14)
CF_ACTIVE=500000000000000000 # 0.5e18
ADDR_FILE="${BP_ADDRESSES_FILE:-ceremony/bp-dlmm-addresses.env}"
PIN_FILE="${BP_PIN_FILE:-ceremony/bp-dlmm-pin.json}"
SCRIPT=script/DeployPharaohBoostedMarketsAvalanche.s.sol
CONTRACT=DeployPharaohBoostedMarketsAvalanche
SKIP=(--skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol)

# the ceremony build has its OWN profile, output and cache (so artifact names never collide with the test build) and skips the tests
export FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_bpdlmm FOUNDRY_CACHE_PATH=cache_bpdlmm

REDACT() { python3 -I tools/avalanche-redact-rpc.py ETH_RPC_URL; }
need_rpc() { [ -n "${ETH_RPC_URL:-}" ] || { echo "ETH_RPC_URL must be set in the ENVIRONMENT (never as an argument; rehearsal: the local anvil fork)" >&2; exit 1; }; }
FS() { forge script "$SCRIPT:$CONTRACT" --skip test "${SKIP[@]}" "$@" 2>&1 | REDACT; }

need_deployer() {
  [ -n "${BP_DEPLOYER:-}" ] || { echo "UNSET: BP_DEPLOYER (the public address of the throwaway deployer)" >&2; exit 1; }
  [ "$(echo "$BP_DEPLOYER" | tr 'A-Z' 'a-z')" != "$(echo "$LEDGER" | tr 'A-Z' 'a-z')" ] || { echo "BP_DEPLOYER must NOT be the Ledger" >&2; exit 1; }
  if [ "$MODE" = live ]; then [ -n "${BP_DEPLOYER_ACCOUNT:-}" ] || { echo "UNSET: BP_DEPLOYER_ACCOUNT (the Foundry keystore name)" >&2; exit 1; }; fi
}
load_new() {
  [ -f "$ADDR_FILE" ] && . "$ADDR_FILE"
  local v bad=0
  for v in BP_DELEGATE BP_MARKET BP_ORACLE; do eval "[ -n \"\${$v:-}\" ]" || { echo "UNSET: $v (written by deploy to $ADDR_FILE)" >&2; bad=1; }; done
  [ "$bad" = 0 ] || exit 1
  export BP_DELEGATE BP_MARKET BP_ORACLE
}

# the compiler's own output for the pinned artifacts, with every immutable zeroed (PToken creates a BorrowAccountingModule in its constructor and keeps
# its address as an immutable, so each delegate instance has its own runtime hash; the oracle has constructor immutables; the delegator has none)
PYLIB='
import json, subprocess
OUT = "out_bpdlmm"
def art(src, name):
    j = json.load(open("%s/%s/%s.json" % (OUT, src, name)))
    d = j["deployedBytecode"]
    return bytes.fromhex(d["object"][2:]), d.get("immutableReferences", {}), bytes.fromhex(j["bytecode"]["object"][2:])
def zero(code, refs):
    b = bytearray(code)
    for lst in refs.values():
        for r in lst:
            b[r["start"]:r["start"] + r["length"]] = b"\0" * r["length"]
    return bytes(b)
def keccak(b):
    return subprocess.check_output(["cast", "keccak", "0x" + b.hex()]).decode().strip()
WANT = [("delegate", "PharaohBoostedDelegate.sol", "PharaohBoostedDelegate"),
        ("delegator", "PErc20Delegator.sol", "PErc20Delegator"),
        ("oracle", "PharaohDlmmShareOracle.sol", "PharaohDlmmShareOracle"),
        ("accountingModule", "BorrowAccountingModule.sol", "BorrowAccountingModule")]
'

case "$STEP" in
  pin)
    if [ -n "$(git status --porcelain -- contracts script foundry.toml tools/bp-dlmm-ceremony.sh 2>/dev/null)" ]; then
      echo "REFUSED: uncommitted changes under contracts/contracts, contracts/script, contracts/foundry.toml or this tool" >&2; exit 1; fi
    rm -rf out_bpdlmm cache_bpdlmm
    forge build --force --skip test "${SKIP[@]}" >/dev/null 2>&1 || { echo "build failed (run: FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_bpdlmm FOUNDRY_CACHE_PATH=cache_bpdlmm forge build --skip test ${SKIP[*]})" >&2; exit 1; }
    mkdir -p ceremony
    COMMIT="$(git rev-parse HEAD)"
    SRCSHA="$( { find contracts -name '*.sol' -type f; echo "$SCRIPT"; echo foundry.toml; } | sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)"
    COMMIT="$COMMIT" SRCSHA="$SRCSHA" PIN_FILE="$PIN_FILE" python3 -I -c "$PYLIB"'
import os
pin = {"commit": os.environ["COMMIT"], "sourcesSha256": os.environ["SRCSHA"], "profile": "debt_accounting (solc 0.8.35, cancun, via_ir, runs 1)", "hashes": {}, "sizes": {}}
for key, src, name in WANT:
    code, refs, creation = art(src, name)
    size = len(code)
    h = keccak(zero(code, refs))
    pin["hashes"][key] = h; pin["sizes"][key] = size
    pin["hashes"][key + "Creation"] = keccak(creation)
    flag = "  OVER THE EIP-170 LIMIT" if size > 24576 else ""
    print("runtime %-22s %6d bytes (limit 24576)%s  keccak(immutables zeroed) %s" % (name, size, flag, h))
    assert size <= 24576, name + " is over the limit"
json.dump(pin, open(os.environ["PIN_FILE"], "w"), indent=1)
print("git commit:", pin["commit"]); print("sources sha256:", pin["sourcesSha256"]); print("written:", os.environ["PIN_FILE"])
'
    ;;

  check)           need_rpc; FS --sig 'check()' -vv ;;

  deploy)
    need_rpc; need_deployer
    if [ "$MODE" = live ]; then SIGN=(--account "$BP_DEPLOYER_ACCOUNT" --sender "$BP_DEPLOYER"); else SIGN=(--unlocked --sender "$BP_DEPLOYER"); fi
    echo "== deploy ($MODE): signer = the throwaway deployer ${BP_DEPLOYER}; three contracts; no role is kept"
    OUT="$(FS --sig 'deploy()' "${SIGN[@]}" --broadcast --slow --timeout 300 --retries 10 -vvv)"; RC=$?
    echo "$OUT"
    mkdir -p "$(dirname "$ADDR_FILE")"
    { for pair in "delegate:BP_DELEGATE" "market:BP_MARKET" "oracle:BP_ORACLE"; do
        label="${pair%%:*}"; var="${pair##*:}"
        a="$(echo "$OUT" | grep -E "^[[:space:]]*${label}:[[:space:]]+0x[0-9a-fA-F]{40}" | tail -1 | grep -oE "0x[0-9a-fA-F]{40}")"
        echo "export ${var}=${a}"
      done; } > "$ADDR_FILE"
    echo "addresses written to $ADDR_FILE: $(grep -c '=0x' "$ADDR_FILE") of 3 found"
    [ "$RC" = 0 ] && [ "$(grep -c '=0x' "$ADDR_FILE")" = 3 ] || exit 1
    exec "$0" verify-deployed "$MODE" ;;

  verify-deployed)
    need_rpc; load_new
    [ -f "$PIN_FILE" ] || { echo "no pin file ($PIN_FILE): run 'pin' first (it also produces the build this check compares with)" >&2; exit 1; }
    FS --sig 'verifyDeployed()' -vv; RC1=$?
    echo "== code check against the pinned build (immutables zeroed)"
    BP_PIN_FILE="$PIN_FILE" python3 -I -c "$PYLIB"'
import os, sys
pin = json.load(open(os.environ["BP_PIN_FILE"]))
def onchain(addr):
    out = subprocess.run(["cast", "code", addr], capture_output=True, text=True)
    if out.returncode != 0: print("cast code failed for", addr); sys.exit(1)   # stderr is dropped: it may contain the endpoint
    return bytes.fromhex(out.stdout.strip()[2:])
ok = True
def cmp(label, key, addr, src, name):
    global ok
    chain = onchain(addr)
    code, refs, _ = art(src, name)
    same = len(chain) == len(code) and keccak(zero(chain, refs)) == keccak(zero(code, refs)) == pin["hashes"][key]
    print("%-12s %s  %s" % (label, addr, "OK" if same else "MISMATCH"))
    ok = ok and same
    return chain, refs
delegate_chain, drefs = cmp("delegate", "delegate", os.environ["BP_DELEGATE"], "PharaohBoostedDelegate.sol", "PharaohBoostedDelegate")
cmp("market", "delegator", os.environ["BP_MARKET"], "PErc20Delegator.sol", "PErc20Delegator")
# the accounting module: its address is the (only) immutable of the delegate; its own code must be the pinned build too
mods = set()
for lst in drefs.values():
    for r in lst:
        mods.add("0x" + delegate_chain[r["start"] + r["length"] - 20:r["start"] + r["length"]].hex())
if len(mods) != 1: print("the delegate carries", len(mods), "immutable addresses (expected 1)"); ok = False
else: cmp("acct module", "accountingModule", mods.pop(), "BorrowAccountingModule.sol", "BorrowAccountingModule")
print("oracle: compared inside the forge script (a fresh build with the same constructor arguments, immutables included)")
sys.exit(0 if ok else 1)
'
    RC2=$?
    [ "$RC1" = 0 ] && [ "$RC2" = 0 ] || { echo "verify-deployed: FAILED" >&2; exit 1; }
    echo "verify-deployed: OK" ;;

  verify-listing)
    need_rpc; load_new
    case "$ARG3" in 1|2|3|4) ;; *) echo "usage: $0 verify-listing <rehearsal|live> <1..4>" >&2; exit 2 ;; esac
    BP_STAGE="$ARG3" FS --sig 'verifyListing()' -vv ;;

  members)
    need_rpc; load_new
    : "${ARG3:?usage: $0 members <rehearsal|live> <from-block (the market deployment block)>}"
    # MarketEntered(address pToken, address account): both words are data, not topics, so the filter is applied here
    MKT_LC="$(echo "$BP_MARKET" | tr 'A-Z' 'a-z' | sed 's/^0x//')"
    echo "== accounts that ENTERED the new market ($BP_MARKET) since block $ARG3 (a still-listed account must be re-checked with checkMembership):"
    cast logs --from-block "$ARG3" --to-block latest --address "$CONTROLLER" 'MarketEntered(address,address)' 2>&1 | REDACT \
      | awk -v m="$MKT_LC" 'tolower($0) ~ /data:/ { d=tolower($0); sub(/.*data: 0x/, "", d); if (substr(d,25,40)==m) print "0x" substr(d,89,40) }' | sort -u
    echo "(an empty list means nobody entered; a rollback to the old oracle freezes every account listed here until a price returns)" ;;

  print-ledger-calls)
    [ -f "$ADDR_FILE" ] && . "$ADDR_FILE"
    [ -n "${BP_MARKET:-}" ] && [ -n "${BP_ORACLE:-}" ] || { echo "UNSET: BP_MARKET / BP_ORACLE (written by deploy to $ADDR_FILE)" >&2; exit 1; }
    ORACLE="$BP_ORACLE"; MARKET="$BP_MARKET"
    if [ "$MODE" = live ]; then SEND="--ledger --from $LEDGER"; else SEND="--unlocked --from $LEDGER"; fi
    WANT="${ARG3:-all}"
    n=0
    # emit <label> <expect> <target> <signature-with-returns> <args...>: the simulation (eth_call from the Ledger) FIRST, then the calldata, then the send
    emit() {
      local label="$1" expect="$2" target="$3" sig="$4"; shift 4
      # the calldata uses the argument part of the signature only
      local argsig="${sig%%)*})"
      n=$((n + 1))
      echo
      echo "# ---- ${label}"
      echo "# expected simulation result: ${expect}"
      printf '# calldata (compare with the device): '
      cast calldata "$argsig" "$@" 2>/dev/null || echo "(cast calldata unavailable)"
      printf 'cast call --from %s %s' "$LEDGER" "$target"; printf " '%s'" "$sig"; for a in "$@"; do printf " '%s'" "$a"; done; echo ' 2>&1 | python3 -I tools/avalanche-redact-rpc.py ETH_RPC_URL   # SIMULATE FIRST'
      printf 'cast send %s %s' "$SEND" "$target"; printf " '%s'" "$argsig"; for a in "$@"; do printf " '%s'" "$a"; done; echo ' 2>&1 | python3 -I tools/avalanche-redact-rpc.py ETH_RPC_URL   # then SIGN'
    }
    read_back() { echo "# read-back: $1"; shift; printf 'cast call %s' "$1"; shift; for a in "$@"; do printf " '%s'" "$a"; done; echo ' 2>&1 | python3 -I tools/avalanche-redact-rpc.py ETH_RPC_URL'; }
    stage_hdr() { echo; echo "################################################################################ $1"; }
    show() { [ "$WANT" = all ] || [ "$WANT" = "$1" ]; }
    echo "# bpPHAR-USDC listing: Ledger transactions ($MODE). THE ENDPOINT COMES FROM ETH_RPC_URL (never printed). Signer: $LEDGER (an EOA; it is the"
    echo "# controller, pToken and oracle admin). Market $MARKET, wrapper $ORACLE, vault $VAULT, guarded oracle (rollback target) $GUARDED_ORACLE."
    echo "# Rules: simulate FIRST; the return code of _supportMarket/_setPriceOracle/_setCollateralFactor must be 0 (they RETURN an error instead of reverting);"
    echo "# after each stage run: tools/bp-dlmm-ceremony.sh verify-listing $MODE <stage>"
    echo "# Preconditions (read the ceremony document): pin matches, verify-deployed OK, the order/operator keepers are on a build that accepts the wrapper,"
    echo "# the order keeper and treasury keepers stopped or ready, and the vault feeds are fresh (check passes)."

    if show 1; then
      stage_hdr "STAGE 1  oracle swap (the only transaction that touches existing markets; the new market is NOT listed yet, so a rollback is clean)"
      emit "T1 controller._setPriceOracle(wrapper)" "0" "$CONTROLLER" "_setPriceOracle(address)(uint256)" "$ORACLE"
      read_back "controller.oracle() == $ORACLE" "$CONTROLLER" 'oracle()(address)'
      echo "# then: tools/bp-dlmm-ceremony.sh verify-listing $MODE 1     (wrapper == guarded oracle for every market, share price sane)"
    fi
    if show 2; then
      stage_hdr "STAGE 2  list, lock borrowing (flash loans are already paused by the delegate at construction)"
      emit "T2 controller._supportMarket(market)" "0" "$CONTROLLER" "_supportMarket(address)(uint256)" "$MARKET"
      read_back "markets(market) -> true, 0 (listed, CF 0)" "$CONTROLLER" 'markets(address)(bool,uint256,bool)' "$MARKET"
      emit "T3 controller._setBorrowPaused(market, true)" "true" "$CONTROLLER" "_setBorrowPaused(address,bool)(bool)" "$MARKET" true
      read_back "borrowGuardianPaused(market) == true" "$CONTROLLER" 'borrowGuardianPaused(address)(bool)' "$MARKET"
      emit "T4 controller._setMarketBorrowCaps([market],[1])  (0 would mean UNLIMITED; 1 blocks every borrow)" "(no return value; must not revert)" "$CONTROLLER" "_setMarketBorrowCaps(address[],uint256[])" "[$MARKET]" "[1]"
      read_back "borrowCaps(market) == 1" "$CONTROLLER" 'borrowCaps(address)(uint256)' "$MARKET"
      echo "# then: tools/bp-dlmm-ceremony.sh verify-listing $MODE 2"
    fi
    if show 3; then
      stage_hdr "STAGE 3  the PERMANENT SEED: 1,000,000 share-wei (1 whole share) -> 5,000,000,000 pToken-wei, all burned to the dead address. Only the admin can mint while supply is 0"
      emit "T5 vault.approve(market, $SEED_SHARES)  (the exact seed, not unlimited)" "true" "$VAULT" "approve(address,uint256)(bool)" "$MARKET" "$SEED_SHARES"
      read_back "vault.allowance(Ledger, market) == $SEED_SHARES" "$VAULT" 'allowance(address,address)(uint256)' "$LEDGER" "$MARKET"
      emit "T6 market.mint($SEED_SHARES)" "0" "$MARKET" "mint(uint256)(uint256)" "$SEED_SHARES"
      read_back "market.balanceOf(Ledger) == $SEED_PTOKENS" "$MARKET" 'balanceOf(address)(uint256)' "$LEDGER"
      read_back "market.totalSupply() == $SEED_PTOKENS" "$MARKET" 'totalSupply()(uint256)'
      read_back "market.getCash() == $SEED_SHARES" "$MARKET" 'getCash()(uint256)'
      read_back "market.exchangeRateStored() == 200000000000000 (2e14: no donation moved it)" "$MARKET" 'exchangeRateStored()(uint256)'
      emit "T7 market.transfer(DEAD, $SEED_PTOKENS)  (the WHOLE seed; the Ledger keeps no pToken)" "true" "$MARKET" "transfer(address,uint256)(bool)" "$DEAD" "$SEED_PTOKENS"
      read_back "market.balanceOf(DEAD) == $SEED_PTOKENS" "$MARKET" 'balanceOf(address)(uint256)' "$DEAD"
      read_back "market.balanceOf(Ledger) == 0" "$MARKET" 'balanceOf(address)(uint256)' "$LEDGER"
      emit "T8 controller._setMintPaused(market, true)  (nobody else supplies until activation)" "true" "$CONTROLLER" "_setMintPaused(address,bool)(bool)" "$MARKET" true
      read_back "mintGuardianPaused(market) == true" "$CONTROLLER" 'mintGuardianPaused(address)(bool)' "$MARKET"
      echo "# then: tools/bp-dlmm-ceremony.sh verify-listing $MODE 3"
    fi
    if show 4; then
      stage_hdr "STAGE 4  ACTIVATION: ONLY after the fork liquidation test passed and verify-listing 3 is OK. CF stays 0 until here"
      emit "T9 controller._setMintPaused(market, false)  (skip if supply should stay closed)" "false" "$CONTROLLER" "_setMintPaused(address,bool)(bool)" "$MARKET" false
      read_back "mintGuardianPaused(market) == false" "$CONTROLLER" 'mintGuardianPaused(address)(bool)' "$MARKET"
      emit "T10 controller._setCollateralFactor(market, 0.5e18)  (refused with a PRICE_ERROR code if the oracle returns 0)" "0" "$CONTROLLER" "_setCollateralFactor(address,uint256)(uint256)" "$MARKET" "$CF_ACTIVE"
      read_back "markets(market) -> true, 500000000000000000" "$CONTROLLER" 'markets(address)(bool,uint256,bool)' "$MARKET"
      echo "# then: tools/bp-dlmm-ceremony.sh verify-listing $MODE 4"
    fi
    if [ "$WANT" = all ] || [ "$WANT" = rollback ]; then
      stage_hdr "ROLLBACK (ONE transaction). Run 'members' first: every account that entered the market is frozen (borrow, redeem, transfer, exit, and its own liquidation) until a price returns"
      emit "R1 controller._setPriceOracle(guarded oracle)" "0" "$CONTROLLER" "_setPriceOracle(address)(uint256)" "$GUARDED_ORACLE"
      read_back "controller.oracle() == $GUARDED_ORACLE" "$CONTROLLER" 'oracle()(address)'
    fi
    echo
    echo "# $n transactions printed." ;;

  *) usage ;;
esac
