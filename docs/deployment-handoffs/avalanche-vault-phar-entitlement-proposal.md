# Pharaoh vaults: PHAR reward entitlement, remediation proposal

Status: PROPOSAL ONLY. Nothing here is implemented, deployed, signed or broadcast. It opens no launch gate, changes no cap and selects no launch date. The launch gates of the Pharaoh USDC vault and the Pharaoh WAVAX vault stay CLOSED.
Branch `avalanche-pharaoh-tracks-abcd`. Product names are used throughout (the track letters are unreconciled between documents). The earlier gate evidence is `docs/deployment-handoffs/avalanche-track-a-launch-gate.md` (called "the gate note" below).

Tags used: **[E]** = measured or asserted in the repo evidence (gate note, evidence logs, fork tests). **[S]** = read from the verified source on the Routescan explorer (summarised to me by a fetch tool, not read line by line by me; re-read before relying on it). **[C]** = read live from the chain through a read-only RPC call. **[R]** = my reasoning, not measured.

## 1. Summary

- **The defect is real, and larger than "bad timing".** [E][S] The vaults have no on-chain claim for depositors on PHAR at all. PHAR is pulled into the vault by the position manager whenever liquidity changes, sits outside `totalAssets()`, and the owner-only `harvestRewards` forwards the vault's entire PHAR balance to the owner Safe. Any distribution to depositors is an optional off-chain swap-and-donate batch. When the Safe does donate, the donation raises share price for whoever holds shares at that moment, so an entrant just before the donation takes his share of supply of rewards earned before he arrived, and a leaver just before it forfeits what accrued while he held.
- **The "97 to 100%" figures are a property of the test sizes, not a constant.** [E] Bob captured exactly his share of supply (97.08% in the Pharaoh USDC vault, 99.84% in the Pharaoh WAVAX vault) because the seed held by the Safe is tiny. In general the entrant captures `(his share of supply) x (rewards accrued before he joined)`. Fair is zero for pre-entry rewards. The donation amount in the tests (100 USDC, 11.69 WAVAX) is a stand-in, not a measured PHAR sale value [E].
- **Nobody is hurt today.** [C] At block 99224805 the Safe holds 100% of the shares of both vaults, `depositCap` is 1 unit, both are unpaused, and the vaults hold 0 PHAR and 0 xPHAR. So the defect is latent, and a replacement vault needs no third-party migration.
- **Recommendation:** a **replacement vault** (new proxy and implementation, not an upgrade of the live ones) whose share token carries a **reward-per-share accumulator with per-account checkpoints** (design a), where **claiming the position's pending PHAR happens inside every balance change** (the claim half of design c), and where PHAR is **never in NAV and never swapped on chain**. Depositors claim PHAR in kind. The owner-only `harvestRewards` sweep disappears.
- **Not recommended:** design b (PHAR inside NAV at an oracle price): it makes the NAV depend on a thin-market price and on a token that may be unsellable. Design c alone (swap on touch): it re-creates the defect whenever the swap fails or is skipped, and it hands every touch a sandwichable forced sale.
- Open assumptions that need fork proof before anything else: claims are continuous across gauge period boundaries; what xPHAR rewards look like (xPHAR is not freely transferable, section 6.8); how a contract holder such as a lending market is rewarded (section 6.3).

## 2. What the evidence shows, checked

| Claim | Basis | Check |
| --- | --- | --- |
| PHAR accrued before entry is claimed into the vault by the entrant's own `deposit` | [E] `testFinding_03_rewardSnipingAtEntry`: PHAR held by the vault after Bob's deposit equals `earned` at the pin (USDC vault 2,320,900,114,408,409,301 wei; WAVAX vault 821,631,199,989,894,334 wei), both logs | Consistent with [S]: the base `deposit` calls `increaseLiquidity`, and the vault has no PHAR code |
| Bob captured the donation in proportion to supply | [E] same test: 9,708 bps and 9,984 bps captured of D equal Bob's 9,708 and 9,984 bps of supply | Confirmed from both logs. Control (harvest and donate first) leaves Bob at or below his deposit (994,255,914 vs 1,000,000,000 in the USDC vault), so the assertion discriminates |
| An exiting holder gets no PHAR | [E] `testFinding_04_rewardForfeitAtExit`: Bob PHAR received 0; PHAR left in the vault grows by exactly the amount `earned` accrued during the 1-day hold (31,969,092,608,816,100 wei USDC vault; 177,181,083,534,743,929 wei WAVAX vault) | Confirmed from the logs: `pharStuck - pharAtJoin` equals the post-warp `earned` in both vaults. The "forfeited" figure (31,035,595,104,638,669 and 176,897,593,801,088,338 wei) is `(PHAR accrued) x (share of supply)`, an approximation by share of supply, not by liquidity-time |
| Nothing enforces an order | [E][S] `deposit` is permissionless; `harvestRewards(bool,uint256)` is `onlyOwner`; the base vault has no PHAR or xPHAR reference | Consistent |
| `harvestRewards` routes everything to the Safe | [S] `PharaohRewardExtension.harvestRewards`: optional `getReward(tokenId,[PHAR,XPHAR])` on the position manager, optional full `xPHAR.exit` with a caller-set minimum, then the **entire** PHAR balance (including any PHAR already held) goes to `owner()`. xPHAR is never forwarded | So depositors hold no claim; the donation in the tests is the documented but unenforced policy |
| The suite's two "FINDING" tests are green while the defect exists | [E] gate note, section 4 | These tests must be inverted, not kept (section 8) |

Limits of that evidence [E]: one day of accrual only; gauge period boundaries, emission changes and vote shifts not run; the PHAR price and the sale are not simulated (the donation is a stand-in); xPHAR reward amounts not measured; no lending-market integration run. Those limits carry into this proposal as assumptions.

Small inconsistency noticed in the test helper: `AvalancheTrackAVaultsBase.sol` has default `PIN_BLOCK = 99208619` and a comment mentioning block 99212200, while the reference runs used 99216397 and 99216312 through `TRACKA_PIN_BLOCK`. Harmless, but the next evidence run should record the pin in one place.

## 3. Can the deployed vaults be changed?

From the evidence [E][C]:

- Each vault is a TransparentUpgradeableProxy whose ERC-1967 implementation is `PharaohRewardExtension` (`0x165E1f072e7bEeDf94f14F732838354cA20bA45d`, shared by both). It delegatecalls an **immutable constant** base implementation `PharaohLiquidityVault` (`0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770`) [S]. The extension checks the base codehash only in its constructor [S].
- The proxy admins are `0x2DD4191B2944396B5853f4219E829f01636F65cf` (USDC vault) and `0x34cBbDFcbcc72e8bf70Cbf6c7245fdB2725B94dC` (WAVAX vault); `owner()` of both is the Safe `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` [C]. The Safe is 1-of-1 with the single owner `0x94696d767e65a75581145646960FA0eC886cE5d2` [C].
- So: **the deployed vaults can technically be changed**, immediately and without a timelock, by that one key (an upgrade to a new extension plus a new base). The base uses plain sequential storage ending in `uint256[40] __gap`, and the OpenZeppelin upgradeable parents use their own layout [S]. A new base would also have to override the ERC-20 `_update`, because the live base has none [S].
- The vault code cannot be fixed "in place" without changing the share token's transfer path, which is the code the whole gate evidence describes. Any upgrade invalidates the 35-test evidence for that vault and needs a fresh review and fresh evidence anyway [R].

Recommendation on this point [R]: **replacement vault, not upgrade.**
1. No third party holds shares [C], so migration moves only the Safe's own seed (about USD 30 and 1.7 WAVAX at the pin [E]). Re-verify with `totalSupply()` and `balanceOf(Safe)` immediately before the decision, because this fact is what makes replacement free.
2. An upgrade puts new, unreviewed logic behind a key that can already replace the code at any time, on live proxies whose storage layout I could not fully verify (inherited bases not read).
3. A new deployment can start with the governance and admin the operator chooses (the separate 1-of-1 finding), instead of inheriting the current ProxyAdmin.
4. Cost of replacing: new addresses (anything pointing at the old vault addresses, such as an oracle wrapper, must be repointed), a new position NFT and gauge position, and the old vaults remain deployed and closed. If the operator prefers address continuity, the in-place upgrade is available but needs a storage-layout diff, a re-initialiser, and the same tests below.

If the deployed vaults ever do gain third-party depositors before this is done, no on-chain remedy can reassign rewards already misallocated; users would have to migrate (redeem, deposit in the replacement), and the entry loss of 51 to 145 bps measured in the gate note [E] would apply to each move. That is one more reason to keep them closed.

## 4. Requirements (what the fix must guarantee)

State of the world: a position NFT held by the vault accrues PHAR continuously while in range; the position manager pays the accrued amount to the NFT owner (the vault) on `getReward` and on every `increaseLiquidity` and `decreaseLiquidity` [E][S]; shares are a plain OpenZeppelin ERC-20 with no transfer hook [S].

Invariants (R1 to R12). "Time-weighted" means by shares held over time, between syncs.

- **R1 Entry.** A holder's claim never includes rewards accrued before the block in which his balance became non-zero (or increased, for the added part).
- **R2 Exit.** A holder's claim at and after exit includes everything accrued while he held, whether he exits fully or partly, and regardless of whether PHAR can be sold, priced or even transferred at that moment.
- **R3 Conservation.** At all times `sum(claimed) + sum(claimable) + orphaned <= total PHAR received by the vault`, and the shortfall is at most the dust bound of section 6.6.
- **R4 Sync before change.** No share balance changes (mint, burn, transfer, in either direction) without the reward index being brought up to date in the same transaction first.
- **R5 Transfers.** A transfer moves no accrued entitlement; the sender keeps what he earned, the receiver starts from the current index.
- **R6 No ordering reliance.** Correctness holds for any interleaving of deposits, exits, transfers, claims and position operations, and for any harvest cadence including never.
- **R7 NAV independence.** Reward accounting never calls `totalAssets()`, any oracle or price-gated view, so the entitlement stays readable and claimable while the stress gates freeze redeem, deposit and views.
- **R8 No price assumption.** Entitlement is in reward-token units; no swap, no price.
- **R9 No operator sweep.** No owner or rebalancer function can move reward tokens that are owed to holders, or change the reward-token list.
- **R10 Fail closed on entry, never trap an exit.** If the position claim cannot be made, entry and transfers revert; exits are still possible with an explicitly bounded loss (section 6.7).
- **R11 Reentrancy.** Claim and sync are protected; state is updated before any external transfer.
- **R12 Pause.** `claim` and transfers are not pausable; pause may block deposits only.

## 5. Design comparison

| | (a) Accumulator, per-account checkpoints, separately claimable PHAR | (b) NAV includes pending PHAR at a guarded oracle price with haircut | (c) Permissionless harvest-and-swap on touch | (d) Where it lives: new vault vs changed vault |
| --- | --- | --- | --- | --- |
| Entry (R1) | Exact, by index at mint | Entrant pays for pending PHAR through NAV; fair only if the PHAR price is right | Exact only if the swap succeeds before pricing the mint | Either |
| Exit (R2) | Exact, paid in PHAR, independent of sale | Paid in asset out of position value; leaver is paid a PHAR value that nobody has realised | Exact only if the swap succeeds | Either |
| Transfers (R5) | Handled in `_update` | Nothing needed (price in NAV) but NAV is only as good as the oracle | Nothing needed, same condition | Either |
| Ordering and cadence (R6) | Independent: allocation happens at each touch for the holders of the interval | Independent in form; value moves whenever the oracle price is wrong | Independent only while the swap works | Either |
| PHAR unsellable | Irrelevant, no sale | NAV is overstated by an unrealisable asset, exits are subsidised by others (insolvency shape) | Either revert (freezes entry and exit) or skip (defect returns) | Either |
| Oracle dependence | None | Needs a PHAR price. The gate note records no PHAR price source on chain [E]; a thin-pool TWAP would be manipulable [R] | A slippage bound or oracle is needed for the sale | Either |
| Survives stress gates (R7) | Yes, if accounting does not read NAV | No, adds another condition that can freeze `totalAssets()` | No, a swap during a gate is the failing action in the gate note | Either |
| xPHAR (non-transferable, penalised exit [S]) | Needs an explicit policy (section 6.8) | Penalty makes valuation worse | Same issue | Either |
| Operator powers left | No sweep, no timing choice. Upgrade key (if any) still dominates | Operator influences oracle inputs, haircut, rebalancing | Operator sets slippage and route, can sandwich own sale | Replacement: governance chosen fresh. Change: current 1-of-1 keeps upgrade rights |
| Cost | State per account, one extra external call per balance change, ERC-20 `_update` override | Oracle plus NAV changes, new gates | Swap on every touch: gas, forced sales, MEV surface | Replacement: new addresses, nothing to migrate today. Change: storage-layout risk on live proxies |
| Verdict | **Recommended** | Reject | Reject as a standalone; its claim-on-touch step is mandatory inside (a) | **Replacement vault** |

Reasoning for the verdict [R]:
- (a) and (c) are not alternatives: (a) is the accounting, and the sync step of (a) is exactly "claim the position's pending PHAR in the same transaction" (the claim half of (c)). Without that claim, rewards that accrue in the gauge over several holders' lifetimes would all be allocated to whoever holds at the later claim, which is the present defect.
- The swap half of (c) is rejected because correctness would then depend on a market (liquidity, price, a PHAR pause), the one thing that cannot be guaranteed.
- (b) is rejected because it turns an ERC-20 accounting problem into a pricing problem: any error in the PHAR price moves value between depositors, and the vault would owe holders in asset what it only holds in an illiquid reward token.

## 6. Recommended mechanism (design a, in a replacement vault)

All of this is specification; no code exists.

### 6.1 State

- `REWARD` = PHAR, immutable. No setter. No list that an owner can extend.
- `accRewardPerShare` (scaled by `RAY = 1e27`, `Math.mulDiv`, floor).
- `accountedBalance`: PHAR balance of the vault already attributed (to the index, to the orphan bucket, or paid out).
- Per account: `rewardIndexPaid[a]`, `rewardOwed[a]` (PHAR owed but unclaimed).
- `orphanedRewards` and an immutable `ORPHAN_SINK`.

### 6.2 Sync (called at the start of every external state-changing function and by `_update`)

```
_syncRewards(bool tolerateClaimFailure) returns (bool claimFailed):
    try positionManager.getReward(tokenId, [PHAR])            // vault is the NFT owner; same call the live extension makes
    catch: if !tolerateClaimFailure revert; claimFailed = true // on failure still book whatever balance delta exists
    delta = PHAR.balanceOf(this) - accountedBalance           // includes claims made earlier by increase/decreaseLiquidity, and donations
    if delta > 0:
        if totalSupply() == 0: orphanedRewards += delta
        else:                  accRewardPerShare += mulDiv(delta, RAY, totalSupply())
        accountedBalance += delta
```

`_update(from, to, value)` (the single path for mint, burn and transfer in OpenZeppelin 5):

```
isBurn = (to == address(0))
claimFailed = _syncRewards(isBurn)           // only a burn (an exit) tolerates a failed position claim
require(!claimFailed || isBurn)              // mint and transfer fail closed; exits proceed (bounded loss, 6.7)
if from != 0: _settle(from)        // rewardOwed[from] += mulDiv(balanceOf(from), acc - paid[from], RAY); paid[from] = acc
if to   != 0: _settle(to)
require(to != address(this))       // also makes deposit(x, receiver = vault) revert
super._update(from, to, value)
```

Entry functions (`deposit`, `deployIdle`, `rebalance`) call `_syncRewards(false)`; exit functions call `_syncRewards(true)`. This is what makes R10 true: without the try/catch a burn would revert whenever the position manager reverts, and every exit would be trapped.

`claim(to)` (holder only): sync, settle `msg.sender`, `amount = rewardOwed`, zero it, `accountedBalance -= amount`, `safeTransfer(to, amount)`; `nonReentrant`.

`pendingReward(a)` view: `owed + balance * (acc - paid) / RAY` plus an optional estimate from the position's `earned` for rewards not yet claimed. It reads no NAV.

Functions that change liquidity or the NFT (`deposit`, `withdraw`, `redeem`, `redeemInKind`, `deployIdle`, `rebalance`, `emergencyExit`) call `_syncRewards()` first. This is redundant for share-balance changes (which sync in `_update`) but is needed so that `rebalance` and `emergencyExit`, which burn the NFT, never destroy accrued rewards before they are booked.

### 6.3 Why it is correct (R1, R2, R4, R5, R6) [R]

- Balances change only inside `_update`, and `_update` first books every reward received so far to the holders of the interval that just ended. So the holders of any interval are exactly the accounts that receive its rewards, in proportion to shares held. There is nothing to order, no cadence, and no harvest function to wait for.
- Claim before allocation matters: rewards still unclaimed in the gauge would be allocated at a later sync to later holders. The explicit `getReward` closes that gap. A claim made by anyone else, or by `increaseLiquidity`, only moves PHAR into the vault earlier; the delta is still booked at the next sync, before any balance change.
- Entry: a minted account is settled at the current index before it receives shares, so its history is zero. Exit: the leaver is settled at the current index before the burn, so the accrued part is in `rewardOwed`, and claiming does not depend on any later vault state.
- Transfer: both parties are settled before the move, so the sender keeps what accrued, the receiver starts at the current index. Self-transfer settles one account twice with the same index (no change). Transfer to the vault address reverts, so a vault-owned balance can never accrue stuck entitlement. A zero-balance receiver settles to zero. Mint and burn go through the same two settle lines.
- ERC-4626 `withdraw` and `redeem` on behalf of an owner burn the owner's shares, so the owner (not the receiver, not the caller) is settled. Rewards belong to the share owner of record.
- Weighting: rewards are allocated per share, while the gauge pays per unit of liquidity. Idle assets, the entry haircut and fee compounding make shares and liquidity-seconds differ slightly (of the order of the 51 to 145 bps entry loss measured in the gate note [E]). This is a bounded approximation that favours long-term holders and cannot be exploited to move more than that gap [R]; it is a known residual (section 9), and the fork test compares the accumulator with the gauge's own number within a stated tolerance.

### 6.4 Shares held in other protocols (R5 for contract holders) [R]

The vault knows only the holder of record. A contract that holds shares (a router, an aggregator, a lending market's pToken, a Safe) earns the entitlement for that contract. It receives PHAR only by calling `claim`, and whatever it does with it is its own accounting.

- A wrapper or router that holds shares briefly in the middle of one transaction gets zero, because the interval is empty. One that holds shares between transactions owns the entitlement.
- **Lending collateral:** if Peridot markets accept these shares as collateral, the pToken contract is the holder, the vault cannot attribute per borrower, and a seizure inside the pToken does not move vault shares at all. Without a pass-through built on the market side, the PHAR earned by collateral shares is owned by the market, not by the borrower. This is a product decision, and the lending integration is not in the evidence [E]. Until it is decided, the safest rule is: **do not list these shares as collateral.** Alternatives for later: a market-level reward ledger fed by `claim`; or a reward-recipient delegation (`setRewardRecipient`) that a contract holder sets once.
- Delegation or a transfer of an NFT-like receipt does not exist for this ERC-20; none is proposed.

### 6.5 Zero supply (reward received while `totalSupply() == 0`)

The delta goes to `orphanedRewards`, not to the next depositor, because giving it to the first depositor would reopen entry sniping at the moment of re-seeding. `sweepOrphans()` is permissionless and pays the immutable `ORPHAN_SINK`. A permanent minimum supply would make this unreachable, but dead shares then accrue entitlement of their own, so the orphan rule is still needed. This keeps the operator out of the loop (R9).

### 6.6 Rounding, decimals, dust

- Shares have the asset's decimals: 6 for the USDC vault, 18 for the WAVAX vault [C]; PHAR has 18 [C]. `RAY = 1e27` with `Math.mulDiv`. Every conversion rounds **down** (index increase, per-account accrual), so the vault never owes more than it received.
- Dust bound: the index floor strands less than `totalSupply / RAY + 1` PHAR wei per sync, and each settle strands under 1 wei. The tests assert `received - (claimed + claimable + orphaned) <= nSyncs * (totalSupply/RAY + 1) + nAccounts`. Stranded dust simply stays in the vault; it is not added to anything.
- Sums are computed in `mulDiv` so no overflow for realistic supply (up to 1e30 shares) and reward amounts.
- Rewards that are donated (a direct PHAR transfer) are indistinguishable from claims and are allocated to the holders of the interval that ended at the next sync. A donor gains nothing from this (it is a gift) and an entrant after the donation is not entitled to it, because the sync precedes his mint.

### 6.7 Failure handling, frozen gates, pausing (R7, R10, R12)

- `_syncRewards` and `claim` read no NAV, no TWAP and no oracle. In the gate note the stress gates revert `deposit`, `redeem` and the views (`totalAssets`, `maxWithdraw`, `convertToAssets`); `redeemInKind` is the only exit that survives [E]. Under this design all of `claim`, `pendingReward`, ERC-20 transfers and the settle inside `redeemInKind` keep working. During a freeze the entitlement keeps accruing to the holders of record (an out-of-range position accrues zero, measured as 0 PHAR per hour in the gate note [E], so nothing is owed for that period either).
- If the position's `getReward` reverts: `deposit`, `deployIdle`, `rebalance` and any transfer revert (fail closed, no value moves because of a skipped claim). Exits (`withdraw`, `redeem`, `redeemInKind`) still run. For an exit with a failed claim, the leaver's rewards since the last successful sync cannot be booked, and are later allocated to the holders then, so the loss is bounded by one sync interval and only exists for that case; see the open question on whether to instead block exits. A fork test injects the failure to show the bound.
- If PHAR itself cannot be transferred (pause, blocklist), `claim` reverts and nothing else is affected: exits never call `PHAR.transfer`. The entitlement stays recorded in `rewardOwed` and is claimable later.
- `claim` and transfers are never pausable (R12). Pausing may stop `deposit`/`deployIdle`/`rebalance`, as today [S].
- Reentrancy: `deposit`, `withdraw`, `redeem`, `redeemInKind`, `claim`, `sync` use one shared `nonReentrant`. `claim` zeroes `rewardOwed` and lowers `accountedBalance` before it transfers. The position manager is a trusted contract. The lock covers the vault entry points, but a plain ERC-20 `transfer`/`transferFrom` reaches `_update` and therefore `getReward` without it, so the transfer path must also be `nonReentrant` (or `_update` must be written so no state a re-entrant call could exploit is written after the external call: settle first, then `super._update`). The proposal requires the former. Reward token is fixed, so no hook-bearing token can be added later.

### 6.8 xPHAR

[S] xPHAR is not transferable between ordinary addresses (the check allows only exempt senders or recipients, set by governance), and `exit(amount)` converts instantly with a 50% penalty. The live extension requests `[PHAR, XPHAR]` from the position manager, forwards only PHAR and keeps xPHAR in the vault; `harvestRewards` can optionally exit all of it with an owner-chosen minimum. [C] Both vaults hold 0 xPHAR now, and [E] no xPHAR amount was measured in any test. I could not establish whether the position manager ever pays xPHAR for these positions.

Proposal: for the replacement vault, request only PHAR if that is possible; otherwise treat xPHAR as an operator decision in section 10 (options: not claimed; or converted inside the sync with a fixed documented loss and the PHAR delta credited to the index; or a governance whitelist so claims can be paid in xPHAR). Not decided here.

### 6.9 What a compromised or malicious operator can still do

| | Today's vaults | Recommended design (a) | (b) | (c) |
| --- | --- | --- | --- | --- |
| Take all PHAR | Yes, `harvestRewards` sends it to the owner | No function exists (R9) | Yes through any sale path the operator controls | Only through route and slippage parameters |
| Choose harvest timing to favour an insider (deposit, then donate) | Yes | Irrelevant, no harvest | Via oracle and rebalance timing | Via the order of touches |
| Withhold or redirect distribution | Yes, the donation is discretionary | No | Partly | No |
| Skip a sync | n/a | No, sync is inside `_update` | n/a | n/a |
| Stop accrual | Yes: `rebalance`, `emergencyExit`, leaving the position out of range [E] | Yes (liveness and future accrual, not accrued entitlement, which is already booked before the NFT is burned) | Same | Same |
| Upgrade the code | Yes, immediately [C][E] | Depends on the replacement's admin design, which this document does not decide. A 1-of-1 upgrade key defeats every reward invariant, so this is the finding in section 9 | Same | Same |

## 7. Why not the other designs, in more detail [R]

- **(b)** needs a PHAR price. The gate note records no PHAR price source and treats the sale as an off-chain Safe batch [E]. NAV would include an asset that exits cannot pay in; the share price would move with a thin-market price an attacker can push; and it adds another condition that can freeze `totalAssets()`, which already freezes in the stress cases [E]. If PHAR cannot be swapped, its value in NAV is a fiction and early leavers are paid by later ones.
- **(c)** swap-on-touch gives anyone the ability to choose the time of a forced sale (a dust deposit triggers it), to sandwich it (the swap needs a bound that someone sets), and it freezes entry and exit whenever the swap fails, or it silently skips and the defect returns. Gas on every touch.
- **(a) without the claim** fails because accrued rewards sit in the gauge until someone claims, and are then allocated to the holders of that moment.

## 8. Tests required before any gate could reopen

These are necessary conditions, not a sufficient set: a third-party review of the replacement vault and of the fixed 1-of-1 / liquidity findings are separate prerequisites. The existing `testFinding_03` and `testFinding_04` assert the unfavourable behaviour; for the replacement vault they are replaced by the tests below (the old ones remain as evidence of the old vaults). "Dust" means the bound in section 6.6. Unit and fuzz tests use a mock position manager that accrues a controlled amount per second to the NFT owner, pays on `getReward`, `increaseLiquidity` and `decreaseLiquidity`, and can be made to revert; fork tests reuse `AvalancheTrackAVaultsBase` at a recent pin.

Unit and fuzz (Foundry):

1. `test_entrantBeforeHarvest_getsZero`: A holds 100%; R PHAR accrues; B deposits; time passes; assert `claimable(B) <= dust` for the R accrued before B, and `claimable(A) >= R - dust`.
2. `test_longTermHolder_getsAll`: one holder, k syncs through donations and warps; assert `claimed == received - dust`.
3. `test_transferThenHarvest_conservation`: A transfers to B (fractions 0, 1/2, all), more PHAR arrives; assert `claimable(A) == earned while held`, `claimable(B) == earned after`, and the sum equals received minus dust.
4. `testFuzz_sumOfClaimsLeReceived`: random sequences of deposit, redeem, transfer, warp, donate, claim over 2 to 6 accounts; assert after every step `claimed + claimable + orphaned <= received` and `received - that <= dustBound`.
5. `test_exitAllThenClaim`: everyone redeems fully; assert every `claim` still pays exactly what was booked, and later PHAR arriving goes to `orphanedRewards`, not to a later depositor.
6. `test_partialExit_keepsAccrued`: B redeems 1/2; assert B's claimable at exit equals the pro-rata accrual and B's remaining half keeps accruing.
7. `test_zeroSupplyDonation`: supply 0; PHAR transferred in; a new depositor joins; assert `claimable(newDepositor) == 0` and the amount is in `orphanedRewards`; `sweepOrphans` pays only the sink.
8. `testFuzz_harvestSkippedNBlocks`: N in 0 to 1e6 blocks, with no position operation by anyone except one deposit and one redeem by different users; assert allocation equals the time-weighted expectation within dust.
9. `test_sandwichAroundSync`: attacker deposits just before a sync trigger, triggers a claim (including a direct third-party claim and a PHAR donation), withdraws in the same block and then a block later; assert the attacker's total claim is 0 (same block) or his time-weighted amount (later).
10. `test_transferEdges`: self-transfer leaves all owed/index values unchanged; transfer to the vault address reverts; transfer to a zero-balance account starts that account at the current index; mint and burn settle the right account; ERC-4626 `redeem` with an allowance settles the owner, not the caller.
11. `test_contractHolder`: shares held by a mock lending pToken and by a router; assert the contract owns the entitlement, claims it, and the borrower does not.
12. `test_donatedPharAllocatedToHolders`: PHAR transferred straight to the vault is allocated to the holders at the donation's sync and not to a later entrant.
13. `test_rewardTokenTransferReverts_exitStillWorks`: make `PHAR.transfer` revert; `redeem`, `withdraw`, `redeemInKind` and transfers succeed, `claim` reverts, `rewardOwed` unchanged; after un-reverting, `claim` pays in full.
14. `test_syncFailure`: make `getReward` revert; assert `deposit`, `deployIdle`, `rebalance` and transfers revert, exits succeed, and the loss to the leaver is below the accrual since the last successful sync (assert the bound, not zero).
15. `test_frozenGates_entitlementReadable`: make `totalAssets()` revert (price gate); `claim`, `pendingReward`, transfers and `redeemInKind` still work and give the same numbers as before the freeze.
16. `test_reentrancy_claim`: a receiver or token hook that re-enters `claim`, `deposit`, `redeem`; assert reverts and no double payment.
17. `testFuzz_rounding_decimals`: share supply from 1 to 1e30, shares with 6 and 18 decimals, PHAR amounts from 1 wei to 1e24; assert no revert on `mulDiv`, rounding always down, and the dust bound.
18. `invariant_*` (stateful, Foundry invariant suite): R3 conservation; "no balance changes without sync"; `accRewardPerShare` monotone non-decreasing; `accountedBalance <= PHAR.balanceOf(vault)`.

Fork (Avalanche, same harness as the gate suite, once per replacement vault):

19. `testFork_entrantBeforeHarvest`: the setup of `testFinding_03` (PHAR accrued at the pin, Bob deposits, 100-unit donation optional). Assert `claimable(Bob) <= dust` for rewards accrued before his deposit, and `claimable(Safe seed) >= earnedAtPin - dust`. Add a control: donation before Bob.
20. `testFork_exitKeepsAccrued`: the setup of `testFinding_04` (1 day). Assert Bob's claim equals `earnedHeld x share-of-supply` within the stated weighting tolerance (compare the accumulator with the gauge's `earned` over the same period; start with 1%, then tighten from measurement), and that the vault's PHAR balance minus claims is dust.
21. `testFork_gaugePeriodBoundary`: warp across a gauge epoch boundary with an entrant before it and a leaver after it; assert allocation stays time-weighted. This tests the assumption in section 6.3 and decides whether it holds.
22. `testFork_rebalanceAndEmergencyExit`: a `rebalance` (NFT burned and re-minted with a new id) and an `emergencyExit` keep the booked entitlement; pending PHAR is not lost with the burn.
23. `testFork_outOfRange`: an out-of-range position accrues zero, the entitlement is unchanged, `claim` works.
24. `testFork_stressGateFreeze`: reuse the dislocation case of the gate suite (`test_09`): ERC-4626 views revert, `claim`/transfer/`redeemInKind` work.
25. `testFork_xPharPath`: measure whether the position manager pays xPHAR for this position; if so, test the chosen policy (section 6.8) including the 50% exit loss.
26. `testFork_unsellablePhar`: no PHAR swap path exists anywhere in the test; everything above still passes (this is the "cannot be sold" requirement).

Pass criteria: all of the above green on a fresh pin; at least one mutation per core test (remove the pre-mint settle, remove the pre-claim, round up) and the test must fail; the evidence note records block, hash, commands and logs as the gate note does.

## 9. What this proposal does NOT do

- It opens no gate, changes no cap, selects no launch date. The gates of both vaults stay CLOSED. No transaction was sent.
- It does not fix, and does not claim to fix, these separate open findings from the gate note [E]: (1) thin USDC/USDt exit liquidity (the USDC vault cannot take a USD 10,000 deposit in one transaction or return a whole USD 1,000 position in one redeem); (2) the stress gates freezing `redeem`, `deposit` and the views (design a only keeps entitlement readable and claimable during a freeze, it does not unfreeze exits); (3) 1-of-1 Safe control, with the single signer being the rebalancer EOA, and an immediate-upgrade proxy admin; (4) donation griefing, entry haircut and out-of-range behaviour; (5) the missing net-return figure and third-party audit.
- It does not decide governance of the replacement vault, the xPHAR policy, the sink address, or the lending-collateral policy; those are in section 10.
- Residual risks of the recommended design [R]: every share transfer, mint and burn now makes an external `getReward` call (gas and a UX cost on a plain ERC-20 transfer, and a new external dependency on the transfer path); share-weighted rather than liquidity-weighted allocation (small, bounded); an upgrade key can still overrule everything; a failed position claim is handled by revert (entry) or by a bounded loss (exit); PHAR price risk moves from the vault to holders (they receive PHAR, not compounded USDC or WAVAX); correctness depends on the position manager paying all accrued rewards at `getReward` without lag across period boundaries (unproven, test 21).

## 10. Open questions for the operator

1. Replacement vault, or upgrade in place (section 3)? Confirm no third-party shares exist right before deciding.
2. xPHAR: not requested, converted at a fixed 50% loss, or governance whitelisting? Does the position manager pay xPHAR for these positions?
3. Orphan sink address, and whether a permanent dead-share seed is wanted.
4. On a failed position claim, should exits also revert (strict fairness, risk of an exit freeze) or proceed with a bounded loss (as proposed)?
5. Lending: will vault shares ever be listed as collateral? If yes, who owns the PHAR earned by market-held shares?
6. Do holders accept receiving PHAR in kind instead of compounding? If a compounding option is wanted, it should be an opt-in, holder-triggered convert, not an operator batch.
7. What governance and admin does the replacement vault get (this document assumes it is not today's 1-of-1 upgrade key and does not choose)?
8. Who writes the replacement code and who reviews it? None of that is done here.

## 11. What I inspected and what I could not

- Repo files read: the gate note; `contracts/test/AvalancheTrackAVaultsFork.t.sol` (lines 1 to 700, covering `testFinding_03` and `testFinding_04`); `contracts/test/helpers/AvalancheTrackAVaultsBase.sol` (all); the first 150 lines of the USDC suite log and 60 lines of the WAVAX suite log (including both finding tests and test_00).
- **The vault source is not in this repository** (a search of the repo for `PharaohLiquidityVault` finds only the test helper and the gate note). I read the verified source of `PharaohLiquidityVault` (`0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770`), `PharaohRewardExtension` (`0x165E1f072e7bEeDf94f14F732838354cA20bA45d`) and xPHAR (`0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A`) through the Routescan API for chain 43114, with the addresses copied from `AvalancheTrackAVaultsBase.sol` (`BASE_IMPL`, `EXT_IMPL`, `XPHAR`). A fetch tool summarised those pages; the first 100,000 of about 246,000 characters (base) and 179,000 (xPHAR) were covered, which contained the vault's own code, not the inherited OpenZeppelin or the Pharaoh libraries. I did not read the source line by line, so every [S] item needs a second reading before it is relied on.
- Live reads (RPC `https://api.avax.network/ext/bc/C/rpc`, block 99224805, read-only `cast call` / `cast storage`): vault `totalSupply`, `balanceOf(Safe)`, `paused`, `depositCap`, ERC-1967 implementation and admin slots, PHAR and xPHAR balances of the vaults, Safe threshold and owners, ProxyAdmin owners, decimals. Vault addresses: `0x855bF832f26a294d28500db59eE941dE3d654129` and `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8`, from the same helper.
- Not verified: the position manager's `getReward`, `earned`, and gauge period semantics (the evidence shows continuous accrual over one day only); whether xPHAR is ever paid; the upgrade path in practice (no simulation of an upgrade); the lending-market side; the storage layout of the inherited bases; any code of the replacement vault (none exists). I ran no tests, built nothing, and edited no contract, test or file under `docs/handoffs/`.
