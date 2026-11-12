# Pharaoh vaults: entry fairness and observation F-IK-2 (ledger investigation)

Status: **F-IK-2: cause EXPLAINED for the scenarios run (share-pricing rule), entry fairness as a launch-gate item: NOT established (it fails the strict reading in the states measured; many states were not tested, see section 9).** Nothing here changes any gate, cap or date. Both Pharaoh vaults stay CLOSED for deposits (live `depositCap` is 1 wei). Names are products (Pharaoh USDC vault, Pharaoh WAVAX vault), not track letters. These are **development runs on the shared warm cache against the public RPC; no isolated-cache reproduction was done** (the lead does that).

The NAV-based "no dilution" PASS of `test_02` (gate row 3) is **not** evidence of deposit/entry fairness and must not be cited as such. It measures haircut NAV per share; this work measures real tokens.

Code: `contracts/test/AvalancheTrackAVaultsFork.t.sol` (tests `test_18_diag_*` to `test_23_diag_*`), `contracts/test/helpers/AvalancheTrackAVaultsBase.sol` (section "F-IK-2 LEDGER"). Logs: `avalanche-track-a-evidence/fik2/attempt<N>-<vault>.txt`, log lines prefixed `FIK2|`. Final code: Fork.t.sol sha256 `dd0e6938...`, Base `9b43eedc...` (full values in the headers of `attempt10`, `attempt11`).

## 1. Result in one paragraph

The incumbent's loss reproduced exactly (Pharaoh WAVAX vault, incumbent USD 10,000 = 1,169.36 WAVAX, newcomer the same size: -1,131 ppm = -11.3 bp at the oracle, `PARITY` line equals `test_17`; Pharaoh USDC vault -111 ppm at the size of `test_17`, a 50% newcomer: the `PARITY` line of `test_18_diag_ledgerLaterDeposit_pct50` prints -111 ppm and -109 ppm with the tick restored, equal to `test_17`; -140 ppm at 10%, -71 ppm at 100%). In **token units** it is a transfer of real holdings from the incumbent (and the Safe's seed) to the newcomer, not a pool effect and not a measurement artefact: the same pool swap executed by an external account with no deposit changes the incumbent by -4 ppm (WAVAX) / +1 ppm (USDC), the transfer is **not undone by restoring the tick** because it sits in the share count, and it is visible at the oracle (-1,131 ppm), at the pool spot before (-1,061 ppm) and at the pool spot after (-1,077 ppm). The transfer is the **share-pricing rule**: shares are minted on `totalAssets()` after minus before, which values the paired token at `(1 - valuationHaircutBps)` (3% on the WAVAX vault, 1% on the USDC vault), while `redeemInKind` pays real tokens at no haircut. When the newcomer's marginal contribution has a different paired-token fraction than the vault's holdings, the haircut credits him a different share of real value than he put in. The haircut term has an exact closed form (asserted, section 5) and accounts for 1,327.15e15 of the 1,320.30e15 wei transfer in the headline case (the TWAP-vs-spot valuation term is -6.85e15, rounding 0). A **mutation control** (local VM only: `valuationHaircutBps` overwritten with 0) removes it: incumbent -1,131 ppm -> -4 ppm; newcomer transfer 1,129 ppm -> 0 ppm. The transfer has either sign (negative at the USDC vault's cap-size deposit: the incumbent gains +176 ppm).

The newcomer **can realise a gain after real execution costs** in the tested states: round trip deposit -> `redeemInKind` -> sell the paired leg through the real pool: Pharaoh WAVAX vault +20.8% of D (D = 1% of incumbent), +1.9% (10%), +0.097% (100%); Pharaoh USDC vault +1.41%, +0.136%, +0.0024%. The absolute gain is small and bounded (about `h x (paired value converted)`: 2.44 WAVAX, 0.283 USDC at the smallest size) and saturates after one or two cycles; it exists because earlier deposits left idle paired token in the vault. In the **live seed-only state** (no deposit yet) the same round trip **loses** 53 to 391 ppm.

## 2. Method

Everything is measured in token units on a fork of the pinned block (USDC vault 99216397, WAVAX vault 99216312), with real swaps through the real router and the real pool; no vault or pool code is mocked. The only mutation is the control in section 6.

**Holdings.** Vault holdings `H = idle balances + position principal + uncollected fees`, read exactly: principal and fees are obtained by replaying `collect`, then `decreaseLiquidity(all)` + `collect`, as the vault, inside a snapshot that is reverted. A holder's in-kind entitlement is `H x shares / supply` (floor), cross-checked against a real replayed `redeemInKind` (asserted equal within rounding).

**Ledger (`FIK2|...|LEDGER residual`).** For each step the change of every account that can hold the two tokens is summed: the five wallets (Alice, Bob, Carol, Safe, external swapper), the vault holdings split by holder, the pool balance (split into vault principal + vault fees, pool protocol fees accrued, and "other LPs", derived as the remainder), router and position manager balances. **The residual is 0 wei in every step of every run (asserted `== 0`).** What is independent and what is derived: the pool balance, the wallets, the vault holdings, the protocol fees, router and manager are separate reads; "other LPs (principal + fees)" is the pool balance minus the other two, so it absorbs anything in the pool that is not the vault or the protocol fee (principal and fees of third-party liquidity providers; it cannot be split further without enumerating their positions, which was not done). The residual-zero identity therefore proves that no token went to a wallet, router, manager or gauge account outside the list; it does not by itself prove the split inside the pool. Independent exact checks that are asserted: pool balance change equals the `Swap` event amounts (control swap), minted shares equal `mulDiv(netContribution, supply+1, valueBefore+1)` applied to the `totalAssets()` the vault reported, `sum(incumbents' real minus control) + newcomer entitlement = K` (observed |x| <= 1 wei, bound 8), formula entitlement equals replayed `redeemInKind`, and the closed form of the haircut term (section 5; observed difference <= 862 wei in 1.3e18). Tolerance: exact equality for the ledger; the others as stated. **No unexplained residual exists in token terms; the explanatory residual of the share-price chain is the valuation term, listed separately in each table.**

**Controls.** (i) *Same pool trades, no deposit*: the deployment swap's size and direction are read from the pool `Swap` event, then executed by an external account from the same state; the incumbent's change in that run is the **pool effect**; real deposit minus control is the **share effect**. (ii) Every amount is valued at three bases: oracle, pool spot before the step, pool spot after. (iii) Tick restoration is reported but is not used as a control (it pays fees and moves value to LPs): the incumbent's change with the tick restored is reported next to the control-with-restore. (iv) Mutation `haircut = 0`.

**Identity used for the separation** (exact, per token): `sum over incumbents (real - control) + newcomer entitlement = K`, where `K = vault holdings after the deposit - vault holdings in the control`, the newcomer's contribution in tokens. Hence incumbent change = pool effect + (K - newcomer entitlement). Newcomer net = (entitlement - K) + (K - D): share transfer T plus execution cost.

## 3. Ledger summary, D = 100% of the incumbent (value, asset units; ppm of the stated base)

Real deposit, `FIK2|...|REAL deposit` (token units are in the logs; wei for WAVAX, 1e-6 USDC for USDC). Positive = gained.

| Line | Pharaoh USDC vault (incumbent USDC 2,000; D 2,000) at oracle / spot before / spot after | Pharaoh WAVAX vault (incumbent 1,169.36 WAVAX; D 1,169.36) at oracle / spot before / spot after |
| --- | --- | --- |
| Alice (incumbent), ppm of her deposit | -71 / -68 / -78 (-143,732 units at oracle) | -1,131 / -1,061 / -1,077 (-1.3231 WAVAX at oracle) |
| Bob (newcomer), ppm of D (entitlement - D) | -11 / -73 / +108 | +1,735 / +938 / +1,119 |
| Safe seed | -1 / -1 / -1 | -1 / -1 / -1 |
| Other LPs in the pool (derived) | +78 / +136 / -35 | -613 / +114 / -50 |
| Pool protocol fees accrued | +6 / +6 / +6 | +10 / +10 / +10 |
| Sum | 0 in tokens (residual 0 asserted); in value 0 within the printed rounding | same |

Reading: at the oracle basis, Bob's WAVAX gain is 1,735 ppm and the other LPs show -613 ppm; at the pool spot after, Bob +1,119, Alice -1,077, others -50. The -613 ppm of "other LPs" at the oracle is the oracle/pool basis (sAVAX bought below the BENQI-rate oracle); it is an artefact unless sAVAX can be redeemed at the oracle rate (not tested). The incumbent's loss does not depend on the basis (-1,131 / -1,061 / -1,077).

## 4. Effect separation (report each effect in token units and in ppm of the position)

Positive T = newcomer gains from the share price. Incumbent figures are ppm of the incumbent's deposit (USDC 2,000 USDC; WAVAX 1,169.36 WAVAX) at the oracle. "Impact" and "fee" are the deployment swap's cost to the swapper valued at the pool spot before, ppm of the newcomer's D. Source: `test_18_diag_*` in attempts 8 and 9 (identical to attempts 3 and 4).

| | USDC 1% | USDC 10% | USDC 50% | USDC 100% | USDC cap-size (306%) | WAVAX 1% | WAVAX 10% | WAVAX 50% | WAVAX 100% | WAVAX cap-size (225%) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| (b) deployment swap | paired->asset 925% of D | asset->paired 36% | asset->paired 47% | asset->paired 49% | asset->paired 50% | paired->asset 686% | paired->asset 24% | asset->paired 35% | asset->paired 43% | asset->paired 47% |
| (b) price impact, ppm of D | 10 | 15 | 87 | 122 | 287 | 214 | 2 | 28 | 82 | 224 |
| (c) pool fee (50 / 100 ppm of the swap), ppm of D | 46 | 17 | 23 | 24 | 24 | 686 | 23 | 35 | 42 | 46 |
| (c) fee split: protocol / vault's own position / other LPs, ppm of D | 11 / 4 / 30 | 4 / 1 / 11 | 5 / 0 / 16 | 6 / 0 / 17 | 6 / 0 / 17 | 171 / 3 / 511 | 5 / 0 / 17 | 8 / 0 / 26 | 10 / 0 / 31 | 11 / 0 / 34 |
| (e) oracle/pool basis on the swap, apparent cost at the oracle, ppm of D (oracle above pool by 126 / 1,714 ppm) | +116 | -44 | -59 | -60 | -62 | +11,788 | +407 | -604 | -730 | -801 |
| incumbent: pool effect (control), ppm | 0 | 0 | 0 | +1 | +18 | 0 | 0 | -1 | -4 | -8 |
| incumbent: share effect, ppm | -142 | -140 | -111 | -73 | +158 | -2,217 | -2,046 | -1,515 | -1,127 | -611 |
| incumbent: total | -141 | -140 | -111 | -71 | +176 | -2,216 | -2,046 | -1,517 | -1,131 | -620 |
| incumbent: total with the tick restored | -141 | -139 | -109 | -71 | +163 | -2,217 | -2,046 | -1,515 | -1,126 | -610 |
| (a) share transfer T to the newcomer, ppm of D (oracle) | +14,416 | +1,427 | +227 | +74 | -52 | +222,094 | +20,498 | +3,036 | +1,129 | +271 |
| T: haircut term, asset units | +287,723 | +287,890 | +233,007 | +154,291 | -356,851 | +2.5949e18 | +2.3963e18 | +1.7790e18 | +1.3272e18 | +0.7257e18 |
| T: valuation (vault values the position at the TWAP tick, not spot), asset units | +612 | -2,359 | -5,710 | -4,880 | +35,434 | +2.19e15 | +0.70e15 | -3.83e15 | -6.85e15 | -9.06e15 |
| (d) rounding (floor of the mint, `+1` offsets) | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| (e) oracle/pool basis term of T at the pool spot basis, asset units | -4,225 | -1,165 | +3,204 | +3,739 | -29,809 | -1.52e17 | -1.37e17 | -9.09e16 | -5.79e16 | -1.79e16 |
| paired share of value: vault holdings before / newcomer's contribution K, ppm (0 = K has no positive paired part: the vault sold paired) | 518,923 / 0 | 518,923 / 357,454 | 518,923 / 471,462 | 518,923 / 485,700 | 518,923 / 495,217 | 503,910 / 0 | 503,910 / 0 | 503,910 / 352,848 | 503,910 / 426,596 | 503,910 / 467,551 |
| idle left after the deposit, oracle value, ppm of D | 46,418 (asset) | 1,952 | 17,013 | 26,920 | 80,256 | 2,209,062 | 347,282 | 185,036 | 167,335 | 162,869 |

Notes. (1) USDC cap-size D = 6,123.795 USDC (hypothetical USD 100,000 cap set in the local VM; the full `maxDeposit` (97,980.7 USDC; 10,539.4 WAVAX) was tried first and reverted with `Vault__DepositCapExceeded` on both vaults (the cap is re-checked inside the deposit), then halved until a single-transaction deposit succeeded; this measures the largest one-shot deposit, not the cap itself), WAVAX cap-size 2,634.8 WAVAX; `capSize` log lines state the sizes. The **live** `depositCap` is 1 wei, so no live cap-size deposit exists. (2) At 1% and 10% on the WAVAX vault and at 1% on the USDC vault the vault **sells incumbents' idle paired token** to match the small deposit (`_balanceIdle`: `pairValue > assetBalance`), a swap of up to 6.9 times the deposit; its fee and impact are charged into the newcomer's K in this accounting (K - D = -901 ppm at spot before), but the ledger shows the incumbents' idle tokens are what is sold. (3) The tick moved 3 to 4 ticks (WAVAX 2,554 -> 2,557) at 100%.

## 5. Where the transfer comes from (share-pricing chain) and the closed form

`totalAssets()` values the position at the TWAP tick and the paired token (idle and principal) at `oracle x (1 - h)`, excluding uncollected fees. `deposit` mints `floor(netContribution x (supply+1) / (valueBefore+1))` with `netContribution = totalAssets after - totalAssets before collect` (asserted exactly). With `K` the newcomer's contribution in tokens, `H1` the holdings after, `P1` the oracle value of their paired part, `O(kP)` the oracle value of K's paired part, all at the oracle:

`T_haircut = h x (K x P1 - O(kP) x H1) / (10^4 x H1 - h x P1)`   (h in bp)

This is an exact algebraic consequence of the minting rule (the log line `ALGEBRA` compares it with the measured chain term; asserted equal within `H1/1e12 + 64`; observed difference: 1 unit on the USDC vault, 862 wei on 1.33e18 on the WAVAX vault). It is **zero when the newcomer's contribution has the same paired fraction as the vault's holdings** and positive when K is less paired than the holdings (he is under-charged the haircut), negative when more paired. Two mechanisms make K differ from H:

1. A deposit larger than the vault's idle paired value: the vault swaps `(assets - pairedIdleValue)/2` into the paired token, so K's paired fraction is below one half by the incumbents' idle paired token (42.7% against 50.4% on the WAVAX vault at 100%).
2. A deposit smaller than the idle paired value: the vault sells `(pairedIdleValue - assets)/2` of the **incumbents' idle paired token** for the asset. The haircut-valued token becomes par-valued asset, so `totalAssets()` rises by about `h x converted value`, and that rise is credited to the newcomer as net contribution. In this regime `T ~ h x (idle paired value)/2`: WAVAX 0.03 x 172.48/2 = 2.59 WAVAX (measured 2.595), USDC 0.01 x 57.02/2 = 0.285 (measured 0.288).

Why idle paired token exists: after one deposit (Alice's, into the seed-only state) the WAVAX vault holds 133.38 sAVAX idle (14.7% of its value, `IDLE ... BEFORE` line) and the USDC vault 57.07 USDt (2.8%); each further deposit leaves more (WAVAX +18 sAVAX at 100%). The source is consistent with this: `_balanceIdle` splits by oracle value 50/50, `_addLiquidity` deploys at the position's own ratio and the remainder stays idle. The exact ratio of the position at the pin was not measured separately.

## 6. Mutation control (local VM only; a control, never a proposal)

`test_23_diag_mutationControl_haircutZero` overwrites `valuationHaircutBps` in the vault's storage with 0 (the packed slot is located by matching all six packed values against the public getters) and repeats the 1% and 100% cases.

| | USDC 1% | USDC 100% | WAVAX 1% | WAVAX 100% |
| --- | --- | --- | --- | --- |
| incumbent total, ppm, unmutated -> haircut 0 | -141 -> 0 | -71 -> +1 | -2,216 -> 0 | -1,131 -> -4 |
| newcomer share transfer T, ppm of D | +14,416 -> 0 | +74 -> 0 | +222,094 -> -11 | +1,129 -> 0 |
| round trip net P&L after the real pool, ppm of D | +14,139 -> -276 | +24 -> -49 | +208,423 -> -13,502 | +974 -> -153 |

So the incumbent's loss, the newcomer's gain and the profitable round trip all disappear when the haircut is removed from the minting NAV; what remains is the newcomer paying fee and impact. This identifies the cause; it does not say the haircut is wrong (it protects cash redemption) or that setting it to 0 is a remedy. No remedy was evaluated.

## 7. Round trips, repeated cycling, more holders

**Newcomer round trip net of real execution costs** (`test_19`, `test_22`, `test_23`): deposit -> `redeemInKind` of all shares -> sell the paired leg through the real router (fee and impact paid) -> asset. "Paper" values the paired leg at the oracle. Net P&L, ppm of D (negative = newcomer lost). All asserted identity: newcomer asset balance = start - D + asset leg + sale proceeds.

| Size (incumbent present) | USDC paper / net | WAVAX paper / net |
| --- | --- | --- |
| D = 1% of incumbent | +14,243 / +14,139 (0.283 USDC) | +209,404 / +208,423 (2.437 WAVAX) |
| D = 10% | +1,439 / +1,364 (0.273 USDC) | +20,064 / +19,237 (2.250 WAVAX) |
| D = 100% | -11 / +24 (0.050 USDC) | +1,735 / +974 (1.140 WAVAX) |
| live seed-only state, USD 100 / 1,000 / 10,000 (USDC: 100 and 1,000 only) | net -53 / -52 | net -391 / -133 / -103 |

The sale of the paired leg costs 28 to 144 ppm of D below the pool spot before the sale (USDC 28, 54, 84; WAVAX 53, 53, 144 for 1%, 10%, 100%), so the newcomer pays for execution; the gain survives it only because T exceeds the cost. **Net gain after execution costs: yes in the incumbent-present states above; no in the live seed-only state.**

**Repeated cycling / extraction loop** (`test_20`, 5 cycles of deposit all his balance -> in-kind -> sell paired leg; control = the same pool trades by an external account, no deposit).

| | attacker cumulative net P&L, ppm of D, cycles 1..5 | incumbent cumulative change, ppm of its deposit, cycles 1..5 (control: external trades only) |
| --- | --- | --- |
| USDC D = 100% | +24, -23, -72, -121, -170 | -72, -72, -70, -69, -68 (control +7) |
| USDC D = 10% | +1,364, +1,312, +1,262, +1,212, +1,162 | -140, -139, -138, -138, -138 (control +2) |
| WAVAX D = 100% | +974, +958, +872, +780, +688 | -1,126, -1,206, -1,211, -1,212, -1,211 (control +2) |
| WAVAX D = 10% | +19,237, +21,569, +21,783, +21,733, +21,651 | -2,045, -2,301, -2,333, -2,337, -2,337 (control 0) |

The harm **does not compound; it saturates after two to three cycles**: the first cycle sets most of it and the next ones add 0 to 256 ppm (WAVAX D = 10%: -2,045, -2,301, -2,333, -2,337, -2,337; WAVAX D = 100%: -1,126, -1,206, -1,211, -1,212, -1,211), because the extractable amount is bounded by `h x (idle paired value)`, that stock includes what the attacker's own cycles leave behind (each cycle leaves some idle paired token), and the first cycles consume most of it; later cycles earn or cost the attacker only the execution cost (about -50 ppm of D per cycle on the USDC vault at 100%). The attacker's cost of an extraction loop is negative in the incumbent-present states (he gains); with the haircut term removed (section 6) one entry/exit/sale cycle costs him 49 to 276 ppm (USDC) and 153 to 13,502 ppm (WAVAX) of D and the incumbent is not harmed (-4 to +1 ppm). Griefing with an attacker loss and no gain was not found; a loop whose idle paired stock is replenished by other depositors was not simulated.

**More than two holders** (`test_21`; ledger residual 0 at every step, incl. `WHOLE RUN`). Holders: Alice (incumbent), Bob, Carol; ppm at the oracle, Alice against the entitlement she had at the start of the run, Bob and Carol against what they paid in.

| Order | Pharaoh USDC vault: Alice / Bob / Carol | Pharaoh WAVAX vault: Alice / Bob / Carol |
| --- | --- | --- |
| Bob 10% enters, Carol 100% enters; exits Bob (middle, before Carol and Alice), Carol, Alice | -71 / +1,508 / -176 | -1,336 / +20,790 / -104 |
| Bob 100% enters, Carol 10% enters; exits Bob, Carol, Alice | -129 / -69 / +1,062 | -2,281 / +582 / +22,573 |
| Interleaved: Bob 100% in, Alice exits half, Carol 10% in, Bob exits half, Carol out, Alice out, Bob out | -99 / -67 / +730 | -1,689 / +617 / +16,592 |

The middle holder is not systematically harmed or helped: the holder who enters with a small deposit while idle paired token is present (Bob 10% first; Carol 10% in the other orders) takes the largest gain, the incumbent loses in all three orders, and the 100% holder's result depends on the order. Exits are pro rata: in every exit step of `test_21` (attempts 8 and 9, scripted over all `EXIT` lines) the other holders' entitlements move by at most 1 wei.

## 8. Classification (requirement 7)

* **Not a measurement artefact.** The loss is in token units (Alice +46.13 WAVAX / -36.70 sAVAX, i.e. a changed in-kind payout), it shows at all three valuation bases, it persists when the tick is restored, and the ledger conserves every token.
* **Not the cost of deploying a deposit into a concentrated position.** That cost is borne by the newcomer (swap fee 42 ppm + impact 82 ppm of D = 125 ppm at 100% WAVAX, seen as K - D = -125 ppm at spot before) and by third parties; the pool effect on the incumbent is -4 ppm (WAVAX) / +1 ppm (USDC) at 100%, within the bound derived in section 10.
* **It is a property of the vault's minting rule** (haircut NAV for the mint, real tokens for the in-kind exit): a design-level value transfer between depositors, exact in the closed form and removed by the mutation control. Whether that is a defect or intended is for the owner to decide; the transfer is one that the vault's own minting rule creates, of either sign, of size up to about `h x (swapped paired value)`, borne by incumbents when the newcomer's contribution is less paired than the vault, and by the newcomer in the opposite case. What it is **not** is a theft of principal: the amounts are 0.1 to 2.6 WAVAX-equivalent at USD 10,000 positions.
* **Entry fairness stays unresolved/not established**: it is explained here for two pools at two pins and one idle-composition state each, not for the vault in general (section 9).

## 9. What was not tested

* Any block other than the two pins; any state with a different idle residual, a different position ratio, or after keeper `rebalance` / `deployIdle`.
* The ERC-4626 `redeem`/`withdraw` exit for the newcomer (it pays the haircut NAV; cash redeem fails at many sizes), so the transfer was measured only as in-kind entitlement and through the round trip above; mixed cash/in-kind exits were not measured.
* Redeeming sAVAX at the BENQI rate (the oracle-basis gain of the WAVAX newcomer is an artefact unless this can be done), exit queues and their time.
* Deployment swaps that cross many initialised ticks or large price impact (largest swap: 3,033 USDC / 1,230 WAVAX); pools other than these two; MEV, front-running of the deposit, price manipulation inside the TWAP band, flash loans; gas.
* Time: fees accruing between steps, PHAR rewards (a different token; outside the ledger; gate rows 5 to 7), oracle moves between entry and exit.
* The pool's other LPs are one derived line; their individual positions, and the gauge / fee-distributor flows other than the pool's own `protocolFees`, were not enumerated (the zero ledger residual shows no listed token went elsewhere).
* A loop whose idle paired stock is replenished by third parties; many cycles beyond five.
* A remedy. The isolated-cache reproduction of tests 18 to 23.

## 10. Cost model and PROPOSED future limits (proposals only; none is adopted, none is in any test)

The existing `KIND_*_PPM` thresholds are **historical observations** taken from earlier logs (marked as such in code and in `inkind/README.md`) and are kept unchanged. The numbers below are derived from a cost model, not from the observed incumbent loss.

**Model.** Deposit D into a vault with haircut `h` (bp), pool fee `phi` (ppm of the swap input), deployment swap input `N` (asset terms, read from the `Swap` event), impact `I(N)` (fitted below), oracle above pool by `beta` (signed ppm), vault liquidity share `l = L_vault / L_pool(active)`, protocol-fee share `pi` of the swap fee (25% here: 12,143 of 48,574 and 12.46e15 of 49.84e15).

1. Newcomer's execution cost (his): `C = phi x N + I(N)`. Measured `I(N)`: roughly quadratic in `N`, `I ~ c N^2`, `c = 3.9e-7` per WAVAX (WAVAX vault: N 80 -> 0.0025 WAVAX, N 498 -> 0.096, N 1,230 -> 0.585) and `c = 2.6e-7` per USDC for `N <= 1,000` (USDC: 971 -> 0.245; at N 3,033 the quadratic overshoots, 2.4 predicted against 1.76 measured). Two data points per vault are not a fit; treat as order of magnitude.
2. Pool effect on an incumbent (counterparty of the swap): `P = l x N x (|beta| + phi)` upper bound (fee income and adverse selection against the oracle). Example WAVAX 100%: `l = 14.88e21 / 2,255e21 = 0.66%`, `N = 498.44`, `beta = 1,714 ppm`, `phi = 100 ppm`: `0.0066 x 498.44 x 0.001814 = 0.00597 WAVAX = 5.1 ppm` of the incumbent; observed pool effect -4 ppm and, with the haircut removed, total -4 ppm. USDC 100%: `l = 197.87e9 / 1,681e9 = 11.8%`, `N = 971.5`, `beta = 126`, `phi = 50`: `20.2e3 units = 10 ppm`; observed +1 ppm.
3. Share transfer (the cause): the closed form of section 5, which is zero when the haircut term is zero. For a deposit D smaller than the idle paired value `I_P`: `|T| <= h x I_P / 2`; otherwise `|T| <= h x |O(kP) - p x K|`, `p` = paired fraction of H1.

**Proposed acceptance limits for a future entry-fairness test** (to be adopted or rejected by the owner of the gate):

* L1 incumbent: for every deposit, every incumbent's oracle-valued in-kind change must lie within `+/- (l x N x (|beta| + phi) x 2 + rounding)` of its position. Example bounds: WAVAX 100%: 10 ppm; USDC 100%: 20 ppm. **The deployed code fails L1** (-1,131 and -71 ppm measured; passes with the haircut mutation: -4 and +1).
* L2 newcomer: the oracle-valued gain of the newcomer's entitlement over D must not exceed `|beta| x N_paired_bought / D - (phi x N + I(N)) / D + rounding` (it may gain the oracle/pool basis on the paired token he buys and must pay execution), and the round trip net P&L after selling both legs through the pool must be <= 0 up to rounding. **The deployed code fails L2** in the incumbent-present states (net +14,139 ppm USDC, +208,423 ppm WAVAX at 1%) and the round-trip part of L2 holds in the live seed-only state (net -53 to -391 ppm); the oracle-gain part of L2 was not evaluated there.
* L3 pure exits: another holder's in-kind entitlement may change by at most rounding (this already holds: <= 1 wei observed, and `R4`/`R5` of the in-kind gate).
* These limits assume the cost model; if the owner prefers a design remedy (price shares on real proportions or on a consistent non-haircut value, or hold idle paired token at zero), the limits become tests of that remedy; none of that was evaluated here.

## 11. Tests added (all inherited by both suites, so 12 test functions run on each vault)

| Test | Content |
| --- | --- |
| `test_18_diag_ledgerLaterDeposit_pct1` / `_pct10` / `_pct50` / `_pct100` | Alice incumbent (USDC vault USD 2,000, WAVAX vault USD 10,000), Bob deposits 1%, 10%, 50%, 100% of her size (50% on the USDC vault is the size of `test_17`): ledger, control swap, tick restored, share chain, closed form |
| `test_18_diag_ledgerLaterDeposit_capSize` | live `depositCap` logged (1 wei); with a hypothetical USD 100,000 cap the largest one-shot deposit that succeeds |
| `test_19_diag_newcomerRoundTripNetOfExecutionCosts` | round trip net of real conversion at 1%, 10%, 100% |
| `test_20_diag_cyclingEntryExit_incumbentHarmAndAttackerCost` | 5 cycles at 100% and 10%, external-trade control |
| `test_21_diag_threeHolders_smallThenLarge` / `_largeThenSmall` / `_interleavedExits` | three holders, middle holder exits before the others |
| `test_22_diag_newcomerIntoLiveSeedOnlyState` | live pin state (only the Safe's seed), ledger and round trip |
| `test_23_diag_mutationControl_haircutZero` | local-VM mutation control |

Asserted (exact identities only; **no fairness threshold**): ledger residual == 0; Swap-event amounts equal pool balance changes (control); minted shares equal the vault formula; incumbents' change plus newcomer entitlement equals K (|x| <= 8 wei); formula entitlement equals the replayed `redeemInKind`; closed-form haircut term; newcomer wallet identity in round trips. `test_17` is unchanged.

## 12. Attempts (every log kept; all are development runs, shared warm cache, direct to `https://api.avax.network/ext/bc/C/rpc`, `--rpc-url ... --compute-units-per-second 20 --fork-retries 10 --fork-retry-backoff 1000`, a grep of every log for HTTP 429 / Max retries / database error finds none)

| Attempt | Vault | Tests | Fork.t.sol sha256 prefix | Result |
| --- | --- | --- | --- | --- |
| 1 | USDC | `test_18` pct10 and pct100 (first exploration) | 6b11882e | 2 passed |
| 2 | USDC | `test_18` to `test_21` | 6b11882e | **6 passed, 3 failed**: the three `test_21` tests failed on the `WHOLE RUN` ledger (`2200000000 != 0`): the test dealt tokens to the newcomers inside the measured run. Test bug, not a vault finding; fixed by pre-funding before the first snapshot |
| 3 | USDC | `test_18` to `test_21` | 6c2036d4 | 9 passed |
| 4 | WAVAX | `test_18` to `test_21` | 6c2036d4 | 9 passed |
| 5, 6 | USDC, WAVAX | `test_22`, `test_23` | f400d650 | 2 passed each |
| 7 | USDC | whole suite, regex `test_` (skips the two `testFinding_*`) | 14d829f9 | 49 passed |
| 8 | USDC | whole suite, regex `test` (51 tests) | 14d829f9 | 51 passed, 0 failed |
| 9 | WAVAX | whole suite, regex `test` (51 tests) | 14d829f9 | 51 passed, 0 failed |
| **10** | **USDC** | **whole suite, regex `test` (52 tests, adds `pct50`)** | **dd0e6938 (final)** | **52 passed, 0 failed** |
| **11** | **WAVAX** | **whole suite, regex `test` (52 tests, adds `pct50`)** | **dd0e6938 (final)** | **52 passed, 0 failed** |

The numbers in sections 3 to 7 are from attempts 8 and 9 (for tests 18 to 21 identical to attempts 3 and 4, checked by script); the 50% column is from attempts 10 and 11 (the other columns are unchanged in them, the only code change between 9 and 10 is the added `pct50` test). Reproduce from `contracts/` (zsh): `AVALANCHE_MAINNET_RPC_URL=https://api.avax.network/ext/bc/C/rpc FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_fik2 FOUNDRY_CACHE_PATH=cache_fik2 TRACKA_PIN_BLOCK=99216397 forge test --threads 1 --rpc-url https://api.avax.network/ext/bc/C/rpc --compute-units-per-second 20 --fork-retries 10 --fork-retry-backoff 1000 <the --skip set of inkind/README.md> --match-contract AvalancheTrackAUsdcVaultForkTest --match-test 'test_(18|19|20|21|22|23)_' -vv` (WAVAX: pin 99216312 and `AvalancheTrackAWavaxVaultForkTest`).
