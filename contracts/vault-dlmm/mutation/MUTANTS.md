# Mutation checks (W7): PharaohDlmmVault and PharaohDlmmPairValidator

Base: commit `b5540678` (Merge feat/dlmm-vault-fork into integration). Branch `feat/dlmm-vault-mut`. The two source files are byte-identical to that commit at the end of the run
(`git diff --stat b5540678 -- contracts/vault-dlmm/src` is empty). Nothing was signed, sent or pushed; no RPC endpoint was used.

## Score

| | count |
|---|---|
| hand mutants (one change each) | 200 (167 on `PharaohDlmmVault.sol` M01..M167, 33 on `PharaohDlmmPairValidator.sol` V01..V14c) |
| killed by the 419 pre-existing tests | 119 |
| killed only by the new tests (`test/Mutation.t.sol`) | 72 |
| equivalent (argued in the table, not killable) | 9 |
| survived, unexplained | 0 |

**Final score: 191 / (200 - 9) = 100.0 % of the non-equivalent mutants killed** (95.5 % of all 200). The pre-existing suite alone scored 119 / (200 - 9) = 62.3 %.
No kill rests on a fuzz or invariant test alone: every kill has at least one deterministic failing unit test (checked on the table). M07 is killed because the deployment in `setUp` reverts (the mutated ceiling 199_999_999 is below the 200_000_000 cap the suites initialise with); M04 and M50 are killed by `test_setDepositCapBounds`.

## Method

- One textual change per mutant (old text must occur exactly once in the file; the spec is the diff list below). Each mutant was applied to a **scratch copy** of `contracts/vault-dlmm` (5 copies in parallel, each with its own `out`/`cache`), the full unit suite run
  (`forge test --no-match-path 'test/fork/*'`, 419 tests, later 541 with the new file) and the failing tests recorded; the git worktree source was never edited
  (**deviation from the brief**: it asked for in-place edits with `git checkout --` between mutants; the compile of this via-IR project takes 1 to 4 minutes, so the sweep ran in parallel on copies, which also removes any risk of leaving the source mutated).
- Compiler config of the sweep: solc 0.8.35, via-IR, **optimizer off** (for compile time); every equivalent mutant (M11, M93, M110, M128, M129, M156, M157, M158, V01b) and every time-boundary mutant
  (M62, M107, M134, M149) plus a sample of the new-test kills (M21, M24, M69, M73, M84, M85, M86, M121, M123, M135) was **re-run under the real config (optimizer 200)**: identical results.
- Fuzz seed: the first pass was unseeded (its kills all rest on deterministic tests, see above); the later passes (re-runs of the suspect and surviving mutants, and the real-config check) ran with `FOUNDRY_FUZZ_SEED=0x2a` and an emptied `cache/fuzz` / `cache/invariant` before each mutant, so a kill never depends on a lucky or a persisted counterexample.
- Fork tests (94, shared lock, RPC): **none was needed**. Every mutant was either killed by a unit/mock test or is equivalent, so no fork run was made, no lock was taken and no endpoint was touched.
- Full suite at the end, real config, plain `forge test` in the worktree: **541 passed, 0 failed, 7 skipped** (the 7 fork suites skip without `DLMM_FORK_BLOCK`).

## Finding in the existing suite (not changed here)

`FuzzTest::testFuzz_depositShareValueNeverExceedsAssets` (and its Flipped twin) **fails on the unmutated source** for a rare input, found during the first (unseeded) sweep and then replayed by forge from `cache/fuzz/failures`:
`first = 1911880305644076833487114229076, income = 35271246637922355855, amt = 12539887258264965128491181840794683951595290493545185096511`
fails `assertGe(n1 * d0, n0 * d1, "share price did not fall on deposit")` with `3495705172959232 < 3495705172960626` (a shortfall of 1394 on 3.5e15, 4e-10 relative).
DERIVED, not separately proven: with the OZ virtual offset (`totalAssets() + 1`, `totalSupply() + 1`) the minted shares round to more than the exact price when the share price is above 1 (income inside the bins), so the share price can fall by a rounding amount; the assertion has no tolerance.
It is a test-precision issue (one unit or 1e-9 relative of tolerance would fix it), not a vault defect. Effect on this report: the persisted failure made that one test fail for every later mutant in the same scratch copy, so those first-pass kills were **discarded** and all 81 mutants whose only killer was this test were re-run with a clean cache (14 killed, 67 survived and were then handled by the new tests). The table below never lists this test.

## New tests (`contracts/vault-dlmm/test/Mutation.t.sol`, 61 test functions, 122 tests with the Flipped twins)

Contracts: `MutationTest` (43: guard boundaries, NAV rounding, entry/exit gates, band and swap checks, deadlines), `MutationInitTest` (18: one fixture per validator check with the EXACT `PairValidationFailed(n)`, the 13b health read, the decimal scale case at bin step 100)
and their `...FlippedTest` twins (USDC as X). Mapping test to mutants killed that no earlier test killed:

- `test_bit16_decimalScalesAtBinStep100`: M21
- `test_bit16_deviationExactlyAtTheThresholdIsSafe`: M24
- `test_bit16_farFromPegIdIsADeviation`: M23
- `test_bit32_hookElsewhereWhileIsLinkedStillTrue`: M153
- `test_bit4_exactBandEdgeIsSafeOneUnitBeyondTrips`: M25
- `test_bit8_exactBandEdgeIsSafeOneUnitBeyondTrips`: M26
- `test_check10_beaconZeroOrNotListingTheRewarder`: V10, V10a
- `test_check12_rewardTokenZeroOrALeg`: V12, V12a, V12b, V12c
- `test_check13_feedDecimalsEachFeed`: V13b
- `test_check13b_unhealthyFeedsAtDeployment`: M106
- `test_check14_tokenDecimalsAboveEighteen`: V14, V14a, V14b, V14c
- `test_check1_everyZeroFieldIsRefused`: V01, V01a, V01c
- `test_check2_assetEqualsPairToken`: V02
- `test_check3_registryHasNoPairOrAnotherPairOrAnotherBinStep`: V03a
- `test_check4_pairDisagreesOnFactoryOrBinStep`: V04, V04a, V04b
- `test_check5_pairTokensAreNotExactlyTheTwoLegs`: V05, V05a
- `test_check6_routerFromAnotherFactory`: V06
- `test_check7_hookIsNotTheRewarder`: V07
- `test_check8_rewarderNotLinked`: V08
- `test_check9_voterZeroOrRouterNotAuthorised`: V09a
- `test_guardSurvivesAFeedReturningShortData`: M113
- `test_initEmitsDepositCapSetFromZero`: M12
- `test_lastHolderExitClearsTheBandFlagEvenWithADustBinLeft`: M123
- `test_maxDepositAndMaxMintAreZeroWhileLatchedEvenWhenLiveSafe`: M136
- `test_maxDepositAndMaxMintAreZeroWhileLiveUnsafe`: M138
- `test_maxMintFloorsAndMintingItStaysInsideTheCap`: M118
- `test_navValuesTheUsdtLegRoundingDown`: M120
- `test_openBandChecksActiveIdBeforeItsOwnSwap`: M86
- `test_openBandDeadline`: M148, M149
- `test_openBandHonoursACallerMinOutAboveTheOracleFloor`: M78
- `test_openBandNavLossExactlyAtTheBoundIsAllowedOneUnitMoreIsNot`: M73
- `test_openBandNavLossTooLargeWhenTheNewBandIsWorthLess`: M71, M75
- `test_openBandRechecksActiveIdAfterItsOwnSwap`: M85
- `test_openBandSwapFloorUsesTheAssetToPairPrice`: M127
- `test_openBandWhileABandExistsRevertsBandExists`: M147
- `test_openBandWithNoFundsRevertsNothingToDeploy`: M151
- `test_openBandWithToleratedIdDifferenceBelowBuildsBandAroundRealId`: M90, M91, M92
- `test_openBandWithToleratedIdDifferenceBuildsBandAroundRealId`: M90, M91, M92
- `test_partialExitWithNoBinSharesLeftClearsTheBandFlag`: M124
- `test_partialInKindBurnsTheFlooredBinSlice`: M121
- `test_rebalanceAllowedCountsTheEdgeBinsAsInRange`: M133
- `test_rebalanceAllowedReadyAtIsTheLaterOfCooldownAndNextDay`: M135
- `test_rebalanceAllowedReportsTheLatchAfterRecovery`: M131
- `test_rebalanceChecksActiveIdBeforeBurning`: M84
- `test_rebalanceDeadline`: M148, M149
- `test_rebalanceHonoursACallerMinOutAboveTheOracleFloor`: M78
- `test_rebalanceNavLossTooLargeWhenTheNewBandIsWorthLess`: M71, M74
- `test_rebalanceSwapFloorRejectsAOnePercentSwapEvenWhenNavLossIsSmall`: M76, M77, M79
- `test_rebalanceSwapOfExactlyMaxSwapBpsOfNavIsAllowed`: M69
- `test_rebalanceWithToleratedIdDifferenceBuildsBandAroundRealId`: M90, M91, M92
- `test_rebalanceWithZeroSwapSkipsTheSwap`: M167
- `test_redeemInKindMoreThanOwnedRevertsExceededMaxRedeem`: M58
- `test_redeemInKindPaysTheReceiverNotTheCaller`: M159
- `test_redeemInKindThatPaysNothingRevertsExitFailed`: M162
- `test_redeemInKindZeroReceiverAndZeroSharesHaveTheirOwnErrors`: M163, M164
- `test_redeemPaysTheReceiverNotTheCaller`: M160
- `test_redeemThatPaysNothingRevertsExitFailed`: M161

Tests that pin behaviour without killing a new mutant on their own: `test_controlHealthyWorldInitialises`, `test_zeroOwnerIsRefusedByOwnable` (documents why V01b is equivalent), `test_check11_codehashPin`, `test_rebalanceSmallSwapWithinTheFloorSucceeds` (control for the swap-floor test).

## Coverage of the brief

cap check in deposit M01, in mint M02; ceiling check in `setDepositCap` M03/M04; cap constant at initialize M05..M09; guard bits 1,2,4,8,16,32 M13..M18; bit-16 orientation M19..M22; latch not set M27; `clearGuard` without the live check M31/M32, by anyone M33;
`setGuardParams` bounds (all 14) M35..M48, access M49; `redeemInKind` gated by pause M51, guard M52, latch M53, makes an oracle read M54/M56, makes a swap M55; exit-triggered precondition M59/M60; cooldown M61/M62; daily cap M63/M64/M130;
`maxSwapBps` M68..M70; NAV-loss M71..M75; swap min-out M76..M81; `ActiveIdMoved` M82..M86; band around `expectedActiveId` M90..M92; `openBand` by non-rebalancer M94; `rebalance` by anyone M95, by owner M96; role check removed M97; harvest to `msg.sender` M100;
paused flag not set M104; staleness `>`/`>=` M107; answer `<= 0` M108/M109; rounding M115..M122; pair validation, all 14 checks and their halves V01..V14c.

## Equivalent mutants (9)

M11, M93, M110, M128, M129, M156, M157, M158, V01b. The reason is in the "killed by" column of each row.


## Table

| id | file:line | change | killed by | status |
|---|---|---|---|---|
| M01 | `PharaohDlmmVault.sol:217` | deposit: cap check removed | `CapTest::test_depositOverCapReverts`, `CapTest::test_depositUpToCapExactly`, `CapTest::test_maxDepositTracksHeadroom` (+3 more) | KILLED |
| M02 | `PharaohDlmmVault.sol:226` | mint: cap check removed | `CapTest::test_mintCapEnforcedAndMaxMintBounded`, `FuzzTest::testFuzz_noSequencePassesTheCap`, `InvariantTest::invariant_noEntryPassedTheCap` | KILLED |
| M03 | `PharaohDlmmVault.sol:751` | setDepositCap: ceiling check removed | `CapTest::test_setDepositCapBounds`, `W2SmokeTest::test_harvestAndParams` | KILLED |
| M04 | `PharaohDlmmVault.sol:751` | setDepositCap: ceiling check > to >= | `CapTest::test_setDepositCapBounds` | KILLED |
| M05 | `PharaohDlmmVault.sol:124` | initialize: ceiling check removed | `CapTest::test_initCapAboveCeilingReverts`, `W2SmokeTest::test_initRejectsWrongCodehashAndCap` | KILLED |
| M06 | `PharaohDlmmVault.sol:114` | ceiling constant 200_000_000 -> 200_000_001 | `CapTest::test_initCapAboveCeilingReverts`, `CapTest::test_initReadBacks`, `CapTest::test_setDepositCapBounds` (+3 more) | KILLED |
| M07 | `PharaohDlmmVault.sol:114` | ceiling constant 200_000_000 -> 199_999_999 | setUp reverts (deployment with the mutated ceiling) | KILLED |
| M08 | `PharaohDlmmVault.sol:160` | initialize: stored cap = requested + 1 | `CapTest::test_depositOverCapReverts`, `CapTest::test_depositUpToCapExactly`, `CapTest::test_initReadBacks` (+4 more) | KILLED |
| M09 | `PharaohDlmmVault.sol:160` | initialize: stored cap = ceiling regardless of the request | `CapTest::test_initZeroCapIsNeverUnlimited` | KILLED |
| M10 | `PharaohDlmmVault.sol:729` | _checkCap: > to >= | `CapTest::test_depositUpToCapExactly`, `CapTest::test_openBandAtCapWorks`, `ExitsTest::test_inKind_conservation_secondHolderNotDiluted` (+3 more) | KILLED |
| M11 | `PharaohDlmmVault.sol:205` | maxDeposit: >= to > (nav == cap gives 0 either way) | nav == cap: `depositCap - nav` is 0 on the equal branch too, both sides return 0 | EQUIVALENT |
| M12 | `PharaohDlmmVault.sol:173` | initialize: DepositCapSet event reports 0 | `MutationTest::test_initEmitsDepositCapSetFromZero` | KILLED (new test) |
| M13 | `PharaohDlmmVault.sol:648` | guard bit 1 (asset feed bad) disabled | `FuzzTest::testFuzz_guardBitsMatchTheModel`, `GuardTest::test_bit1_answerNegative`, `GuardTest::test_bit1_answerZero` (+8 more) | KILLED |
| M14 | `PharaohDlmmVault.sol:649` | guard bit 2 (pair feed bad) disabled | `FuzzTest::testFuzz_guardBitsMatchTheModel`, `GuardTest::test_bit2_answerNegative`, `GuardTest::test_bit2_answerZero` (+6 more) | KILLED |
| M15 | `PharaohDlmmVault.sol:651` | guard bit 4 (asset leg out of band) disabled | `ExitsTest::test_inKind_withEveryConditionAtOnce`, `ExitsTest::test_inKind_withGuardLatched`, `ExitsTest::test_redeem_worksWithPauseAndLatch` (+5 more) | KILLED |
| M16 | `PharaohDlmmVault.sol:652` | guard bit 8 (pair leg out of band) disabled | `ExitsTest::test_inKind_100PercentInTheDepeggedLeg`, `FuzzTest::testFuzz_guardBitsMatchTheModel`, `GuardTest::test_bit8_blocksEntries` (+6 more) | KILLED |
| M17 | `PharaohDlmmVault.sol:653` | guard bit 16 (pool/oracle deviation) disabled | `GuardTest::test_bit16_blocksEntries`, `GuardTest::test_bit16_blocksRebalance`, `GuardTest::test_bit16_feedsMoveWithinBandStillDeviate` (+8 more) | KILLED |
| M18 | `PharaohDlmmVault.sol:654` | guard bit 32 (rewarder) disabled | `ExitsTest::test_hook_unlinkRestoresExits`, `GuardTest::test_bit32_blocksEntries`, `GuardTest::test_bit32_blocksRebalance` (+8 more) | KILLED |
| M19 | `PharaohDlmmVault.sol:690` | bit 16 orientation: oracle ratio inverted (Y per X -> X per Y) | `GuardTest::test_bit16_orientationPoolAtTruePriceIsSafe`, `GuardTest::test_bit16_orientationWrongWayPoolTrips` | KILLED |
| M20 | `PharaohDlmmVault.sol:688` | bit 16 orientation: oracle price legs swapped for the X/Y order | `GuardTest::test_bit16_orientationPoolAtTruePriceIsSafe`, `GuardTest::test_bit16_orientationWrongWayPoolTrips` | KILLED |
| M21 | `PharaohDlmmVault.sol:685` | bit 16: decimal scales swapped for the X/Y order | `MutationInitTest::test_bit16_decimalScalesAtBinStep100` | KILLED (new test) |
| M22 | `PharaohDlmmVault.sol:683` | bit 16: sign of the bin offset inverted | `GuardTest::test_bit16_orientationPoolAtTruePriceIsSafe`, `GuardTest::test_bit16_orientationWrongWayPoolTrips` | KILLED |
| M23 | `PharaohDlmmVault.sol:681` | bit 16: far-from-peg id no longer a deviation | `MutationTest::test_bit16_farFromPegIdIsADeviation` | KILLED (new test) |
| M24 | `PharaohDlmmVault.sol:691` | bit 16: deviation threshold > to >= | `MutationTest::test_bit16_deviationExactlyAtTheThresholdIsSafe` | KILLED (new test) |
| M25 | `PharaohDlmmVault.sol:651` | bit 4: band > to >= | `MutationTest::test_bit4_exactBandEdgeIsSafeOneUnitBeyondTrips` | KILLED (new test) |
| M26 | `PharaohDlmmVault.sol:652` | bit 8: band > to >= | `MutationTest::test_bit8_exactBandEdgeIsSafeOneUnitBeyondTrips` | KILLED (new test) |
| M27 | `PharaohDlmmVault.sol:593` | tripGuard: latch not set | `ExitsTest::test_inKind_withGuardLatched`, `FuzzTest::testFuzz_guardNeverRevertsAndLatchableMaskHolds`, `GuardTest::test_latchBlocksOpenBand` (+5 more) | KILLED |
| M28 | `PharaohDlmmVault.sol:53` | tripGuard latchable mask 15 -> 31 (bit 16 latchable) | `FuzzTest::testFuzz_guardNeverRevertsAndLatchableMaskHolds`, `GuardTest::test_tripGuardRevertsWhenNothingLatchable` | KILLED |
| M29 | `PharaohDlmmVault.sol:53` | tripGuard latchable mask 15 -> 63 (bits 16 and 32 latchable) | `FuzzTest::testFuzz_guardNeverRevertsAndLatchableMaskHolds`, `GuardTest::test_tripGuardRevertsWhenNothingLatchable` | KILLED |
| M30 | `PharaohDlmmVault.sol:592` | tripGuard: no-latchable-reason revert removed | `FuzzTest::testFuzz_guardNeverRevertsAndLatchableMaskHolds`, `GuardTest::test_tripGuardRevertsWhenNothingLatchable` | KILLED |
| M31 | `PharaohDlmmVault.sol:599` | clearGuard: live-safe check removed | `GuardTest::test_clearGuardRefusedUnderLiveBit16and32`, `GuardTest::test_clearGuardRefusedWhileLiveUnsafe`, `GuardTest::test_tripLatchesOnlyLatchableBitsEvenWhenOthersHold` | KILLED |
| M32 | `PharaohDlmmVault.sol:599` | clearGuard: live-safe check only on latchable bits (bits 16, 32 ignored) | `GuardTest::test_clearGuardRefusedUnderLiveBit16and32`, `GuardTest::test_tripLatchesOnlyLatchableBitsEvenWhenOthersHold` | KILLED |
| M33 | `PharaohDlmmVault.sol:597` | clearGuard: callable by anyone | `GuardTest::test_clearGuardOwnerOnly`, `W2SmokeTest::test_guardLatchAndClear` | KILLED |
| M34 | `PharaohDlmmVault.sol:600` | clearGuard: latch not cleared | `GuardTest::test_clearGuardReleasesWhenSafe`, `W2SmokeTest::test_guardLatchAndClear` | KILLED |
| M35 | `PharaohDlmmVault.sol:762` | setGuardParams bound loosened: legBandBps lower 10 | `GuardTest::test_setGuardParamsBounds_legBandBps`, `W2SmokeTest::test_harvestAndParams` | KILLED |
| M36 | `PharaohDlmmVault.sol:762` | setGuardParams bound loosened: legBandBps upper 200 | `FuzzTest::testFuzz_guardParamsBounds`, `GuardTest::test_setGuardParamsBounds_legBandBps` | KILLED |
| M37 | `PharaohDlmmVault.sol:762` | setGuardParams bound loosened: maxFeedAge lower 3600 | `GuardTest::test_setGuardParamsBounds_maxFeedAge` | KILLED |
| M38 | `PharaohDlmmVault.sol:762` | setGuardParams bound loosened: maxFeedAge upper 172800 | `GuardTest::test_setGuardParamsBounds_maxFeedAge` | KILLED |
| M39 | `PharaohDlmmVault.sol:763` | setGuardParams bound loosened: maxPoolOracleDevBps lower 20 | `FuzzTest::testFuzz_guardParamsBounds`, `GuardTest::test_setGuardParamsBounds_maxPoolOracleDevBps` | KILLED |
| M40 | `PharaohDlmmVault.sol:763` | setGuardParams bound loosened: maxPoolOracleDevBps upper 300 | `FuzzTest::testFuzz_guardParamsBounds`, `GuardTest::test_setGuardParamsBounds_maxPoolOracleDevBps` | KILLED |
| M41 | `PharaohDlmmVault.sol:763` | setGuardParams bound loosened: rebalanceCooldown lower 111 | `GuardTest::test_setGuardParamsBounds_rebalanceCooldown` | KILLED |
| M42 | `PharaohDlmmVault.sol:764` | setGuardParams bound loosened: rebalanceCooldown upper 3600 | `GuardTest::test_setGuardParamsBounds_rebalanceCooldown` | KILLED |
| M43 | `PharaohDlmmVault.sol:764` | setGuardParams bound loosened: maxRebalancesPerDay lower 4 | `FuzzTest::testFuzz_guardParamsBounds`, `GuardTest::test_setGuardParamsBounds_maxRebalancesPerDay` | KILLED |
| M44 | `PharaohDlmmVault.sol:764` | setGuardParams bound loosened: maxRebalancesPerDay upper 96 | `GuardTest::test_setGuardParamsBounds_maxRebalancesPerDay` | KILLED |
| M45 | `PharaohDlmmVault.sol:765` | setGuardParams bound loosened: maxSwapBps lower 1 (zero allowed) | `GuardTest::test_setGuardParamsBounds_maxSwapBps` | KILLED |
| M46 | `PharaohDlmmVault.sol:765` | setGuardParams bound loosened: maxSwapBps upper 10000 | `GuardTest::test_setGuardParamsBounds_maxSwapBps` | KILLED |
| M47 | `PharaohDlmmVault.sol:765` | setGuardParams bound loosened: maxRebalanceLossBps lower 5 | `GuardTest::test_setGuardParamsBounds_maxRebalanceLossBps` | KILLED |
| M48 | `PharaohDlmmVault.sol:765` | setGuardParams bound loosened: maxRebalanceLossBps upper 300 | `GuardTest::test_setGuardParamsBounds_maxRebalanceLossBps` | KILLED |
| M49 | `PharaohDlmmVault.sol:756` | setGuardParams: callable by anyone | `GuardTest::test_setGuardParamsOwnerOnly` | KILLED |
| M50 | `PharaohDlmmVault.sol:750` | setDepositCap: callable by anyone | `CapTest::test_setDepositCapBounds` | KILLED |
| M51 | `PharaohDlmmVault.sol:265` | redeemInKind gated by pause | `ExitsTest::test_inKind_100PercentInTheDepeggedLeg`, `ExitsTest::test_inKind_idleOnlyNoBand`, `ExitsTest::test_inKind_withEveryConditionAtOnce` (+3 more) | KILLED |
| M52 | `PharaohDlmmVault.sol:265` | redeemInKind gated by guard (live reasons) and latch via _requireEntryOk | `ExitsTest::test_hook_unlinkRestoresExits`, `ExitsTest::test_inKind_100PercentInTheDepeggedLeg`, `ExitsTest::test_inKind_100PercentInTheOtherLeg` (+9 more) | KILLED |
| M53 | `PharaohDlmmVault.sol:265` | redeemInKind gated by the latch only | `ExitsTest::test_inKind_100PercentInTheDepeggedLeg`, `ExitsTest::test_inKind_withEveryConditionAtOnce`, `ExitsTest::test_inKind_withGuardLatched` (+1 more) | KILLED |
| M54 | `PharaohDlmmVault.sol:265` | redeemInKind makes an oracle read (strict feeds) | `ExitsTest::test_inKind_100PercentInTheDepeggedLeg`, `ExitsTest::test_inKind_100PercentInTheOtherLeg`, `ExitsTest::test_inKind_idleOnlyNoBand` (+9 more) | KILLED |
| M55 | `PharaohDlmmVault.sol:277` | redeemInKind makes a router swap of half the USDt leg | `ExitsTest::test_hook_swapHookDown_inKindWorksUsdcRedeemNeedsTheSwap`, `ExitsTest::test_inKind_100PercentInTheDepeggedLeg`, `ExitsTest::test_inKind_basicProRataAndEvent` (+9 more) | KILLED |
| M56 | `PharaohDlmmVault.sol:265` | redeemInKind evaluates the guard (feed staticcalls, no revert) | `ExitsTest::test_inKind_100PercentInTheDepeggedLeg`, `ExitsTest::test_inKind_idleOnlyNoBand`, `ExitsTest::test_inKind_withEveryConditionAtOnce` (+6 more) | KILLED |
| M57 | `PharaohDlmmVault.sol:274` | redeemInKind: allowance not spent (anyone can redeem for an owner) | `ExitsTest::test_inKind_allowanceAndInputs` | KILLED |
| M58 | `PharaohDlmmVault.sol:273` | redeemInKind: excess-shares check removed (burn reverts instead) | `MutationTest::test_redeemInKindMoreThanOwnedRevertsExceededMaxRedeem` | KILLED (new test) |
| M59 | `PharaohDlmmVault.sol:412` | rebalance: exit-triggered precondition removed (rebalances while in range) | `RebalanceTest::test_rebalanceNotOutOfRange`, `RebalanceTest::test_rebalanceNotOutOfRangeAtTheEdge`, `W2SmokeTest::test_rebalanceFlow` | KILLED |
| M60 | `PharaohDlmmVault.sol:414` | rebalance: edge bins count as out of range | `RebalanceTest::test_rebalanceNotOutOfRangeAtTheEdge` | KILLED |
| M61 | `PharaohDlmmVault.sol:418` | rebalance: cooldown removed | `RebalanceTest::test_rebalanceCooldown`, `RebalanceTest::test_rebalanceCooldownFollowsParams` | KILLED |
| M62 | `PharaohDlmmVault.sol:418` | rebalance: cooldown < to <= | `RebalanceTest::test_rebalanceCooldown` | KILLED |
| M63 | `PharaohDlmmVault.sol:424` | rebalance: daily cap off by one (>= to >) | `RebalanceTest::test_rebalanceDailyCap` | KILLED |
| M64 | `PharaohDlmmVault.sol:424` | rebalance: daily cap removed | `RebalanceTest::test_rebalanceDailyCap` | KILLED |
| M65 | `PharaohDlmmVault.sol:420` | rebalance: daily counter never reset on a new day | `RebalanceTest::test_dailyCapResetsAtUtcMidnightNotRolling24h`, `RebalanceTest::test_rebalanceDailyCap` | KILLED |
| M66 | `PharaohDlmmVault.sol:441` | rebalance: daily counter never incremented | `RebalanceTest::test_dailyCapResetsAtUtcMidnightNotRolling24h`, `RebalanceTest::test_rebalanceCooldown`, `RebalanceTest::test_rebalanceDailyCap` (+2 more) | KILLED |
| M67 | `PharaohDlmmVault.sol:440` | rebalance: lastRebalanceAt never written | `RebalanceTest::test_rebalanceCooldown`, `RebalanceTest::test_rebalanceCooldownFollowsParams`, `RebalanceTest::test_rebalanceRecentresUp` (+1 more) | KILLED |
| M68 | `PharaohDlmmVault.sol:461` | _guardedSwap: maxSwapBps ignored | `RebalanceTest::test_rebalanceSwapTooLarge`, `RebalanceTest::test_rebalanceSwapTooLargeFollowsParams` | KILLED |
| M69 | `PharaohDlmmVault.sol:461` | _guardedSwap: > to >= | `MutationTest::test_rebalanceSwapOfExactlyMaxSwapBpsOfNavIsAllowed` | KILLED (new test) |
| M70 | `PharaohDlmmVault.sol:459` | _guardedSwap: maxIn = 100 % of NAV | `RebalanceTest::test_rebalanceSwapTooLarge`, `RebalanceTest::test_rebalanceSwapTooLargeFollowsParams` | KILLED |
| M71 | `PharaohDlmmVault.sol:547` | _checkNavLoss: check removed (both call sites) | `MutationTest::test_openBandNavLossTooLargeWhenTheNewBandIsWorthLess`, `MutationTest::test_rebalanceNavLossTooLargeWhenTheNewBandIsWorthLess` | KILLED (new test) |
| M72 | `PharaohDlmmVault.sol:547` | _checkNavLoss: comparison inverted | `CapTest::test_openBandAboveCapIsNotBlockedByTheCap_D6`, `CapTest::test_openBandAtCapWorks`, `ExitsTest::test_control_depositAndRedeemDoReadTheFeeds` (+7 more) | KILLED |
| M73 | `PharaohDlmmVault.sol:547` | _checkNavLoss: < to <= | `MutationTest::test_openBandNavLossExactlyAtTheBoundIsAllowedOneUnitMoreIsNot` | KILLED (new test) |
| M74 | `PharaohDlmmVault.sol:438` | rebalance: NAV-loss check removed | `MutationTest::test_rebalanceNavLossTooLargeWhenTheNewBandIsWorthLess` | KILLED (new test) |
| M75 | `PharaohDlmmVault.sol:394` | openBand: NAV-loss check removed | `MutationTest::test_openBandNavLossTooLargeWhenTheNewBandIsWorthLess` | KILLED (new test) |
| M76 | `PharaohDlmmVault.sol:464` | _guardedSwap: swap min-out removed (0) | `MutationTest::test_rebalanceSwapFloorRejectsAOnePercentSwapEvenWhenNavLossIsSmall` | KILLED (new test) |
| M77 | `PharaohDlmmVault.sol:464` | _guardedSwap: oracle floor ignored (caller min-out only) | `MutationTest::test_rebalanceSwapFloorRejectsAOnePercentSwapEvenWhenNavLossIsSmall` | KILLED (new test) |
| M78 | `PharaohDlmmVault.sol:464` | _guardedSwap: caller min-out ignored (oracle floor only) | `MutationTest::test_openBandHonoursACallerMinOutAboveTheOracleFloor`, `MutationTest::test_rebalanceHonoursACallerMinOutAboveTheOracleFloor` | KILLED (new test) |
| M79 | `PharaohDlmmVault.sol:464` | _guardedSwap: max(min-out, floor) -> min | `MutationTest::test_rebalanceSwapFloorRejectsAOnePercentSwapEvenWhenNavLossIsSmall` | KILLED (new test) |
| M80 | `PharaohDlmmVault.sol:463` | _guardedSwap: oracle floor without loss allowance (100 % of oracle out) | `CapTest::test_openBandAboveCapIsNotBlockedByTheCap_D6`, `CapTest::test_openBandAtCapWorks`, `ExitsTest::test_control_depositAndRedeemDoReadTheFeeds` (+7 more) | KILLED |
| M81 | `PharaohDlmmVault.sol:295` | redeem payout swap: min-out removed | `ExitsTest::test_redeem_revertsWhenThePoolPaysBelowTheOracleMinimum` | KILLED |
| M82 | `PharaohDlmmVault.sol:553` | _checkActive: ActiveIdMoved check removed (all call sites) | `RebalanceTest::test_openBandActiveIdMoved`, `RebalanceTest::test_rebalanceActiveIdMoved` | KILLED |
| M83 | `PharaohDlmmVault.sol:553` | _checkActive: > to >= | `W2SmokeTest::test_capExactThenOneWeiRevertsAndOpenBandSurvivesFavourableSwap`, `W2SmokeTest::test_depositCapAndOpenBand`, `W2SmokeTest::test_depositWhileBandThenRebalanceFoldsIdle` (+7 more) | KILLED |
| M84 | `PharaohDlmmVault.sol:425` | rebalance: pre-burn ActiveIdMoved check removed | `MutationTest::test_rebalanceChecksActiveIdBeforeBurning` | KILLED (new test) |
| M85 | `PharaohDlmmVault.sol:491` | _addBand: post-swap ActiveIdMoved check removed | `MutationTest::test_openBandRechecksActiveIdAfterItsOwnSwap` | KILLED (new test) |
| M86 | `PharaohDlmmVault.sol:379` | openBand: pre-swap ActiveIdMoved check removed | `MutationTest::test_openBandChecksActiveIdBeforeItsOwnSwap` | KILLED (new test) |
| M87 | `PharaohDlmmVault.sol:378` | openBand: idSlippage bound removed | `RebalanceTest::test_openBandIdSlippageAboveTwoReverts` | KILLED |
| M88 | `PharaohDlmmVault.sol:410` | rebalance: idSlippage bound removed | `RebalanceTest::test_rebalanceIdSlippageAboveTwoReverts` | KILLED |
| M89 | `PharaohDlmmVault.sol:43` | MAX_ID_SLIPPAGE 2 -> 3 | `RebalanceTest::test_openBandIdSlippageAboveTwoReverts`, `RebalanceTest::test_rebalanceIdSlippageAboveTwoReverts` | KILLED |
| M90 | `PharaohDlmmVault.sol:527` | _addBand: router activeIdDesired = expectedActiveId instead of the real id | `MutationTest::test_openBandWithToleratedIdDifferenceBelowBuildsBandAroundRealId`, `MutationTest::test_openBandWithToleratedIdDifferenceBuildsBandAroundRealId`, `MutationTest::test_rebalanceWithToleratedIdDifferenceBuildsBandAroundRealId` | KILLED (new test) |
| M91 | `PharaohDlmmVault.sol:540` | _addBand: stored band built around expectedActiveId | `MutationTest::test_openBandWithToleratedIdDifferenceBelowBuildsBandAroundRealId`, `MutationTest::test_openBandWithToleratedIdDifferenceBuildsBandAroundRealId`, `MutationTest::test_rebalanceWithToleratedIdDifferenceBuildsBandAroundRealId` | KILLED (new test) |
| M92 | `PharaohDlmmVault.sol:492` | _addBand: active = expectedActiveId (band and router id around the expected id) | `MutationTest::test_openBandWithToleratedIdDifferenceBelowBuildsBandAroundRealId`, `MutationTest::test_openBandWithToleratedIdDifferenceBuildsBandAroundRealId`, `MutationTest::test_rebalanceWithToleratedIdDifferenceBuildsBandAroundRealId` | KILLED (new test) |
| M93 | `PharaohDlmmVault.sol:528` | _addBand: caller idSlippage forwarded to the router | the router is always given `activeIdDesired` = the real active id, so its slippage window (`desired +- idSlippage`) can never be hit whatever idSlippage it is handed | EQUIVALENT |
| M94 | `PharaohDlmmVault.sol:374` | openBand: callable by anyone | `RebalanceTest::test_openBandOnlyRebalancer`, `SharesTest::test_onlyTheKeeperCanOpenAndRebalance`, `SharesTest::test_setRebalancer` | KILLED |
| M95 | `PharaohDlmmVault.sol:408` | rebalance: callable by anyone | `RebalanceTest::test_rebalanceRoleGated` | KILLED |
| M96 | `PharaohDlmmVault.sol:185` | onlyRebalancer also accepts the owner (openBand and rebalance) | `SharesTest::test_onlyTheKeeperCanOpenAndRebalance` | KILLED |
| M97 | `PharaohDlmmVault.sol:185` | onlyRebalancer: role check removed (openBand and rebalance) | `RebalanceTest::test_openBandOnlyRebalancer`, `RebalanceTest::test_rebalanceRoleGated`, `SharesTest::test_onlyTheKeeperCanOpenAndRebalance` (+1 more) | KILLED |
| M98 | `PharaohDlmmVault.sol:567` | harvestRewards: caller check removed | `SharesTest::test_harvestRewards` | KILLED |
| M99 | `PharaohDlmmVault.sol:567` | harvestRewards: owner not accepted | `SharesTest::test_harvestWorksWithDeadFeedsPausedAndLatched` | KILLED |
| M100 | `PharaohDlmmVault.sol:574` | harvestRewards: PHAR forwarded to msg.sender instead of owner | `SharesTest::test_harvestRewards`, `W2SmokeTest::test_harvestAndParams` | KILLED |
| M101 | `PharaohDlmmVault.sol:744` | setRebalancer: callable by anyone | `SharesTest::test_setRebalancer` | KILLED |
| M102 | `PharaohDlmmVault.sol:736` | pause: callable by anyone | `SharesTest::test_pauseUnpauseOwnerOnly` | KILLED |
| M103 | `PharaohDlmmVault.sol:740` | unpause: callable by anyone | `SharesTest::test_pauseUnpauseOwnerOnly` | KILLED |
| M104 | `PharaohDlmmVault.sol:180` | initialize: paused flag not set | `W2SmokeTest::test_capExactThenOneWeiRevertsAndOpenBandSurvivesFavourableSwap`, `W2SmokeTest::test_depositCapAndOpenBand`, `W2SmokeTest::test_depositWhileBandThenRebalanceFoldsIdle` (+7 more) | KILLED |
| M105 | `PharaohDlmmVault.sol:159` | initialize: rebalancer not set | `CapTest::test_initReadBacks`, `CapTest::test_openBandAboveCapIsNotBlockedByTheCap_D6`, `CapTest::test_openBandAtCapWorks` (+6 more) | KILLED |
| M106 | `PharaohDlmmVault.sol:178` | initialize: healthy-feeds check (13b) removed | `MutationInitTest::test_check13b_unhealthyFeedsAtDeployment` | KILLED (new test) |
| M107 | `PharaohDlmmVault.sol:670` | feed staleness: > to >= | `FuzzTest::testFuzz_guardBitsMatchTheModel`, `GuardTest::test_bit1_staleBoundaryIsFresh` | KILLED |
| M108 | `PharaohDlmmVault.sol:666` | feed answer == 0 accepted (<= to <) | `FuzzTest::testFuzz_guardBitsMatchTheModel`, `GuardTest::test_bit1_answerZero`, `GuardTest::test_bit2_answerZero` (+1 more) | KILLED |
| M109 | `PharaohDlmmVault.sol:666` | feed answer <= 0 accepted (check removed) | `FuzzTest::testFuzz_guardBitsMatchTheModel`, `GuardTest::test_bit1_answerNegative`, `GuardTest::test_bit1_answerZero` (+2 more) | KILLED |
| M110 | `PharaohDlmmVault.sol:669` | feed: updatedAt == 0 accepted | `updatedAt == 0` is also rejected by the very next line (`block.timestamp - 0 > maxFeedAge` for any real timestamp, maxFeedAge <= 172_800) | EQUIVALENT |
| M111 | `PharaohDlmmVault.sol:669` | feed: incomplete round (answeredInRound < roundId) accepted | `GuardTest::test_bit1_incompleteRound`, `GuardTest::test_bit2_incompleteRound` | KILLED |
| M112 | `PharaohDlmmVault.sol:670` | feed: staleness check removed | `ExitsTest::test_redeem_revertsWhenAFeedIsStale`, `FuzzTest::testFuzz_guardBitsMatchTheModel`, `GuardTest::test_bit1_stale` (+2 more) | KILLED |
| M113 | `PharaohDlmmVault.sol:663` | feed: short return data accepted | `MutationTest::test_guardSurvivesAFeedReturningShortData` | KILLED (new test) |
| M114 | `PharaohDlmmVault.sol:653` | bit 16 evaluated with one feed healthy | `FuzzTest::testFuzz_guardBitsMatchTheModel`, `FuzzTest::testFuzz_guardNeverRevertsAndLatchableMaskHolds`, `GuardTest::test_bit1_answerNegative` (+5 more) | KILLED |
| M115 | `PharaohDlmmVault.sol:218` | deposit: share conversion rounds up (Floor -> Ceil) | `SharesTest::test_previewMatchesActualAtEntry`, `SharesTest::test_sharePriceNeverDecreasesOnDepositAndRedeem` | KILLED |
| M116 | `PharaohDlmmVault.sol:226` | mint: asset conversion rounds down (Ceil -> Floor) | `SharesTest::test_previewMatchesActualAtEntry` | KILLED |
| M117 | `PharaohDlmmVault.sol:255` | withdraw: share conversion rounds down (Ceil -> Floor) | `SharesTest::test_withdrawBurnsCeilShares` | KILLED |
| M118 | `PharaohDlmmVault.sol:211` | maxMint: rounds up | `MutationTest::test_maxMintFloorsAndMintingItStaysInsideTheCap` | KILLED (new test) |
| M119 | `PharaohDlmmVault.sol:814` | _holdings: NAV bin share rounds up | `RebalanceTest::test_navIsTheOwnershipValueIncludingBinFees`, `RebalanceTest::test_navUsesTheTwoFeedsForTheUsdtLeg`, `RebalanceTest::test_openBandKeepsNavAndIsEvenByValue` (+1 more) | KILLED |
| M120 | `PharaohDlmmVault.sol:822` | _pairToAsset rounds up | `MutationTest::test_navValuesTheUsdtLegRoundingDown` | KILLED (new test) |
| M121 | `PharaohDlmmVault.sol:319` | _sliceOut: bin burn amount rounds up (over-pays the redeemer) | `MutationTest::test_partialInKindBurnsTheFlooredBinSlice` | KILLED (new test) |
| M122 | `PharaohDlmmVault.sol:307` | _sliceOut: idle X slice rounds up | `SharesTest::test_withdrawBurnsCeilShares` | KILLED |
| M123 | `PharaohDlmmVault.sol:306` | _sliceOut: full-exit shortcut removed | `MutationTest::test_lastHolderExitClearsTheBandFlagEvenWithADustBinLeft` | KILLED (new test) |
| M124 | `PharaohDlmmVault.sol:350` | _sliceOut: band flag cleared only on full exit | `MutationTest::test_partialExitWithNoBinSharesLeftClearsTheBandFlag` | KILLED (new test) |
| M125 | `PharaohDlmmVault.sol:324` | _sliceOut: dust-skip && -> || | `ExitsTest::test_hook_burnHookDown_blocksEveryExitThatTouchesBins`, `ExitsTest::test_hook_mintHookDown_exitsWorkButBandOpsFail`, `ExitsTest::test_hook_swapHookDown_inKindWorksUsdcRedeemNeedsTheSwap` (+8 more) | KILLED |
| M126 | `PharaohDlmmVault.sol:795` | _nav: USDt leg valued at par, no feeds | `InvariantTest::invariant_navEqualsIndependentModel`, `RebalanceTest::test_navUsesTheTwoFeedsForTheUsdtLeg`, `W2SmokeTest::test_capExactThenOneWeiRevertsAndOpenBandSurvivesFavourableSwap` | KILLED |
| M127 | `PharaohDlmmVault.sol:826` | _assetToPair: prices swapped | `MutationTest::test_openBandSwapFloorUsesTheAssetToPairPrice` | KILLED (new test) |
| M128 | `PharaohDlmmVault.sol:389` | openBand: USDt swap amount not capped by idle USDt | `min(assetToPair((pv-aAmt)/2), pAmt)`: half of the value gap converted back is always below the idle USDt balance, so the `min` never binds | EQUIVALENT |
| M129 | `PharaohDlmmVault.sol:386` | openBand: even-split threshold changed (no deadband) | the extra cases (`aAmt` in {pv, pv+1}) give a swap amount `(aAmt-pv)/2 = 0`, which `_guardedSwap` returns on at once: no behaviour change | EQUIVALENT |
| M130 | `PharaohDlmmVault.sol:617` | rebalanceAllowed: daily cap off by one | `RebalanceTest::test_rebalanceDailyCap` | KILLED |
| M131 | `PharaohDlmmVault.sol:608` | rebalanceAllowed: latch bit not reported | `MutationTest::test_rebalanceAllowedReportsTheLatchAfterRecovery` | KILLED (new test) |
| M132 | `PharaohDlmmVault.sol:607` | rebalanceAllowed: paused bit not reported | `RebalanceTest::test_rebalanceWhenPausedReverts` | KILLED |
| M133 | `PharaohDlmmVault.sol:613` | rebalanceAllowed: in-range edges | `MutationTest::test_rebalanceAllowedCountsTheEdgeBinsAsInRange` | KILLED (new test) |
| M134 | `PharaohDlmmVault.sol:616` | rebalanceAllowed: cooldown < to <= | `RebalanceTest::test_rebalanceCooldown` | KILLED |
| M135 | `PharaohDlmmVault.sol:620` | rebalanceAllowed: readyAt always the next day on cap | `MutationTest::test_rebalanceAllowedReadyAtIsTheLaterOfCooldownAndNextDay` | KILLED (new test) |
| M136 | `PharaohDlmmVault.sol:201` | maxDeposit: latch not considered | `MutationTest::test_maxDepositAndMaxMintAreZeroWhileLatchedEvenWhenLiveSafe` | KILLED (new test) |
| M137 | `PharaohDlmmVault.sol:201` | maxDeposit: pause not considered | `SharesTest::test_pauseBlocksEntriesNotExits`, `W2SmokeTest::test_pausedBlocksDeposit` | KILLED |
| M138 | `PharaohDlmmVault.sol:203` | maxDeposit: live guard reasons not considered | `MutationTest::test_maxDepositAndMaxMintAreZeroWhileLiveUnsafe` | KILLED (new test) |
| M139 | `PharaohDlmmVault.sol:214` | deposit: entry guard check removed | `GuardTest::test_bit16_blocksEntries`, `GuardTest::test_bit1_blocksEntries`, `GuardTest::test_bit2_blocksEntries` (+4 more) | KILLED |
| M140 | `PharaohDlmmVault.sol:223` | mint: entry guard check removed | `GuardTest::test_bit16_blocksEntries`, `GuardTest::test_bit32_blocksEntries`, `GuardTest::test_bit4_blocksEntries` (+1 more) | KILLED |
| M141 | `PharaohDlmmVault.sol:214` | deposit: whenNotPaused removed | `SharesTest::test_pauseBlocksEntriesNotExits`, `W2SmokeTest::test_pausedBlocksDeposit` | KILLED |
| M142 | `PharaohDlmmVault.sol:223` | mint: whenNotPaused removed | `SharesTest::test_pauseBlocksEntriesNotExits` | KILLED |
| M143 | `PharaohDlmmVault.sol:722` | _requireEntryOk: latch check removed | `GuardTest::test_latchBlocksOpenBand`, `GuardTest::test_latchBlocksOpenBandAndRebalance`, `GuardTest::test_latchSurvivesRecovery` (+1 more) | KILLED |
| M144 | `PharaohDlmmVault.sol:722` | _requireEntryOk: bits 16 and 32 not enforced at entry | `GuardTest::test_bit16_blocksEntries`, `GuardTest::test_bit16_blocksRebalance`, `GuardTest::test_bit32_blocksEntries` (+2 more) | KILLED |
| M145 | `PharaohDlmmVault.sol:416` | rebalance: entry guard check removed | `GuardTest::test_bit16_blocksRebalance`, `GuardTest::test_bit1_blocksRebalance`, `GuardTest::test_bit2_blocksRebalance` (+4 more) | KILLED |
| M146 | `PharaohDlmmVault.sol:375` | openBand: entry guard check removed | `GuardTest::test_bitsBlockOpenBand`, `GuardTest::test_latchBlocksOpenBand` | KILLED |
| M147 | `PharaohDlmmVault.sol:377` | openBand: BandExists check removed | `MutationTest::test_openBandWhileABandExistsRevertsBandExists` | KILLED (new test) |
| M148 | `PharaohDlmmVault.sol:557` | _checkDeadline: deadline not enforced | `MutationTest::test_openBandDeadline`, `MutationTest::test_rebalanceDeadline` | KILLED (new test) |
| M149 | `PharaohDlmmVault.sol:557` | _checkDeadline: > to >= | `MutationTest::test_openBandDeadline`, `MutationTest::test_rebalanceDeadline` | KILLED (new test) |
| M150 | `PharaohDlmmVault.sol:411` | rebalance: NoBand check removed | `RebalanceTest::test_rebalanceNoBand` | KILLED |
| M151 | `PharaohDlmmVault.sol:495` | _addBand: NothingToDeploy check removed | `MutationTest::test_openBandWithNoFundsRevertsNothingToDeploy` | KILLED (new test) |
| M152 | `PharaohDlmmVault.sol:432` | rebalance: old band not burned | `ExitsTest::test_hook_burnHookDown_blocksEveryExitThatTouchesBins`, `ExitsTest::test_hook_mintHookDown_exitsWorkButBandOpsFail`, `InvariantTest::invariant_navEqualsIndependentModel` (+5 more) | KILLED |
| M153 | `PharaohDlmmVault.sol:696` | bit 32: hook != rewarder not detected | `MutationTest::test_bit32_hookElsewhereWhileIsLinkedStillTrue` | KILLED (new test) |
| M154 | `PharaohDlmmVault.sol:698` | bit 32: rewarder.isLinked() == false not detected | `W2SmokeTest::test_exitsIgnoreGuardPauseFeedAndPin` | KILLED |
| M155 | `PharaohDlmmVault.sol:702` | bit 32: beacon implementation codehash change not detected | `GuardTest::test_bit32_clearsWhenRelinked`, `GuardTest::test_bit32_implementationCodehashChanged` | KILLED |
| M156 | `PharaohDlmmVault.sol:700` | bit 32: failed beacon read not detected | a failed beacon read leaves `impl = address(0)`, whose codehash is 0, which differs from the pinned (non-zero, enforced by validator check 1) codehash: bit 32 is set either way | EQUIVALENT |
| M157 | `PharaohDlmmVault.sol:696` | bit 32: failed hook read not detected | a failed hook read leaves the hook word 0, which differs from the (non-zero) rewarder: bit 32 is set either way | EQUIVALENT |
| M158 | `PharaohDlmmVault.sol:678` | bit 16: failed getActiveId read not a deviation | a failed `getActiveId` read leaves word 0, i.e. id 0, which is more than 4096 bins from 2^23 and returns `true` on the next line: deviation either way | EQUIVALENT |
| M159 | `PharaohDlmmVault.sol:278` | redeemInKind: pays msg.sender instead of receiver | `MutationTest::test_redeemInKindPaysTheReceiverNotTheCaller` | KILLED (new test) |
| M160 | `PharaohDlmmVault.sol:298` | redeem/withdraw: pays msg.sender instead of receiver | `MutationTest::test_redeemPaysTheReceiverNotTheCaller` | KILLED (new test) |
| M161 | `PharaohDlmmVault.sol:297` | redeem/withdraw: ExitFailed on zero payout removed | `MutationTest::test_redeemThatPaysNothingRevertsExitFailed` | KILLED (new test) |
| M162 | `PharaohDlmmVault.sol:277` | redeemInKind: ExitFailed on zero payout removed | `MutationTest::test_redeemInKindThatPaysNothingRevertsExitFailed` | KILLED (new test) |
| M163 | `PharaohDlmmVault.sol:270` | redeemInKind: zero receiver allowed | `MutationTest::test_redeemInKindZeroReceiverAndZeroSharesHaveTheirOwnErrors` | KILLED (new test) |
| M164 | `PharaohDlmmVault.sol:269` | redeemInKind: zero shares allowed | `MutationTest::test_redeemInKindZeroReceiverAndZeroSharesHaveTheirOwnErrors` | KILLED (new test) |
| M165 | `PharaohDlmmVault.sol:288` | redeem/withdraw payout: allowance not spent | `SharesTest::test_redeemOnBehalfNeedsAllowance` | KILLED |
| M166 | `PharaohDlmmVault.sol:146` | initialize: assetIsX inverted | `ExitsTest::test_control_depositAndRedeemDoReadTheFeeds`, `ExitsTest::test_hook_mintHookDown_exitsWorkButBandOpsFail`, `ExitsTest::test_hook_swapHookDown_inKindWorksUsdcRedeemNeedsTheSwap` (+4 more) | KILLED |
| M167 | `PharaohDlmmVault.sol:458` | _guardedSwap: zero-amount early return removed | `MutationTest::test_rebalanceWithZeroSwapSkipsTheSwap` | KILLED (new test) |
| V01 | `PharaohDlmmPairValidator.sol:31` | check 1: zero-address/empty-field check removed (all fields) | `MutationInitTest::test_check1_everyZeroFieldIsRefused` | KILLED (new test) |
| V01a | `PharaohDlmmPairValidator.sol:35` | check 1: zero codehash no longer rejected | `MutationInitTest::test_check1_everyZeroFieldIsRefused` | KILLED (new test) |
| V01b | `PharaohDlmmPairValidator.sol:34` | check 1: zero owner no longer rejected | a zero owner never reaches the validator: `__Ownable_init` reverts `OwnableInvalidOwner` first (pinned by `test_zeroOwnerIsRefusedByOwnable`) | EQUIVALENT |
| V01c | `PharaohDlmmPairValidator.sol:34` | check 1: zero rebalancer no longer rejected | `MutationInitTest::test_check1_everyZeroFieldIsRefused` | KILLED (new test) |
| V02 | `PharaohDlmmPairValidator.sol:37` | check 2: asset == pairToken check removed | `MutationInitTest::test_check2_assetEqualsPairToken` | KILLED (new test) |
| V03 | `PharaohDlmmPairValidator.sol:41` | check 3: factory registry (pair, binStep) check removed | `CapTest::test_initValidationFailures` | KILLED |
| V03a | `PharaohDlmmPairValidator.sol:41` | check 3: binStep half removed | `MutationInitTest::test_check3_registryHasNoPairOrAnotherPairOrAnotherBinStep` | KILLED (new test) |
| V03b | `PharaohDlmmPairValidator.sol:41` | check 3: pair half removed | `CapTest::test_initValidationFailures` | KILLED |
| V04 | `PharaohDlmmPairValidator.sol:44` | check 4: pair.getFactory/getBinStep check removed | `MutationInitTest::test_check4_pairDisagreesOnFactoryOrBinStep` | KILLED (new test) |
| V04a | `PharaohDlmmPairValidator.sol:44` | check 4: getFactory half removed | `MutationInitTest::test_check4_pairDisagreesOnFactoryOrBinStep` | KILLED (new test) |
| V04b | `PharaohDlmmPairValidator.sol:44` | check 4: getBinStep half removed | `MutationInitTest::test_check4_pairDisagreesOnFactoryOrBinStep` | KILLED (new test) |
| V05 | `PharaohDlmmPairValidator.sol:47` | check 5: pair tokens == {asset, pairToken} check removed | `MutationInitTest::test_check5_pairTokensAreNotExactlyTheTwoLegs` | KILLED (new test) |
| V05a | `PharaohDlmmPairValidator.sol:47` | check 5: only tokenX checked | `MutationInitTest::test_check5_pairTokensAreNotExactlyTheTwoLegs` | KILLED (new test) |
| V05b | `PharaohDlmmPairValidator.sol:47` | check 5: reversed X/Y order rejected (only asset = X accepted) | setUp reverts (deployment with the mutated ceiling) | KILLED |
| V06 | `PharaohDlmmPairValidator.sol:50` | check 6: router.getFactory check removed | `MutationInitTest::test_check6_routerFromAnotherFactory` | KILLED (new test) |
| V07 | `PharaohDlmmPairValidator.sol:51` | check 7: pair hook == rewarder check removed | `MutationInitTest::test_check7_hookIsNotTheRewarder` | KILLED (new test) |
| V08 | `PharaohDlmmPairValidator.sol:53` | check 8: rewarder.isLinked check removed | `MutationInitTest::test_check8_rewarderNotLinked` | KILLED (new test) |
| V09 | `PharaohDlmmPairValidator.sol:55` | check 9: router authorised-manager check removed | `CapTest::test_initValidationFailures` | KILLED |
| V09a | `PharaohDlmmPairValidator.sol:55` | check 9: voter == 0 check removed | `MutationInitTest::test_check9_voterZeroOrRouterNotAuthorised` | KILLED (new test) |
| V10 | `PharaohDlmmPairValidator.sol:59` | check 10: beacon lists rewarder for pair check removed | `MutationInitTest::test_check10_beaconZeroOrNotListingTheRewarder` | KILLED (new test) |
| V10a | `PharaohDlmmPairValidator.sol:59` | check 10: beacon == 0 check removed | `MutationInitTest::test_check10_beaconZeroOrNotListingTheRewarder` | KILLED (new test) |
| V11 | `PharaohDlmmPairValidator.sol:62` | check 11: beacon implementation codehash pin removed | `CapTest::test_initValidationFailures`, `W2SmokeTest::test_initRejectsWrongCodehashAndCap` | KILLED |
| V12 | `PharaohDlmmPairValidator.sol:66` | check 12: reward token sanity check removed | `MutationInitTest::test_check12_rewardTokenZeroOrALeg` | KILLED (new test) |
| V12a | `PharaohDlmmPairValidator.sol:66` | check 12: zero reward token accepted | `MutationInitTest::test_check12_rewardTokenZeroOrALeg` | KILLED (new test) |
| V12b | `PharaohDlmmPairValidator.sol:66` | check 12: reward token == asset accepted | `MutationInitTest::test_check12_rewardTokenZeroOrALeg` | KILLED (new test) |
| V12c | `PharaohDlmmPairValidator.sol:66` | check 12: reward token == pairToken accepted | `MutationInitTest::test_check12_rewardTokenZeroOrALeg` | KILLED (new test) |
| V13 | `PharaohDlmmPairValidator.sol:69` | check 13: feed decimals check removed | `CapTest::test_initValidationFailures` | KILLED |
| V13a | `PharaohDlmmPairValidator.sol:69` | check 13: asset-feed decimals not checked | `CapTest::test_initValidationFailures` | KILLED |
| V13b | `PharaohDlmmPairValidator.sol:69` | check 13: pair-feed decimals not checked | `MutationInitTest::test_check13_feedDecimalsEachFeed` | KILLED (new test) |
| V14 | `PharaohDlmmPairValidator.sol:74` | check 14: token decimals <= 18 check removed | `MutationInitTest::test_check14_tokenDecimalsAboveEighteen` | KILLED (new test) |
| V14a | `PharaohDlmmPairValidator.sol:74` | check 14: asset decimals not checked | `MutationInitTest::test_check14_tokenDecimalsAboveEighteen` | KILLED (new test) |
| V14b | `PharaohDlmmPairValidator.sol:74` | check 14: pair decimals not checked | `MutationInitTest::test_check14_tokenDecimalsAboveEighteen` | KILLED (new test) |
| V14c | `PharaohDlmmPairValidator.sol:74` | check 14: bound 18 -> 19 | `MutationInitTest::test_check14_tokenDecimalsAboveEighteen` | KILLED (new test) |

## Diffs (one change each, against the starting commit)

### M01 deposit: cap check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -217 +216,0 @@
-        _checkCap(assets);
```

### M02 mint: cap check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -227 +226,0 @@
-        _checkCap(assets);
```

### M03 setDepositCap: ceiling check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -751 +750,0 @@
-        if (newCap > DEPOSIT_CAP_CEILING) revert CapAboveCeiling(newCap, DEPOSIT_CAP_CEILING);
```

### M04 setDepositCap: ceiling check > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -751 +751 @@
-        if (newCap > DEPOSIT_CAP_CEILING) revert CapAboveCeiling(newCap, DEPOSIT_CAP_CEILING);
+        if (newCap >= DEPOSIT_CAP_CEILING) revert CapAboveCeiling(newCap, DEPOSIT_CAP_CEILING);
```

### M05 initialize: ceiling check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -124 +123,0 @@
-        if (p.depositCap > DEPOSIT_CAP_CEILING) revert CapAboveCeiling(p.depositCap, DEPOSIT_CAP_CEILING);
```

### M06 ceiling constant 200_000_000 -> 200_000_001

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -114 +114 @@
-        DEPOSIT_CAP_CEILING = 200_000_000;
+        DEPOSIT_CAP_CEILING = 200_000_001;
```

### M07 ceiling constant 200_000_000 -> 199_999_999

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -114 +114 @@
-        DEPOSIT_CAP_CEILING = 200_000_000;
+        DEPOSIT_CAP_CEILING = 199_999_999;
```

### M08 initialize: stored cap = requested + 1

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -160 +160 @@
-        depositCap = p.depositCap;
+        depositCap = p.depositCap + 1;
```

### M09 initialize: stored cap = ceiling regardless of the request

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -160 +160 @@
-        depositCap = p.depositCap;
+        depositCap = DEPOSIT_CAP_CEILING;
```

### M10 _checkCap: > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -729 +729 @@
-        if (afterAssets > depositCap) revert CapExceeded(depositCap, afterAssets);
+        if (afterAssets >= depositCap) revert CapExceeded(depositCap, afterAssets);
```

### M11 maxDeposit: >= to > (nav == cap gives 0 either way)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -205 +205 @@
-        return nav >= depositCap ? 0 : depositCap - nav;
+        return nav > depositCap ? 0 : depositCap - nav;
```

### M12 initialize: DepositCapSet event reports 0

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -173 +173 @@
-        emit DepositCapSet(0, p.depositCap);
+        emit DepositCapSet(0, 0);
```

### M13 guard bit 1 (asset feed bad) disabled

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -648 +647,0 @@
-        if (okMask & 1 == 0) reasons |= FEED_ASSET_STALE_OR_BAD;
```

### M14 guard bit 2 (pair feed bad) disabled

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -649 +648,0 @@
-        if (okMask & 2 == 0) reasons |= FEED_PAIR_STALE_OR_BAD;
```

### M15 guard bit 4 (asset leg out of band) disabled

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -651 +650,0 @@
-        if (hasMask & 1 != 0 && _absDiff(pa, ONE_USD) * BPS > band) reasons |= ASSET_LEG_OUT_OF_BAND;
```

### M16 guard bit 8 (pair leg out of band) disabled

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -652 +651,0 @@
-        if (hasMask & 2 != 0 && _absDiff(pp, ONE_USD) * BPS > band) reasons |= PAIR_LEG_OUT_OF_BAND;
```

### M17 guard bit 16 (pool/oracle deviation) disabled

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -653 +652,0 @@
-        if (okMask == 3 && _poolDeviates(pa, pp)) reasons |= POOL_ORACLE_DEVIATION;
```

### M18 guard bit 32 (rewarder) disabled

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -654 +653,0 @@
-        if (_rewarderBroken()) reasons |= REWARDER_UNLINKED_OR_CODEHASH_CHANGED;
```

### M19 bit 16 orientation: oracle ratio inverted (Y per X -> X per Y)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -690 +690 @@
-        uint256 oracleRatio = _md(priceX, WAD, priceY); // Y per X
+        uint256 oracleRatio = _md(priceY, WAD, priceX); // Y per X
```

### M20 bit 16 orientation: oracle price legs swapped for the X/Y order

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -688,2 +688,2 @@
-        uint256 priceX = assetIsX ? pa : pp;
-        uint256 priceY = assetIsX ? pp : pa;
+        uint256 priceX = assetIsX ? pp : pa;
+        uint256 priceY = assetIsX ? pa : pp;
```

### M21 bit 16: decimal scales swapped for the X/Y order

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -685,2 +685,2 @@
-        uint256 scaleX = assetIsX ? assetScale : pairScale;
-        uint256 scaleY = assetIsX ? pairScale : assetScale;
+        uint256 scaleX = assetIsX ? pairScale : assetScale;
+        uint256 scaleY = assetIsX ? assetScale : pairScale;
```

### M22 bit 16: sign of the bin offset inverted

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -683 +683 @@
-        uint256 raw = k < 0 ? _md(WAD, WAD, pw) : pw; // Y_raw per X_raw, 1e18
+        uint256 raw = k < 0 ? pw : _md(WAD, WAD, pw); // Y_raw per X_raw, 1e18
```

### M23 bit 16: far-from-peg id no longer a deviation

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -681 +681 @@
-        if (absK > 4096) return true; // more than ~+-40 % at 1 bp: not a peg
+        if (absK > 4096) return false; // more than ~+-40 % at 1 bp: not a peg
```

### M24 bit 16: deviation threshold > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -691 +691 @@
-        return _absDiff(poolPrice, oracleRatio) * BPS > uint256(_gp.maxPoolOracleDevBps) * oracleRatio;
+        return _absDiff(poolPrice, oracleRatio) * BPS >= uint256(_gp.maxPoolOracleDevBps) * oracleRatio;
```

### M25 bit 4: band > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -651 +651 @@
-        if (hasMask & 1 != 0 && _absDiff(pa, ONE_USD) * BPS > band) reasons |= ASSET_LEG_OUT_OF_BAND;
+        if (hasMask & 1 != 0 && _absDiff(pa, ONE_USD) * BPS >= band) reasons |= ASSET_LEG_OUT_OF_BAND;
```

### M26 bit 8: band > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -652 +652 @@
-        if (hasMask & 2 != 0 && _absDiff(pp, ONE_USD) * BPS > band) reasons |= PAIR_LEG_OUT_OF_BAND;
+        if (hasMask & 2 != 0 && _absDiff(pp, ONE_USD) * BPS >= band) reasons |= PAIR_LEG_OUT_OF_BAND;
```

### M27 tripGuard: latch not set

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -593 +592,0 @@
-        _latched = true;
```

### M28 tripGuard latchable mask 15 -> 31 (bit 16 latchable)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -53 +53 @@
-    uint256 internal constant LATCHABLE_MASK = 15;
+    uint256 internal constant LATCHABLE_MASK = 31;
```

### M29 tripGuard latchable mask 15 -> 63 (bits 16 and 32 latchable)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -53 +53 @@
-    uint256 internal constant LATCHABLE_MASK = 15;
+    uint256 internal constant LATCHABLE_MASK = 63;
```

### M30 tripGuard: no-latchable-reason revert removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -592 +591,0 @@
-        if (latchable == 0) revert GuardUnsafe(0);
```

### M31 clearGuard: live-safe check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -599 +598,0 @@
-        if (reasons != 0) revert GuardStillUnsafe(reasons);
```

### M32 clearGuard: live-safe check only on latchable bits (bits 16, 32 ignored)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -599 +599 @@
-        if (reasons != 0) revert GuardStillUnsafe(reasons);
+        if (reasons & LATCHABLE_MASK != 0) revert GuardStillUnsafe(reasons);
```

### M33 clearGuard: callable by anyone

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -597 +597 @@
-    function clearGuard() external onlyOwner {
+    function clearGuard() external {
```

### M34 clearGuard: latch not cleared

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -600 +599,0 @@
-        _latched = false;
```

### M35 setGuardParams bound loosened: legBandBps lower 10

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -762 +762 @@
-            p.legBandBps < 10 || p.legBandBps > 200 || p.maxFeedAge < 3_600 || p.maxFeedAge > 172_800
+            p.legBandBps < 9 || p.legBandBps > 200 || p.maxFeedAge < 3_600 || p.maxFeedAge > 172_800
```

### M36 setGuardParams bound loosened: legBandBps upper 200

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -762 +762 @@
-            p.legBandBps < 10 || p.legBandBps > 200 || p.maxFeedAge < 3_600 || p.maxFeedAge > 172_800
+            p.legBandBps < 10 || p.legBandBps > 201 || p.maxFeedAge < 3_600 || p.maxFeedAge > 172_800
```

### M37 setGuardParams bound loosened: maxFeedAge lower 3600

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -762 +762 @@
-            p.legBandBps < 10 || p.legBandBps > 200 || p.maxFeedAge < 3_600 || p.maxFeedAge > 172_800
+            p.legBandBps < 10 || p.legBandBps > 200 || p.maxFeedAge < 3_599 || p.maxFeedAge > 172_800
```

### M38 setGuardParams bound loosened: maxFeedAge upper 172800

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -762 +762 @@
-            p.legBandBps < 10 || p.legBandBps > 200 || p.maxFeedAge < 3_600 || p.maxFeedAge > 172_800
+            p.legBandBps < 10 || p.legBandBps > 200 || p.maxFeedAge < 3_600 || p.maxFeedAge > 172_801
```

### M39 setGuardParams bound loosened: maxPoolOracleDevBps lower 20

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -763 +763 @@
-                || p.maxPoolOracleDevBps < 20 || p.maxPoolOracleDevBps > 300 || p.rebalanceCooldown < 111
+                || p.maxPoolOracleDevBps < 19 || p.maxPoolOracleDevBps > 300 || p.rebalanceCooldown < 111
```

### M40 setGuardParams bound loosened: maxPoolOracleDevBps upper 300

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -763 +763 @@
-                || p.maxPoolOracleDevBps < 20 || p.maxPoolOracleDevBps > 300 || p.rebalanceCooldown < 111
+                || p.maxPoolOracleDevBps < 20 || p.maxPoolOracleDevBps > 301 || p.rebalanceCooldown < 111
```

### M41 setGuardParams bound loosened: rebalanceCooldown lower 111

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -763 +763 @@
-                || p.maxPoolOracleDevBps < 20 || p.maxPoolOracleDevBps > 300 || p.rebalanceCooldown < 111
+                || p.maxPoolOracleDevBps < 20 || p.maxPoolOracleDevBps > 300 || p.rebalanceCooldown < 110
```

### M42 setGuardParams bound loosened: rebalanceCooldown upper 3600

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -764 +764 @@
-                || p.rebalanceCooldown > 3_600 || p.maxRebalancesPerDay < 4 || p.maxRebalancesPerDay > 96
+                || p.rebalanceCooldown > 3_601 || p.maxRebalancesPerDay < 4 || p.maxRebalancesPerDay > 96
```

### M43 setGuardParams bound loosened: maxRebalancesPerDay lower 4

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -764 +764 @@
-                || p.rebalanceCooldown > 3_600 || p.maxRebalancesPerDay < 4 || p.maxRebalancesPerDay > 96
+                || p.rebalanceCooldown > 3_600 || p.maxRebalancesPerDay < 3 || p.maxRebalancesPerDay > 96
```

### M44 setGuardParams bound loosened: maxRebalancesPerDay upper 96

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -764 +764 @@
-                || p.rebalanceCooldown > 3_600 || p.maxRebalancesPerDay < 4 || p.maxRebalancesPerDay > 96
+                || p.rebalanceCooldown > 3_600 || p.maxRebalancesPerDay < 4 || p.maxRebalancesPerDay > 97
```

### M45 setGuardParams bound loosened: maxSwapBps lower 1 (zero allowed)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -765 +765 @@
-                || p.maxSwapBps < 1 || p.maxSwapBps > 10_000 || p.maxRebalanceLossBps < 5 || p.maxRebalanceLossBps > 300
+                || p.maxSwapBps < 0 || p.maxSwapBps > 10_000 || p.maxRebalanceLossBps < 5 || p.maxRebalanceLossBps > 300
```

### M46 setGuardParams bound loosened: maxSwapBps upper 10000

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -765 +765 @@
-                || p.maxSwapBps < 1 || p.maxSwapBps > 10_000 || p.maxRebalanceLossBps < 5 || p.maxRebalanceLossBps > 300
+                || p.maxSwapBps < 1 || p.maxSwapBps > 10_001 || p.maxRebalanceLossBps < 5 || p.maxRebalanceLossBps > 300
```

### M47 setGuardParams bound loosened: maxRebalanceLossBps lower 5

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -765 +765 @@
-                || p.maxSwapBps < 1 || p.maxSwapBps > 10_000 || p.maxRebalanceLossBps < 5 || p.maxRebalanceLossBps > 300
+                || p.maxSwapBps < 1 || p.maxSwapBps > 10_000 || p.maxRebalanceLossBps < 4 || p.maxRebalanceLossBps > 300
```

### M48 setGuardParams bound loosened: maxRebalanceLossBps upper 300

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -765 +765 @@
-                || p.maxSwapBps < 1 || p.maxSwapBps > 10_000 || p.maxRebalanceLossBps < 5 || p.maxRebalanceLossBps > 300
+                || p.maxSwapBps < 1 || p.maxSwapBps > 10_000 || p.maxRebalanceLossBps < 5 || p.maxRebalanceLossBps > 301
```

### M49 setGuardParams: callable by anyone

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -756 +756 @@
-    function setGuardParams(GuardParams calldata p) external onlyOwner {
+    function setGuardParams(GuardParams calldata p) external {
```

### M50 setDepositCap: callable by anyone

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -750 +750 @@
-    function setDepositCap(uint256 newCap) external onlyOwner {
+    function setDepositCap(uint256 newCap) external {
```

### M51 redeemInKind gated by pause

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -266,0 +267 @@
+        whenNotPaused
```

### M52 redeemInKind gated by guard (live reasons) and latch via _requireEntryOk

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -269,0 +270 @@
+        _requireEntryOk();
```

### M53 redeemInKind gated by the latch only

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -269,0 +270 @@
+        if (_latched) revert GuardLatched();
```

### M54 redeemInKind makes an oracle read (strict feeds)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -269,0 +270 @@
+        _prices();
```

### M55 redeemInKind makes a router swap of half the USDt leg

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -277,0 +278 @@
+        { uint256 half = (assetIsX ? amountY : amountX) / 2; if (half != 0) { uint256 got = _swap(pairToken, IERC20(asset()), half, 0, block.timestamp); if (assetIsX) { amountY -= half; amountX += got; } else { amountX -= half; amountY += got; } } }
```

### M56 redeemInKind evaluates the guard (feed staticcalls, no revert)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -269,0 +270 @@
+        _evaluate();
```

### M57 redeemInKind: allowance not spent (anyone can redeem for an owner)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -274 +273,0 @@
-        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
```

### M58 redeemInKind: excess-shares check removed (burn reverts instead)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -273 +272,0 @@
-        if (shares > ownerShares) revert ERC4626ExceededMaxRedeem(owner_, shares, ownerShares);
```

### M59 rebalance: exit-triggered precondition removed (rebalances while in range)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -412,4 +411,0 @@
-        {
-            uint24 a = _activeId();
-            if (a >= _lower && a <= _upper) revert NotOutOfRange(a, _lower, _upper);
-        }
```

### M60 rebalance: edge bins count as out of range

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -414 +414 @@
-            if (a >= _lower && a <= _upper) revert NotOutOfRange(a, _lower, _upper);
+            if (a > _lower && a < _upper) revert NotOutOfRange(a, _lower, _upper);
```

### M61 rebalance: cooldown removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -418 +417,0 @@
-        if (lastRebalanceAt != 0 && block.timestamp < readyAt) revert CooldownActive(readyAt);
```

### M62 rebalance: cooldown < to <=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -418 +418 @@
-        if (lastRebalanceAt != 0 && block.timestamp < readyAt) revert CooldownActive(readyAt);
+        if (lastRebalanceAt != 0 && block.timestamp <= readyAt) revert CooldownActive(readyAt);
```

### M63 rebalance: daily cap off by one (>= to >)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -424 +424 @@
-        if (_countToday >= _gp.maxRebalancesPerDay) revert DailyRebalanceCapReached();
+        if (_countToday > _gp.maxRebalancesPerDay) revert DailyRebalanceCapReached();
```

### M64 rebalance: daily cap removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -424 +423,0 @@
-        if (_countToday >= _gp.maxRebalancesPerDay) revert DailyRebalanceCapReached();
```

### M65 rebalance: daily counter never reset on a new day

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -420,4 +420 @@
-        if (_day != today) {
-            _day = today;
-            _countToday = 0;
-        }
+        _day = today;
```

### M66 rebalance: daily counter never incremented

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -441 +440,0 @@
-        ++_countToday;
```

### M67 rebalance: lastRebalanceAt never written

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -440 +439,0 @@
-        lastRebalanceAt = uint48(block.timestamp);
```

### M68 _guardedSwap: maxSwapBps ignored

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -461 +460,0 @@
-        if (inValue > maxIn) revert SwapTooLarge(inValue, maxIn);
```

### M69 _guardedSwap: > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -461 +461 @@
-        if (inValue > maxIn) revert SwapTooLarge(inValue, maxIn);
+        if (inValue >= maxIn) revert SwapTooLarge(inValue, maxIn);
```

### M70 _guardedSwap: maxIn = 100 % of NAV

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -459 +459 @@
-        uint256 maxIn = _md(nav, _gp.maxSwapBps, BPS);
+        uint256 maxIn = _md(nav, BPS, BPS);
```

### M71 _checkNavLoss: check removed (both call sites)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -547 +547 @@
-        if (navAfter * BPS < navBefore * (BPS - _gp.maxRebalanceLossBps)) revert NavLossTooLarge(navBefore, navAfter);
+
```

### M72 _checkNavLoss: comparison inverted

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -547 +547 @@
-        if (navAfter * BPS < navBefore * (BPS - _gp.maxRebalanceLossBps)) revert NavLossTooLarge(navBefore, navAfter);
+        if (navAfter * BPS > navBefore * (BPS - _gp.maxRebalanceLossBps)) revert NavLossTooLarge(navBefore, navAfter);
```

### M73 _checkNavLoss: < to <=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -547 +547 @@
-        if (navAfter * BPS < navBefore * (BPS - _gp.maxRebalanceLossBps)) revert NavLossTooLarge(navBefore, navAfter);
+        if (navAfter * BPS <= navBefore * (BPS - _gp.maxRebalanceLossBps)) revert NavLossTooLarge(navBefore, navAfter);
```

### M74 rebalance: NAV-loss check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -438 +437,0 @@
-        _checkNavLoss(navBefore, pa, pp);
```

### M75 openBand: NAV-loss check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -394 +393,0 @@
-        _checkNavLoss(navBefore, pa, pp);
```

### M76 _guardedSwap: swap min-out removed (0)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -464 +464 @@
-        amountOut = _swap(tokenIn, tokenOut, amountIn, swapMinOut > floorOut ? swapMinOut : floorOut, deadline);
+        amountOut = _swap(tokenIn, tokenOut, amountIn, 0, deadline);
```

### M77 _guardedSwap: oracle floor ignored (caller min-out only)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -464 +464 @@
-        amountOut = _swap(tokenIn, tokenOut, amountIn, swapMinOut > floorOut ? swapMinOut : floorOut, deadline);
+        amountOut = _swap(tokenIn, tokenOut, amountIn, swapMinOut, deadline);
```

### M78 _guardedSwap: caller min-out ignored (oracle floor only)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -464 +464 @@
-        amountOut = _swap(tokenIn, tokenOut, amountIn, swapMinOut > floorOut ? swapMinOut : floorOut, deadline);
+        amountOut = _swap(tokenIn, tokenOut, amountIn, floorOut, deadline);
```

### M79 _guardedSwap: max(min-out, floor) -> min

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -464 +464 @@
-        amountOut = _swap(tokenIn, tokenOut, amountIn, swapMinOut > floorOut ? swapMinOut : floorOut, deadline);
+        amountOut = _swap(tokenIn, tokenOut, amountIn, swapMinOut < floorOut ? swapMinOut : floorOut, deadline);
```

### M80 _guardedSwap: oracle floor without loss allowance (100 % of oracle out)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -463 +463 @@
-        uint256 floorOut = _md(oracleOut, BPS - _gp.maxRebalanceLossBps, BPS);
+        uint256 floorOut = _md(oracleOut, BPS, BPS);
```

### M81 redeem payout swap: min-out removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -295 +295 @@
-            paid += _swap(pairToken, IERC20(asset()), pairAmt, _md(expectedOut, BPS - _gp.maxRebalanceLossBps, BPS), block.timestamp);
+            paid += _swap(pairToken, IERC20(asset()), pairAmt, 0, block.timestamp);
```

### M82 _checkActive: ActiveIdMoved check removed (all call sites)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -553 +553 @@
-        if (diff > slip) revert ActiveIdMoved(expected, a, slip);
+
```

### M83 _checkActive: > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -553 +553 @@
-        if (diff > slip) revert ActiveIdMoved(expected, a, slip);
+        if (diff >= slip) revert ActiveIdMoved(expected, a, slip);
```

### M84 rebalance: pre-burn ActiveIdMoved check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -425 +424,0 @@
-        _checkActive(expectedActiveId, idSlippage);
```

### M85 _addBand: post-swap ActiveIdMoved check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -491 +490,0 @@
-        _checkActive(expectedActiveId, idSlippage);
```

### M86 openBand: pre-swap ActiveIdMoved check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -379 +378,0 @@
-        _checkActive(expectedActiveId, idSlippage);
```

### M87 openBand: idSlippage bound removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -378 +377,0 @@
-        if (idSlippage > MAX_ID_SLIPPAGE) revert ParamOutOfBounds();
```

### M88 rebalance: idSlippage bound removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -410 +409,0 @@
-        if (idSlippage > MAX_ID_SLIPPAGE) revert ParamOutOfBounds();
```

### M89 MAX_ID_SLIPPAGE 2 -> 3

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -43 +43 @@
-    uint256 private constant MAX_ID_SLIPPAGE = 2;
+    uint256 private constant MAX_ID_SLIPPAGE = 3;
```

### M90 _addBand: router activeIdDesired = expectedActiveId instead of the real id

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -527 +527 @@
-                activeIdDesired: active, // the REAL active id read after the inventory swap: ids and distributions are built around it
+                activeIdDesired: expectedActiveId, // the REAL active id read after the inventory swap: ids and distributions are built around it
```

### M91 _addBand: stored band built around expectedActiveId

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -540,2 +540,2 @@
-        _lower = active - 1;
-        _upper = active + 1;
+        _lower = expectedActiveId - 1;
+        _upper = expectedActiveId + 1;
```

### M92 _addBand: active = expectedActiveId (band and router id around the expected id)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -492 +492 @@
-        active = _activeId();
+        active = expectedActiveId;
```

### M93 _addBand: caller idSlippage forwarded to the router

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -528 +528 @@
-                idSlippage: 0, // the caller's tolerance was applied above (ActiveIdMoved); the router must see exactly the id used here
+                idSlippage: idSlippage, // the caller's tolerance was applied above (ActiveIdMoved); the router must see exactly the id used here
```

### M94 openBand: callable by anyone

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -374 +374 @@
-    ) external onlyRebalancer nonReentrant whenNotPaused {
+    ) external nonReentrant whenNotPaused {
```

### M95 rebalance: callable by anyone

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -408 +408 @@
-    ) external onlyRebalancer nonReentrant whenNotPaused {
+    ) external nonReentrant whenNotPaused {
```

### M96 onlyRebalancer also accepts the owner (openBand and rebalance)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -185 +185 @@
-        if (msg.sender != rebalancer) revert NotRebalancer();
+        if (msg.sender != rebalancer && msg.sender != owner()) revert NotRebalancer();
```

### M97 onlyRebalancer: role check removed (openBand and rebalance)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -185 +184,0 @@
-        if (msg.sender != rebalancer) revert NotRebalancer();
```

### M98 harvestRewards: caller check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -567 +566,0 @@
-        if (msg.sender != rebalancer && msg.sender != owner()) revert NotRebalancer();
```

### M99 harvestRewards: owner not accepted

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -567 +567 @@
-        if (msg.sender != rebalancer && msg.sender != owner()) revert NotRebalancer();
+        if (msg.sender != rebalancer) revert NotRebalancer();
```

### M100 harvestRewards: PHAR forwarded to msg.sender instead of owner

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -574 +574 @@
-        if (amount != 0) phar.safeTransfer(owner(), amount);
+        if (amount != 0) phar.safeTransfer(msg.sender, amount);
```

### M101 setRebalancer: callable by anyone

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -744 +744 @@
-    function setRebalancer(address r) external onlyOwner {
+    function setRebalancer(address r) external {
```

### M102 pause: callable by anyone

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -736 +736 @@
-    function pause() external onlyOwner {
+    function pause() external {
```

### M103 unpause: callable by anyone

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -740 +740 @@
-    function unpause() external onlyOwner {
+    function unpause() external {
```

### M104 initialize: paused flag not set

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -181 +180,0 @@
-        _pause();
```

### M105 initialize: rebalancer not set

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -159 +158,0 @@
-        rebalancer = p.rebalancer;
```

### M106 initialize: healthy-feeds check (13b) removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -178 +178 @@
-        if (reasons & (FEED_ASSET_STALE_OR_BAD | FEED_PAIR_STALE_OR_BAD) != 0) revert PairValidationFailed(13);
+        if (reasons & (FEED_ASSET_STALE_OR_BAD | FEED_PAIR_STALE_OR_BAD) != 0) {}
```

### M107 feed staleness: > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -670 +670 @@
-            if (updatedAt <= block.timestamp && block.timestamp - updatedAt > maxAge) continue;
+            if (updatedAt <= block.timestamp && block.timestamp - updatedAt >= maxAge) continue;
```

### M108 feed answer == 0 accepted (<= to <)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -666 +666 @@
-            if (answer <= 0) continue;
+            if (answer < 0) continue;
```

### M109 feed answer <= 0 accepted (check removed)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -666 +666 @@
-            if (answer <= 0) continue;
+
```

### M110 feed: updatedAt == 0 accepted

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -669 +669 @@
-            if (updatedAt == 0 || answeredInRound < roundId) continue;
+            if (answeredInRound < roundId) continue;
```

### M111 feed: incomplete round (answeredInRound < roundId) accepted

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -669 +669 @@
-            if (updatedAt == 0 || answeredInRound < roundId) continue;
+            if (updatedAt == 0) continue;
```

### M112 feed: staleness check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -670 +669,0 @@
-            if (updatedAt <= block.timestamp && block.timestamp - updatedAt > maxAge) continue;
```

### M113 feed: short return data accepted

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -663 +663 @@
-            if (!s || r.length < 160) continue;
+            if (!s) continue;
```

### M114 bit 16 evaluated with one feed healthy

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -653 +653 @@
-        if (okMask == 3 && _poolDeviates(pa, pp)) reasons |= POOL_ORACLE_DEVIATION;
+        if (okMask != 0 && _poolDeviates(pa, pp)) reasons |= POOL_ORACLE_DEVIATION;
```

### M115 deposit: share conversion rounds up (Floor -> Ceil)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -218 +218 @@
-        shares = _convertToShares(assets, Math.Rounding.Floor);
+        shares = _convertToShares(assets, Math.Rounding.Ceil);
```

### M116 mint: asset conversion rounds down (Ceil -> Floor)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -226 +226 @@
-        assets = _convertToAssets(shares, Math.Rounding.Ceil);
+        assets = _convertToAssets(shares, Math.Rounding.Floor);
```

### M117 withdraw: share conversion rounds down (Ceil -> Floor)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -255 +255 @@
-        shares = _convertToShares(assets, Math.Rounding.Ceil);
+        shares = _convertToShares(assets, Math.Rounding.Floor);
```

### M118 maxMint: rounds up

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -211 +211 @@
-        return _convertToShares(maxAssets, Math.Rounding.Floor);
+        return _convertToShares(maxAssets, Math.Rounding.Ceil);
```

### M119 _holdings: NAV bin share rounds up

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -814,2 +814,2 @@
-                x += bx * bal / sup;
-                y += by * bal / sup;
+                x += (bx * bal + sup - 1) / sup;
+                y += (by * bal + sup - 1) / sup;
```

### M120 _pairToAsset rounds up

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -822 +822 @@
-        return _md(amount, pp * assetScale, pa * pairScale);
+        return (amount * pp * assetScale + pa * pairScale - 1) / (pa * pairScale);
```

### M121 _sliceOut: bin burn amount rounds up (over-pays the redeemer)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -319 +319 @@
-            uint256 amt = full ? bal : bal * shares / supply;
+            uint256 amt = full ? bal : (bal * shares + supply - 1) / supply;
```

### M122 _sliceOut: idle X slice rounds up

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -307 +307 @@
-        outX = full ? tokenX.balanceOf(address(this)) : tokenX.balanceOf(address(this)) * shares / supply;
+        outX = full ? tokenX.balanceOf(address(this)) : (tokenX.balanceOf(address(this)) * shares + supply - 1) / supply;
```

### M123 _sliceOut: full-exit shortcut removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -306 +306 @@
-        bool full = all || shares == supply;
+        bool full = all;
```

### M124 _sliceOut: band flag cleared only on full exit

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -350 +350 @@
-        if (full || !any) _hasBand = false;
+        if (full) _hasBand = false;
```

### M125 _sliceOut: dust-skip && -> ||

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -324 +324 @@
-            if (bx * amt < binSupply && by * amt < binSupply) {
+            if (bx * amt < binSupply || by * amt < binSupply) {
```

### M126 _nav: USDt leg valued at par, no feeds

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -795 +795 @@
-        return aAmt + _pairToAsset(pAmt, pa, pp);
+        return aAmt + pAmt;
```

### M127 _assetToPair: prices swapped

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -826 +826 @@
-        return _md(amount, pa * pairScale, pp * assetScale);
+        return _md(amount, pp * pairScale, pa * assetScale);
```

### M128 openBand: USDt swap amount not capped by idle USDt

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -389 +389 @@
-            uint256 amountIn = Math.min(_assetToPair((pv - aAmt) / 2, pa, pp), pAmt);
+            uint256 amountIn = _assetToPair((pv - aAmt) / 2, pa, pp);
```

### M129 openBand: even-split threshold changed (no deadband)

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -386 +386 @@
-        if (aAmt > pv + 1) {
+        if (aAmt >= pv) {
```

### M130 rebalanceAllowed: daily cap off by one

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -617 +617 @@
-        if (rebalancesToday() >= _gp.maxRebalancesPerDay) {
+        if (rebalancesToday() > _gp.maxRebalancesPerDay) {
```

### M131 rebalanceAllowed: latch bit not reported

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -608 +607,0 @@
-        if (_latched) reasonBits |= RB_LATCHED;
```

### M132 rebalanceAllowed: paused bit not reported

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -607 +606,0 @@
-        if (paused()) reasonBits |= RB_PAUSED;
```

### M133 rebalanceAllowed: in-range edges

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -613 +613 @@
-            if (a >= _lower && a <= _upper) reasonBits |= RB_IN_RANGE;
+            if (a > _lower && a < _upper) reasonBits |= RB_IN_RANGE;
```

### M134 rebalanceAllowed: cooldown < to <=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -616 +616 @@
-        if (block.timestamp < readyAt) reasonBits |= RB_COOLDOWN;
+        if (block.timestamp <= readyAt) reasonBits |= RB_COOLDOWN;
```

### M135 rebalanceAllowed: readyAt always the next day on cap

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -620 +620 @@
-            if (nextDay > readyAt) readyAt = nextDay;
+            readyAt = nextDay;
```

### M136 maxDeposit: latch not considered

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -201 +201 @@
-        if (paused() || _latched) return 0;
+        if (paused()) return 0;
```

### M137 maxDeposit: pause not considered

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -201 +201 @@
-        if (paused() || _latched) return 0;
+        if (_latched) return 0;
```

### M138 maxDeposit: live guard reasons not considered

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -203 +202,0 @@
-        if (reasons != 0) return 0;
```

### M139 deposit: entry guard check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -216 +215,0 @@
-        _requireEntryOk();
```

### M140 mint: entry guard check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -225 +224,0 @@
-        _requireEntryOk();
```

### M141 deposit: whenNotPaused removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -214 +214 @@
-    function deposit(uint256 assets, address receiver) public override nonReentrant whenNotPaused returns (uint256 shares) {
+    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
```

### M142 mint: whenNotPaused removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -223 +223 @@
-    function mint(uint256 shares, address receiver) public override nonReentrant whenNotPaused returns (uint256 assets) {
+    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
```

### M143 _requireEntryOk: latch check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -722 +721,0 @@
-        if (_latched) revert GuardLatched();
```

### M144 _requireEntryOk: bits 16 and 32 not enforced at entry

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -724 +724 @@
-        if (reasons != 0) revert GuardUnsafe(reasons);
+        if (reasons & LATCHABLE_MASK != 0) revert GuardUnsafe(reasons);
```

### M145 rebalance: entry guard check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -416 +415,0 @@
-        _requireEntryOk(); // latched -> GuardLatched, live unsafe -> GuardUnsafe(reasons)
```

### M146 openBand: entry guard check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -376 +375,0 @@
-        _requireEntryOk();
```

### M147 openBand: BandExists check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -377 +376,0 @@
-        if (_hasBand) revert BandExists();
```

### M148 _checkDeadline: deadline not enforced

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -557 +557 @@
-        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
+
```

### M149 _checkDeadline: > to >=

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -557 +557 @@
-        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
+        if (block.timestamp >= deadline) revert DeadlineExpired(deadline);
```

### M150 rebalance: NoBand check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -411 +410,0 @@
-        if (!_hasBand) revert NoBand();
```

### M151 _addBand: NothingToDeploy check removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -495 +494,0 @@
-        if (bx == 0 && by == 0) revert NothingToDeploy();
```

### M152 rebalance: old band not burned

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -432 +431,0 @@
-        _sliceOut(0, 1, true); // burn the whole band (and keep every idle token in the vault)
```

### M153 bit 32: hook != rewarder not detected

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -696 +696 @@
-        if (!ok || address(uint160(hooks)) != rewarder) return true;
+        if (!ok) return true;
```

### M154 bit 32: rewarder.isLinked() == false not detected

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -698 +698 @@
-        if (!ok || hooks != 1) return true;
+        if (!ok) return true;
```

### M155 bit 32: beacon implementation codehash change not detected

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -702 +702 @@
-        return impl.codehash != rewarderImplCodehash;
+        return false;
```

### M156 bit 32: failed beacon read not detected

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -700 +699,0 @@
-        if (!ok) return true;
```

### M157 bit 32: failed hook read not detected

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -696 +696 @@
-        if (!ok || address(uint160(hooks)) != rewarder) return true;
+        if (address(uint160(hooks)) != rewarder) return true;
```

### M158 bit 16: failed getActiveId read not a deviation

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -678 +677,0 @@
-        if (!ok) return true;
```

### M159 redeemInKind: pays msg.sender instead of receiver

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -278,2 +278,2 @@
-        if (amountX != 0) tokenX.safeTransfer(receiver, amountX);
-        if (amountY != 0) tokenY.safeTransfer(receiver, amountY);
+        if (amountX != 0) tokenX.safeTransfer(msg.sender, amountX);
+        if (amountY != 0) tokenY.safeTransfer(msg.sender, amountY);
```

### M160 redeem/withdraw: pays msg.sender instead of receiver

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -298 +298 @@
-        IERC20(asset()).safeTransfer(receiver, paid);
+        IERC20(asset()).safeTransfer(msg.sender, paid);
```

### M161 redeem/withdraw: ExitFailed on zero payout removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -297 +296,0 @@
-        if (paid == 0) revert ExitFailed();
```

### M162 redeemInKind: ExitFailed on zero payout removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -277 +276,0 @@
-        if (amountX == 0 && amountY == 0) revert ExitFailed();
```

### M163 redeemInKind: zero receiver allowed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -270 +269,0 @@
-        if (receiver == address(0)) revert ZeroAddress();
```

### M164 redeemInKind: zero shares allowed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -269 +268,0 @@
-        if (shares == 0) revert ZeroAmount();
```

### M165 redeem/withdraw payout: allowance not spent

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -288 +287,0 @@
-        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
```

### M166 initialize: assetIsX inverted

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -146 +146 @@
-        assetIsX = tx_ == p.asset;
+        assetIsX = tx_ != p.asset;
```

### M167 _guardedSwap: zero-amount early return removed

```diff
--- a/PharaohDlmmVault.sol
+++ b/PharaohDlmmVault.sol
@@ -458 +457,0 @@
-        if (amountIn == 0) return 0;
```

### V01 check 1: zero-address/empty-field check removed (all fields)

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -31,6 +30,0 @@
-        if (
-            p.asset == address(0) || p.pairToken == address(0) || p.pair == address(0) || p.router == address(0)
-                || p.factory == address(0) || p.rewarder == address(0) || p.feedAsset == address(0)
-                || p.feedPair == address(0) || p.owner == address(0) || p.rebalancer == address(0)
-                || p.rewarderImplCodehash == bytes32(0)
-        ) revert IPharaohDlmmVault.PairValidationFailed(1);
```

### V01a check 1: zero codehash no longer rejected

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -35 +34,0 @@
-                || p.rewarderImplCodehash == bytes32(0)
```

### V01b check 1: zero owner no longer rejected

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -34 +34 @@
-                || p.feedPair == address(0) || p.owner == address(0) || p.rebalancer == address(0)
+                || p.feedPair == address(0) || p.rebalancer == address(0)
```

### V01c check 1: zero rebalancer no longer rejected

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -34 +34 @@
-                || p.feedPair == address(0) || p.owner == address(0) || p.rebalancer == address(0)
+                || p.feedPair == address(0) || p.owner == address(0)
```

### V02 check 2: asset == pairToken check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -37 +36,0 @@
-        if (p.asset == p.pairToken) revert IPharaohDlmmVault.PairValidationFailed(2);
```

### V03 check 3: factory registry (pair, binStep) check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -41 +40,0 @@
-        if (info.LBPair != p.pair || info.binStep != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(3);
```

### V03a check 3: binStep half removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -41 +41 @@
-        if (info.LBPair != p.pair || info.binStep != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(3);
+        if (info.LBPair != p.pair) revert IPharaohDlmmVault.PairValidationFailed(3);
```

### V03b check 3: pair half removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -41 +41 @@
-        if (info.LBPair != p.pair || info.binStep != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(3);
+        if (info.binStep != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(3);
```

### V04 check 4: pair.getFactory/getBinStep check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -44 +43,0 @@
-        if (pr.getFactory() != p.factory || pr.getBinStep() != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(4);
```

### V04a check 4: getFactory half removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -44 +44 @@
-        if (pr.getFactory() != p.factory || pr.getBinStep() != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(4);
+        if (pr.getBinStep() != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(4);
```

### V04b check 4: getBinStep half removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -44 +44 @@
-        if (pr.getFactory() != p.factory || pr.getBinStep() != p.binStep) revert IPharaohDlmmVault.PairValidationFailed(4);
+        if (pr.getFactory() != p.factory) revert IPharaohDlmmVault.PairValidationFailed(4);
```

### V05 check 5: pair tokens == {asset, pairToken} check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -47,3 +46,0 @@
-        if (!((tokenX == p.asset && tokenY == p.pairToken) || (tokenX == p.pairToken && tokenY == p.asset))) {
-            revert IPharaohDlmmVault.PairValidationFailed(5);
-        }
```

### V05a check 5: only tokenX checked

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -47 +47 @@
-        if (!((tokenX == p.asset && tokenY == p.pairToken) || (tokenX == p.pairToken && tokenY == p.asset))) {
+        if (!(tokenX == p.asset || tokenX == p.pairToken)) {
```

### V05b check 5: reversed X/Y order rejected (only asset = X accepted)

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -47 +47 @@
-        if (!((tokenX == p.asset && tokenY == p.pairToken) || (tokenX == p.pairToken && tokenY == p.asset))) {
+        if (!((tokenX == p.asset && tokenY == p.pairToken))) {
```

### V06 check 6: router.getFactory check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -50 +49,0 @@
-        if (IDLMMRouter(p.router).getFactory() != p.factory) revert IPharaohDlmmVault.PairValidationFailed(6);
```

### V07 check 7: pair hook == rewarder check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -51 +50,0 @@
-        if (address(uint160(uint256(pr.getLBHooksParameters()))) != p.rewarder) revert IPharaohDlmmVault.PairValidationFailed(7);
```

### V08 check 8: rewarder.isLinked check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -53 +52,0 @@
-        if (!rw.isLinked()) revert IPharaohDlmmVault.PairValidationFailed(8);
```

### V09 check 9: router authorised-manager check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -55 +55 @@
-        if (voter == address(0) || !IDLMMVoter(voter).isAuthorizedDLMMManager(p.router)) {
+        if (voter == address(0)) {
```

### V09a check 9: voter == 0 check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -55 +55 @@
-        if (voter == address(0) || !IDLMMVoter(voter).isAuthorizedDLMMManager(p.router)) {
+        if (!IDLMMVoter(voter).isAuthorizedDLMMManager(p.router)) {
```

### V10 check 10: beacon lists rewarder for pair check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -59 +59 @@
-        if (beacon == address(0) || IDLMMRewarderBeacon(beacon).getRewarder(p.pair) != p.rewarder) {
+        if (beacon == address(0)) {
```

### V10a check 10: beacon == 0 check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -59 +59 @@
-        if (beacon == address(0) || IDLMMRewarderBeacon(beacon).getRewarder(p.pair) != p.rewarder) {
+        if (IDLMMRewarderBeacon(beacon).getRewarder(p.pair) != p.rewarder) {
```

### V11 check 11: beacon implementation codehash pin removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -62,3 +61,0 @@
-        if (IDLMMRewarderBeacon(beacon).implementation().codehash != p.rewarderImplCodehash) {
-            revert IPharaohDlmmVault.PairValidationFailed(11);
-        }
```

### V12 check 12: reward token sanity check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -66,3 +65,0 @@
-        if (rewardToken == address(0) || rewardToken == p.asset || rewardToken == p.pairToken) {
-            revert IPharaohDlmmVault.PairValidationFailed(12);
-        }
```

### V12a check 12: zero reward token accepted

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -66 +66 @@
-        if (rewardToken == address(0) || rewardToken == p.asset || rewardToken == p.pairToken) {
+        if (rewardToken == p.asset || rewardToken == p.pairToken) {
```

### V12b check 12: reward token == asset accepted

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -66 +66 @@
-        if (rewardToken == address(0) || rewardToken == p.asset || rewardToken == p.pairToken) {
+        if (rewardToken == address(0) || rewardToken == p.pairToken) {
```

### V12c check 12: reward token == pairToken accepted

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -66 +66 @@
-        if (rewardToken == address(0) || rewardToken == p.asset || rewardToken == p.pairToken) {
+        if (rewardToken == address(0) || rewardToken == p.asset) {
```

### V13 check 13: feed decimals check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -69,3 +68,0 @@
-        if (IChainlinkFeed(p.feedAsset).decimals() != 8 || IChainlinkFeed(p.feedPair).decimals() != 8) {
-            revert IPharaohDlmmVault.PairValidationFailed(13);
-        }
```

### V13a check 13: asset-feed decimals not checked

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -69 +69 @@
-        if (IChainlinkFeed(p.feedAsset).decimals() != 8 || IChainlinkFeed(p.feedPair).decimals() != 8) {
+        if (IChainlinkFeed(p.feedPair).decimals() != 8) {
```

### V13b check 13: pair-feed decimals not checked

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -69 +69 @@
-        if (IChainlinkFeed(p.feedAsset).decimals() != 8 || IChainlinkFeed(p.feedPair).decimals() != 8) {
+        if (IChainlinkFeed(p.feedAsset).decimals() != 8) {
```

### V14 check 14: token decimals <= 18 check removed

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -74 +73,0 @@
-        if (assetDecimals > 18 || pairDecimals > 18) revert IPharaohDlmmVault.PairValidationFailed(14);
```

### V14a check 14: asset decimals not checked

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -74 +74 @@
-        if (assetDecimals > 18 || pairDecimals > 18) revert IPharaohDlmmVault.PairValidationFailed(14);
+        if (pairDecimals > 18) revert IPharaohDlmmVault.PairValidationFailed(14);
```

### V14b check 14: pair decimals not checked

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -74 +74 @@
-        if (assetDecimals > 18 || pairDecimals > 18) revert IPharaohDlmmVault.PairValidationFailed(14);
+        if (assetDecimals > 18) revert IPharaohDlmmVault.PairValidationFailed(14);
```

### V14c check 14: bound 18 -> 19

```diff
--- a/PharaohDlmmPairValidator.sol
+++ b/PharaohDlmmPairValidator.sol
@@ -74 +74 @@
-        if (assetDecimals > 18 || pairDecimals > 18) revert IPharaohDlmmVault.PairValidationFailed(14);
+        if (assetDecimals > 19 || pairDecimals > 19) revert IPharaohDlmmVault.PairValidationFailed(14);
```
