# Pharaoh vaults: PHAR reward entitlement, remediation proposal (third draft, EXPERIMENTAL)

**STATUS: EXPERIMENTAL. NOT IMPLEMENTATION-READY.** Nothing here has been implemented, deployed, signed or broadcast. The gates of the Pharaoh USDC vault and the Pharaoh WAVAX vault stay CLOSED; this document sets no cap and no date. The design is specified, checked against an exact-rational reference model (section 9) and against ten new fork probes (section 6.1), and it changes the second draft's recommendation. What still blocks implementation:

1. **Operator decisions (section 10).** The window policy is no longer "W1 by default": W1 is rejected as a production default (section 6.4) and a queued, rate-limited batching variant is recommended instead (section 6.5). The operator still has to choose it and its parameters, accept or negotiate the Pharaoh governance surface, and pick the reconciliation rule for unresolved intervals. This document accepts nothing on the operator's behalf.
2. **A bound that no design can provide.** If Pharaoh governance raises the threshold, or blacklists the vault wallet or its position hash, a liquidity-changing principal exit cannot be both lossless and prompt: the best bound is `lastModified + threshold + margin`, which governance can make indefinite (probe Q6 sets it to `uint256.max`; every later claim is slashed, principal still exits but rewards are forfeited). Under hard constraint C (no automatic forfeiture, no forced waiver) the design therefore waits, and says so (section 6.5, table of bounds). Only exits paid from an idle buffer are unaffected.
3. **Engineering not yet bounded.** No Solidity exists. Per-call gas of the paginated record, settle and harvest steps is estimated from probe unit costs, not measured (section 5A.7). The unit mocks must reproduce the gauge's `S * T / (WEEK << 96)` formula and the debt and cascade semantics the model mirrors (section 9.2).

Branch `avalanche-pharaoh-tracks-abcd`. Product names throughout (track letters are unreconciled). Companion: `docs/deployment-handoffs/avalanche-vault-source-references.md` ("the references file"). Earlier gate evidence: `docs/deployment-handoffs/avalanche-track-a-launch-gate.md` ("the gate note"). Evidence files: `docs/deployment-handoffs/avalanche-vault-phar-evidence/` (`probe/` P1 to P9, `probe2/` Q1 to Q10, `tools/refmodel.py`, `tools/refmodel2.py`, `tools/test_refmodel2.py`, `tools/variant_econ.py`).

Basis tags: **[E]** repo evidence; **[S]** source saved and read (references file section 3); **[C]** read-only chain read; **[P]** probe P1 to P9; **[Q]** probe Q1 to Q10 (this revision); **[M]** reference model; **[R]** reasoning, not measured.

## 0. Changes in this revision (third draft)

- **Operator direction applied.** W1 is no longer the default. Three alternatives are compared (section 6): W1 as drafted; an epoch or rate-limited queue with an idle buffer; per-NFT cohorts or a sleeve NFT. Recommended: the queue variant (6.5), with the bound for every variant stated for quiet markets, a dust attacker, a governance-raised threshold, a blacklisted vault and a failed exposure reading.
- **New source and probe findings (section 6.1 to 6.3).** The position manager's `lastModified` is per NFT (Q1); `collect`, NFT transfer and a different owner do not touch it (Q2); the first liquidity change after a quiet span is always lossless and only a second change inside the window loses (Q3); `getPeriodReward` forfeits only the period it names and writes no debt, whereas `getReward` writes a debt that wipes every earlier period (Q4); a chain of slashed changes loses everything from the chain start (Q5); a gauge-side pool-read failure hides the backlog from `getReward` but it is recoverable per period (Q8, Q10, which corrects a premise that it is lost). No route avoids the auto-claim or the validator without circumventing it (6.3).
- **Hard constraint C enforced in the design.** Removed: the second draft's "degraded wall-clock split" for burns, "proportional shortfall", and `emergencyExit` reverting inside the window as an unbounded wait. Replaced by unresolved intervals (5A.4), a classified loss ledger (5A.3), and stated bounds.
- **Model extended (section 9.2).** Slashing and the debt cascade, zero-payment success, unavailable readings, retired and burned NFTs, governance changes, bounded processing with checkpoint compaction, an independent ground-truth oracle, and three explicit properties (ownership, liveness, no value from unresolved intervals). 47 tests pass; six mutations are caught.
- Kept from the second draft: replacement-vault recommendation, comparison against NAV pricing and swap-on-touch, the ledger formula, the verified Pharaoh facts, the D1 to D6 named tests (their numbers still hold).

## 1. What changed from the first draft (history, second draft)

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
| A slashed `getReward` returns normally, pays zero, records a forfeit DEBT, and at the next clean claim forfeits **every earlier period's unpaid amount in full** plus the current period's unpaid amount up to the debt; the forfeited tokens go to r33. A slashed `getPeriodReward(period)` forfeits only that period, immediately, and writes no debt [Q4]. Each further slashed call overwrites the debt with the cumulative unpaid, so a chain of slashed changes loses everything from the chain start [Q5] | [S] GaugeV3 459 to 463, 468 to 489, 553 to 583; [P] P2, P8, P9 |
| `increaseLiquidity` / `decreaseLiquidity` auto-claim `[PHAR, xPHAR]` with the old `lastModified` inside a swallowed try/catch, then set `lastModified = now` | [S] position manager 207 to 221, 254 and 291, 319 and 361 |
| `burn(tokenId)` does not check rewards; afterwards no one can claim | [S] 468 to 473; [P] P5 |
| xPHAR: `xRatio = 0`; the vault cannot transfer xPHAR; `exit` is instant at 50% | [C] and [P] P6 |
| PHAR is a plain ERC-20 (burn, permit; no fee, pause or blacklist) | [S] Pharaoh.sol 10 to 42 |
| Pharaoh governance can change: validator address, anti-sybil switch, threshold, `xRatio`, gauge implementation | [S] **U1, UNRESOLVED as a risk** |

## 5. Mechanism: the period exposure ledger

Specification only; no code exists. **Section 5A (third draft) amends this section and governs where they conflict.**

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
| ERC-20 `transfer`, `transferFrom`, mint, burn | `_record`, `_settle` both sides, then move. No external claim. Always allowed, not pausable. Reverts only if the pool time source cannot be read: mint and transfer fail closed; burns proceed and the interval becomes UNRESOLVED (5A.4). [The second draft's degraded wall-clock split is removed.] |
| `deposit` | [third draft: queued, minted at the next batch, section 6.5] second draft: outside the window `harvest`, then deploy; inside the window policy W1/W3 |
| `withdraw`, `redeem`, `redeemInKind` | [third draft: idle buffer at once, else a locked request served by the next batch, section 6.5] pay from idle balance when it covers the amount (no liquidity change). When liquidity must be removed: outside the window `harvest` then remove. Inside the window: W1 reverts |
| `deployIdle`, `rebalance` | rebalancer (or owner). Outside the window only. **`rebalance` never burns the old NFT**: it removes liquidity, keeps the NFT in `retiredIds`, mints a new one |
| `emergencyExit` | owner. Pauses, removes all liquidity, **keeps the NFT**, under the same guard as a batch (6.5); it never waives or forfeits. When the guard cannot pass (raised threshold, blacklist) its bound is stated in section 6.5, not hidden |
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

## 5A. Amendments to section 5 (third draft; where they conflict, this section governs)

Superseded: the section 5.3 loop (now deferred, 5A.1), the 5.4 shortfall branch (5A.3), the 5.10 rows for `emergencyExit`, whole-vault exit and the "degraded wall-clock split" for burns (5A.4, 6.5), and the section 6 W1 default (section 6).

**5A.1 Bounded recording and settlement (checkpoint compaction).** `_update` does O(1) inline work: one pool read per NFT for the CURRENT period, and for every ended period since the NFT's cursor it pushes ONE deferred record segment `(nft, firstPeriod, lastPeriod, supplyThen)` onto a backlog. The supply in force over those periods is exactly the supply before this `_update`, so applying them later with that stored supply is exact (the period's pool reading is final once it ended). A permissionless `drain(maxSteps)` applies backlog steps FIFO, each step reading one `(nft, period)`. Account settlement is the same idea: `_update` closes the account's open segment in O(1); a segment inside one period folds directly into `W[h][p]`; a segment spanning several periods is pushed as one closed segment, so an account holds at most one deferred segment per period in which it was touched, however many dust transfers it receives [M: 500 dust transfers onto a victim leave at most one segment]. `settle(h, maxSteps)` and `claim(h, maxSteps)` advance by period steps. Every public call is bounded by its `maxSteps` argument, strictly progresses until done, and a partially processed state satisfies the invariant that every period below `settledThrough(h)` already equals the exact result and `sum W + Z + U == Tt` for each period that is fully settled for all accounts [M: tests `partial_processing_is_consistent_and_holder_always_progresses`, `conservation_for_fully_settled_periods_at_every_prefix`, `paginated_equals_unpaginated`]. A holder can always make progress alone: `progress(h, n)` drains the global backlog it depends on and then its own segments.

**5A.2 Funding is per period.** `harvest()` (permissionless) calls `positionManager.getPeriodReward(period, tokenId, tokens, vault)` for each period that is sealed (read after it ended) or current, instead of one `getReward`. It pre-computes `owed = S[p] * Trec / WEEK - periodClaimedAmount` from its own exposure reading and the gauge's public mappings, so every paid unit is booked to its period from the balance delta of that single call. It never calls inside the window, for a blacklisted wallet or position hash, or when the validator reverts (the `willSlash` guard of 5.5, now with `margin` added to the threshold). After all periods read zero owed it may issue one `getReward` purely to advance the gauge's `lastClaimByToken`; that call must pay exactly zero.

**5A.3 Classification and loss ledger (replaces the 5.4 shortfall branch).** After each per-period call the vault compares three things it can read: the balance delta (`paid`), the change of `periodClaimedAmount` (`paid + forfeited`) and its own `owed`.

| Observation | Meaning | Ledger |
| --- | --- | --- |
| `owed == 0` | nothing owed | no call, no entry |
| `claimedDelta > 0`, `forfeited == 0` | paid | `funded[p] += paid` |
| `claimedDelta > 0`, `forfeited > 0` | the call was slashed or realised an earlier debt; forfeited tokens went to r33 | `funded[p] += paid`, `lost[p][SLASHED] += forfeited` |
| `claimedDelta == 0` while `owed > 0` | zero-payment "success": the gauge's own pool read failed, or the gauge implementation returns without paying | NOTHING booked; period stays outstanding; retried (Q10: a per-period call pays it in full once the gauge's read works) |
| call reverts | gauge or position manager reverted | NOTHING booked; retried |
| guard says blocked | window, blacklist, validator revert | no call at all |

A period is **final** only when it ended, every NFT's reading for it is sealed, the record backlog no longer covers it, and `outstanding(p) = sum_nft S[p] * Trec / WEEK - funded[p] - lost[p] == 0` exactly. Loss is therefore an explicit number, equal to what r33 received, and it is **borne pro rata by recorded exposure** (`entitlement = funded[p] * W / Tt`), by every holder of that period including holders who already left; it is never re-attributed to anyone else [M: `slash_is_booked_as_external_loss_borne_pro_rata`]. Zero payment that is "nothing owed" is distinguished from "slashed" and from "no effect" by the exposure reading, which is exactly why the reading is kept (the gauge's own `earned` also reports 0 when its pool read fails, so it cannot tell them apart [Q8]).

**5A.4 Unavailable exposure reading: UNRESOLVED, never wall-clock.** If `positionPeriodSecondsInRange` cannot be read (or returns less than the recorded value), `_update` for mint and transfer reverts (fail closed). Burns proceed (principal exit stays available) and mark the PERIOD of the burn as having a supply event inside a failure span. When the reading returns: periods without a supply event in the span are exact (constant supply, applied from the backlog); periods WITH an event put the whole `dT` since the last good record into `U[p]` (unresolved). `U[p]` is attributed to nobody: it is in no account's `W`, the corresponding share of `funded[p]` is `reservedUnresolved(p)` and stays in the vault, and no elapsed-time rule exists in the contract. It is released only by `reconcile(p, split)` with an externally supplied split (holders plus a zero-supply share), whose rule is an operator decision (section 10, item 3); the only computable evidence is event timestamps, and using it is the operator's explicit choice, not an automatic default [M: properties (iii)]. A period does not become final while its reading is down.

**5A.5 Liquidity changes always auto-claim; book it per period.** `increaseLiquidity` and `decreaseLiquidity` call `getRewardForOwner` unconditionally, swallowed by try/catch [S, Q3]. The vault harvests first, so the auto-claim pays about zero; whatever it still pays is booked PER PERIOD from the `periodClaimedAmount` deltas (no pool read needed), and only a remainder that cannot be explained goes to `donated`. A liquidity change is never made inside the window (guard), so the auto-claim is never slashed.

**5A.6 NFT lifecycle.** The NFT is never burned by the vault except when `outstanding == 0` for every period and liquidity is zero (and the design does not need a burn at all; it only stops accruing). A retired NFT keeps its cursor, its `Trec` and its ownership intervals until drained [M: `retired_nft_keeps_intervals_and_burn_is_refused_with_outstanding`, `unguarded_burn_orphans_rewards`].

**5A.7 Gas bounds (estimates, not measurements).** Unit costs from probes [Q]: `positionPeriodSecondsInRange` 47,910 gas cold, 18,806 for a second period; `gauge.periodEarned` 55,966; `getPeriodReward` for one period 178,344 (cold); `getReward` over 12 periods 1,053,520 (about 88,000 per period, two tokens); `positionLastModified` 926; `mint` 1,014,864; `increaseLiquidity` 279,436. The gauge's own `getReward` and the auto-claim loop from `lastClaim` to the current period, so a dormant NFT needs a claim before about (budget / 88,000) periods have passed: at a 15M budget about 170 periods (3.3 years), at a 30M budget about 340. A permissionless `harvest()` keeps `lastClaim` fresh; no trusted keeper is required [R]. The RPC reported a block gas limit of 80,000,000 when read; that is not a safe per-call budget and is not relied on. The vault's own per-step cost (one pool read plus about three storage writes) is estimated at 100,000 to 150,000 gas, so a default `maxSteps` of about 50 stays under about 7.5M gas [R]. These figures are to be replaced by measurements once Solidity exists.

## 6. The liquidity-change policy: alternatives compared (blocker 1, revised)

Operator direction: W1 (revert inside the window) is NOT approved as a production default, because repeated dust activity or a governance change of the threshold must not silently become indefinite withdrawal blocking. This section compares W1, a queue, and per-NFT routes, and states the bound of each. Nothing here accepts Pharaoh governance risk or changes the recovery policy.

### 6.1 New probe results (second probe project, `probe2/`, fork of block 99216397, local VM only; 11 test functions, Q1 to Q10 with Q4b, all pass)

| Probe | Result (USDC vault NFT 485334 unless stated) |
| --- | --- |
| Q1 per-NFT window and additivity | A second NFT minted by the vault (same pool and range) has its own `lastModified` and position hash. Minting it and dust-touching it five times leaves NFT A's `lastModified` unchanged; A's claim afterwards is lossless (pays the full `earned`, nothing to r33, no debt). A claim on the dust NFT inside its own window pays 0 and records a debt on that NFT only. Per-liquidity accrual of A and B over one hour: 65264146698854585720873 and 65264146698854690138914 (e18-scaled), equal to 1.6e-15 relative: the gauge's reward is additive in liquidity, so splitting a position over several NFTs dilutes nothing. Gas: `mint` 1,014,864; `increaseLiquidity` 279,436; `getReward` over 12 periods 1,053,520 |
| Q2 | `collect`, ERC-721 transfer to another account, and a claim by the new owner do not change `lastModified`, do not auto-claim and do not write a debt. The reward goes to whoever owns the NFT at claim time |
| Q3 | `getReward` outside the window pays everything; a `decreaseLiquidity` right after it auto-claims 0 and sets `lastModified`; a SECOND change 50 s later is slashed: debt recorded 3,458,434,936,670 wei, which is exactly the accrual of those 50 s and exactly what r33 later receives. The first change after any quiet span is lossless whatever the threshold; only the second inside the window loses |
| Q4 | Inside the window, `getReward` records a debt against the current period (36,687,694,978,723) and the next clean claim sends the old period (6,847,701,174,606) AND the new period's debt to r33: 43,535,396,153,329. `getPeriodReward(old period)` forfeits only the old period, immediately to r33 (6,847,701,174,606), writes NO debt, and leaves the new period fully payable later. Neither is free; the second has a smaller blast radius |
| Q4b | Outside the window `getPeriodReward(q)` pays exactly period q (cold gas 178,344), leaves the others untouched, and a later `getReward` pays only the rest |
| Q5 | A chain of slashed changes overwrites the debt with the cumulative unpaid since the chain start: 6.92e12, 1.38e13, 2.08e13, 2.77e13 wei after 1 to 4 changes 100 s apart; the next clean claim sends the whole 2.77e13 to r33. Loss grows linearly with chain length |
| Q6 (governance simulated locally) | With the threshold set to 7 days, the first change after a quiet span is lossless, a second one a day later is slashed, a harvest at day 2 is slashed and rewrites the debt (so even a failed harvest loses), and the first clean harvest after 7 days later sends 11,952,345,175,720,190 wei to r33 and pays the vault 3,013,538,858,302,927. With the threshold set to `uint256.max`, a full `decreaseLiquidity` still succeeds (principal is never blocked by the gauge) and no claim is ever clean again |
| Q7 | `validateReward(owner = any non-position-manager address, receiver, hash, origin, ...)` is a pure wallet-blacklist read (no time check): true for a blacklisted origin, false for a clean one. With owner = the position manager the window check applies |
| Q8 and Q10 | If the pool's period-seconds view reverts, the gauge's `earned` reports 0, `getReward` returns normally, pays 0, writes no debt and still advances `lastClaimByToken` (backlog 2,320,900,114,408,409,301 shown as 486,511,446,621,211,325 afterwards). The old periods are hidden, not gone: after the read works again `getPeriodReward(old period)` pays the full 26,207,949,171,163,724 wei (Q10). The second draft's reasoning "lost at the gauge" is therefore corrected |
| Q9 | Gas: `positionPeriodSecondsInRange` 47,910 cold and 18,806 warm; `periodEarned` 55,966; `earned` over 12 periods 342,418 |

### 6.2 What sets `lastModified` and what triggers the validator [S, Q]

| Call | Sets `lastModified` | Triggers claim and validator |
| --- | --- | --- |
| `mint` | yes, for the NEW id | no |
| `increaseLiquidity` / `decreaseLiquidity` | yes (after the claim) | yes: auto-claim `getRewardForOwner` with the OLD `lastModified`, swallowed, slashed if inside the window. No liquidity change exists without it |
| `collect` | no | no |
| ERC-721 transfer, approval | no | no |
| `getReward` (also `Voter.claimClGaugeRewards`) | no | yes, all periods; slash writes a debt that wipes every earlier period at the next clean claim |
| `getPeriodReward(period)` | no | yes, one period; slash forfeits that period only |
| `burn` | deletes the position | no; succeeds with rewards outstanding and orphans them [P5] |

Validator checks (RewardValidator 154 to 193): blacklisted owner, receiver or `tx.origin`, blacklisted position hash, anti-sybil switch, then `now - lastModified[id] <= timeThresholdForGauge`. Only the position manager can call the gauge's claim functions; there is no other caller path.

### 6.3 Routes that avoid the gauge auto-claim or lastModified dependency

| Route | Technically available | Effect | Evasion? | Verdict |
| --- | --- | --- | --- | --- |
| Avoid the auto-claim altogether | NO: unconditional in `increaseLiquidity` and `decreaseLiquidity` | none | making the swallowed call fail on purpose (gas starvation, the gauge reentrancy lock) would rely on a failure mode to skip the validator | NOT recommended: unreliable and would amount to circumventing the protection |
| Separate NFT per cohort or epoch, or a sleeve NFT for entries | YES (Q1): windows are per NFT, rewards are additive | dust or entry activity on the sleeve never opens a window on the main NFT. Costs: one more NFT per cohort (1.01M gas to mint against 0.28M for an increase); every NFT adds a pool read per period per touch (19k to 48k gas) and a claim loop (about 88k per period); NFTs cannot be burned until drained; unbounded NFT count if dust is allowed to mint cohorts, so entries must be batched or have a minimum size | none: no claim is made inside any NFT's own window | Legitimate, but it only protects ENTRIES. Exits still change liquidity of some NFT, and dust deposit plus withdraw can heat K cold NFTs in 2K transactions per window, so it does not bound exits by itself |
| Claim with `getPeriodReward` per period | YES (Q4) | smaller slash scope, no debt, and exact per-period attribution (used in 5A.2) | none | Adopted for funding; still guarded, still not free inside the window |
| Claim through a different caller, receiver, owner contract | YES (Q2: transfer then claim) | `lastModified` unchanged; the validator checks owner, receiver and origin | choosing a caller, receiver or `tx.origin` to avoid a blacklist entry would circumvent it | NOT recommended. A blacklist hit means the vault stops and the operator talks to Pharaoh. Plain key rotation of a keeper for security reasons is ordinary operations, but the design never selects an origin to dodge a check |
| Replace the NFT to shed a position-hash blacklist | YES technically | new hash, new window | evasion if the hash was listed on purpose | NOT recommended |
| Wait out the window | YES | lossless; the first change after a quiet span is free (Q3) | none | the basis of every variant below |

I could not find Pharaoh's published rules for these controls (a web search returned only marketing and listing pages), and the validator's own comment says its logic is meant to be hidden. The "evasion" classification therefore rests on the code's evident purpose, not on a published policy. Recommended and listed as an operator decision: ask Pharaoh to confirm that batched or queued liquidity changes with a clean claim before each change are acceptable.

### 6.4 The variants and their trade-offs

Numbers: gas from probe Q; the dust-attack cost uses 279,436 measured plus an ASSUMED 150,000 vault overhead and the gas price read once from the RPC (2.5 gwei); the yield figures use an ASSUMED 20% per year of fees plus emissions, because no yield was measured. All from `tools/variant_econ.py`; none is a USD figure.

| | (1) W1 as drafted | (2) Queue with idle buffer: deposits and withdrawals requested any time, executed as one net liquidity change per batch, at most once per `threshold + margin` | (3) Per-NFT cohorts or sleeve, synchronous |
| --- | --- | --- | --- |
| Fees and PHAR on deployed capital | full; deposits deployed at once | full once deployed. Queued deposits earn nothing: mean wait E/2 costs 0.0039 bps of the deposit at E = 122 s, 0.114 bps at 1 hour, 0.685 bps at 6 hours, 2.74 bps at 1 day (assumed 20% APR) | full |
| PHAR rewards | none lost by construction (guard) | none lost by construction; queued deposits have no share-time and dilute nobody | none lost; additive across NFTs (Q1) |
| Idle capital | none | buffer b of NAV: 20 bps per year of NAV per 1% of buffer (assumed APR); pending deposits only until the next batch | none, or a buffer |
| Deposit availability | refused for up to 111 s after any liquidity change; an organic refusal rate of 0.64%, 2.5%, 12%, 47% of requests at 5, 20, 100, 500 liquidity-changing operations per day (Poisson) | always accepted into the queue; shares minted at the next batch | accepted into the sleeve NFT |
| Principal exit, quiet market | instant if idle covers it or outside the window; else refused until the window passes | instant up to the buffer; else at the next batch, at most `max(E, threshold + margin)` = 121 s today | instant from a cold NFT or buffer |
| Principal exit under a dust attacker (one operation per 112 s) | UNBOUNDED: every window is reopened by the attacker, cost about 771 transactions or 3.3e8 gas, about 0.83 AVAX per day at 2.5 gwei [model test `W1_dust_attacker_blocks_exits_unbounded`] | unchanged: dust is queue accounting and does not touch liquidity; an attacker-triggered batch is rate limited and also serves the victim's request [model tests `EPOCH_dust_attacker_cannot_extend_the_bound`, `EPOCH_empty_batches_do_not_reset_the_window`] | UNBOUNDED by itself: deposit plus withdraw dust heats the cold NFTs |
| Principal exit, threshold raised to T' | liquidity part waits `lastModified + T' + margin - now`; buffer part instant | same for the liquidity part; buffer part instant | per NFT, same |
| Principal exit, vault wallet or position hash blacklisted | UNBOUNDED for the liquidity part (every claim and every change slashes); the second draft's `emergencyExit` cannot override | UNBOUNDED for the liquidity part; buffer part instant | UNBOUNDED for blacklisted NFTs |
| Exposure reading down | deposits and transfers fail closed, exits proceed, the interval is unresolved | exit-only batches proceed, deposits stay queued [model test `EPOCH_reading_outage_exits_still_served_deposits_stay_queued`] | as W1 |
| Gas and complexity | simplest | queue and batch accounting O(1) per user; one batch is one liquidity change plus one harvest | more NFTs, more reads, higher mint cost |

### 6.5 Recommended variant, and the stated bound of each variant

Recommendation (EXPERIMENTAL): variant (2), with a single position NFT (never burned, retired ones kept until drained), asynchronous deposits and withdrawals, and a synchronous idle buffer.

- **Deposits**: assets are escrowed in a queue; shares are minted at the batch, at NAV, so queued assets have no share-time and nobody is diluted; cancellable before the batch.
- **Withdrawals**: paid at once from the idle buffer when it covers the amount (no liquidity change, no window); otherwise a request locks the shares (they keep their exposure and cannot move) and is served by the next batch.
- **Batch**: permissionless, allowed only when `now - lastModified > liveThreshold + margin` and the validator pre-check (5.5) passes; it first completes the per-period harvest, then makes ONE net liquidity change, then mints and burns. A batch with an empty queue changes nothing. `emergencyExit` is the same batch for all liquidity, owner-triggered, under the same guard; it cannot waive anything.
- **Parameters for the operator (section 10)**: `E` (a floor of `threshold + margin`, i.e. about 2 minutes today; 1 hour suggested for operating cost), `margin` (10 s modelled), buffer b (cost 20 bps per year per 1%), minimum request sizes.

Bound on lossless principal exit, per variant and condition (the model tests named in section 9.2 assert these; `None` means the test asserts that no bound exists):

| Condition | (1) W1 | (2) queue + buffer | (3) per-NFT, synchronous |
| --- | --- | --- | --- |
| Quiet | 0 s, or until the window ends (at most 111 s) | 0 s for amounts within the buffer; else at most `max(E, threshold + margin)` | 0 s from a cold NFT or buffer |
| Dust attacker | NONE (unbounded) | same as quiet | NONE (unbounded) |
| Governance raises the threshold to T' | `lastModified + T' + margin - now` (indefinite for a huge T', Q6) | same, for the liquidity part; buffer part 0 s | same per NFT |
| Vault blacklisted (wallet or hash) or validator replaced to always slash | NONE for the liquidity part | NONE for the liquidity part; buffer part 0 s | NONE |
| Exposure reading down | exits proceed (interval unresolved) | exits proceed, deposits wait | exits proceed |

No variant can bound the liquidity part when Pharaoh governance or its blacklist makes every claim a slash: the only alternative is exiting with the forfeiture, which hard constraint C forbids as an automatic or forced action. A holder-initiated "exit now and accept the loss" path is a separate operator decision (section 10, item 4) and cannot isolate the loss to the exiting holder, because the forfeited backlog belongs to all holders of the position. The idle buffer is what keeps part of principal available in these states.

### 6.6 Why not W1

W1 is simple and loses nothing, but it makes every liquidity-changing exit depend on nobody else having made a liquidity change in the last `threshold` seconds. That is true of the vault's own organic traffic (2.5% of requests refused at 20 operations a day) and false against an attacker who spends about 0.83 AVAX a day; with the queue the attacker's operations stop being liquidity changes.

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

(Third draft: the W-tests below are to be re-specified against the chosen variant of section 6; the model tests of section 9.2 are the executable form of the same properties and supersede the W1 specifics.)

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

### 9.1 First reference model (second draft)

`docs/deployment-handoffs/avalanche-vault-phar-evidence/tools/refmodel.py` (exact rational arithmetic, sha256 `e0720088649589184fe915a6b954be4a8dd77e75f85dee819ba95d830aae976f`). Output [M]:

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

### 9.2 Extended model (third draft)

Files: `tools/refmodel2.py` (model), `tools/test_refmodel2.py` (47 tests, `python3 -I test_refmodel2.py` or `python3 -I -m unittest test_refmodel2` from the `tools/` directory, about 5 seconds), `tools/variant_econ.py` (section 6.4 numbers), logs `tools/test_refmodel2_run.txt`, `tools/variant_econ_run.txt`. `refmodel.py` is unchanged (its sha256 cited above still holds). Exact rational arithmetic. Result of the last run: **47 tests, 47 pass, 0 fail** (two of them property tests over 60 and 80 random histories, the first run for both policies).

What it contains: a gauge mirror (per-NFT `lastModified`, mutable threshold, forfeit debt and the `_forfeitedShare` cascade, `periodClaimedAmount`, r33, `getReward` against `getPeriodReward`, the unconditional auto-claim, gauge-side pool-read failure, validator replaced, reverting or blacklisting, a second reward token appearing mid-period, burned NFTs); the ledger with deferred recording and account segments; per-period funding with the classification of 5A.3; the W1 and queue policies; and an INDEPENDENT oracle in the test harness that records each holder's true exposure from the true balances while time passes, without using any vault code path.

Properties and the tests that carry them:

| Property | Statement | Tests |
| --- | --- | --- |
| (i) Ownership correctness | after full settlement, `W[h][p]` equals the oracle's true exposure of `h` in `p` for every holder and period; independent of when the vault claimed and of who touched it (arbitrary permissionless `touch`, `harvest`, `progress`, `claim`, `drain` calls inserted between operations leave `W` and entitlements identical) | `ownership_equals_oracle_and_ignores_touchers` (60 histories, W1 and queue), `claim_timing_independence`, `late_notify_goes_by_recorded_weights`, `ten_then_ninety_...`, `paginated_equals_unpaginated` |
| (ii) Recovery liveness | principal exit within the stated bound in each modelled state, or the test asserts the absence of a bound | `TestLiveness`: W1 quiet 0 s; W1 dust attacker NONE; W1 and queue under a raised threshold `lastModified + T' + margin`; queue under a dust attacker at most `threshold + margin + 1`; empty batches do not reset the window; idle-buffer exit survives blacklist and `threshold = 10^9`; blacklisted vault NONE for W1 and queue; reading outage still serves queued exits |
| (iii) No value from an unresolved interval until reconciled | `sum W + Z + U == Tt`; `U` is in nobody's `W`; the funded share of `U` is reserved; permissionless calls cannot change it; `reconcile` with an externally supplied split restores exact ownership | `unresolved_interval_not_attributed_until_reconciled`, `failure_without_supply_event_is_exact_not_unresolved`, `failure_across_periods_only_event_period_is_unresolved`, `period_does_not_finalise_while_reading_is_down`, fuzz `unresolved_never_attributed_and_ownership_after_reconcile` (80 histories with outages, at every step) |
| Conservation | `sum entitlements + buckets + reserved <= funded`, equality when settled | asserted in the ownership, slash, xPHAR and unresolved tests |
| No wall clock in attribution | the attribution functions contain no time read | `attribution_functions_do_not_read_time` (source inspection) |

Scenario coverage requested in the operator direction: **slashing** (a call slashed despite the guard is classified `SLASHED`, `lost[p] == r33 received`, funded is lower, the loss is borne by every holder of the period pro rata to recorded exposure, nobody is re-credited: `slash_is_booked_as_external_loss_borne_pro_rata`; gauge semantics for chains, debt and scope: `slash_chain_loss_grows_gauge_semantics`, `get_period_reward_scope_vs_get_reward_debt`); **zero-payment success** (nothing owed gives no call and no entry; owed but paid 0 is `NO_EFFECT_ZERO_PAYMENT` and books nothing; gauge-side read failure is recovered by the per-period call: `zero_payment_distinguishes_...`, `gauge_side_read_failure_is_recoverable_by_period_call`); **unavailable readings** (above); **retired and burned NFTs** (intervals preserved, burn refused with rewards outstanding, the unguarded burn leaves the period unable to finalise, visibly); **governance** (threshold changed mid-period is read live, a second reward token appearing mid-period is split by the same weights, validator replaced or reverting and a blacklisted vault block every claim without forfeiting, a replaced gauge whose claims revert recovers to the same entitlements as a control run); **bounded processing** (after 300 dormant periods a transfer does at most 6 inline steps and leaves one deferred segment; a tiny-call-at-a-time drive makes progress on every call, keeps every settled prefix equal to the oracle, and ends equal to the unpaginated run; 500 dust transfers onto a victim leave at most one segment; claims paginate to the same total).

Mutation self-check: six deliberate breakages are each caught by at least one test (an unresolved interval treated as resolved; no settlement before a balance change; the backlog applied with the current supply; the window guard removed; burning with rewards outstanding; the first draft's wall-clock treatment of a failed reading).

**What the model proves and does not.** It shows that the specified rules, with exact rational arithmetic, attribute every reward unit to the exposure that earned it, independent of claim timing and of who touches the vault, keep losses explicit, keep unresolved intervals out of everyone's entitlement, and keep partial processing consistent. It does NOT prove anything about Solidity: floor rounding (the second draft's dust bound in 5.9 is untouched), gas (steps are counted, gas is not measured), reentrancy, storage layout, upgrade safety, event ordering inside one transaction, or the behaviour of the pool beyond the monotone reading assumed. The gauge mirror follows the lines that were read and the behaviours probed, not the deployed bytecode; the Voter implementation and RewardValidator implementation are attested by Routescan alone (references file section 3). Oracle equality is only as good as the oracle's assumption that `positionPeriodSecondsInRange` is the exposure the gauge pays on (probe P7). Liveness is proved only for the adversaries written in the tests (dust at a fixed cadence, one threshold raise, one blacklist); an adversary that also controls Pharaoh governance is not bounded, as section 6.5 states. Concurrency between independent transactions in one block is not modelled. Governance changes are modelled as state changes of the mirror, not as the real access-hub flows.


## 10. REMAINING OPERATOR DECISIONS (nothing below is decided or accepted by this document)

1. **Liquidity-change policy** (section 6): confirm that W1 is rejected as a default, and choose between the queue with buffer (recommended), per-NFT routes, or something else. For the queue: batch floor `E` (at least `threshold + margin`, about 2 minutes; 1 hour suggested), `margin`, idle buffer b (cost about 20 bps per year per 1% at an assumed 20% yield; the real figure is not measured), minimum request sizes, cancellation rules, whether deposits are asynchronous (recommended) or accepted synchronously at a cost to ownership accuracy.
2. **Pharaoh governance surface (U1).** Accept, negotiate an exemption or allow-list, or choose a monitored halt. The bound on a lossless liquidity exit is `lastModified + threshold + margin` and can be made indefinite by governance or by a blacklist of the vault wallet or position hash (Q6, Q7). Also decide whether to ask Pharaoh to confirm that queued or batched liquidity changes with a clean claim first are acceptable under their rules (I could not find published rules).
3. **Reconciliation rule for UNRESOLVED intervals** (5A.4): who may call `reconcile`, on what evidence (event timestamps are the only computable evidence, and using them is a wall-clock rule that the design refuses to apply automatically), within what delay, and where `U` goes if it is never reconciled (default: stays reserved; no release function).
4. **Forced exit versus forfeiture.** Whether any holder-initiated "exit now and accept the loss" path should exist at all. It is not designed here: constraint C forbids forced waivers, and the loss of a slashed position belongs to all holders, so it cannot be limited to the exiting holder.
5. **Release rule for the buckets** (zero-supply, donated, waived, unreconciled): default none; if wanted, an immutable sink, a fixed delay of at least 180 days, a permissionless trigger (5.7).
6. **Waiver function**: exists or not (default: not), and where waived amounts go (section 7).
7. **Claim availability**: claims only for final periods (a period is final only after its exposure is sealed and `outstanding == 0`, so up to a week plus the funding delay, and longer after a reading outage or a blocked window).
8. **xPHAR disposition** (5.11): holder-triggered 50% exit, or hold.
9. **What the vault does on discovering a blacklist or a replaced validator**: halt batches (modelled), who escalates to Pharaoh, and the keeper policy: the design never selects a `tx.origin`, caller or receiver to avoid a check.
10. **Pagination parameters**: `maxSteps` default, who runs `drain` and `harvest` (permissionless; a keeper is a convenience, not a dependency), and the maximum dormancy before a claim is needed (about 170 periods at a 15M gas budget, estimate).
11. **Replacement vault or upgrade in place**; governance and admin of the replacement (this document assumes it is not today's 1-of-1 upgrade key); lending collateral stays off until a market-side reward ledger exists; who writes and who reviews the code. Unchanged from the second draft.

## 11. What this proposal does NOT do

- Opens no gate, changes no cap, selects no launch date. No transaction was sent; no contract, test or file under `docs/handoffs/` was edited.
- Does not fix the separate open findings of the gate note [E]: thin USDC/USDt exit liquidity; the stress gates freezing `redeem`, `deposit` and the views; the 1-of-1 Safe whose single signer is the rebalancer EOA and the immediate-upgrade proxy admin; donation griefing, entry haircut and out-of-range behaviour; the missing net-return figure and third-party audit.
- Residual risks of the recommended design [R]: Pharaoh governance can change the integration under the vault (U1) and make the lossless liquidity exit bound indefinite; the queue trades synchronous deposits for an idle wait and a buffer drag; attribution is share-weighted; every transfer makes external pool calls; xPHAR cannot be paid in kind; an upgrade key still dominates any invariant here.

## 12. What I inspected and what I could not

(Second-draft list first; third-draft additions at the end of this section.)

- Read in full with the Read tool: the first-draft proposal; `AvalancheTrackAVaultsBase.sol`; the vault base (817 lines) and extension (100 lines); the OpenZeppelin `ERC20Upgradeable._update` region and all of `ERC4626Upgradeable`; the position manager (508 lines); `GaugeV3` (642); `ClGaugeFactory`; `RewardValidator` (242); the relevant parts of `Voter` (`_distribute`, `distribute`, `notifyRewardAmount`, claim functions, governance setters) and its claim and governance libraries; the pool's `_advancePeriod` and `positionPeriodSecondsInRange`; xPHAR (283) and PHAR (42). Sources fetched from Routescan, cross-checked against Sourcify for six contracts (identical).
- Chain: read-only `cast` calls, `cast storage`, `cast code`, `cast block` with an explicit block pin against `https://api.avax.network/ext/bc/C/rpc` (blocks 99216397 and 99216312); `cast codehash` is unavailable on that node (no `eth_getProof`), so keccak of the code was used. Upgrade history and NotifyReward events came from the Routescan `getLogs` API.
- Probes: a Foundry fork project in the scratchpad (not in the repo), local VM only (`vm.prank`, `vm.warp`, `deal`; Pharaoh governance blacklisting in P9 is a local simulation); 9 passed. Reference model in Python. Both listed with sha256 in the references file.
- **Not done or not verified:** WAVAX position probes beyond `earned` and the threshold (U4); source-to-bytecode reproduction (U5, Voter implementation and RewardValidator implementation are on Routescan only); Minter, access hub, timelock and r33 contracts (U3); any Solidity for the replacement vault, hence no gas figure for the settlement loop and no confirmation that the pool call path is acceptable inside `_update`; the lending-market side; the effect of Pharaoh governance changing any of the parameters in U1; USD value of any reward amount (no PHAR price source on chain [E]); a run of the existing gate suites (none was run or edited).

- Added in this revision: the third draft's probes were read-only forks on a local VM at the same pin (governance changes and blacklisting are local simulations by pranking the real governance addresses); no transaction was sent; no file under `contracts/contracts/`, `contracts/test/` or `docs/handoffs/` was edited and no existing probe file was changed.
- **Not done or not verified (third draft):** Pharaoh's published rules for the anti-sybil controls (one web search found nothing); probes Q1 to Q10 were not repeated on the WAVAX vault; the C-Chain block gas limit was read once (80,000,000) and is not used as a budget; no yield, fee or PHAR price was measured, so every cost in basis points assumes a 20% yearly yield and is illustrative; the gas of the vault's own record, settle and harvest steps is estimated, not measured; the model's liveness covers only the adversaries written in its tests; whether a `getPeriodReward` per period is cheaper than `getReward` over a long history is only known per period (178,344 cold gas) and not as a total; `mint` of a sleeve NFT was exercised with test tokens dealt to the vault address in the local VM only.
