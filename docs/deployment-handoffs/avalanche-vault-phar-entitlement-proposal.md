# Pharaoh vaults: PHAR reward entitlement, remediation proposal (second draft)

**VERDICT: NOT IMPLEMENTATION-READY.** The attribution mechanism in section 5 is specified and checked against a reference model (section 9), and every claim about the Pharaoh contracts below is read from source or from the chain. What blocks implementation is a short list, none of it code:

1. **Window policy (product decision, section 6).** Pharaoh's gauge slashes every reward claim made within `timeThresholdForGauge` (111 s today) of the position's last liquidity change, and a slash forfeits *all unclaimed accrual*, not 111 s of it (probes P2, P8, P9). The vault can only avoid that by refusing liquidity-changing operations inside the window. That makes deposits, liquidity-removing exits, `redeemInKind` and `emergencyExit` revert for up to 111 s after each liquidity change, and a cheap dust operation can reopen the window. Operator must choose between W1 (revert, recommended default), W2 (proceed and accept forfeiture, rejected here) and W3 (idle-hold, scheduled deployment). Until chosen, the entry and exit flows cannot be written.
2. **Pharaoh governance dependency (section 4, U1).** The validator, its blacklist, the 111 s threshold, `xRatio` and the gauge implementation are all changeable by Pharaoh governance at any time. Accept it as a stated residual risk, or negotiate; the vault cannot remove it. Consequence stated bluntly: under rule B as written (forced recovery never forfeits) `emergencyExit` has no override, so if Pharaoh sets the threshold to a year, `emergencyExit` cannot remove liquidity for a year, and the only principal-protection tool left is `pause`, which blocks deposits only. The operator must either accept that or relax B for `emergencyExit` specifically (for example: allow it inside the window and record the forfeiture as a stated external loss).
3. **Operator confirmations (section 10):** release rule for the unattributed, waived and donated buckets (default: none exists); whether the waiver function exists at all and where waived amounts go; xPHAR disposition; claims only for *finalised* periods (a holder can wait up to one week plus the next successful harvest); behaviour when the pool's time source cannot be read; replacement vault versus upgrade; no lending-collateral listing.
4. **Engineering not yet bounded:** the per-account settlement loop over weeks since last touch has no gas measurement (no Solidity exists); the unit mocks must reproduce the gauge's `S * T / (WEEK << 96)` formula (probe P7 gives the oracle).

Gates stay CLOSED. This document opens no gate, proposes no cap and no launch date, and nothing in it was deployed, signed or broadcast. Branch `avalanche-pharaoh-tracks-abcd`. Product names throughout (track letters are unreconciled). Companion file with every address, proxy slot, code hash, compiler, file name, sha256 and the resolved/unresolved list: `docs/deployment-handoffs/avalanche-vault-source-references.md` ("the references file"). Earlier gate evidence: `docs/deployment-handoffs/avalanche-track-a-launch-gate.md` ("the gate note").

Basis tags: **[E]** repo evidence; **[S]** source I saved and read (file and line, references file section 3); **[C]** read-only chain read (block stated); **[P]** my local-fork probe P1 to P9 (references file section 6, 9 passed, scratch project outside the repo); **[M]** reference model result (section 9); **[R]** reasoning, not measured.

## 1. What changed from the first draft

Operator corrections:

- **A. No automatic forfeiture on claim failure.** The first draft let exits proceed with a "bounded loss" when the position claim failed (old R10, 6.7). Removed. In this draft recording *who held shares when* is independent of whether any reward call works. A claim that cannot be made leaves the interval recorded and **quarantined**: not attributed to others, not swept, not forfeited, and settled by the recorded history of that interval once a later harvest succeeds (section 5.6). An exited holder's entitlement to what accrued up to exit is preserved and stays claimable.
- **B. Waiver only under an explicit policy; forced paths can never forfeit.** Section 7: a waiver is an on-chain, per-account, holder-only, irrevocable action, never available to the operator; emergency exit, in-kind recovery, stress gates, rebalance and pause cannot reduce any entitlement.
- **C. No orphan sweep of delayed rewards.** The first draft's `orphanedRewards` plus permissionless `sweepOrphans()` is gone. Section 5.7 defines exactly which case is attributed (always, including late and delayed rewards), which goes to a separately accounted bucket, and the release rule (default: none).
- **D. Required named tests**, with exact numbers from the reference model: section 8.

Findings from reading the source and probing, which changed the design more than A to D:

- **Claim-on-every-touch is harmful, not just risky.** The first draft's core (sync inside every `_update`, calling `getReward`) is replaced. Pharaoh's `RewardValidator` slashes any claim within 111 s of the position's last `lastModified`, and the gauge then forfeits **all** unclaimed accrual of that position to r33 (P2, P8: a slashed claim 80 s after a change straddling a weekly boundary forfeited the whole old-period balance), and a Pharaoh-blacklisted `tx.origin` makes the vault's own auto-claim forfeit the **entire backlog** (P9: 2,320,900,114,408,409,301 wei at the pin). The new design **records exposure on every touch (read only) and claims only outside the window**.
- **Never burn the NFT.** `positionManager.burn` succeeds with rewards outstanding and nothing can claim afterwards (P5, position manager 468 to 473). The live base burns in `_freeLiquidity` (whole-vault exit) and `_exitPosition` (rebalance, emergency exit) [S]. The first draft's test 22 ("pending PHAR is not lost with the burn") is wrong and is replaced.
- **"Both reward calls failing" is one call.** The live path is a single `getReward(tokenId, [PHAR, XPHAR])` [S, EXT line 68]. Section 8, test D2 defines the failure modes.
- **Late rewards are real but confined.** `notifyRewardAmount` pays retroactively for in-range seconds already elapsed in the *current* period (P4); there are no past-period notifies (`notifyRewardAmountForPeriod` requires a future period, GaugeV3 line 236). A period's funding is final once the period ended and one successful claim happened after it.
- Resolved from the first draft's open assumptions: claims are continuous across period boundaries (P3, to the wei); `earned` equals the claim (P1, P7); `xRatio` is 0 so the vault receives PHAR only today, and xPHAR cannot be handed to holders (P6).
- Corrected from the first draft: the "[S] summarised by a fetch tool" caveat is gone (all sources saved and read, two verifiers agree byte for byte for six of the contracts); old test 21 is resolved by P3; the protocol-level claim that a burned NFT keeps its pending PHAR was false.
- **Kept from the first draft:** the replacement-vault recommendation (section 2), the design comparison against NAV-priced PHAR and swap-on-touch (section 3), the gate-note evidence table (trimmed), tests 1 to 6, 8 to 13, 15 to 20, 23 to 26 with edits (section 8.3).

## 2. The defect, what is measured, can the deployed vaults be changed

Corrected evidence table (unchanged results from the gate note [E], with the source reading added):

| Claim | Basis | Check |
| --- | --- | --- |
| PHAR accrued before a deposit is pulled into the vault by the depositor's own `deposit` | [E] `testFinding_03_rewardSnipingAtEntry` (vault PHAR after Bob's deposit = `earned` at the pin: 2,320,900,114,408,409,301 wei USDC vault; 821,631,199,989,894,334 wei WAVAX vault) | [S] `deposit` -> `_deployIdle` -> `increaseLiquidity` -> `_tryClaimRewards` (position manager 254). [C]/[P] both `earned` values reproduce exactly at the pins |
| Bob captured the donation in proportion to supply (9,708 and 9,984 bps) | [E] same test | Unchanged. Fair share of pre-entry rewards is zero |
| An exiting holder gets no PHAR | [E] `testFinding_04_rewardForfeitAtExit` | [S] no code path pays a holder PHAR: the only reward code is the Safe-only `harvestRewards` (EXT 55 to 88) |
| `harvestRewards` routes everything to the Safe | [S] EXT lines 85 to 86 | Depositors hold no claim; the donation in the tests is an unenforced policy |
| Rewards are lost when the NFT is burned with an unclaimed or slashed balance | [S] base 599 and 616; [P] P5 | New finding |
| One touch by a blacklisted origin, or two liquidity changes within 111 s, forfeits the unclaimed accrual | [P] P2, P8, P9 | New finding. Latent today (cap is 1 unit, Safe holds all shares [C]) |

Nobody is hurt today [C]: the Safe holds 100% of both vaults, `depositCap` is 1, vaults hold 0 PHAR and 0 xPHAR, but the backlog is large relative to a normal cadence: 2,320,900,114,408,409,301 wei unclaimed since period 2954 (11 periods) in the USDC vault, because the last liquidity change was 77 days before the pin [C].

**Can the deployed vaults be changed?** Yes, immediately, by one key. The vault proxies are TransparentUpgradeableProxies whose implementation is `PharaohRewardExtension` (shared), delegating to the immutable base. Both ProxyAdmins are owned by the Safe `0x80f4...fB12`, 1-of-1 with the single owner equal to the rebalancer EOA (`0x9469...e5d2`) [C]. The proxies were upgraded **four times in about 12 days** (blocks 92070793, 92556750, 92634831, 93019580) with no timelock [C]. No vault function changes the share token, name, symbol, asset or transfer behaviour [S: no `_update` override; storage is ERC-7201 namespaced]. Only an upgrade can. The base uses sequential storage ending in `uint256[40] __gap` [S 816].

Recommendation, unchanged: **replacement vault (new proxies, new implementation, new NFT), not an upgrade.** (1) No third party holds shares [C], so there is nothing to migrate but the Safe's own seed; re-verify `totalSupply()` and `balanceOf(Safe)` immediately before the decision. (2) An in-place upgrade needs a storage-layout diff, a re-initialiser and new review anyway, behind a key that can already replace the code. (3) A new deployment can choose its own admin. (4) Cost: new addresses, new NFT, old vaults stay deployed and closed. If the operator prefers address continuity the in-place route exists but needs the same tests.

## 3. Design comparison (kept, shortened)

| | (a) Period exposure ledger, rewards in kind (this proposal) | (b) PHAR priced into NAV | (c) Swap on touch |
| --- | --- | --- | --- |
| Attribution | exact by share-time, independent of claim timing | by oracle price; errors move value between holders | exact only if the swap succeeds |
| Needs a PHAR price or a sale | no | yes (none on chain [E]) | yes |
| Works while PHAR/xPHAR cannot be sold | yes | NAV overstated | freezes or skips |
| Survives stress gates (reads no NAV) | yes | no | no |
| Operator can sweep | no | via sale path | via route and slippage |
| Verdict | **recommended** | reject | reject |

Reasoning [R]: (b) turns an accounting problem into a pricing problem. (c) puts a forced, sandwichable sale on every touch. Neither removes the need to know *who held when*, which is what (a) records.

## 4. Verified facts about the Pharaoh reward plumbing

All numbers are for the Pharaoh USDC vault at block 99216397 unless stated. Detail, lines and hashes: references file.

| Fact | Basis |
| --- | --- |
| Rewards are per weekly period (`block.timestamp / 1 weeks`, GaugeV3 line 26, pool 764). A position's reward for period `p` is `tokenTotalSupplyByPeriod[p][token] * T / (WEEK << 96)` minus what was claimed, where `T` is the pool's `positionPeriodSecondsInRange` (GaugeV3 352 to 359). It accrues continuously while in range, and `earned` grows within the period | [S] and [P] P7: the formula, computed from the pool's own view, equals `earned` to the wei (2,320,900,114,408,409,301) |
| The amount for the *current* period can increase after the fact: `notifyRewardAmount` (permissionless for whitelisted tokens, GaugeV3 199 to 215) and the permissionless `Voter.distribute` add to the current period's total, and pay for **all in-range seconds of the period so far**. Delayed or catch-up emissions are notified into the *current* period (`Voter._distribute` 560 to 569, `distribute` 826 to 831) | [P] P4: a 1,000 PHAR notification 100,000 s after the vault's last claim raised `earned` by 23,792,616,857,857,937,937 wei, of which 23,459,092,025,127,617,000 wei is for seconds before that claim. [C] NotifyReward logs for the USDC gauge, periods 2960 to 2965: seconds into the period 62, 1801, 62, 23, 22, 8, so lateness is rare and bounded to one week |
| Only the NFT owner or approved account can trigger a claim | [S][P] P1 |
| Claims are continuous across period boundaries | [P] P3 (to the wei) |
| `earned` equals what `getReward` pays, except slashing and an un-advanced new period | [P] P1, [S] section (iii) of the references file |
| Anti-sybil slash: the validator returns "slash" if `now - positionLastModified <= timeThresholdForGauge` (111 s [C]), or if the owner, receiver, `tx.origin` or position hash is blacklisted, or if the validator reverts (fail closed) | [S] RewardValidator 154 to 193, GaugeV3 535 to 551 |
| A slashed claim returns normally, pays zero, records a forfeit, and forfeits **every earlier period's unpaid amount in full** plus the current period's unpaid amount; the forfeited tokens go to r33 on the next successful claim | [S] GaugeV3 459 to 463, 468 to 489, 553 to 583; [P] P2, P8, P9 |
| `increaseLiquidity` / `decreaseLiquidity` auto-claim `[PHAR, xPHAR]` with the old `lastModified` inside a swallowed try/catch, then set `lastModified = now` | [S] position manager 207 to 221, 254 and 291, 319 and 361 |
| `burn(tokenId)` does not check rewards; afterwards no one can claim | [S] 468 to 473; [P] P5 |
| xPHAR: `xRatio = 0`; the vault cannot transfer xPHAR; `exit` is instant at 50% | [C] and [P] P6 |
| PHAR is a plain ERC-20 (burn, permit; no fee, pause or blacklist) | [S] Pharaoh.sol 10 to 42 |
| Pharaoh governance can change: validator address, anti-sybil switch, threshold, `xRatio`, gauge implementation | [S] **U1, UNRESOLVED as a risk** |

## 5. Mechanism: the period exposure ledger

Specification only; no code exists.

### 5.1 Principle

Separate **attribution** (who is owed what, from history) from **funding** (PHAR actually received from the gauge).

- Attribution uses only: the pool's `positionPeriodSecondsInRange` (the same number the gauge pays on), the share supply, and share balances. It needs no reward call, so it works whether or not any claim succeeds.
- Funding is the vault calling `positionManager.getReward` when outside the slash window. It adds `funded[p]` for the period(s) paid.
- A holder's entitlement for a finalised period `p` is `funded[p] * W[h][p] / Tt[p]`, where `W[h][p]` is the holder's share-time exposure in `p` and `Tt[p]` the total share-time recorded in `p`. Late, delayed, skipped and retried claims all land in `funded[p]` and are split by the *same recorded weights*, so they go to the holders of the intervals they were earned in.

### 5.2 State

- Immutable: `REWARD_PHAR`, optionally `REWARD_XPHAR`, position manager, pool, voter, gauge lookup via `voter.gaugeForPool(pool)` read live. No reward-token setter. No owner function can move reward tokens.
- `period(t) = t / 1 weeks`.
- Per `(tokenId, p)`: `Trec[tokenId][p]` = last recorded `positionPeriodSecondsInRange` value.
- Per `p`: `Tt[p]` (total recorded share-time), `J[p]` (exposure per share, scaled by `RAY = 1e27`), `Zsupply[p]` (share-time recorded while `totalSupply() == 0`), `Zwaived[p]`, `funded[p][token]`.
- Global: `finalThrough` (highest finalised period), per-NFT `drained[tokenId]`, `retiredIds[]`.
- Per account `h`: `lastP[h]`, `jPaid[h]` (value of `J[lastP[h]]` at the last settlement), `W[h][p]`, `claimCursor[h][token]` (all finalised periods below the cursor are fully paid or waived).
- Buckets (counters, not transfers): `unattributed`, `waivedBucket`, `donatedBucket`, per token.

### 5.3 Recording (read-only, runs first in every `_update`, `harvest`, `claim`, `waive`)

```
_record():
    if no active or retired NFT with liquidity history: return
    pool._advancePeriod()                         // permissionless, idempotent; positionPeriodSecondsInRange reverts FTR for an un-advanced period
    for each NFT id with reward history not yet drained:
        for p in cursorPeriod[id] .. period(now):
            T  = pool.positionPeriodSecondsInRange(p, positionManager, id, lo, hi)   // X96 seconds, same call the gauge makes
            if T < Trec[id][p]: treat as time-source failure (decision 7), do NOT lower Trec
            dT = T - Trec[id][p]; Trec[id][p] = T
            if dT > 0:
                Tt[p] += dT
                if totalSupply() > 0: J[p] += mulDiv(dT, RAY, totalSupply())
                else:                 Zsupply[p] += dT
        cursorPeriod[id] = period(now)
```

`Trec` never decreases. `positionPeriodSecondsInRange` is monotone in normal operation but returns 0 in two corner cases (the debt-underflow branch and the sanity clamp, Position.sol 260 to 272); a reading below `Trec` is the time-source-failure case of decision 7, never a negative or re-counted delta (otherwise the next normal read would double-count). `_update(from, to, value)` for mint, burn and transfer: `_record()`, then `_settle(from)`, `_settle(to)`, then `super._update`. No call to `getReward`; no dependence on NAV, price or oracle (R7). Same-block deposit and withdrawal record `dT = 0` and earn nothing [R].

```
_settle(h):                                       // after _record, before the balance changes
    b = balanceOf(h)
    for p in lastP[h] .. period(now):
        jStart = (p == lastP[h]) ? jPaid[h] : 0
        if b > 0: W[h][p] += mulDiv(b, J[p] - jStart, RAY)          // floor
    lastP[h] = period(now); jPaid[h] = J[period(now)]
```

An account with no history has `lastP` set to the current period and `jPaid` to `J[current]` at its first settle (its balance was zero before). A permissionless `settle(account, maxPeriods)` advances an account in steps (it sets `lastP` to the next period and `jPaid = 0` when it stops early), so a dormant account never traps itself; whether `_update` requires a full settle or tolerates a backlog is part of blocker 4.

### 5.4 Funding: `harvest()` (permissionless)

```
harvest():
    _record()
    for each NFT id not drained:
        require(!willSlash(id))                    // see 5.5; otherwise revert Vault__RewardWindow(retryAfter)
        for p in lastFundedPeriod[id] .. period(now): e[p] = gauge.periodEarned(p, PHAR, id)   // pre-read, already net of earlier forfeits
        before = balances
        try positionManager.getReward(id, [PHAR, XPHAR]) catch { emit HarvestFailed(id); continue }
        delta = balances - before
        if delta == sum(e): funded[p] += e[p]; fundedThrough[id] = period(now) - 1
        // finalThrough = min over all non-drained NFTs of fundedThrough[id]; a period is final only when every NFT that accrued in it is funded through it
        // shortfall branch: nothing is finalised yet. After a slash the gauge has recorded the loss in periodClaimedAmount (forfeited + paid, GaugeV3 572), so the NEXT clean
        // harvest pre-reads e[p] == 0 for that period, delta == sum(e) holds, and it finalises. A slashed period is therefore not unclaimable forever; its funded[p] is just lower.
        else: emit HarvestShortfall(id, sum(e), delta); funded[p] += delta * e[p] / sum(e)   // proportional, documented; no finalisation
        if liquidity == 0 and fundedThrough[id] == period(now)-1 and Trec[id][period(now)] == 0 and periodEarned == 0 for all p: drained[id] = true
        // Trec[id][period(now)] == 0 matters: a late notify raises the CURRENT period's payout for any position with T > 0 in it, even at zero liquidity (P4)
```

Any increase of the PHAR or xPHAR balance that is not a booked harvest delta is an **unexplained inflow**, booked to `donatedBucket`. Because every state-changing call into the position manager (`increaseLiquidity`, `decreaseLiquidity`) is preceded by a harvest in the same transaction, the position manager's own auto-claim then pays 0 (P1: a second claim in the same block pays 0), so legitimate gauge payments are not misclassified.

### 5.5 `willSlash`, and what is gated

```
willSlash(id) = (address(gauge.rewardValidator()) != address(0)                         // the only guard the gauge itself uses (GaugeV3 543)
                  && ( try gauge.rewardValidator().validateReward(positionManager, address(this), positionHash, tx.origin, id, lo, hi, pool)
                       returns (bool s) { s } catch { true } ))                         // a validator revert is a slash, as in GaugeV3 545 to 549
             || (block.timestamp - positionManager.positionLastModified(id) <= voter.timeThresholdForGauge(gauge))
```

Two details that matter. (a) The blacklist checks in `RewardValidator.validateReward` (lines 164 to 170) run **before** the anti-sybil switch test (173 to 175), so a blacklisted owner, receiver, `tx.origin` or position hash is slashed even with anti-sybil switched off; the guard must therefore be "a validator is set", not `isAntiSybilEnabled()`. (b) When the vault calls `validateReward` itself, `msg.sender` inside the validator is the vault, so its `voter.timeThresholdForGauge(msg.sender)` (line 178) falls back to `timeThresholdForRewarder` (Voter 1009 to 1013), not the gauge's own value. Today both are 111 s [C], but if governance calls `setTimeThresholdForGauge` for this gauge the direct call would use the wrong number. The explicit `positionLastModified` / `timeThresholdForGauge(gauge)` clause covers that; the OR can only over-block, never under-block. The wallet blacklist has no public getter [S RewardValidator 30 to 31 are private sets], so the direct `validateReward` call is the only way to pre-detect it.

Using the gauge's own validator with `tx.origin` covers the blacklist and the window. **Every call that can make the position manager auto-claim, and every explicit claim, is gated by `!willSlash`.** That is `harvest`, `deployIdle`, `rebalance`, `emergencyExit`, the deployment step of `deposit`, and the liquidity-removal step of `withdraw`, `redeem`, `redeemInKind`. Share transfers, mints and burns are **not** gated (they only record).

### 5.6 Quarantine and settlement (A)

An interval is *quarantined* when it is recorded (`Tt`, `J`, `W` updated) but its reward has not been funded: the harvest reverted, was blocked by the window, paid less than expected, or the period is not yet final. Nothing is attributed to anyone else, nothing is swept, nothing is forfeited by the vault. Settlement is automatic: the next clean `harvest` adds the missing PHAR to `funded[p]`, and the entitlement formula splits it over the **recorded** weights, so the holders of the quarantined interval receive it whoever holds shares at settlement time. [M] differential result: entitlements after failing-then-working claims equal those of a run where no call ever failed (section 8, D2).

A period `p` is **final** when `p < period(now)` and `p <= finalThrough`, where `finalThrough` is the minimum of `fundedThrough[id]` over all NFTs not yet drained. Only final periods are claimable (5.8). `funded[p]` for a final period cannot change again because the gauge cannot add rewards to a past period [S GaugeV3 236, 213, 221].

### 5.7 Which case is which (C)

| Case | Predicate | Treatment |
| --- | --- | --- |
| **Attributed, always** | share-time `dT` recorded while `totalSupply() > 0`, for any reward that reaches `funded[p]`, however late (retroactive notify in the same period, delayed or retried harvest, harvest after every holder has left, catch-up emissions the voter notified into the current period) | split by `W/Tt` among the holders of those intervals; the delayed amount is **never** given to current holders as such |
| **Unattributed bucket** (`Zsupply`) | share-time recorded while `totalSupply() == 0`: the position has liquidity but no shares exist (idle assets donated to an empty vault and deployed by `deployIdle`) | the share `funded[p] * Zsupply[p] / Tt[p]` is counted in `unattributed`; nobody is entitled; never given to the first depositor (entry sniping) |
| **Donated bucket** | any PHAR or xPHAR balance increase not produced by a booked harvest (direct transfers, including while supply is 0) | `donatedBucket`; not allocated to holders (a donor gains nothing, an entrant cannot be harmed by or profit from it) |
| **Waived bucket** | holder-initiated waiver (section 7) | `waivedBucket` |
| **Externally forfeited** | the gauge pays less than `S * T / Q` because of a forfeit (should not occur because of 5.5, but Pharaoh governance can slash by blacklist) | not a bucket and not a vault decision: `funded[p]` is lower, so every holder of period `p` bears it pro rata by weight; event `GaugeShortfall` |
| **Dust** | floor rounding in `J`, `W`, entitlement | stays in the vault, bounded in 5.9 |

**Release rule.** None of the three buckets can be released in the first version: there is **no release function**. They are visible counters (`unattributedOf(token)`, `waivedOf(token)`, `donatedOf(token)`) and the tokens stay in the vault. This satisfies "cannot be triggered by the operator alone" trivially and loses nothing that anyone is owed. If the operator wants a release path, the minimum acceptable form is: an **immutable** sink fixed at deployment, a fixed delay (suggested not less than 180 days after the period was finalised), a **permissionless** trigger, an event, and no role that can shorten the delay or change the sink. The sink choice is an operator decision (section 10).

### 5.8 Claim (D4)

`claim(token, to)` (holder) and `claimFor(token, account)` (anyone, pays `account` only): `_record()`, `_settle(account)`, then for finalised `p` from `claimCursor[account]` to `finalThrough`: `amount += mulDiv(funded[p][token], W[account][p], Tt[p])` (skipping `Tt[p] == 0`), advance the cursor, `safeTransfer`. State is updated before the transfer; `nonReentrant`; not pausable (R12). It works with a zero share balance, after any number of later events, and reads no NAV. A holder who exited in the middle of a week can claim that week's share after the week is final, i.e. after the next successful harvest (up to one week plus the funding delay; blocker 3). A view `pendingReward(account)` returns the final amount plus a non-binding estimate for open periods.

### 5.9 Rounding and dust

Shares have the asset's decimals (6 for the USDC vault, 18 for WAVAX [C]); PHAR 18. `J` increments `mulDiv(dT, RAY, supply)` (floor), `W` increments `mulDiv(b, dJ, RAY)` (floor), entitlement `mulDiv(funded, W, Tt)` (floor). The vault never owes more than it received: `sum(entitlements) + buckets <= funded`, and equality holds up to the stranded floor (tests assert `funded - (sum + buckets) <= nRecords + nAccounts + nPeriods`). No overflow for supply up to 1e30 and `dT` up to `WEEK << 96` (about 4.8e34): `dT * RAY < 2^256`, checked with `mulDiv`.

### 5.10 Functions and what they do in a window

| Function | Behaviour |
| --- | --- |
| ERC-20 `transfer`, `transferFrom`, mint, burn | `_record`, `_settle` both sides, then move. No external claim. Always allowed, not pausable. Reverts only if the pool time source cannot be read (decision, section 10: default fail-closed for mint and transfer; for burns a degraded wall-clock split with an event) |
| `deposit` | outside the window: `harvest`, then deploy as today. Inside the window: policy W1/W3 (section 6) |
| `withdraw`, `redeem`, `redeemInKind` | pay from idle balance when it covers the amount (no liquidity change). When liquidity must be removed: outside the window `harvest` then remove. Inside the window: W1 reverts |
| `deployIdle`, `rebalance` | rebalancer (or owner). Outside the window only. **`rebalance` never burns the old NFT**: it removes liquidity, keeps the NFT in `retiredIds`, mints a new one |
| `emergencyExit` | owner. Pauses, removes all liquidity, **keeps the NFT**. Reverts inside the window. This is the only choice consistent with B: a decrease would auto-claim and be slashed. The owner retries after the window |
| Whole-vault exit (`shares == supply`) | removes all liquidity and **keeps the NFT** (`_freeLiquidity`'s burn is dropped). A later deposit re-uses it if it is in range, otherwise `rebalance` mints a new one |
| `harvest` | permissionless, section 5.4 |
| `claim`, `claimFor`, `exitXPhar` | section 5.8 and 5.11 |
| `pause` | blocks `deposit`, `deployIdle`, `rebalance` only; never transfers, claims or exits |
| `harvestRewards` to the owner | **removed** |

### 5.11 xPHAR

Dormant today (`xRatio = 0` [C], all xPHAR period totals 0, vault holds 0). The position manager auto-claims `[ram, xRam]` on every liquidity change, so if governance raises `xRatio` xPHAR arrives without notice, and the vault cannot transfer it (P6). Proposed, operator-confirm: the ledger is token-agnostic, so xPHAR gets its own `funded[p][xPHAR]` and entitlements in xPHAR units with the same weights. A holder may call `exitXPhar(minPharOut)` to turn **their own** xPHAR entitlement into PHAR at the 50% penalty (the vault calls `xPHAR.exit(amount)`, measures the PHAR it receives, and pays that to the holder); the penalty is borne by that holder only. It is never operator-triggered and never batched. If xPHAR is paused or exit reverts, the entitlement stays recorded. No other disposition exists unless Pharaoh exempts the vault.

### 5.12 Other properties

- **Share-weighted, not liquidity-weighted.** Attribution is by shares held over time; the gauge pays by liquidity-time. They differ while assets are idle, by the entry haircut and by fee compounding (of the order of the 51 to 145 bps entry loss in the gate note [E]). Bounded, favours long-term holders, a known residual; the fork test compares ledger totals with the gauge's `earned` within a stated tolerance.
- **Contract holders.** A contract holding shares (router, aggregator, lending pToken) earns the entitlement for that contract and must call `claim`. A holder inside a single transaction earns zero (`dT = 0`). Shares held by a lending market's pToken are owned by the market, not the borrower; **do not list these shares as collateral** until a market-side reward ledger exists. The lending integration is not in the evidence [E].
- **Reentrancy.** `deposit`, `withdraw`, `redeem`, `redeemInKind`, `harvest`, `claim`, `claimFor`, `exitXPhar`, `waiveRewards`, `settle` and the ERC-20 transfer path share one `nonReentrant`, because `_update` makes external calls (`pool._advancePeriod`, pool views). Reward tokens are fixed and have no hooks.
- **Frozen gates.** `_record`, `harvest`, `claim`, `pendingReward` read no `totalAssets`, TWAP or oracle, so entitlement stays readable and claimable while the stress gates freeze deposit, redeem and the views [E gate note].
- **Out of range.** An out-of-range position has `dT = 0`; nothing accrues to anyone [E: 0 PHAR per hour measured].
- **Other gauge reward tokens** (the gauge lists USDC, USDT, WAVAX, sAVAX and others as whitelisted and anyone may notify them [C][S]) are neither claimed nor attributed by this design. A USDC incentive claimed into the USDC vault would raise `totalAssets()` for current holders. Out of scope; flagged.

## 6. The window policy (blocker 1)

**Measured facts.** Window 111 s [C]; any liquidity change resets it for that NFT; a claim inside it pays zero and forfeits every unclaimed period [P2, P8]; a blacklisted `tx.origin` slashes regardless of time [P9]. The loss bound is therefore "accrual since the last successful harvest", which is small only if harvests are frequent (the USDC vault accrued 2.32e18 wei over 77 days, about 3.0e16 wei per day at this size [C]; no dollar value is claimed).

| Option | Deposits | Exits | `emergencyExit`, `rebalance` | Consequence |
| --- | --- | --- | --- | --- |
| **W1 revert (recommended default)** | the deploy step reverts inside the window (`Vault__RewardWindow(retryAfter)`); the user retries after at most 111 s | pay from idle when idle covers the amount (a change from the live flow, which always removes liquidity pro rata; NAV-neutral [R]); if liquidity must be removed, revert inside the window. `redeemInKind` must hand over a pro-rata share of the position, so it reverts inside the window | revert inside the window | Never forfeits. **Weakens liveness**: `redeemInKind` is no longer unconditional, and a dust deposit outside the window reopens the window for 111 s, so an attacker can hold liquidity-changing exits closed for the price of gas plus the entry haircut on dust. Mitigations to specify with the operator: a minimum deploy size relative to NAV, a keeper-kept idle buffer so ordinary exits never need liquidity removal, and a stated maximum threshold the vault tolerates |
| W2 proceed | deposits and exits go through | go through | go through | **Rejected as default**: a slashed auto-claim forfeits all unfunded accrual (P8, P9), recorded only as a shared external loss. Violates the spirit of B for exits, and a blacklisted origin can force it |
| W3 idle-hold, scheduled deployment | deposits stay idle and are minted at NAV; only a rebalancer-or-permissionless `deployIdle` (rate-limited, minimum idle size) changes liquidity | pay from idle first | revert inside the window | Window opens only on the schedule, so griefing is expensive. **Changes the economics**: the entry haircut is no longer charged to the entrant at deposit; it is realised at deployment and shared by all holders, and idle shares earn exposure without liquidity for their idle period (the share-weighted approximation, 5.12). Needs a re-run of the entry-loss evidence |

A Pharaoh-blacklisted `tx.origin` cannot perform liquidity-removing exits under W1 (every such call is a slash); it can still transfer its shares to a clean address, which only records and never claims, and exit from there. If Pharaoh governance sets the threshold large (it is one governance call, U1), W1 and W3 freeze liquidity operations for that long. The vault should read the live threshold each time and the operator should decide a ceiling above which operations stay blocked and everything else (transfers, recording, claims of funded rewards) still works.

## 7. Waiver and forced paths (B)

**Forced recovery can never waive or forfeit.** Emergency exit, `redeemInKind`, stress gates, `rebalance`, `pause`, a position claim that fails or is gated, and any operator or rebalancer action have no write access to `W`, `claimCursor`, `funded` or the buckets other than the recording that adds exposure. Test: for every state-changing function other than `waiveRewards` and `claim*`, the per-account entitlement for finalised periods is non-decreasing across the call (section 8, test B1).

**Voluntary waiver, only under this policy** (operator-confirm whether the function exists at all; default: it does **not** exist in the first version):

| Question | Rule |
| --- | --- |
| Who | the account itself: `msg.sender == account`. No allowance, no operator, no rebalancer, no owner, no `claimFor`-style relay, no signature relay, no multicall by a third party on its behalf |
| What exactly | `waiveRewards(throughPeriod, maxPhar, maxXphar)` waives the entitlement of that account for **final** periods from its `claimCursor` through `throughPeriod`, for the reward tokens configured. Amounts are computed on chain and must not exceed the caller's `max*` arguments (protection against changes between signing and inclusion) |
| Effect | the account's weight for those periods moves to `Zwaived[p]` (so `waivedBucket` increases by exactly the waived amount), `claimCursor` advances; irrevocable. Already claimed amounts are untouched. Rewards of non-final periods cannot be waived |
| Where it goes | `waivedBucket`, never to the operator, never redistributed in the first version (redistribution to the other holders of the period by weight is deterministic and possible; it is an operator decision) |
| Recorded | event `RewardsWaived(account, fromPeriod, throughPeriod, phar, xphar)` and the per-account cursor |
| Opt-in | per account, by that account's own call; there is no global or default waiver and no way to pre-sign one for another party |

## 8. Required tests

All tests below are specified, none written. "Dust" is the bound in 5.9. Unit and fuzz tests use mocks: `MockPool.positionPeriodSecondsInRange(p, ...) = f[p] * (WEEK << 96)` with a settable `f[p]` in `[0, 1]`; `MockGauge` with `S[p]` (settable, including after the fact), `claimed[p]`, `periodEarned(p) = S[p] * f[p] - claimed[p]`, a `mode` of `Ok`, `Revert` (whole `getReward` call reverts), `Zero` (call succeeds, pays nothing and leaves `earned` unchanged) or `Slash` (pays nothing and removes the pending amount from `earned`, sending it to a mock r33); and a mock validator returning the slash predicate. Units: `S` and funded amounts in 1e18 wei, shares as integers. The numbers come from the reference model [M] (references file section 6). Every scenario uses period 0 and then `advancePeriod()`.

### 8.1 Named tests (D)

**D1. "10-then-90".** Definition: holder A is the only holder while **10 reward units** accrue to the position; then holder B enters with a balance equal to A's; then **90 more units** accrue; the period ends. "Reward units" are PHAR that the gauge owes the position (`S[0] = 100e18`, `f` rising 0.1 then 0.9). With equal balances after B's entry, A is entitled to **10 + 45 = 55** and B to **45**, and the result does not depend on harvest or claim timing. Interpretation, and why: I read "10-then-90" as two successive slices of one reward stream that straddle B's entry, because the point of the test is that B must not share in the first slice and that *when the vault claims* must not matter. Alternative readings, all covered: (1) 10% of the period then 90% at a constant rate with total 100: identical numbers; (2) the 10 is already claimed into the vault before B's entry versus still sitting in the gauge when B enters (the "claimed before or after B's entry" independence you asked for): both tests below; (3) the full 100 is notified only after both have entered (late notify): third test. A reading in which B also shares the first 10 is the defect and must fail.

| Test | Steps | Exact assertions |
| --- | --- | --- |
| `test_tenThenNinety_claimedBeforeEntry` | `S[0]=100e18`; A deposits 1000; `f[0]=0.1`; `harvest()` (funds 10e18); B deposits 1000; `f[0]=1`; advance period; `harvest()` | `funded[0]==100e18`; `claimable(A)==55e18`; `claimable(B)==45e18`; `unattributedOf==0`; after both claim, vault PHAR minus bucket and dust `== 0` |
| `test_tenThenNinety_claimedAfterEntry` | as above without the first `harvest()` (the 10 is still in the gauge when B enters) | the same three numbers |
| `test_tenThenNinety_lateNotify` | `S[0]=0` while A then B enter; `f` 0.1 then 1; only then `S[0]=100e18`; advance; `harvest()` | A 55e18, B 45e18. A first-draft per-sync accumulator would give 50e18 and 50e18, so this test is the discriminator [M] |
| `testFuzz_tenThenNinety` | fuzz `x` (fraction before entry, 1 to 99), `bA`, `bB` (1 to 1e24), the number and order of harvests, `S` notified at any point in the period | `claimable(A)==floor(funded * (x + (1-x)*bA/(bA+bB)))` and `claimable(B)==floor(funded * (1-x)*bB/(bA+bB))` within dust; independent of harvest count and order |
| `invariant_tenThenNinety` | handler: deposit, redeem, transfer, accrue, notify, harvest, advance over accounts A, B, C | `sum(entitlements)+buckets <= funded` always; equality within dust for every final period with `Tt>0` |
| `testFork_tenThenNinety` | on the real position manager, gauge and pool at a fresh pin: A (the Safe seed) then B deposit into the replacement vault; at B's entry read `T1` from the pool, at the period end `T2`; `notifyRewardAmount` sets `S` locally (probe P4 technique) | after the period closes and `harvest()` (A held from before the period start, so `T` counts from 0): `claimable(A) - claimable(B) == floor(funded * T1/T2)` within dust and `claimable(A)+claimable(B)+buckets == funded` within dust. This is the fork form of "A gets the 10 on top of an equal 45" |

**D2. Both reward calls failing.** Concrete meaning: the single call `getReward(tokenId, [PHAR, XPHAR])` is the claim for both tokens, so "PHAR and xPHAR claims both fail" means the mock gauge is in mode `Revert` (whole call reverts), `Zero` (returns, pays nothing for either token) or `Slash`. With the ledger a failing claim cannot block or alter any balance change; it only defers funding. One scenario, four failing events, then settlement. `S[0]=100e18`, mode `Revert` from the start. A deposits 1000 (`f=0`); `f=0.1`; **B deposits 1000 (entry)**; `f=0.3`; **A transfers 500 to C (transfer)**; `f=0.5`; **A redeems 500 (exit)**; `f=0.8`; **B redeems 1000 and C redeems 500 (whole-vault exit)**; advance period.

| Assertion | Exact value |
| --- | --- |
| Each of the four operations succeeds; balances, supply and `totalAssets` movement equal a control run in which the gauge never fails | equality |
| NFT after whole-vault exit | still owned by the vault, liquidity 0, not burned |
| `harvest()` while still failing | returns without revert, emits `HarvestFailed`, `finalThrough` unchanged; `claimable(A)==claimable(B)==claimable(C)==0` (quarantined, not final); `unattributedOf==0` |
| Mock gauge switched to `Ok`, `harvest()` | `funded[0]==80e18`; `finalThrough==0` |
| Entitlements | `claimable(A)==25e18`, `claimable(B)==40e18`, `claimable(C)==15e18`; `unattributedOf==0`; `totalSupply()==0` at settlement time |
| After the three claims | vault PHAR balance minus dust `==0` |
| Differential | for every fuzzed sequence, entitlements after "failing then working" equal those of the same sequence with the gauge always `Ok` |

Variants of the same file: mode `Zero` and mode `Slash` (the `Slash` run must additionally show the vault never *calls* `getReward` inside the window: the validator mock reports slash, `harvest` reverts `Vault__RewardWindow`, and the mock r33 receives nothing). xPHAR variant: both tokens fail in turn and together, with the xPHAR ledger enabled. Fork variant: forge `vm.mockCallRevert` on `positionManager.getReward` selector at each of the four events, same assertions with the real position manager for everything else.

**D3. Zero-supply cases.**

| Test | Setup | Exact assertions |
| --- | --- | --- |
| `test_zeroSupply_liquidityNoShares_thenFirstDepositor` | `S[0]=100e18`; the position holds liquidity but `totalSupply()==0` (idle assets donated and deployed); `f=0.2`; C deposits 500 (first depositor after an empty period); `f=1`; advance; `harvest()` | `claimable(C)==80e18`; `unattributedOf==20e18`; C gets nothing of the first 0.2; `donatedBucket==0` [M] |
| `test_zeroSupply_directPharDonation` | supply 0; 7e18 PHAR transferred in; C deposits | `donatedOf==7e18`; `claimable(C)` unchanged from a control without the donation; no function moves the 7e18 |
| `test_lastHolderLeaves_thenNewDepositor` | A deposits 100; `f=0.3`; A redeems all; `f` stays 0.3 (liquidity removed, no accrual); D deposits 100; `f=1`; advance; `harvest()` | `claimable(A)==30e18`, `claimable(D)==70e18`, bucket 0 [M] |
| `test_donationToEmptyVault` | assets and PHAR donated to an empty vault; first depositor mints | shares follow the existing NAV rule (unchanged); PHAR donation in `donatedBucket`; the depositor's entitlement is only for share-time while he held |
| `test_rewardsArriveWhileSupplyZero` | every holder has left; period ends; the delayed `harvest()` runs while `totalSupply()==0` | funding lands in `funded[p]`; entitlements by recorded history (see D6); `unattributedOf` only for `Zsupply` share-time; the next depositor receives 0 of it |

**D4. Exited holder claims later.** A deposits 100, B deposits 100 after `f=0.5`; `f=1`; both redeem fully **before any harvest** (nothing yet claimed from the gauge); two periods pass; `harvest()`. Assert `claimable(A)==75e18`, `claimable(B)==25e18`, `totalSupply()==0` [M]. Then: a new depositor E joins in period 2 and leaves; `claimFor(A)` by a third party pays `A` only; A's amount is unchanged by every later event (fuzz: any later sequence leaves `claimable(A)` for finalised periods non-increasing only through `claim`/`waive`); A's claim works while `paused()`, while `totalAssets()` reverts (stress gate mock), and with a zero share balance.

**D5. Transfer-then-settle conservation.** A deposits 1000; `f=0.4`; A transfers 500 to B; `f=1`; advance; `harvest()`: `claimable(A)==70e18`, `claimable(B)==30e18`, bucket 0 [M]. Variants and exact values: transfer of the whole balance (A 40e18, B 60e18); self-transfer (unchanged: no `W` or `jPaid` change); transfer to a zero-balance account (starts at the current `J`); transfer to the vault address reverts; fuzz over 2 to 6 accounts: after every step `sum(entitlements)+buckets <= funded` and `W` totals equal `Tt` within dust.

**D6. No orphan sweep of delayed rewards.** (a) Everyone leaves before the first harvest; the harvest arrives two periods later: entitlements 75e18 and 25e18, `unattributedOf==0`, `totalSupply()==0` (same run as D4) [M]. (b) Rewards for period 0 are funded after a new depositor E joined in period 2: E receives 0 of `funded[0]`. (c) ABI test: enumerate the vault's selectors; the only functions that can reduce the vault's PHAR or xPHAR balance are `claim`, `claimFor`, `exitXPhar` (and a release function only if the operator chose one). (d) Fuzz with the owner and rebalancer as actors performing every callable function: `PHAR.balanceOf(vault) - paidOut` never decreases except through those functions. (e) No function named or behaving as `sweep`, `rescue`, `harvestRewards` (owner forward) exists.

### 8.2 Tests for the new mechanisms

- **W-tests (window).** With the validator mock reporting slash: `harvest`, `deployIdle`, `rebalance`, `emergencyExit`, deposit deploy step and liquidity-removing exits revert `Vault__RewardWindow`; transfers, mint, burn, `claim`, `settle` still work; after the window, all succeed. With a blacklisted `tx.origin` (fork P9 setup): the same operations revert and the backlog is unchanged; the same call from a clean origin succeeds and funds the full backlog. Griefing test for the chosen option (W1 dust deposit reopens window; minimum deploy size; W3 rate limit).
- **NFT retention.** Whole-vault exit, `rebalance` and `emergencyExit` leave the old NFT owned by the vault with zero liquidity; `harvest` after the window pays the pending amount (fork P5 setup: the amount is not lost); `drained` is set only after a post-period harvest finds `periodEarned == 0`; a new deposit after a whole-vault exit works (re-use or `rebalance`).
- **B1 forced paths never reduce entitlements.** Invariant over all functions except `claim*` and `waiveRewards`: finalised entitlements are non-decreasing across the call, for fuzzed states including `emergencyExit`, `redeemInKind` and a failing or slashed harvest.
- **B2 waiver (if the function exists).** Only `msg.sender == account` can waive (owner, rebalancer, approved spender, third party all revert); a waiver of a non-final period reverts; `maxPhar` below the computed amount reverts; after waiving, `waivedBucket` rises by exactly the amount and the account cannot claim those periods; no other account's entitlement changes; the event is emitted; there is no way to waive for another account (including via `transferFrom` allowances and multicall).
- **Late-reward attribution (C).** Retroactive notify inside a period after a holder-set change: `S` raised after B entered, with `f` before and after entry fixed: the increase is split between A and B by the recorded weights, not equally (extends D1 `lateNotify`).
- **Pool time source failure.** `positionPeriodSecondsInRange` reverts: mint and transfer revert with a specific error; a burn follows the chosen degraded rule and emits; nothing is silently misattributed.

### 8.3 The first draft's tests: kept, changed, replaced

| First-draft test | Disposition |
| --- | --- |
| 1 entrant before harvest gets zero; 2 long-term holder gets all | keep; assert on `claimable` after finalisation |
| 3 transfer then harvest conservation | keep; superseded in detail by D5 |
| 4 fuzz sum of claims <= received | keep, now `sum(entitlements)+buckets <= funded` and equality within dust (the reference model fuzz holds this over 3,000 sequences [M]) |
| 5 exit-all then claim | keep; assert NFT retained and later PHAR arrives into `funded`, not an orphan sweep |
| 6 partial exit keeps accrued | keep |
| 7 zero-supply donation | **replaced** by D3 |
| 8 fuzz harvest skipped N blocks | keep; N up to many periods |
| 9 sandwich around sync | keep, edited: same-block deposit/withdraw records `dT=0` and earns 0; deposit one block before a harvest earns only the seconds held; a late notify cannot be captured by an entrant |
| 10 transfer edges | keep |
| 11 contract holder | keep |
| 12 donated PHAR allocated to holders | **replaced**: donations go to `donatedBucket` |
| 13 reward-token transfer reverts, exit still works | keep: `claim` reverts, entitlements unchanged, later pays in full |
| 14 sync failure bounded loss | **replaced** by D2 (no loss exists) |
| 15 frozen gates, entitlement readable | keep |
| 16 reentrancy | keep; add `harvest`, the ERC-20 transfer path and a malicious `pool._advancePeriod` stub |
| 17 rounding and decimals fuzz | keep; add `dT` up to `WEEK << 96`, `RAY` overflow check |
| 18 invariant suite | keep; add the new invariants above |
| 19 fork entrant before harvest; 20 fork exit keeps accrued | keep; the oracle is P7's identity (ledger weights times funded versus `S*T/Q`), tolerance 1% then tighten from measurement |
| 21 fork gauge period boundary | **resolved by P3** (continuous to the wei); keep as a regression test: ledger totals equal the gauge's `earned` before and after the boundary |
| 22 fork rebalance and emergency exit keep entitlement | **replaced** by NFT retention (the premise "burn keeps pending PHAR" was false, P5) |
| 23 fork out of range | keep |
| 24 fork stress-gate freeze | keep |
| 25 fork xPHAR path | change: assert `xRatio==0` at the pin and the dormant ledger with a mock; fork test of `exitXPhar` returns 50% (P6) |
| 26 fork unsellable PHAR | keep |

### 8.4 Fork oracles from the probes (assert these values at the stated pin, then re-measure on a fresh pin)

| Oracle | Value | Probe |
| --- | --- | --- |
| `earned(PHAR, 485334)` equals the pay of `getReward`; second claim pays 0 without reverting | 2,320,900,114,408,409,301 wei | P1 |
| Claim 50 s after a liquidity change pays 0; forfeit recorded equals the pending amount; the next claim sends exactly that to r33 | 3,454,986,920,120 wei | P2 |
| One claim after the boundary equals the sum of a claim before and one after | 2,335,866,022,354,893,294 wei | P3 |
| Late notification of 1,000 PHAR raises `earned` by `X * f` | delta 23,792,616,857,857,937,937 wei, 23,459,092,025,127,617,000 wei for seconds before the last claim | P4 |
| Full decrease inside the window pays 0, `burn` succeeds, later claims revert | pending 3,454,986,920,120 wei lost | P5 |
| xPHAR transfer from the vault reverts; `exit(10e18)` returns | 5e18 | P6 |
| `S*T/Q - claimed` summed from `lastClaim` equals `earned` | 2,320,900,114,408,409,301 wei | P7 |
| Slash 80 s after a change straddling a boundary forfeits all earlier-period unpaid | 3,385,887,181,717 wei to r33 | P8 |
| Blacklisted `tx.origin` forfeits the entire backlog | 2,320,900,114,408,409,301 wei to r33 | P9 |

Pass criteria: all green on a fresh pin; at least one mutation per core test (remove the pre-mint record, use claim timing instead of recorded weights, round up, drop the window gate, burn the NFT, add an owner sweep, allow a non-holder waiver) and the test must fail; the evidence note records block, hash, commands and logs as the gate note does.

## 9. Reference model

`/private/tmp/claude-501/-Users-joshua-Peridot-peridot-contracts-2-5/248fd71c-044a-4eb7-9df4-18a648d75742/scratchpad/phar_tools/refmodel.py` (exact rational arithmetic, sha256 `e0720088649589184fe915a6b954be4a8dd77e75f85dee819ba95d830aae976f`, outside the repo). Output [M]:

| Scenario | Result |
| --- | --- |
| 10-then-90, 10 claimed before B's entry | A 55, B 45, bucket 0 |
| 10-then-90, no early claim | A 55, B 45, bucket 0 |
| late `S` (all 100 notified after both entered) | A 55, B 45 |
| claims fail at entry, exit (single failing call, A exits fully), then work | A 35, B 65, bucket 0 |
| failing at entry, transfer, exit and whole-vault exit, then work (D2) | A 25, B 40, C 15, bucket 0, vault left with 0, funded 80, supply 0 |
| zero supply with liquidity, then first depositor | C 80, bucket 20 |
| last holder leaves, new depositor | A 30, D 70, bucket 0 |
| transfer of half | A 70, B 30, bucket 0 |
| everyone leaves before any claim, delayed claim two periods later | A 75, B 25, bucket 0, supply 0 |
| 3,000 random sequences of deposit, redeem, transfer, accrue, late notify, period advance, failing and working harvests | `sum(entitlements)+bucket == funded` in every finalised period with `Tt>0` |

The model implements this document's ledger, not the live contracts. It should be committed next to the tests when implementation starts.

## 10. Open decisions for the operator

1. **Window policy** W1, W2 or W3 (section 6), the maximum threshold tolerated, minimum deploy size, idle buffer. Blocker.
2. **Accept the Pharaoh governance surface** (U1), or negotiate an exemption/allow-list for the vault position. Blocker (acceptance).
3. **Release rule for the buckets:** default none; if wanted, sink address, delay, and who may call (section 5.7). Blocker for the release path only.
4. **Waiver:** does the function exist, and do waived amounts stay in `waivedBucket` or go pro rata to the other holders of the period (section 7).
5. **Claim availability:** claims only for finalised periods (up to a week plus the funding delay). Alternative (pay open-period amounts as they accrue) is possible but makes early claimers' payment depend on a not-yet-final `funded[p]`; not recommended.
6. **xPHAR:** the holder-triggered 50% exit (5.11), or hold only.
7. **Pool time-source failure:** fail closed for mint and transfer; for burns, degraded wall-clock split with an event versus revert.
8. **Replacement vault or upgrade in place** (section 2); governance and admin of the replacement (this document assumes it is not today's 1-of-1 upgrade key and does not choose).
9. **Lending:** shares are not listed as collateral until a market-side reward ledger exists.
10. Who writes the replacement code and who reviews it. None of that is done here.

## 11. What this proposal does NOT do

- Opens no gate, changes no cap, selects no launch date. No transaction was sent; no contract, test or file under `docs/handoffs/` was edited.
- Does not fix the separate open findings of the gate note [E]: thin USDC/USDt exit liquidity; the stress gates freezing `redeem`, `deposit` and the views; the 1-of-1 Safe whose single signer is the rebalancer EOA and the immediate-upgrade proxy admin; donation griefing, entry haircut and out-of-range behaviour; the missing net-return figure and third-party audit.
- Residual risks of the recommended design [R]: Pharaoh governance can change the integration under the vault (U1); the window policy trades liveness for no-forfeiture; attribution is share-weighted; every transfer makes external pool calls; xPHAR cannot be paid in kind; an upgrade key still dominates any invariant here.

## 12. What I inspected and what I could not

- Read in full with the Read tool: the first-draft proposal; `AvalancheTrackAVaultsBase.sol`; the vault base (817 lines) and extension (100 lines); the OpenZeppelin `ERC20Upgradeable._update` region and all of `ERC4626Upgradeable`; the position manager (508 lines); `GaugeV3` (642); `ClGaugeFactory`; `RewardValidator` (242); the relevant parts of `Voter` (`_distribute`, `distribute`, `notifyRewardAmount`, claim functions, governance setters) and its claim and governance libraries; the pool's `_advancePeriod` and `positionPeriodSecondsInRange`; xPHAR (283) and PHAR (42). Sources fetched from Routescan, cross-checked against Sourcify for six contracts (identical).
- Chain: read-only `cast` calls, `cast storage`, `cast code`, `cast block` with an explicit block pin against `https://api.avax.network/ext/bc/C/rpc` (blocks 99216397 and 99216312); `cast codehash` is unavailable on that node (no `eth_getProof`), so keccak of the code was used. Upgrade history and NotifyReward events came from the Routescan `getLogs` API.
- Probes: a Foundry fork project in the scratchpad (not in the repo), local VM only (`vm.prank`, `vm.warp`, `deal`; Pharaoh governance blacklisting in P9 is a local simulation); 9 passed. Reference model in Python. Both listed with sha256 in the references file.
- **Not done or not verified:** WAVAX position probes beyond `earned` and the threshold (U4); source-to-bytecode reproduction (U5, Voter implementation and RewardValidator implementation are on Routescan only); Minter, access hub, timelock and r33 contracts (U3); any Solidity for the replacement vault, hence no gas figure for the settlement loop and no confirmation that the pool call path is acceptable inside `_update`; the lending-market side; the effect of Pharaoh governance changing any of the parameters in U1; USD value of any reward amount (no PHAR price source on chain [E]); a run of the existing gate suites (none was run or edited).
