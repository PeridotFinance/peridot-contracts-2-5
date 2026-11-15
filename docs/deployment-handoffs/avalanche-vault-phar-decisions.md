# Pharaoh vault PHAR entitlement: independent verification of the reference model, and the reduced operator decisions

**STATUS: EXPERIMENTAL. Nothing here is implemented, deployed, signed or broadcast. No gate is opened, no cap is set. This file accepts nothing on the operator's behalf; the items marked OPERATOR ACCEPTS are the operator's alone.** It does not change the recovery policy (no automatic forfeiture, no forced waiver). Companion to `avalanche-vault-phar-entitlement-proposal.md` (third draft, sections 9 and 10) and `avalanche-vault-source-references.md`.

Two parts. **Part A** is the verification of the reference model by an oracle written separately from it (and what that found: the model has defects, the design needs three amendments). **Part B** reduces the ten operator questions to five product choices.

**None of Part B blocks the cash-only lending product.** Cash-only lending does not use the Pharaoh vault shares as collateral (lending collateral stays off until a market-side reward ledger exists, proposal 5.12), so every decision below can be deferred without touching it. Which decisions block a vault launch is stated per decision and summarised in B.7.

---

## Part A. Verification

### A.1 Method, and how independent it is

Files (all under `avalanche-vault-phar-evidence/tools/`, nothing existing was edited):

| File | What it is |
| --- | --- |
| `phar_oracle.py` | Ground-truth oracle. Imports nothing from `refmodel2.py`. (1) Exposure per holder and period computed from the definition over a raw event history (in-range seconds split among the share balances in force, zero-supply to a separate bucket). (2) A **gauge replay written from the Solidity text** (`GaugeV3.sol` `_getAllRewards`, `_recordForfeit`, `_forfeitedShare`, `_claimAll`, `sweepForfeited`, `_getReward`, `cachePeriodEarned`; `RewardValidator.validateReward`; position manager `_tryClaimRewards`, `mint`, `increaseLiquidity`, `decreaseLiquidity`; the fetched copies in the scratchpad `phar/src_*`), including functions the model does not have. (3) The section 5.5 guard predicate. |
| `phar_difftest.py` | Randomised differential test. Generates histories as data (lists of operations), executes them on `refmodel2.py` through a logging wrapper that records every external gauge call as a raw event, replays the same events on the oracle, and compares. Failing histories are minimised by delta debugging. Also a gauge-only fuzz (model gauge against the source-based gauge, no vault). |
| `phar_repros.py` | One minimal reproduction per finding. |
| `phar_mutations.py` | Ten new mutations of `refmodel2.py` (text replacements, each applied to a scratch copy), each run against my tests and the original 47. |
| `*_run.txt` | Logs: `phar_difftest_run.txt`, `mutations_run.txt`, `phar_repros_run.txt`, `test_refmodel2_rerun.txt`. |

Independence is real but limited, and the reader should weigh it: the oracle is separate code with no shared lines, its gauge follows the Solidity text rather than the model, and it is exercised by histories the original tests do not contain. But it was written after reading `refmodel2.py` and the proposal by the same kind of author, so a misreading of the specification common to both would pass. Its exposure definition IS the proposal's definition (share-weighted in-range seconds), so it cannot find a flaw in the specification itself; it checks that the model implements the stated rules and that the model's gauge mirror equals the source.

What each check compares (exact rationals; no tolerances anywhere):

| Check | Statement |
| --- | --- |
| G | after every gauge call (claim all, claim one period, liquidity change with its swallowed auto-claim, mint, burn, notify, governance toggle) the model gauge state (`periodClaimedAmount`, debt, `lastClaim`, r33, balances, `lastModified`, revert flag) equals the oracle gauge state |
| A | exposure: `W[h,p]`, `Z[p]`, `Tt[p]` equal the oracle for every period without an outage-time supply change; for the other (ambiguous) periods `W <= oracle`, `sum W + Z + U == Tt`, `U == 0` elsewhere, and `reconcile` with the oracle-derived residual restores equality |
| F | `funded[p,tok]` equals what the oracle gauge paid the vault for `p`; `lost` equals what the oracle gauge forfeited on vault calls |
| N | `final(p)` is true if and only if the period ended and the oracle gauge owes nothing for it (both directions: no premature finality, no missing finality) |
| E, C | entitlements equal funded times the oracle exposure share; conservation; `claim()` (paginated during the history, unbounded at the end) pays exactly the oracle entitlement of the contiguous final prefix |
| B | the guard (liveness) claim: a liquidity-changing operation is refused if and only if the oracle's section 5.5 predicate says so, with the same reason and the same `retry_after`; an allowed EPOCH batch drains all queued withdrawals; an EPOCH deposit or withdrawal request never touches the gauge (so dust cannot move `lastModified`); a refused operation changes no balance |

Generator: W1 and EPOCH variants (EPOCH with idle buffers 0, 5, 20 percent), three holders, deposits, redeems, transfers, harvests with three tx origins, batches, notifications to the current and the next period (including a second reward token), threshold changes (0, 111, 300, 5000, 1e9), anti-sybil off, validator normal/reverting/replacing, gauge implementation reverting or returning zero, gauge-side pool read failing, blacklisting of origins, wallets, position hashes, vault-side reading failing and recovering, a second NFT created, retired, burned, partial drain/progress/claim calls (pagination), dormant spans of up to three weeks, and time steps aimed at the exact guard boundary (`lastModified + threshold + margin + {-1, 0, 1, 2}`).

### A.2 Verdict

**Mismatches were found. The model has two defects that corrupt or stall the ledger (F1, F2), one design premise that makes the specification fragile (F3), two gaps where the model is weaker than the specification (F4, F5) and two deviations from the gauge source that are benign (F6, F7). Everything else agreed exactly.** Each has a minimal reproduction in `phar_repros.py` (run log `phar_repros_run.txt`).

| # | Finding | Kind | Severity | Minimal reproduction |
| --- | --- | --- | --- | --- |
| F1 | An NFT created while the exposure reading is down, after a burn inside the same failure span, is recorded with the supply at the START of the span (`_resolve_fail` starts a new NFT at `supply_start`). Its exposure is spread over a supply that no longer exists, so it lands on no holder and not in the zero-supply bucket: `sum W + Z + U < Tt`. | model defect (and a spec gap: 5A.4 does not say which supply a new NFT starts with) | High for the affected period (silent loss of attribution, conservation broken); rare: needs a reading outage, a burn inside it, and a new NFT before recovery | R1: deposit A 248; reading down; one period in range; A redeems 50; add NFT 2; reading up. Period sum is 1,087,292.25 against `Tt` 1,209,186 |
| F2 | (Drain path.) Draining (burning) an NFT in period `p` leaves `(nft, p)` unsealed for ever, so `final(p)` and every later `final` stay false, and `claim()` stops at the first non-final period: **every later period becomes unclaimable although the gauge owes nothing.** | model defect in the burn path (the proposal says the design does not need a burn, 5A.6) | High if the burn path is implemented as modelled; avoided by never burning | R2: second NFT, 3 weeks, retire, burn: periods 103 and 104 never final |
| F3 | Finality is exact equality `target - funded - lost == 0` over what the vault itself booked. Anything that moves the gauge's `periodClaimedAmount` without the vault booking it stalls the period for ever (and, because `claim()` stops at the first non-final period, all later ones). The source has one such path that the model lacks: `GaugeV3.sweepForfeited(owner, index, ticks, tokens)` is permissionless (modifier `lock` only) and realises the forfeit debt immediately. It is reachable only after a slash created a debt (guard failure, a governance-authorised claimer, a race with a governance change), but then it converts a recoverable booked loss into a permanent stall. | design premise gap (not modelled, not probed) | Medium to high (liveness of reward claims, no loss of principal) | R5 (sweep emulated on the mirror with the source semantics) |
| F4 | The model's vault guard (`will_slash`) ignores a blacklist of the OWNER address (the position manager), which the gauge's validator checks first; the specified guard (validateReward called with owner = position manager) does detect it. With it blacklisted, a "guarded" harvest is slashed. The 47 tests never blacklist the position manager. | model weaker than the specification | Medium (the test suite could not have caught the omission in an implementation either) | R3 |
| F5 | `Vault2.retire()` makes a liquidity change (so an auto-claim) without the window guard. A freshly minted NFT is inside its own window, so retiring it within 121 s writes a forfeit debt. The specification gates every call that can auto-claim (5.5). | model weaker than the specification | Low (small amount) but it shows the gating list needs a test per entry point | R4 |
| F6 | The gauge caches an ended period's seconds per (period, position hash), not per token (`periodAmountsWritten`, GaugeV3 340 to 343). A claim for any token after the period ended caches it; a later failing pool read no longer hides that period. The model (and the Q8/Q10 reading of "hidden, not gone") treats every period as hidden. | deviation from source, benign direction (the real gauge pays more, never less) | Low | R6 (gauge-only fuzz, strict mode, finds it in about 0.2 percent of histories) |
| F7 | With no validator set the model's guard does not block inside the window; the specification's explicit `lastModified` clause does. The gauge slashes nothing in that state, so nothing is lost either way. | model and spec differ, benign | Low | R7 |

What agreed exactly (no mismatch in the stated number of histories, see A.3): the gauge mirror against the source-based gauge (debt, cascade of earlier periods, `getPeriodReward` scope, caching, validator fail-closed, blacklist orders, burned NFTs, `lastClaim`, zero-mode and reverting gauge implementation), holder exposure in all periods without an outage-time supply change, funding per period, loss booking, finality in both directions (apart from F2/F3), entitlements, conservation, `claim` totals under pagination, and the guard decision including its reason and `retry_after` at the exact boundary (apart from F4/F7).

### A.3 Differential results

Full logs: `avalanche-vault-phar-evidence/tools/phar_difftest_run.txt`. "Aligned" = the generator avoids the two benign guard deviations F4 and F7; "strict" = it emits them.

| Run | Histories x ops | Operations executed | Result |
| --- | --- | --- | --- |
| 1 vault ledger vs oracle, aligned | 20,000 x 45 | 899,100 (61,196 operations refused by the guard, 1,231 ambiguous outage periods, 25,411 funded (period, token) cells, 130,010 final periods compared) | 20 histories differ: 12 are F1 (kind A), 8 are F2 (kind N). All 20 reduce to the minimal histories in `phar_repros.py` |
| 2 same, with minimisation | 600 x 45 | 26,955 | seed 229 minimised to 9 operations (F1) |
| 3 vault ledger vs oracle, strict | 4,000 x 45 | 162,630 (120 loss entries, i.e. real slashes, 24,377 final periods) | 386 histories differ: 382 guard refusals that disagree with the oracle (a position-manager blacklist, F4, or validator absent, F7; re-checked on 1,200 of them with the blacklist and validator state printed: 118 of 118 explained, 0 unexplained), 3 F1, 1 F2 |
| 4 longer histories, aligned | 5,000 x 90 | 445,860 | 46 differ: 37 kind A and 9 kind N; see the confirmation run below |
| 5 gauge mirror vs source-based gauge, gauge-side read never off | 20,000 x 60 | | **0 mismatches** |
| 6 same, gauge-side read may fail | 10,000 x 60 | | 25 mismatches, all F6 (period seconds cached per position hash) |

Confirmation that F1 and F2 explain the aligned mismatches: I patched a scratch copy of `refmodel2.py` (not committed; `final()` ignores drained NFTs, and an NFT created inside a failure span starts with the supply in force at its creation) and reran run 4: 46 failing histories fall to 4. The 4 that remain (minimal: new NFT, reading down, time passes, `retire`, `burn`) are further defects of the same burn path (a drained NFT's unrecorded exposure is dropped and the "nothing outstanding" test of `burn_nft` uses the vault's own, stale, record); I did not chase them. The practical conclusion is that the burn/drain path of the model is unreliable and, since 5A.6 says the design does not need a burn, **the specification should not include one.**

Not a single mismatch of kind G (gauge state), F (funding and loss), E (entitlement, conservation) or C (claim totals) appeared in any run, in about 1.5 million executed vault operations and 30,000 gauge histories; every one of the mismatches above is F1, F2, F4, F6 or F7.


### A.4 Premises of the model checked against the saved evidence

Evidence used: `probe/` P1 to P9 and `probe2/run_final.txt` (Q1 to Q10, 11 test functions, all pass), `avalanche-vault-source-references.md`, and the source copies in the scratchpad `phar/src_*` (fetched from Routescan, cross-checked against Sourcify for six contracts per the references file).

| Premise | Supported by | Verdict |
| --- | --- | --- |
| Slash rule: slashed if `now - lastModified <= timeThresholdForGauge` (111 s), comparison inclusive, `lastModified == 0` never slashed | Source: `RewardValidator.validateReward` 181 to 192; chain read `timeThresholdForGauge` and `timeThresholdForRewarder` both 111 (chain_reads_4); probes P2, Q3, Q5 (a second change 50 s or 100 s later is slashed, the first after a quiet span is not). `mint` sets `lastModified = block.timestamp` (position manager 183), so a new NFT is inside its window. | Supported. Not probed: the exact equality second (`now - lm == 111`), and a gauge-specific threshold that differs from the rewarder's (the validator reads `timeThresholdForGauge(msg.sender)`; the vault's direct pre-check has msg.sender = vault and so reads the rewarder value, which is why 5.5 adds the explicit clause). |
| `getPeriodReward` is one period, `getReward` is all periods from `lastClaim` | Source: `getPeriodReward` 364 to 380 (no debt written, no `lastClaim` change, works for periods below `lastClaim`), `_claimAll` 491 to 509; position manager 437 to 460 (both `isAuthorizedForToken`); probes Q4, Q4b, Q10 | Supported, including that a slashed `getPeriodReward` forfeits only that period and writes no debt. |
| Forfeiture of the backlog: a slashed `getReward` writes a debt (current period, current unpaid); the next clean claim forfeits every earlier unpaid period in full and the current period up to the debt; forfeited tokens go to r33 (else treasury) | Source: `_recordForfeit`, `_forfeitedShare`, `_getReward`, `_slashRecipient`; probes P2, P8, P9, Q3, Q5, Q6 (amounts equal to the wei) | Supported. The recipient is r33 only where set, else the fee collector treasury (`_slashRecipient`); the model books a counter called r33 either way. |
| Burn behaviour: burn with rewards outstanding succeeds and orphans them; afterwards no claim, not even by the former owner | Source: position manager `burn` 468 to 473 (requires zero liquidity and zero `tokensOwed`, otherwise `NotCleared`); probe P5 | Supported for the claim consequence. The model's burn has no `tokensOwed` condition (the vault's fee collection is not modelled). |
| `increaseLiquidity` / `decreaseLiquidity` auto-claim `[PHAR, xPHAR]` with the old `lastModified` inside a swallowed try/catch, receiver = owner | Source: position manager 207 to 221, 254, 291, 319, 361, `getRewardForOwner`; probes P2, Q3 | Supported. Also: `increaseLiquidity` requires `isAuthorizedForToken`, so no third party can open a window on the vault's NFT (the "dust attacker" is a depositor acting through the vault, which is exactly what the queue neutralises). |
| Exposure used by the gauge equals the pool's `positionPeriodSecondsInRange`; additive across NFTs | Probes P7 (to the wei at one pin), Q1 (1.6e-15 relative) | Supported at one pin and one pool. Not probed on the WAVAX pool (U4). |
| A late `notifyRewardAmount` is retroactive for the whole current period; ended periods cannot grow | Source: `notifyRewardAmount` 199 to 215 (current period), `notifyRewardAmountNextPeriod`, `notifyRewardAmountForPeriod` (`period > current` required, `CANT_REWARD_PAST`); probe P4 | Supported. The model's `notify(period)` for future periods is source-supported but no probe exercises the next-period variants. |
| Gauge-side pool read failure: `earned` reports 0, `getReward` pays 0, writes no debt, advances `lastClaim`; recoverable by `getPeriodReward` | Source: `cachePeriodEarned` returns 0 on a failed staticcall; probes Q8, Q10 | Supported for uncached periods; **F6**: the model ignores the per-hash cache. |
| Governance changes (threshold, anti-sybil, validator, blacklist) take effect as the model toggles them | Probes Q6 and Q7 and P9 simulate threshold and wallet blacklist locally by pranking governance; the real access-hub/timelock flow was not read (U3) | Partly. Validator replaced by a contract that always slashes, validator reverting (fail closed by `_shouldSlash`'s catch), **gauge implementation that reverts or returns zero** (`mode revert`, `mode zero`), and receiver or position-hash blacklists exist in the model with source support only for the validator paths and none for the two gauge-implementation modes. They are hypothetical adversaries, not observed behaviour. |
| xPHAR: `xRatio` 0, second token appears mid-period if governance raises it, vault cannot transfer it, exit at 50 percent | Probe P6, chain reads | Supported for transfer and exit. No probe of an emission actually arriving as xPHAR through the gauge; the model treats it as a symmetric second token (a per-hash cache and the validator are token-agnostic, so this is plausible). |
| Threshold `uint32` / timestamp arithmetic, same-block ordering, reentrancy | none | Not modelled, not probed (see A.6). |
| `sweepForfeited` | Source only (GaugeV3) | **Not in the model, not probed** (F3). |

Premises with no probe and no source reading behind them, in one list: the gauge implementation returning zero or reverting as a governance upgrade (adversary invented by the model); the exact-equality second of the window; gauge threshold differing from the rewarder threshold; the access-hub/timelock path by which governance changes parameters; xPHAR emission through the gauge; the next-period notify entry points; WAVAX vault behaviour; and that the Voter implementation and the RewardValidator implementation are what Routescan says (bytecode-to-source not reproduced, U5).

### A.5 The existing 47 tests, and new mutations

Re-run of `test_refmodel2.py` (`python3 -I test_refmodel2.py -v`, log `test_refmodel2_rerun.txt`): **47 tests, 47 pass**, unchanged `refmodel2.py` (sha256 `aaeddb7f0bc3c9ed53e097ba2e69c46f66698ca083b6f2c05657bf977c01fcdb`). That they pass while F1 to F5 exist is the main finding about them: their random histories (60 and 80) are too few and too short to reach a new NFT inside a failure span or a drain-then-burn, and they never blacklist the position manager.

Ten NEW mutations (none of the original six; `phar_mutations.py`, log `mutations_run.txt`; "vault D" = vault-vs-oracle fuzz on the aligned generator, "strict" = same with the F4/F7 operations enabled, "gauge G" = gauge-only fuzz, "47" = the original tests):

| Mutation | vault D | strict | gauge G | 47 tests |
| --- | --- | --- | --- | --- |
| M1 same-period settlement ignores the account's J checkpoint | caught | caught | missed | caught |
| M2 guard boundary off by one (`<` for `<=` at `threshold + margin`) | caught | caught | missed | caught |
| M3 gauge debt cascade dropped (earlier periods forfeit only up to the debt) | missed | missed | caught | missed |
| M4 harvest books forfeited tokens as funded | missed | caught | missed | caught |
| M5 finality ignores the outstanding amount | caught | caught | missed | caught |
| M6 continuing multi-period segment keeps the first period's checkpoint | caught | caught | missed | caught |
| M7 entitlement divided by non-zero-supply exposure only | caught | caught | missed | caught |
| M8 gauge sets `lastModified` before the auto-claim | caught | caught | caught | caught |
| M9 gauge window comparison `<` for `<=` | missed | missed | caught | missed |
| M10 gauge does not decrement the forfeit debt as it is realised | missed | missed | caught | missed |

("caught" for the vault columns means failing histories beyond the three the unmutated model already fails at 1,500 histories; the mutation run used the checks A to N and B; check C was added afterwards.)

Reading: all ten are caught by the new tests; the original 47 catch seven and miss all three gauge-mirror mutations (cascade dropped, boundary `<`, debt not decremented). The vault-level fuzz alone misses M3, M9, M10 (they are only visible when a slash really happens, which the guard prevents in aligned histories) and the gauge-only fuzz catches them; M4 (loss booked as income) needs the strict generator because only the F4 gap produces a slash. This is the point of having both.

### A.6 What remains unproven

- **Solidity rounding.** Everything is exact rational arithmetic. The gauge floors per call (`mulDiv(S, T, WEEK << 96)`), with `T` in X96 units, per NFT, per period, and the vault will floor `J`, `W` and entitlements. The model's exact-equality finality (`target - funded - lost == 0` with a rational target) cannot hold in integers; finality must be defined on the gauge's own integer `cachePeriodEarned == 0` (and, per F3, from `periodClaimedAmount`). The dust bound of 5.9 is untouched by this work.
- **Gas.** Steps are counted, gas is not measured. The per-step estimates (100,000 to 150,000 gas) and the `maxSteps` default are placeholders until Solidity exists.
- **Storage and upgrade safety**, layout, ERC-7201 namespacing, reentrancy (`_update` makes external calls), event ordering inside one transaction.
- **Same-block and same-timestamp concurrency.** Operations are strictly sequential here. Two transactions in one block share `block.timestamp`; the `<=` boundary, `lastModified` as `uint32`, and a keeper racing a depositor are unmodelled.
- **Deployed bytecode.** The Voter implementation and the RewardValidator implementation are attested only by block explorers (Routescan; Sourcify for six other contracts); the source copies I replayed are those, not bytecode-verified. The oracle's gauge is as good as that source.
- **Governance as an adversary.** Modelled as state toggles, not as the real access-hub/timelock flows; the two gauge-implementation modes are inventions.
- **Liveness** is verified for the adversaries the generator emits (dust at the exact boundary, one threshold raise, wallet and hash blacklists, validator replaced, reading outage). An adversary that controls Pharaoh governance remains unbounded, as the proposal states.
- **Coverage gaps of this verification:** no third-party calls on the vault's position other than those the model has (no `sweepForfeited` in the random vault histories, only emulated in R5), no `collect` / `tokensOwed` / fee accrual, no out-of-range price movement beyond the in-range mask, no two-pool or WAVAX run, share-weighted versus liquidity-weighted attribution differences (5.12) not tested.

---

## Part B. The ten questions reduced to five product choices

Mapping. Section 10 items 1 and 10 (policy and parameters, pagination) become **B.1**; items 2, 4 and 9 (governance surface, forced exit, what the vault does on discovering a blacklist) become **B.2**; items 3, 5 and 6 (unresolved intervals, buckets, waiver) become **B.3**; items 7 and 8 (claim availability, xPHAR) become **B.4**; item 11 is **B.5**. Pagination parameters (`maxSteps`, who runs `drain`, maximum dormancy) are implementation details to be set from measured gas, not a product choice. "Halt batches, escalate, never choose a `tx.origin`, caller or receiver to dodge a check" is a consequence of B.2 and a code requirement, not a separate choice.

### B.1 How deposits and withdrawals reach the Pharaoh position

**Question.** Every liquidity change opens a 111 s slash window on the NFT. How are user deposits and withdrawals executed?

**Options.**
1. Synchronous with refusal inside the window (W1). Rejected as a default (proposal 6.4/6.6): a dust attacker (one deposit per 112 s, about 771 transactions and 0.83 AVAX per day at an assumed 2.5 gwei) keeps every liquidity-dependent exit refused; organic refusal rate 0.64, 2.5, 12, 47 percent of requests at 5, 20, 100, 500 liquidity-changing operations per day.
2. Asynchronous queue with one net liquidity change per batch, permissionless, at most once per `threshold + margin`, plus a synchronous idle buffer. Verified here: dust never touches the gauge (check B), an allowed batch serves every queued withdrawal, the refusal predicate and `retry_after` match the oracle at the exact second.
3. Per-NFT cohorts or a sleeve NFT, synchronous. Protects entries only; exits still change liquidity; more NFTs (mint 1.01M gas against 0.28M for an increase), more pool reads and claim loops.

**Recommendation.** Option 2. Starting values (illustrative, none measured): batch floor E = 1 hour (not the 2-minute minimum), margin 10 s, idle buffer 3 percent of NAV, a minimum request size to keep the queue small. Recalibrate buffer and E from the measured redemption pattern and the measured yield before launch.

**Consequences.**
- Fees and PHAR on deployed capital: full. Queued deposits earn nothing until the batch: mean wait E/2 costs 0.114 bps of the deposit at E = 1 hour (assumed 20 percent APR).
- PHAR rewards: none lost by construction (guard before every claim and liquidity change); queued deposits have no share-time and dilute nobody.
- Idle capital: 20 bps of NAV per year per 1 percent of buffer at the assumed 20 percent yield (3 percent is about 60 bps a year; unmeasured).
- Withdrawal availability: instant up to the buffer; beyond it, at the next batch, at most E after the request in a quiet market. Under a raised threshold or a blacklist the liquidity part has no bound (B.2); the buffer part is unaffected.
- Deposit availability: always accepted into the queue; shares are minted at the batch at NAV.
- Trust: nobody has discretion over a batch; any account can run it.

**Blocks any vault launch: yes** (the code cannot be specified further without it). Blocks cash-only lending: no.

### B.2 Pharaoh's governance surface and the exit bound under a raised threshold or a blacklist (OPERATOR ACCEPTS; this document does not)

**Question.** Pharaoh governance can raise the window threshold (probe Q6 sets it to `uint256.max`), blacklist the vault wallet or a position hash, replace the validator, or change the gauge. Then no claim or liquidity change is clean. Principal itself still exits (the gauge never blocks it) but only with the forfeiture, and the design, under hard constraint C, does not forfeit or force. The best bound on the liquidity part of an exit is `lastModified + threshold + margin`, which governance can make indefinite; only the idle buffer is unaffected. Does the operator accept that residual, and what is the response?

**Options.**
1. Accept and disclose the residual; rely on the buffer; on detection, halt batches, publish, escalate to Pharaoh.
2. Before launch, ask Pharaoh to confirm in writing that queued or batched liquidity changes with a clean claim first are acceptable, and to allow-list the vault wallet and its position hashes (their rules are unpublished; one search found only marketing pages). Launch only with an answer and with option 1 accepted for what remains.
3. Do not launch the vault.

Sub-choice, same item: whether a holder-initiated "exit now and accept the loss" path should exist. It cannot be isolated to the exiting holder (the forfeited backlog belongs to all holders of the position), so it would be a loss transfer between holders.

**Recommendation.** Ask Pharaoh first (option 2: no code, no cost); make no launch commitment until the answer and the operator's explicit acceptance of the remainder. Offer no holder-initiated loss-bearing exit in version 1 and keep the recovery policy as it is. The monitored halt (batches stop on a detected blacklist, validator replacement or threshold above a limit, the vault never selects an origin, caller or receiver to avoid a check) is a code requirement under either option. I have not decided or accepted any of it.

**Consequences.**
- Rewards: if governance acts, rewards for the blocked span wait in the gauge; nothing is forfeited by the vault; a gauge-side slash caused by a guard failure is booked as an explicit loss borne pro rata by recorded exposure.
- Withdrawal availability: the buffer part stays instant; the liquidity part can wait indefinitely. A 3 percent buffer means 97 percent of NAV is exposed to that wait.
- Idle capital: the buffer is the only mitigation; raising it costs B.1's drag.
- Trust: permanent dependence on Pharaoh governance (the integration can change under the vault), and an upgrade key still dominates every invariant (B.5).

**Blocks any vault launch: yes**, as a precondition to opening a gate (acceptance, not code). Blocks cash-only lending: no.

### B.3 Reward value that nobody can be shown to own (unresolved intervals, buckets, waiver)

**Question.** Three kinds of value can exist that no holder is entitled to: (a) an UNRESOLVED interval (the exposure reading was down while shares were burned, so the split inside the interval is unknowable without a clock); (b) the zero-supply share, donated PHAR, and an optional waiver; (c) rounding dust. What, if anything, may ever move them?

**Options.**
1. Nothing: no `reconcile`, no release, no waiver; counters only, tokens stay in the vault (the proposal's default, 5.7).
2. Release to an immutable sink fixed at deployment, after a fixed delay of at least 180 days, permissionless trigger, event, no role able to shorten or redirect.
3. `reconcile(period, split)` by a named party on stated evidence (event timestamps, a wall-clock rule the design refuses to apply automatically), plus option 2 for the rest.

**Recommendation.** Option 1 for version 1: the unresolved case needs a reading outage and a burn inside it (and F1 shows that this path still has an unfixed defect), its size is one interval's share of one period, and every mover is added operator trust. Revisit with real occurrence data. No waiver function.

**Consequences.** Fees: none. Rewards: an unresolved interval's share stays locked for good (small, bounded by one interval); other holders' entitlements are unaffected (verified: `U` is in nobody's `W`, and the corresponding funded part is reserved). Idle capital: none. Withdrawals: unaffected. Trust: option 1 adds none; options 2 and 3 add a rule that must be audited and a party that must be trusted.

**Blocks any vault launch: no** (default option 1 is safe and is what the code does without extra work). Decide before code freeze only if option 2 or 3 is wanted. Blocks cash-only lending: no.

### B.4 What holders see: when rewards are claimable, and xPHAR

**Question.** (a) Claims only for final periods (ended, sealed, fully funded): up to a week plus the funding delay after the exposure, longer after a reading outage or a blocked window. Or something earlier. (b) xPHAR (dormant: `xRatio` is 0): hold, or a holder-triggered exit at the 50 percent penalty.

**Options.** (a) final-only claims; or provisional advances against estimates (needs a loss reserve and an owner of the risk). (b) hold, with the ledger token-agnostic; or `exitXPhar` by the holder for their own entitlement only, never operator-triggered or batched, penalty borne by that holder.

**Recommendation.** (a) final-only; (b) hold now, specify `exitXPhar` as the holder's own option, and build nothing xPHAR-specific until `xRatio` is non-zero.

**Consequences.** Rewards: exiting holders collect after the period is final (up to about a week); no loss, no dilution, exact under the ledger. Fees: none. Idle capital: none. Availability: claims do not depend on balance, pause or NAV, and are unaffected by the stress gates. Trust: no operator role. xPHAR: a 50 percent haircut only on the holder who chooses to exit.

**Blocks any vault launch: no** for xPHAR (can follow launch while `xRatio` is 0); the claim-timing wording must be fixed before holders are told anything, but not for the design. Blocks cash-only lending: no.

### B.5 Delivery vehicle and control

**Question.** Replacement vault or upgrade of the existing implementation; who holds the upgrade and admin keys of the result; who writes and who independently reviews the code.

**Options.**
1. New vault, depositors migrate by choice; the old vaults stay closed.
2. Upgrade the existing proxies in place (today: ProxyAdmins owned by a 1-of-1 Safe whose single owner is the rebalancer EOA, upgraded four times in 12 days with no timelock).
3. New vault with a multi-signer, timelocked admin and an independent review before any gate opens.

**Recommendation.** Options 1 and 3 together: a replacement vault under a multi-signer timelocked admin with an independent code review. Option 2 inherits a 1-of-1 key that can defeat every invariant here, and the existing base has no ledger to extend. Lending against vault shares stays off until a market-side reward ledger exists.

**Consequences.** Fees and rewards: migration costs gas and a step for each depositor; nothing is taken. Idle capital: none beyond B.1. Availability: old vaults remain as they are. Trust: the main trust reduction in the whole programme, and the only thing that makes the other guarantees mean anything.

**Blocks any vault launch: yes.** Blocks cash-only lending: no.

### B.6 Operator decisions this document does NOT make

Accepting the Pharaoh governance surface and the unbounded liquidity-exit residual (B.2); whether to ask Pharaoh and what to do with the answer; the recovery policy (unchanged here); any parameter value above (all illustrative); and whether to launch the vault at all.

### B.7 What blocks what

| Decision | Blocks any vault launch | Blocks cash-only lending |
| --- | --- | --- |
| B.1 liquidity-change policy and parameters | yes (needed to specify the code) | no |
| B.2 governance surface acceptance (operator) | yes (precondition to opening a gate) | no |
| B.3 residual value | no (default option 1 is safe) | no |
| B.4 claim timing and xPHAR | no | no |
| B.5 replacement and control | yes | no |

Independently of the decisions, the specification needs these amendments before implementation: capture the supply in force when an NFT is created inside a failure span (F1); seal an NFT's last recorded period when it is drained, or never drain (F2); define period finality from the gauge's own `periodClaimedAmount` and integer `cachePeriodEarned`, with an explicit entry for claims the vault did not initiate, so `sweepForfeited` or any other realisation cannot stall a period (F3); put the owner (position manager) blacklist into the guard and a named test per gated entry point, including retire and rebalance (F4, F5).

---

## Part C. Reproduce

From `avalanche-vault-phar-evidence/tools/` (Python 3, standard library only, a few minutes in total):

```
python3 -I test_refmodel2.py -v                      # the original 47 tests
python3 -I phar_repros.py                            # the findings, one block each
python3 -I phar_difftest.py --n 20000 --mode aligned --minimise
python3 -I phar_difftest.py --n 6000 --mode strict --minimise
python3 -I phar_difftest.py --n 0 --gauge 20000 --gauge-aligned
python3 -I phar_mutations.py --n 1500                # about 4 minutes
```
