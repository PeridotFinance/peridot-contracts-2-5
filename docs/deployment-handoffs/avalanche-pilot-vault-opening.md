# Avalanche Pharaoh vaults: opening at a USD 5,000 deposit cap each (target 12 Nov)

Status: **PREPARED, NOT EXECUTED.** Two Safe transactions, signed by the Ledger (the Safe's only owner, threshold 1). The assistant signs and sends nothing. Rehearsed on a local fork of the current mainnet head with the Ledger impersonated (`operator/scripts/rehearse-vault-opening.ts`, report `avalanche-cash-only-operator-evidence/vault-opening-rehearsal.json`). No vault code is changed by this step; the R3 mint-rule fix (13 to 15 Nov) is a separate upgrade.

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
- USDC vault: **USD 5,000 = `5000000000`** (6 decimals).
- WAVAX vault: the cap is in WAVAX units, so its dollar value moves with the price. Proposal **595 WAVAX = `595000000000000000000`**, USD 4,977 at AVAX = USD 8.365 today; at USD 10 it would be USD 5,950. Tell me the number you accept; I recompute the calldata.
- **The frontend is password-gated but the contracts are public: any address can call `deposit` on the vaults directly. The deposit cap is therefore the real limit, not the password.** The cap counts the whole vault (`totalAssets`), first come first served.

## 3. The two transactions (Ledger; Safe `execTransaction`, caller = the owner)
The owner may call `execTransaction` itself with the "approved by msg.sender" signature (65 bytes: the owner's address left-padded to 32 bytes, 32 zero bytes, `01`). One Ledger confirmation per transaction, no typed-data signing:
```
export ETH_RPC_URL="$AVALANCHE_MAINNET_RPC_URL"
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD ; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12
SIG=0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001
Z=0x0000000000000000000000000000000000000000
# 1. USDC vault: setDepositCap(5000000000)
cast send $SAFE 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
  0x855bF832f26a294d28500db59eE941dE3d654129 0 0x86651203000000000000000000000000000000000000000000000000000000012a05f200 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER
# 2. WAVAX vault: setDepositCap(595e18)
cast send $SAFE 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' \
  0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8 0 0x866512030000000000000000000000000000000000000000000000204148a38e0d6c0000 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER
```
(`0x86651203` is the selector of `setDepositCap(uint256)`; the Safe's own calldata was produced by the rehearsal script from exactly these arguments.) Gas: 74k each.

**Read-backs (read-only):** `cast call 0x855b...4129 'depositCap()(uint256)'` = `5000000000`; `cast call 0xe9a5...90E8 'depositCap()(uint256)'` = `595000000000000000000`; `cast call $SAFE 'nonce()(uint256)'` = 14 (12 now, +1 per transaction); `cast call <vault> 'maxDeposit(address)(uint256)' <any address>` = cap minus `totalAssets` (about 4,970.16 USDC and 593.26 WAVAX).

**Close again** (same form, argument `1`): `setDepositCap(1)` = calldata `0x866512030000000000000000000000000000000000000000000000000000000000000001`. Pause: `pause()` from the Safe (owner).

## 4. What the rehearsal showed (fork at the live head)
- Both transactions succeed and the read-backs match; the Safe nonce goes 12 -> 13 -> 14.
- A depositor can deposit up to the cap and **one deposit more than the cap is refused** on both vaults.
- **`maxDeposit()` can overstate the room by a few units** (it returned 3 units of USDC more than the cap check accepted): a frontend must not build a transaction from `maxDeposit` to the last unit.
- **Idle assets earn nothing until the rebalancer calls `deployIdle()`.** The rebalancer is the Ledger. The rehearsal called it as the Ledger and it succeeded on both vaults. **No automated deployer exists today**: someone must send `deployIdle()` (and `rebalance()` when the position leaves range) from the rebalancer key. Options: you send them from the Ledger, or the rebalancer role moves to a hot keeper (a decision for you; it needs a keeper I have not built).
- **A deposit followed by `deployIdle()` and an immediate redeem of all shares returned 99.46% of the USDC and 98.77% of the WAVAX** (round-trip cost 54 bp and 123 bp): entry/exit costs of the Pharaoh position and the valuation haircut. This is not yield: depositors who leave quickly lose that much.
- On one of four rehearsal runs a transaction failed at that block (the diagnostics for it were added afterwards, so the cause is unconfirmed; the vault has price and oracle deviation guards that revert deposits and withdrawals when the pool is away from its TWAP). Treat a reverting deposit as the guard working, not as a cap problem.
- Not rehearsed: the R3 mint-rule fix, the real Pharaoh rewards (PHAR) and what they pay, withdrawals under a stressed pool, and the Ledger device flow.
