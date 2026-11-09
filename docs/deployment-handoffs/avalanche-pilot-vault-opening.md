# Avalanche Pharaoh vaults: opening at a USD 200 deposit cap each (CAP = 200; target 12 Nov)

Status: **PREPARED, NOT EXECUTED.** Two Safe transactions, signed by the Ledger (the Safe's only owner, threshold 1). The assistant signs and sends nothing. Rehearsed on a local fork of the current mainnet head with the Ledger impersonated (`operator/scripts/rehearse-vault-opening.ts`, report `avalanche-cash-only-operator-evidence/vault-opening-rehearsal.json`). **Sizes: CAP = USD 200 (AVAX = USD 7.987), from `contracts/ceremony/pilot-sizing.json` / `avalanche-pilot-sizing-table.md`.** The rehearsal ran at the research size (cap USD 5,000 / 595 WAVAX, seeds 500 USDC / 60 WAVAX); the commands below are the CAP-200 ones and the rehearsal script has not been re-run at this size. Rehearsal numbers quoted below are marked "research size". No vault code is changed by this step; the R3 mint-rule fix (13 to 15 Nov) is a separate upgrade.

## 1. State today (read-only, mainnet block 99,580,000)
| | USDC vault `0x855bF832f26a294d28500db59eE941dE3d654129` | WAVAX vault `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` |
|---|---|---|
| `owner()` | the Safe `0x80f4...fB12` | the Safe |
| `rebalancer()` | the Ledger | the Ledger |
| `paused()` | false | false |
| `depositCap()` | **1** (the closed sentinel) | **1** |
| `totalAssets()` / `totalSupply()` | 29.84 USDC / 29.85 shares | 1.737 WAVAX / 1.724 shares |
The Safe: version 1.4.1, owners = [the Ledger], threshold 1, nonce 12.

## 2. The caps (decide before the day)
- USDC vault: **USD 200 = `200000000`** (6 decimals; `usdc_deposit_cap_units`). Research size: USD 5,000 = `5000000000`.
- WAVAX vault: the cap is in WAVAX units, so its dollar value moves with the price. Proposal **25.040864280322299010 WAVAX = `25040864280322299010`** (`wavax_deposit_cap_units`; about USD 200 at AVAX = USD 7.987; at USD 10 it would be about USD 250). Research size: 595 WAVAX = `595000000000000000000`, USD 4,977 at AVAX = USD 8.365. Tell me the number you accept; I recompute the calldata.
- **The frontend is password-gated but the contracts are public: any address can call `deposit` on the vaults directly. The deposit cap is therefore the real limit, not the password.** The cap counts the whole vault (`totalAssets`), first come first served.

## 3. The two transactions (Ledger; Safe `execTransaction`, caller = the owner)
The owner may call `execTransaction` itself with the "approved by msg.sender" signature (65 bytes: the owner's address left-padded to 32 bytes, 32 zero bytes, `01`). One Ledger confirmation per transaction, no typed-data signing:
```
export ETH_RPC_URL="$AVALANCHE_MAINNET_RPC_URL"
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD ; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12
SIG=0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001
Z=0x0000000000000000000000000000000000000000
# 1. USDC vault: setDepositCap(200000000)
cast send $SAFE 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
  0x855bF832f26a294d28500db59eE941dE3d654129 0 0x866512030000000000000000000000000000000000000000000000000000000000bebc200 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER
# 2. WAVAX vault: setDepositCap(25040864280322299010)
cast send $SAFE 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
  0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8 0 0x866512030000000000000000000000000000000000000000000000015b8305640960d482 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER
```
(`0x86651203` is the selector of `setDepositCap(uint256)`; the Safe's own calldata was produced by the rehearsal script from exactly these arguments.) Gas: 74k each.

**Read-backs (read-only):** `cast call 0x855b...4129 'depositCap()(uint256)'` = `200000000`; `cast call 0xe9a5...90E8 'depositCap()(uint256)'` = `25040864280322299010`; `cast call $SAFE 'nonce()(uint256)'` = 14 (12 now, +1 per transaction); `cast call <vault> 'maxDeposit(address)(uint256)' <any address>` = cap minus `totalAssets` (from the state in section 1, before the team seeds: about 170.16 USDC and 23.30 WAVAX at CAP 200; research size 4,970.16 USDC and 593.26 WAVAX).

**Close again** (same form, argument `1`): `setDepositCap(1)` = calldata `0x866512030000000000000000000000000000000000000000000000000000000000000001`. Pause: `pause()` from the Safe (owner).

## 3b. The team seed and `deployIdle` (Ledger, same day, after the caps)
The Ledger deposits the team seed into each vault and calls `deployIdle()` (the Ledger is the `rebalancer`). **Send these with explicit gas limits**: the first deposit into a position uses about 2.4M gas and a raw estimate is not safe (section 4, "the failed transaction"). Seed amounts are yours to confirm (CAP-200 values, 5% of CAP per vault, minimum USD 10: **10 USDC = `10000000`** and **1.25204321401611495 WAVAX = `1252043214016114950`**, about USD 10 each; they count against the caps. Research size: 500 USDC and 60 WAVAX).
```
USDC=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E ; WAVAX=0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7
UV=0x855bF832f26a294d28500db59eE941dE3d654129 ; WV=0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8
# USDC vault
cast send $USDC 'approve(address,uint256)' $UV 10000000 --ledger --from $LEDGER --gas-limit 120000
cast send $UV  'deposit(uint256,address)' 10000000 $LEDGER --ledger --from $LEDGER --gas-limit 4000000
cast send $UV  'deployIdle()' --ledger --from $LEDGER --gas-limit 2000000
# WAVAX vault
cast send $WAVAX 'approve(address,uint256)' $WV 1252043214016114950 --ledger --from $LEDGER --gas-limit 120000
cast send $WV  'deposit(uint256,address)' 1252043214016114950 $LEDGER --ledger --from $LEDGER --gas-limit 4000000
cast send $WV  'deployIdle()' --ledger --from $LEDGER --gas-limit 2000000
```
(The Ledger must hold the seed assets (10 USDC and 1.2521 WAVAX, already in the Ledger line of the sizing table) and about 0.2 AVAX of gas for these six transactions.) **Read-backs (read-only), per vault:** `cast call <vault> 'balanceOf(address)(uint256)' $LEDGER` > 0 (research-size rehearsal: 497.2M shares for the USDC vault, 58.6e18 for the WAVAX vault; at CAP 200 the share count scales with the seed, about 99% and 98% of it at the research ratios: read it back, do not expect the research figures); `cast call <vault> 'totalAssets()(uint256)'` (research-size rehearsal 527.3M and 60.99e18, i.e. above the seed plus the 29.8 USDC / 1.7 WAVAX already there; at CAP 200 the sum is about 39.8 USDC and 2.99 WAVAX); **`cast call <asset> 'balanceOf(address)(uint256)' <vault>` = 0 after `deployIdle`** (nothing left idle: the liquidity is in the position); `cast call <vault> 'tokenId()(uint256)'` non-zero; `cast call <vault> 'previewRedeem(uint256)(uint256)' <ledger shares>` (research-size rehearsal 497.4M USDC and 59.25 WAVAX for the seeds: the 0.5% and 1.2% entry cost, section 4; at CAP 200 about 9.95 USDC and 1.237 WAVAX). Gas used in the rehearsal: deposit 2.39M and 2.31M, `deployIdle` 0.74M and 0.67M.

## 4. What the rehearsal showed (fork at the live head)
- Both transactions succeed and the read-backs match; the Safe nonce goes 12 -> 13 -> 14.
- A depositor can deposit up to the cap and **one deposit more than the cap is refused** on both vaults.
- **`maxDeposit()` can overstate the room by a few units** (3 units of USDC): it is computed before the fee collection that `deposit` performs first, and the collected fees raise `totalAssets`. A frontend must not build a transaction from `maxDeposit` to the last unit.
- **Idle assets earn nothing until the rebalancer calls `deployIdle()`.** The rebalancer is the Ledger. The rehearsal called it as the Ledger and it succeeded on both vaults. **No automated deployer exists today**: someone must send `deployIdle()` (and `rebalance()` when the position leaves range) from the rebalancer key. Options: you send them from the Ledger, or the rebalancer role moves to a hot keeper (a decision for you; it needs a keeper I have not built).
- **A deposit followed by `deployIdle()` and an immediate redeem of all shares returned 99.46% of the USDC and 98.77% of the WAVAX** (round-trip cost 54 bp and 123 bp): entry/exit costs of the Pharaoh position and the valuation haircut. This is not yield: depositors who leave quickly lose that much.
- **The failed transaction of an earlier rehearsal run is explained and reproduced.** It was an **out-of-gas of a transaction sent with the node's raw `eth_estimateGas` result.** The vault's `deposit` and `deployIdle` use a few percent more gas when they execute in a LATER block than at the estimate (the oracle/TWAP reads and the fee collection depend on the block time). Reproduced with the same script and raw estimates at 6 of 8 blocks tried (99,580,735 to 99,580,770) (each failure: gas used 96% to 97% of the limit, status 0, the same call succeeds with more gas); not reproduced in **12 of 12** runs with an explicit gas limit. Causal table (`explain-gas-failure.ts`, `gas-failure-explained.json`): the estimate taken now for `deployIdle` is 839,752; sent in the next block (1 s later) or 3 s, 10 s, 60 s, 600 s later with that limit it reverts every time (used 810k to 815k); with +5% it succeeds at 60 s, with +10% and +25% as well, also at 600 s. **Rule for everything that sends these transactions: explicit gas limit or a margin of at least 30% on the estimate** (`cast send` already multiplies the estimate by 1.3; ethers v5 and viem do NOT). The ceremony commands above carry explicit limits. The same applies to the frontend (frontend notes) and to any keeper that calls the vaults (the executor and the treasury keeper already add 30%).
- **The cap binds on the conservative (haircut) valuation, not on the gross deposit.** A deposit raises `totalAssets` by less than the amount deposited (entry cost), so total gross deposits can pass the nominal cap by about that cost: in the rehearsal the WAVAX vault accepted a further 5.95 WAVAX after being filled to 99.99% of its room (a 1% test was therefore not conclusive; the script now tests 3%). Plan for the cap as "about USD 200 of haircut value", i.e. up to roughly USD 201 (USDC) and USD 203 (WAVAX) of gross deposits at CAP 200 (the same +0.6% / +1.3% as the research size's USD 5,030 and USD 5,065; the entry cost is a percentage, so it scales, but it was measured at the research size).
- Not rehearsed: the R3 mint-rule fix, the real Pharaoh rewards (PHAR) and what they pay, withdrawals under a stressed pool, and the Ledger device flow.
