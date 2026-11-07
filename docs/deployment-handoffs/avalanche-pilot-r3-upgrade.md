# Pharaoh vaults: the R3 share-pricing upgrade and the rebalancer module (target 15 Nov)

Status: **prepared, nothing sent.** Everything below was run on a local fork; the Ledger signs on the day. Decision of 2026-11-06: R3 goes in as a new implementation behind the existing proxies; the rebalancer module ships with it; both vaults' `rebalancer()` moves to a fourth keystore by one Safe transaction each. Audits do not gate this; the caps do (section 8).

## 1. What changes, in one paragraph
Today a deposit is minted against the **haircut** NAV (`totalAssets`) while the vault's real holdings are worth more, so a depositor who enters a vault holding idle paired token takes value from earlier holders, and cycling deposits and exits can repeat it. R3 mints on the **ownership NAV** (the same position split, the oracle value of the real holdings at the same price-checked valuation tick, **no haircut**) and deploys a new deposit **in the vault's own composition** (it swaps `x = D·P0/N0` of the new asset and never sells an incumbent's idle paired token). `totalAssets`, the deposit cap, `maxDeposit`, `redeem`/`withdraw`, `rebalance` and every view other than `previewDeposit` stay on the haircut. **No storage variable is added, removed or moved.** Source of the rule and the model behind it: `avalanche-vault-share-pricing-remedy.md` (R1 + R2 = R3).

## 2. The code (in `contracts/vault-r3/`)
| File | What |
| --- | --- |
| `src/orig/` | the verified deployed sources, unchanged (`PharaohLiquidityVault.sol` sha256 `fb951b92f0b9333ca25674249f094fadb86a681d6bad87e0b24b8ff66ecb8dc8`, `PharaohRewardExtension.sol` `d7e3ea8370ee24756233c5be7acab0e826de3cb2cf9c97b792df5764519535d5`) |
| `src/r3/PharaohLiquidityVaultR3.sol` | the new base implementation; diff against `src/orig/PharaohLiquidityVault.sol`: `diff -u src/orig/PharaohLiquidityVault.sol src/r3/PharaohLiquidityVaultR3.sol` (144 lines, imports and the contract name aside: `totalAssets` split into `_holdingsValue`, `previewDeposit` on the ownership NAV, `_executeDeposit` mint on the ownership NAV with the cap check left on the haircut, `_deployDeposit`) |
| `src/r3/PharaohRewardExtensionR3.sol` | the extension, **only** change: base address and its expected codehash are constructor arguments (immutables) instead of constants; the constructor still **reverts** unless the base has exactly that codehash (checked in the rehearsal) |
| `tools/check-layout.sh` | storage-layout comparison, original against R3 |
| `test/R3Fork.t.sol` | fork tests against the live vaults (section 4) |

**Reproduction of the deployed code (byte for byte).** Building `src/orig/` with this project's settings (`foundry.toml`: solc 0.8.35, optimizer 200, via-IR, evm osaka, no metadata hash) gives exactly the code on chain: base `0x37E28a2C…3770` 24,153 bytes identical, extension `0x165E1f07…A45d` 2,219 bytes identical (`avalanche-vault-r3-evidence/reproduction-original-vs-chain.txt`). So the R3 diff is the only difference between what runs today and what will run.

**Layout check** (`avalanche-vault-r3-evidence/layout-check.txt`): base 22 linear slots **identical**, extension 0 linear slots (ERC-7201 namespaced) identical. Runtime sizes: R3 base **24,490 bytes** (limit 24,576: 86 bytes of margin; any later change must re-check this), R3 extension 2,231.

**The bytecode you deploy.** A clean build gives, for the R3 base, runtime keccak `0x62c312eca7879a53f56bb56d232150b16f45a53c84a5f94c85878f5bdc58d535` (24,490 bytes). Do `cd contracts/vault-r3 && forge clean && forge build` and compare before deploying (section 5 step 1). *Lesson recorded: an earlier rehearsal of mine ran on an artifact left behind by a mutation test (24,484 bytes); it was discarded and re-run on a clean build. The hash check in step 1 is there so that this cannot happen on the day.*

## 3. The residual R3 does not remove
Shares are minted on the oracle value at the **valuation tick** (TWAP-based, deviation-checked), not on the spot price. When spot and the valuation tick differ, a depositor can still move value by about the gap. In the grid below the worst case is 0.08% (USDC vault) and 0.25% (WAVAX vault) of the deposit, **in the states with an artificial spot skew of a third of the vault's maximum allowed deviation**; with spot at the valuation tick it is rounding. The vault's `PriceDeviation` guard bounds the gap, and the pilot caps bound the size. Not fixed by R3; do not describe R3 as "no value transfer possible".

## 4. Evidence (`avalanche-vault-r3-evidence/`)
All on forks of the live vaults (Foundry fork tests, the real pools, the real routers; `full-suite-run.txt`: **26 of 26 pass**, 13 per vault).
- **144-state grid per vault** (4 idle-paired levels × 3 share-price levels × 4 deposit sizes (1%, 10%, 100%, 300% of NAV) × 3 spot skews), each state checks: every incumbent bears exactly the pro-rata share of the newcomer's transfer up to the derived rounding bound, the transfer equals the valuation-gap closed form, `previewDeposit` equals the ownership-basis formula, and **no swap in the deposit sold the paired token**.

  | | violating states, ORIGINAL | violating states, R3 | worst transfer / deposit, ORIGINAL | worst, R3 |
  | --- | --- | --- | --- | --- |
  | USDC vault | every state that ran (30 + 30 + 29 + 18) | **0** | 1.4% … 25% | 0.06% … 0.08% |
  | WAVAX vault | every state that ran (30 × 4) | **0** | 10% … 85% | 0.20% … 0.25% |

  Some states do not run: a deposit of 100–300% of NAV (or into a skewed pool) is refused by the vault's own swap slippage bound ("Too little received") on **both** rules (6–18 of 36 states per level; `depositRevertedByGuard` in the summary). That is the vault protecting itself; it is also why large deposits fail, see section 6.
- **Mutation probe** (`mutants.txt`): seven of the eight R1/R2 mutants are killed; one (`x = assets/2`) is equivalent at the probe states (the position is ~50/50) and is documented as such. The first version of the probe did not kill "R2 removed"; it was extended, not loosened.
- **Deposit ladder** (single deposits from 100 to 4,400 USDC and 10 to 530 WAVAX, post-opening state): all accepted under both rules; gas **+5.6% (USDC) / +5.9% (WAVAX)** (e.g. 755k vs 715k and 591k vs 558k at the smaller sizes).
- **Upgrade and rotation rehearsal** (`rehearsal-upgrade-rotation.txt/.json`, **32 of 32**, fork head 99,592,366): the 12 Nov opening under the deployed code (cap, team seed, `deployIdle`, one user deposit), the R3 deployment, both Safe upgrades, the rotation, the module, and the rollback. Highlights: every parameter, role, the position and the supply identical before and after the upgrade; `totalAssets` and `previewRedeem` for the team seed and the user **identical**; a deposit after the upgrade mints more than `previewDeposit`; an immediate round trip returns **99.46% (USDC) and 98.73% (WAVAX)**; rollback restores the previous extension and the exit values.

## 5. The ceremony (Ledger; all four Safe/Ledger steps are one signature each)
Preconditions (read-only, the day before): the Safe `0x80f4…fB12` still has the Ledger as sole owner and threshold 1 (`cast call $SAFE 'getOwners()(address[])'`); `cast call <ProxyAdmin> 'owner()(address)'` is the Safe for both ProxyAdmins; the extension slot of each proxy still reads `0x165E1f07…A45d`; record `totalAssets()` and `previewRedeem(<ledger shares>)` of each vault. The Ledger holds about 0.3 AVAX.

```
export ETH_RPC_URL="$AVALANCHE_MAINNET_RPC_URL"
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD ; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12
SIG=0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001
Z=0x0000000000000000000000000000000000000000
UV=0x855bF832f26a294d28500db59eE941dE3d654129 ; UADMIN=0x2DD4191B2944396B5853f4219E829f01636F65cf
WV=0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8 ; WADMIN=0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC
```
**Step 1: build, compare, deploy the base** (two plain transactions from the Ledger; they change nothing yet):
```
[ -e contracts/vault-r3/lib ] || ln -s ../lib contracts/vault-r3/lib   # the symlink is tracked; recreate it if missing
cd contracts/vault-r3 && forge clean && forge build
python3 -c "import json;print(json.load(open('out/PharaohLiquidityVaultR3.sol/PharaohLiquidityVaultR3.json'))['deployedBytecode']['object'])" | xargs cast keccak
#   must print 0x62c312eca7879a53f56bb56d232150b16f45a53c84a5f94c85878f5bdc58d535 ; if not, STOP
forge create src/r3/PharaohLiquidityVaultR3.sol:PharaohLiquidityVaultR3 --ledger --from $LEDGER --gas-limit 8000000 --broadcast
BASE=<the "Deployed to" address>
cast keccak $(cast code $BASE)                       # must print the same hash (read-back)
forge create src/r3/PharaohRewardExtensionR3.sol:PharaohRewardExtensionR3 --constructor-args $BASE 0x62c312eca7879a53f56bb56d232150b16f45a53c84a5f94c85878f5bdc58d535 \
   --ledger --from $LEDGER --gas-limit 3000000 --broadcast
EXT=<the "Deployed to" address>
```
(About 5.4M gas for the base, 0.6M for the extension. The extension constructor reverts if `$BASE` has any other codehash.)

**Step 2: upgrade the two proxies** (Safe `execTransaction`, caller = the owner; ~74k gas each):
```
DATA_U=$(cast calldata 'upgradeAndCall(address,address,bytes)' $UV $EXT 0x)
cast send $SAFE 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
   $UADMIN 0 $DATA_U 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER --gas-limit 500000
DATA_W=$(cast calldata 'upgradeAndCall(address,address,bytes)' $WV $EXT 0x)
cast send $SAFE 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
   $WADMIN 0 $DATA_W 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER --gas-limit 500000
```
(`0x9623609d` is the selector of `upgradeAndCall(address,address,bytes)`; the call goes to the ProxyAdmin, not to the vault.)
**Read-backs (each vault):** `cast storage <vault> 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` = `$EXT` (padded); `owner()`, `rebalancer()`, `depositCap()`, `paused()`, `tokenId()`, `totalSupply()` unchanged; `totalAssets()` and `previewRedeem(<ledger shares>)` **equal** to the values recorded before. If any read differs: roll back (below) and tell me.

**Step 3: rotate `rebalancer()` to the fourth keystore** (`NEWREB` = its public address; one Safe transaction per vault, ~74k gas):
```
for V in $UV $WV; do
  cast send $SAFE 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
     $V 0 $(cast calldata 'setRebalancer(address)' $NEWREB) 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER --gas-limit 500000
done
```
**Read-backs:** `cast call <vault> 'rebalancer()(address)'` = `$NEWREB` on both. From then on **the Ledger can no longer call `deployIdle()`/`rebalance()`** (the rehearsal shows `Vault__NotRebalancer`); rotate back with the same call if you ever want that. Do not rotate before the module is running and the new wallet holds AVAX (section 7): idle deposits earn nothing meanwhile.

**Rollback** (same Safe call, previous extension): `upgradeAndCall(<vault>, 0x165E1f072e7bEeDf94f14F732838354cA20bA45d, 0x)` on each ProxyAdmin. The layouts are identical, so state is untouched (rehearsed, last two checks of the log). Shares minted under R3 stay valid.

## 6. What users will see
- **Entry cost is unchanged in kind**: `previewDeposit` is a lower bound (after the vault's entry-loss allowance); the shares actually minted are higher (rehearsal: minted 99.43M vs preview 96.46M shares for 100 USDC). Show the preview, not the mint.
- **An immediate deposit-and-exit returns 99.46% (USDC) / 98.73% (WAVAX)** at the rehearsal head: show it as an exit cost on the deposit screen (frontend notes). The WAVAX figure under the deployed rule was 98.77%; the difference is the fork head, not the rule.
- **Large deposits revert** when their swap leg is large relative to pool depth (the vault's own slippage bound). In the grid that starts at deposits of about the vault's NAV; the pilot caps keep real deposits far below it. The frontend should cap the input at `maxDeposit` and warn above a few percent of the pool's depth.
- `maxDeposit` can still overstate the room by a few units (fees are collected inside `deposit`); do not build the last unit from it.

## 7. The rebalancer module (`operator/src/rebalancer.ts`)
Runs on the keeper Droplet as a **separate process** under its own keystore (`REBALANCER_KEYSTORE_PASSWORD`, config block `rebalancer`; the configuration refuses a process that is also a keeper or an executor). It does two things: `deployIdle()` when the idle asset of a vault is above its threshold (USDC vault 1 USDC, WAVAX vault 0.1 WAVAX), and `rebalance()` when spot is outside the position or within 5 ticks of an edge (at most once an hour per vault). Every transaction is simulated first, sent with gas limit = estimate × 1.5, preceded by a persisted pending marker, and followed by a read-back of `totalAssets`; a loss above 50 bp, an interrupted transaction or any unexpected error **halts** the module until a human clears the state file; at most 24 actions a day; a fee cap and a gas floor. It checks that its own address is the vault's `rebalancer()` and refuses to act otherwise.
- **What the role can do** (rehearsed): `deployIdle`, `rebalance`. It **cannot** pause, change the cap or the role, upgrade, harvest or exit (all owner functions: `OwnableUnauthorizedAccount`).
- **What a stolen key can do:** call `rebalance()` repeatedly. Each call is bounded by the vault's guards (TWAP and oracle deviation, per-swap slippage, `ExcessiveLoss` of about 3% per call) but nothing limits how often, so it can bleed value through swap costs until the Safe rotates the role away (one transaction; the monitor watches `totalAssets`). The module's own limits protect against its own mistakes, not against a thief. The key holds AVAX for gas only, **no USDC**, and should not share a password with the keeper's.
- Start: as in `avalanche-pilot-host-setup.md` section 3, with `main.js rebalance` and the fourth keystore.
- Tested: 7 unit tests (decision table, loss arithmetic, configuration exclusivity) and the fork rehearsal (section 4): on the upgraded vaults the module's `deployIdle` deployed the idle donation on both vaults at a 3 bp measured loss, a second pass found nothing to do, and a wallet that is not the rebalancer was refused before any transaction. **`rebalance()` itself is not exercised on the fork** (it needs the spot to leave the range and the TWAP guard to allow it); its decision logic is unit-tested and the call is the same one the Ledger would make.

## 8. The caps are the real limit
The frontend is password-gated but the contracts are public: anyone can call `deposit` once the cap is open. The cap (USD 5,000 per vault, 12 Nov) is the only limit that binds. R3 narrows what a depositor can take from earlier holders (section 3) but does not make an open cap safe at a larger size.

## 9. Reproduce
```
[ -e contracts/vault-r3/lib ] || ln -s ../lib contracts/vault-r3/lib   # the symlink is tracked; recreate it if missing
cd contracts/vault-r3 && forge clean && forge build && bash tools/check-layout.sh          # no RPC
export AVALANCHE_MAINNET_RPC_URL=...                                                       # from the environment only
forge test --rpc-url avalanche --no-match-test test_debug_sweep --threads 1 --gas-limit 9000000000000000000 --compute-units-per-second 20   # ~12 minutes
cd ../../operator && npm run build && node dist/scripts/rehearse-r3-upgrade.js --out /tmp/report.json     # needs contracts/vault-r3/out built clean
```
Pipe both through `contracts/tools/avalanche-redact-rpc.py AVALANCHE_MAINNET_RPC_URL` if the output is kept. The free Alchemy tier rate-limits parallel fork jobs (429): run them one at a time.
