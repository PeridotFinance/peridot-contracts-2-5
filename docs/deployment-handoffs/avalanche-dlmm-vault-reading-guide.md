# DLMM vault: frozen commit and reading guide (16 Nov 2026)

**Frozen source** (branch `feat/dlmm-vault-int`; the vault source is byte-identical to commit `3726773c`; later commits touched only tests, docs and one interface comment):
| File | sha256 |
| --- | --- |
| `contracts/vault-dlmm/src/PharaohDlmmVault.sol` (865 lines) | `4eec28a7e0eaf5a5687b0ea37090f76d6e231ff5fb5f86723bafcf534959ad40` |
| `contracts/vault-dlmm/src/PharaohDlmmPairValidator.sol` (76 lines) | `9cc0a953d622e4a50301f9a95a387e4161baa899896d0c1bad160462e1862b40` |
| `contracts/vault-dlmm/src/IPharaohDlmmVault.sol` | `d7215f130a3cb9bd6f0cba287ca53427397fff2331991f0224e5d6290cb07651` |
Re-check before the deploy: `sha256sum contracts/vault-dlmm/src/*.sol`. Any change to `src/` re-opens the rehearsal.

## What you read: the review-fix diff (113 lines, one file): `avalanche-dlmm-vault-review-fixes.diff`
`git diff 182d272c 3726773c -- contracts/vault-dlmm/src/PharaohDlmmVault.sol`. It is on top of the code the independent review (W10, `avalanche-dlmm-vault-review-W10.md`) read. Hunks, in order:
1. L42-72: new errors/constants (`SupplyBelowMinimum`, `RenounceDisabled`, `MIN_SUPPLY` 1e6).
2. L217-240 `deposit`/`mint` + `_requireMinSupply`: **deposit side only**, reverts if resulting supply is in (0, 1e6). Check: no exit function calls it.
3. L305 `_payOutAsset`: pays the vault's USDC balance delta, not the router's returned amount.
4. L390/434: post-swap `_poolDeviates` re-check in `openBand` and `rebalance` (reverts `GuardUnsafe(16)`).
5. L568 `harvestRewards`: `PharHarvested.amount` = PHAR claimed in the call (balance delta), forwarding of the whole balance unchanged.
6. L741-785: `renounceOwnership` reverts; cooldown bound 112.

## If you read more (suggested 20 minutes, not required): the lines that carry the money
- `initialize` L126-186 (cap 200e6 set here, starts paused, pair validation call, roles) and the validator's 14 checks.
- `redeemInKind` L277-295 + `_sliceOut` L321-369: no oracle, no swap, no pause/guard/latch gate, pro-rata direct `pair.burn`. This is the guaranteed exit.
- `_evaluate`/`_feeds`/`_poolDeviates` L664-713: guard bits; bit 16 orientation from the token order.
- `rebalance` L416-465 and `_addBand` L505-562: preconditions, band around the REAL active id.
- `_checkCap` L747: the cap, enforced on `deposit`/`mint` only.

## Evidence behind the code you do not read (labelled)
- Independent adversarial review W10: no Critical/High; one Medium (first-depositor dust supply) FIXED in the diff above and by the $1 seed to the dead address in the ceremony. Accepted for the pilot: F3 (96 re-centres across UTC midnight, worst case about $76 at the cap if the keeper key is stolen; Safe can pause), F5 (PHAR dust-burn griefing, attacker pays about 60 to 130 times the damage).
- Mutation checks: 200 mutants on the pre-fix code, 191 killed, 9 argued equivalent; the rerun on the post-fix code is running at the time of writing (partial results to follow).
- Fuzz flake verdict: test tolerance, not a vault defect (a deposit can lower the share price only above par and by at most D <= a*(N-S)/(N+1); at most about 31 raw units at the cap); the test now asserts the exact bound.
- Tests: 589 pass, 0 fail, 7 fork tests skipped without the fork (94 fork tests passed on the real pool at block 100,420,249 on the pre-fix code; the rehearsal ran on `3726773c`).
- Accepted residual risks, unchanged: a failing Pharaoh rewarder/voter hook blocks every exit while the guard reads clean (the keeper's exit probe alerts; you pause); PHAR income is 90 % of the modelled return and controlled by Pharaoh governance; re-centre cost measured at 41 to 288 ppm (3 to 20 times the model).
