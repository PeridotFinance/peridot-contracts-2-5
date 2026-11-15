# Pharaoh vaults: independent check of F-IK-2 and a consistent share-pricing remedy (PROTOTYPE, test-only)

Status: **analysis and prototype only. Nothing here is deployable code, changes a gate, a cap or a date, or touches the deployed contracts.** Both Pharaoh vaults stay CLOSED (live `depositCap` is 1 wei). Product names are used throughout: **Pharaoh USDC vault** (pair USDC/USDt, deposited asset USDC, haircut 1%), **Pharaoh WAVAX vault** (pair sAVAX/WAVAX, deposited asset WAVAX, haircut 3%). The WAVAX/USDC Pharaoh *allocation strategy* (AVAX/stablecoin exposure) is a different thing and is not analysed here; every reserve table below is about the two correlated pairs only.

Files: fork replay `contracts/test/AvalancheVaultShareCheckFork.t.sol`; model `contracts/test/prototype/VaultShareModel.sol`; model tests `contracts/test/AvalancheVaultSharePricingPrototype.t.sol` (no RPC); exact-rational twin `docs/deployment-handoffs/avalanche-vault-remedy-evidence/exact_check.py`; logs `docs/deployment-handoffs/avalanche-vault-remedy-evidence/` (see its `README.md`; final runs are attempts 16, 17, 18). Final sha256: fork test `f85621ad...`, prototype test `02858949...`, model `7df6400c...` (full values in the headers of attempts 16 to 18). Source cites `V:<n>` are line numbers of the verified `PharaohLiquidityVault.sol` (817 lines, sha256 `fb951b92...`, see `avalanche-vault-source-references.md`), which I read myself with the Read tool.

## 0. Summary

* **The earlier F-IK-2 report is confirmed in its totals, to the ppm, by an independent replay** (own helpers, own ledger, own decomposition): incumbent change USDC -141 / -140 / -71 ppm and WAVAX -2,215 / -2,045 / -1,130 ppm at deposits of 1% / 10% / 100% (earlier: -141 / -140 / -71 and -2,216 / -2,046 / -1,131), round trips +1,364 / +24 ppm (USDC 10% / 100%) and +19,237 / +974 ppm (WAVAX), seed-only round trips -53 / -52 and -391 / -133 / -103 ppm, 5-cycle sequences identical to the ppm, ledger residual 0 in every deposit.
* **One correction of substance:** the earlier *partition* of the transfer into a "haircut term" and a tiny "valuation term" is not reproduced. The sum is, the split depends on how the contribution K is defined (section 2.4). Both parts vanish when the haircut is removed from the mint NAV, so the cause is confirmed and strengthened.
* **Two things the earlier report did not measure:** (a) when the spot tick differs from the TWAP tick (the state a deposit leaves behind before an arbitrage restores the price) the sign of the transfer can flip: Pharaoh USDC vault, 100% deposit, incumbent **+25 ppm** unrestored against **-71 ppm** restored; (b) "cycling saturates" is true only while nothing replenishes the idle paired token; with a stream of idle paired token the transfer is re-armed every cycle and the extractor captures about **h/2 of every unit of idle paired token that arrives** (model: 5.1 to 5.8 thousand ppm of the inflow against h/2 = 5,000 ppm on the USDC vault; 15.3 to 17.5 thousand against 15,000 on the WAVAX vault), which is what makes a reserve drain (section 5).
* **Recommended remedy: R3 = R1 + R2.** R1 mints on the **ownership NAV** (same position split as `totalAssets`, no haircut); R2 deploys the new asset in the **vault's own composition** (swap `x = D * P0 / H0`, never sell incumbents' idle paired token). `totalAssets()`, collateral value, `maxDeposit`, `redeem`/`withdraw` and all ERC-4626 views stay on the haircut. R1 alone is not enough when the oracle/pool basis is large, as it is at the WAVAX pin (round trip +260 ppm of D in the model); R2 alone leaves a second-order residual that is not rounding. In the model R1 and R3 keep every incumbent inside a rounding-only bound over a 144-state grid per vault and 5 operation sequences (0 violations), the current rule fails the same sets (138 and 144 of 144 grid cases; 29 to 84 violating (holder, operation) pairs per sequence set), two mutations of R1 are caught, and under a steady inflow of idle paired token a reserve is never drawn by R1/R3 (cumulative incumbent loss 3 to 19 raw units against rounding bounds of 75,600 to 112,353) while the current rule drains it.
* **A reserve must not be funded before the mint rule is fixed:** under the current rule a reserve paying incumbents' loss is drained again and again (0.1% of vault value after 17 to 339 cycles on the USDC vault and 4 to 72 on the WAVAX vault, depending on the inflow of idle paired token; section 5).
* **Open decisions** (section 7): the deployed cash `redeem` pays the haircut NAV and is an **exit fee in favour of the stayers** (asserted identity), not a neutral operation; whether to keep it or settle cash exits at the realised value; the deposit-side ERC-4626 views; spot versus TWAP valuation for the ownership NAV; migration route.

## 1. Part 1(a): the arithmetic, from the source

Notation: asset units of the deposited asset throughout. `q(p)` = `priceOracle.quotePairToAsset(p)` (V:217). `h` = `valuationHaircutBps / 1e4` (3% WAVAX vault, 1% USDC vault at the pins). `S` = `totalSupply()`.

**Valuation, V:210-220 and 222-239.** `totalAssets() = A + floor(q(P) * (1e4 - hBps) / 1e4)` where `A` = idle asset + principal asset and `P` = idle paired + principal paired. The principal is `getAmountsForLiquidity` at the **TWAP-checked tick** (`_checkPrice`, V:454-475), not the spot tick. Uncollected fees and reward tokens are excluded. If `P = 0` the result is `A` (V:215).

**Deposit, V:277-292 and 382-407.** `deposit` first calls `_collectFees()` (V:285), so fees accrued before the call are **inside** `valueBefore`; the exclusion of uncollected fees in `totalAssets` therefore does not leak value at a deposit (it affects the `previewDeposit` view only). `_executeDeposit`: `valueBefore = totalAssets()`; the asset is pulled; `_deployIdle()` runs `_balanceIdle()` then `_addLiquidity()`; `valueAfter = totalAssets()`; `netContribution = valueAfter - valueBefore`; **`shares = mulDiv(netContribution, supply + 1, valueBefore + 1)`** (floor, V:401). The `+1` terms are the ERC-4626 virtual offsets (decimals offset 0).

**Deployment, V:494-515 and 517-581.** `_balanceIdle` compares the asset balance with `q(paired balance)` for **all idle tokens, including incumbents' idle paired token**. If the asset balance exceeds the paired value by more than 1 it swaps `(assetBalance - pairValue)/2` of asset into paired. If the paired value exceeds the asset balance by more than 1 it swaps `(pairValue - assetBalance)/2` of **paired value (the incumbents' idle paired token) into asset**. `_addLiquidity` deploys at the position's own ratio (`getLiquidityForAmounts`, mint or `increaseLiquidity`); whatever does not fit stays idle. Both swaps execute at the pool price, with fee and price impact.

**In-kind exit, V:353-380 and 583-604.** `redeemInKind` calls `_collectFees()` (V:364); idle claims are `mulDiv(balance, shares, supply)` (floor, V:367-368); the liquidity removed is `floor(L * shares / supply)` (V:591-592, `Rounding.Floor` passed at V:372, whole liquidity when `shares == supply`), paid at the **spot** price of the pool by `decreaseLiquidity`. Real tokens, no haircut, no oracle. The cash `redeem` (V:318-346) uses `Rounding.Ceil` for the liquidity and pays `convertToAssets` = `floor(shares * (V + 1) / (S + 1))` at the **haircut** NAV.

**Derivation of the transfer.** Let `H` be the oracle value of the vault's real holdings (idle + principal at spot + collected fees), `P` the oracle value of their paired part, `V = H - hP` the haircut NAV (TWAP principal replaced by spot for the moment). A deposit adds the contribution `K` of oracle value `Hk = H1 - H0` with paired part `kP = P1 - P0` (**signed**: negative when `_balanceIdle` sold incumbents' idle paired token). Ignoring floors and the `+1` offsets the newcomer receives the fraction `f = (V1 - V0)/V1` of the supply, because `S + m = S * V1/V0`. In kind he is paid `f * H1`. Therefore

`T = f H1 - Hk = [H1 (Hk - h kP) - Hk (H1 - h P1)] / (H1 - h P1) = h (Hk P1 - kP H1) / (H1 - h P1)`

(`h` as a fraction; with `h` in bp: `h (Hk P1 - kP H1) / (1e4 H1 - h P1)`). This is the earlier closed form. It is zero exactly when `kP/Hk = P1/H1` (the contribution has the vault's composition), positive when the contribution is less paired than the vault, negative when more paired. By the value ledger the other holders lose exactly `T` (their entitlements plus the newcomer's sum to `Hk`). Mints and claims add floors (<1 share, <a few units, section 3.3) and the `+1` offsets add `a (S0 - N0)/(N0 (N0 + 1))` shares, both bounded in the tests.

**Verified exactly, with no rounding:** `exact_check.py` (Python `fractions.Fraction`) draws 20,000 random states (vault 500 to 5e6, paired share 0 to 90%, `h` in {1%, 3%, 10%, 20%}, contribution 0.01% to 300% of the vault, contribution composition independent of the vault's and often negative) and asserts that the transfer of the current rule **equals** the closed form as a rational identity, that R1's transfer is **exactly 0**, and that R2's residual is exactly `h * costVal * A0 / (H1 - h P1)` (section 3.2). 5,011 of the states had `T < 0` (incumbent gains). In the sell regime (deposit `D` smaller than the idle paired value `I`, the vault sells `y = (I - D)/2` of incumbents' paired token) the exact `T` is `1.01` to `1.13` times `h y` (log lines in `attempt09-python-exact-check.txt`), the excess being the `H1 - h P1` denominator.

## 2. Part 1(b): independent fork replay

### 2.1 What is independent

`AvalancheVaultShareCheckFork.t.sol` imports nothing from `TrackAVaultsBase` or the earlier suite; interfaces, funding (`deal`, BENQI `submit()` for sAVAX), the holdings read, the ledger and the decomposition are new. Method: every entitlement is what a **replayed `redeemInKind`** pays inside a reverted snapshot; the vault's holdings `H` (idle + principal + uncollected fees) are the sum of the three holders' replayed claims (the last claim takes the remainder; the three must own the whole supply, asserted). Value is the vault's own oracle. `V0` is read after a vault-impersonated `collect`, i.e. exactly what `deposit` sees. The **scenario is deliberately the same** as the earlier report (incumbent Alice USD 2,000 USDC resp. USD 10,000 = 1,169.36 WAVAX in one deposit, then Bob; pins 99216397 and 99216312; identical share counts 1,988,444,134 and 1.1434e21 prove the same state), so that totals can be compared. What is independent is the code and the new measurements (unrestored tick, mint-floor and redeem-floor parts). The pool-side split ("other LPs") is still a derived remainder (pool balance minus the vault's position and fees minus protocol fees); the zero ledger residual proves that no listed account kept anything, not the split inside the pool.

Ledger, every deposit run: accounts Alice, Bob, Safe (seed), vault idle, pool (total), router, position manager, factory fee collector, gauge, voter; **sum of changes 0 for both tokens (asserted)**; router and position manager unchanged (asserted). Local-VM only: `vm.prank` of the Safe lifts the deposit cap, `deal`/`submit()` fund actors and the arbitrage whale; no key, no signing, no broadcast.

Asserted per deposit (exact identities and rounding-derived bounds only, no ppm threshold): (1) minted shares equal `floor((V1 - V0)(S0 + 1)/(V0 + 1))` to the share; (2) the four parts of the decomposition sum to `T` exactly; (3) value ledger: incumbents' changes plus the newcomer's entitlement equal `K` within 3 replayed claims' floors (bound `fl = 4 + 4 ceil(q) + 2 ceil(H/L)` per claim, derivation at `_flBound`); (4) the mint floor loses at most one share, the redeem floors at most `fl`; (5) the closed form equals the exact haircut part to the effect of the `+1` offsets and floors. Observed: mint floor 0 or -1 unit, redeem floors 0 to -2 units (USDC) and 0 to -2 wei (WAVAX).

### 2.2 Deposit results (pins 99216397 and 99216312; attempts 16 and 17)

"Restored" = after Alice's deposit an arbitrageur moves the real pool back to the pre-deposit tick with one real router swap (the state the earlier report's `_buildPosition` leaves; spot = TWAP). "As left" = no arbitrage (spot 3 to 5 ticks above the TWAP). Incumbent = Alice, ppm of her in-kind value; the Safe seed moves by the same ppm. `T` = newcomer's entitlement value minus the oracle value of his contribution `K`, ppm of `D`. Earlier numbers in brackets (earlier report, section 4).

| Case | Pharaoh USDC vault (USDC/USDt): incumbent ppm / T ppm of D | Pharaoh WAVAX vault (sAVAX/WAVAX): incumbent ppm / T ppm of D |
| --- | --- | --- |
| 1%, restored | -141 / +14,397 (earlier -141 / +14,416) | -2,215 / +222,011 (-2,216 / +222,094) |
| 10%, restored | -140 / +1,429 (-140 / +1,427) | -2,045 / +20,495 (-2,046 / +20,498) |
| 100%, restored | -71 / +72 (-71 / +74) | -1,130 / +1,133 (-1,131 / +1,129) |
| 1%, as left | -134 / +13,649 | -2,199 / +220,406 |
| 10%, as left | -108 / +1,096 | -2,020 / +20,251 |
| 100%, as left | **+25 / -25** (sign flips) | -1,067 / +1,069 |
| mutation `valuationHaircutBps = 0`, 100% restored | +1 / -1 (earlier -71 to +1) | -4 / +4 (-1,131 to -4) |
| mutation, 100% as left | +8 / -8 | -3 / +3 |
| mutation, 10% as left | +4 / -43 | 0 / +5 |

### 2.3 Round trips and cycling (net of real execution, real router)

Round trip = deposit, `redeemInKind` of all shares, sell the paired leg through the real router; asserted identity `net = (entitlement - D) + (sale proceeds - oracle value of the leg)` and that the paired leg is fully sold. Net P&L, ppm of D.

| | Pharaoh USDC vault | Pharaoh WAVAX vault |
| --- | --- | --- |
| 10%, restored | **+1,364** (earlier +1,364) | **+19,237** (+19,237) |
| 100%, restored | **+24** (+24) | **+974** (+974) |
| 10% / 100%, as left | +1,129 / -66 | +19,347 / +934 |
| live seed-only state, USD 100 / 1,000 / 10,000 | -53 / -52 / not run (a USD 10,000 deposit into the seed-only USDC vault reverts with "Too little received", vault behaviour; attempt 06 keeps the failed run) | -391 / -133 / -103 (identical to the earlier report) |
| 5 cycles, 10%, restored: attacker cumulative ppm of D | 1,364, 1,312, 1,262, 1,212, 1,162 (identical); Alice -140, -139, -138, -138, -138 | 19,237, 21,569, 21,783, 21,733, 21,651 (identical); Alice -2,044, -2,300, -2,331, -2,335, -2,336 (earlier -2,045, -2,301, -2,333, -2,337, -2,337) |
| same 5 cycles (restored), haircut mutated to 0 | -63, -112, -162, -212, -262; Alice 0 to +2 | -1,244 to -1,750; Alice 0 to +1 |
| 5 cycles, 100%, as left (new) | -66 to -258; Alice **+18 to +22** | +934, +919, +833, +742, +650; Alice -1,063 to -1,148 |

The gain exists only because the incumbent's deposit left idle paired token in the vault (seed-only: losses). It is not extracted from an oracle/pool basis: with the haircut at 0 the same loop loses money every cycle.

### 2.4 Decomposition, and why the earlier split is not reproduced

The telescoping parts (exact in the tests): `T = [haircut part] + [TWAP-vs-spot valuation] + [mint floor] + [redeem floors]`, where the haircut part is the rational-mint transfer of the spot-consistent haircut NAV (equals the closed form: |difference| <= 1 unit USDC, 0 wei WAVAX in all cases), and the valuation part is the difference between the vault's own TWAP-based `V` and that spot NAV.

| | Mine (K = holdings after - holdings before) | Earlier (K net of an external-trade control) |
| --- | --- | --- |
| USDC 100% restored | haircut +521,109, valuation -375,219, floors -2, T +145,888 | haircut +154,291, valuation -4,880, T about +148,000 |
| WAVAX 100% restored | haircut +1.4273e18, valuation -1.0220e17, T +1.3251e18 | haircut +1.3272e18, valuation -6.85e15 |
| USDC 100%, as left | haircut +326,492, valuation -378,412, T -51,919 | not measured |

Totals agree; the partition does not. The difference is a definition: in my K the vault's own LP position has shifted composition because the deployment swap moved the pool price (the vault is a counterparty of its own swap: in the USDC case 36.5e6 paired units, K paired share 467,448 ppm against 485,700 ppm in the earlier K), and the haircut term is linear in the paired part of K (`d T / d kP = -h H1/(H1 - h P1)`): 1% of 36.5e6 is 365k, the difference between 521,109 and 154,291 (366,818). That composition shift is invisible to a TWAP-valued NAV, which is why my "valuation" term is large; it is haircut-driven (it falls to -2,874 for USDC and +5.3e15 for WAVAX when the haircut is set to 0). So the earlier text "the haircut term accounts for 1,327e15 of the 1,320e15 transfer, the valuation term is -6.85e15" is a statement about their definition of K, not an independent oracle effect. **Verdict: cause CONFIRMED and strengthened (both channels vanish at h = 0); numerical split CONFIRMED WITH CORRECTIONS (attribution depends on K).**

### 2.5 Verdicts on the earlier headline claims

| Claim | Verdict | Evidence (mine next to theirs) |
| --- | --- | --- |
| Cause: mint on haircut NAV delta versus real, unhaircut in-kind payout | **CONFIRMED** (strengthened: closed form is an exact identity, minted shares reproduced to the share, both parts vanish at h = 0) | sections 1, 2.2, 2.4; `exact_check.py` |
| Split into haircut term and small valuation term | **CONFIRMED WITH CORRECTIONS** | section 2.4: same total, different partition; basis-dependent |
| Sign can be either | **CONFIRMED** | as-left USDC 100%: incumbent +25 ppm, restored -71 ppm in the same vault and size; earlier cap-size case negative; model: 99 of 144 USDC-grid and WAVAX-grid cases each have `T < 0` or a negative swap cost (log of test_00) |
| Magnitude about `h` times swapped paired value | **CONFIRMED WITH CORRECTIONS** | exact in the sell regime (`T = 1.01 to 1.13 h y`, `y` = paired value sold); in the buy regime the driver is the composition mismatch `h abs(Hk P1 - kP H1) / (H1 - h P1)`, not the swapped value (USDC 100%: swapped paired value about 971e6, `h` times it 9.7e6, actual `T` 0.146e6) |
| Round-trip gain after execution costs | **CONFIRMED, conditional** | reproduced to the ppm (section 2.3); requires the idle paired stock created by an earlier deposit; seed-only state loses (reproduced) |
| Cycling saturates | **CONFIRMED without replenishment; REFUTED as a general statement** | fork 5-cycle sequences identical; model with no inflow flat after the first cycles (USDC 753 ppm of vault after 10 and after 60 cycles; WAVAX 2,284 and 2,284); model with a steady inflow of idle paired token drains at about h/2 of the inflow indefinitely (section 5) |
| Mutation control (haircut 0 removes the transfer) | **CONFIRMED WITH CORRECTIONS** | incumbent +1 / -4 ppm at 100% restored (earlier +1 / -4); a residual of 1 to 8 ppm remains and is TWAP-vs-spot valuation of the position plus the pool's effect on the vault's position; larger gap, larger residual (as left USDC 100%: +8 ppm) |
| Ledger sums to 0 | **CONFIRMED** (same limitation: pool-internal split derived) | 18 deposit runs, 10 accounts, both tokens |
| Rounding term is 0 | **CONFIRMED** | mint floor 0 or -1 unit; redeem floors 0 to -2 units |
| "Exits are pro rata (<= 1 wei)" | **not replayed on the fork**; model: other holders move by at most `3 fl` per in-kind exit (0 violations, all sequences) | section 4 |

## 3. Part 2: candidate remedies

### 3.1 Principle

Keep two valuations with two jobs. **Ownership** (how many shares a deposit mints, what a share redeems in kind): a single consistent basis, the oracle value of the real token vector, `N = A + q(P)`, same position split as `totalAssets`, **no haircut**. **Conservative** (collateral value, cash-exit gating, caps, views): `totalAssets()` with the haircut, unchanged. The transfer exists because the mint used the conservative basis while in-kind redemption pays the ownership basis; a share count can match only one price, so the mint must use the redemption's.

### 3.2 Candidates (model rules in `VaultShareModel.Rule`)

* **R1, ownership-NAV mint.** `valueBefore/After := N`, `shares = floor((N1 - N0)(S + 1)/(N0 + 1))` (V:389-401). Then `f = (N1 - N0)/N1`, the newcomer's in-kind value is `f H1 = Hk` (N = H), so `T = 0` and each incumbent's value is `s H1/(S + m) = s H0/S` up to rounding. Deployment unchanged. Costs of the deployment swaps (fee, impact, oracle/pool basis) reduce `N1 - N0` and are therefore borne by the newcomer, as intended.
* **R2, proportional deployment (keep the haircut mint).** The new asset `D` is swapped in the vault's own composition: `x = floor(D * P0 / H0)` of asset into paired (oracle values, `P0/H0` the paired share of the real holdings before the deposit), nothing else is sold; incumbents' idle paired token is never touched; the rest is added at the position ratio. Then `K` has the vault's composition up to the cost `c` of the swap: with `costVal = c x`, `Hk = D - costVal`, `kP = x - costVal`, and exactly `T = h * costVal * A0 / (1e4 H1 - h P1)` (`A0 = H0 - P0`; verified as a rational identity in `exact_check.py` and to rounding in the model, test_03). It is zero for a cost-free swap and **second order** otherwise (WAVAX: up to 12 ppm of D over the grid; USDC: 0 ppm), but it is **not rounding**, so the R2 tests assert the closed form, not the rounding bound, and R2 fails the rounding-only protection bound in 6 to 18 (holder, operation) pairs per sequence set on the USDC vault and 42 to 84 on the WAVAX vault (printed). The sign of the residual is the sign of `costVal`, i.e. of the oracle/pool basis net of fee and impact.
* **R3 = R1 + R2.** Mint on N, deploy proportionally.
* **Mutations of R1 (must fail the tests):** `MUT_ASYM_NET` charges `h` on the paired leg the newcomer adds but not on the vault's holdings (the asymmetric haircut reintroduced); `MUT_DENOM_HAIRCUT` takes the net contribution on N and the denominator on the haircut NAV.
* **Not modelled (the task's alternative R2 forms):** haircut mint with a symmetrical haircut charged at in-kind exit (`redeemInKind` returns `(1 - h)` of the paired leg and the vault keeps `h P_slice`). Objection: pro-rata in-kind exits already keep the haircut NAV per share constant, so the asymmetry is at the mint only; charging at exit turns every in-kind exit into an exit fee that accrues to whoever exits last (the last exiter cannot be paid more than the vault holds, so `h P` is stranded unless he is paid out of a reserve), and it weakens the permissionless liveness escape hatch. Settling the difference "in kind" by burning or minting shares after the fact equals R1 (same shares) with a more complicated code path. A vector-proportional mint (`S min(Ka/Ha, Kp/Hp)`) cannot be used: a swap-based deposit never has the vault's composition, the unmatched part would be donated.

### 3.3 Bounds used in the model tests (rounding only, derived)

* Claim floors `fl = 4 + 4 ceil(q) + 2 ceil(posValue/L) + 2` asset units (idle floors, liquidity floor, amount floors, quote floor), `_flBound`.
* One deposit, mint basis `N0 -> N1`, `S0 -> S1`, `a = N1 - N0`, holder with `s` shares: `|change| <= 2 fl + [ s a |S0 - N0| / (S1 (N0 + 1) S0) ] + [ s N0 /(S1 S0) ] + 1`; the first bracket is the `+1` offsets, the second the mint floor (< 1 share), `_depBound`. Observed worst |change| / bound is 7.4% (USDC) and 7.7% (WAVAX).
* Pure in-kind exit or realised cash exit: other holders move by at most `3 fl`.
* Newcomer transfer against the continuous closed form: `2 fl + (H1/S1 + 1)(a |N0 - S0|/N0^2 + 2) + 1`.
Nothing is tuned; the thresholds are functions of the state.

### 3.4 What the remedy does to everything else

| Item | R1 / R3 | Note |
| --- | --- | --- |
| `totalAssets()` and `convertToAssets` | **unchanged, haircut** | lending/collateral value stays conservative |
| `maxDeposit`, `depositCap` check (V:246-251, 391) | unchanged, haircut basis | the cap binds a little later (the added shares' haircut NAV rises by less than the assets) |
| cash `redeem`/`withdraw`/`maxWithdraw`/`maxRedeem`, `rebalance` loss guard (V:434) | unchanged | see the exit-fee finding in section 4.3 |
| `redeemInKind` | unchanged | pro rata of the real vector |
| mint rate | new shares are priced at `N0/S` instead of `V0/S`: higher by `N0/V0 = 1/(1 - h pf)`, `pf` the paired share of value: about **1.005 (USDC, pf 0.52, h 1%) and 1.015 (WAVAX, pf 0.50, h 3%)** | existing holders: no change of share count, `totalAssets`, or `convertToAssets` |
| `previewDeposit` (V:273) and `convertToShares` | **inconsistent with the actual mint unless overridden**: they use the haircut basis, the mint would use N (about 0.5% / 1.5% fewer shares). EIP-4626 wants `previewDeposit` not above the actual shares: the deposit-side previews must move to N | open decision (section 7); the `minimumShares` check in `deposit` (V:290-291) uses `_applyEntryLoss` = `2 slippage + h` (>= 3% on both vaults per the logs) so the gap does not trip it spuriously, to be re-checked when specified |
| fees | the vault charges none (no fee code in the source) | nothing to migrate |
| storage | none new (a view/function change in the base; R2 adds a swap-size formula) | the base is immutable and its code hash is pinned in the extension constructor (`PharaohRewardExtension` lines 27-46), so a base change means a new base plus a new extension |

### 3.5 Share-price continuity and migration

Only the Safe's seed exists in both deployed vaults, so switching the mint basis moves value between nobody: the first outside depositor simply pays the ownership price. If, later, several holders exist, an upgrade or redeploy must pick a block at which all accept that new deposits mint on N (existing holders are unaffected by the switch itself; the only risk is a deposit in flight). Routes: (i) deploy a replacement base and extension and `upgradeAndCall` through the ProxyAdmin (owner: the 1-of-1 Safe; **no timelock**, four upgrades in 12 days so far) while the vault holds only the seed; (ii) a new vault with the seed redeemed in kind and re-deposited. Nothing is deployable here: no Solidity for the vault was written, the model is a test contract.

## 4. Prototype results (`AvalancheVaultSharePricingPrototype`, 22 tests, no RPC; attempt 18)

Model assumptions, stated: static position ratio (no price moves, no impermanent loss), linear price impact `valueIn/depth`, pool fee and a signed oracle/pool basis `beta` (USDC vault pool 126 ppm below the oracle, WAVAX vault 1,714 ppm below), idle paired inflow exogenous, vault of 1,000 whole asset units with three incumbents (Safe seed 3%, Alice 47%, Carol 50%). Pools: fee 50 / 100 ppm, haircut 1% / 3%. The model reproduces the vault's integer arithmetic (OZ `mulDiv`, floors, `+1` offsets, both `_balanceIdle` branches, `_addLiquidity` at the position ratio, pro-rata in-kind claims). `test_00`: the CURRENT-rule model equals the closed form within the derived tolerance in all 144 grid cases of each vault (max difference 5 raw units).

### 4.1 (i) incumbent protection: grid, orderings, more than two holders

Grid per vault: idle paired 0 / 3 / 15 / 50% of value x position paired share 30 / 50 / 70% x deposit 1 / 10 / 100 / 300% x share price 1.00 / 0.97 / 1.03 = 144 states, incumbents SEED, ALICE, CAROL.

| Rule | Pharaoh USDC vault (USDC/USDt, deposited USDC): violations of the rounding bound | Pharaoh WAVAX vault (sAVAX/WAVAX, deposited WAVAX) | Max abs(T)/D |
| --- | --- | --- | --- |
| CURRENT | **138 of 144** (max incumbent loss 3,267 ppm) | **144 of 144** (9,899 ppm) | 252,476 / 765,932 ppm |
| R1 | **0** | **0** | 0 ppm |
| R3 | **0** | **0** | 0 ppm |
| R2 (own closed form, test_03) | 48-state subgrid: closed form holds | same | 0 / 12 ppm |
| MUT_ASYM_NET | 99 caught | 99 caught | |
| MUT_DENOM_HAIRCUT | 144 caught | 144 caught | |

The 6 USDC grid states that the current rule passes were not inspected one by one; they are expected where the closed form is about zero. Sequences (5 holders SEED, ALICE, CAROL, BOB, DAVE; after each operation every non-actor holder is checked; run at 6 inventory states each): small-then-large with exits in the middle, large-then-small, interleaved partial exits, mixed in-kind/realised-cash exits, and **replenishment** (third-party donations of idle paired token, keeper `deployIdle`, more deposits and exits). R1 and R3: **0 violations** over 30 to 54 operations per sequence set (6 inventory states each); CURRENT: 29 to 72 (USDC) and 42 to 84 (WAVAX) violating (holder, operation) pairs per sequence set; R2: 6 to 18 (USDC) and 42 to 84 (WAVAX). The keeper `deployIdle` operation and donations are applied but not bound-checked (they change nobody's share count; every holder's value moves pro rata by construction); this is not asserted.

### 4.2 (ii) round trips, (iv) replenishment, (v) conservation

Round trip (deposit, in-kind exit, sell the paired leg in the modelled pool), best case over a 48-state grid, ppm of D:

| | no oracle/pool basis (`beta` = 0) | with the pinned basis |
| --- | --- | --- |
| USDC vault: R1 / R3 / CURRENT | -29 / -30 / **+251,158** | -15 / -30 / +247,959 |
| WAVAX vault: R1 / R3 / CURRENT | -62 / -59 / **+763,150** | **R1 +260** / R3 -59 / +718,643 |

With no basis R1 and R3 never exceed rounding (asserted for all 48 states) and the current rule is profitable. **With the WAVAX pin's basis R1 alone has a positive round trip (+260 ppm of D)**: during deployment the newcomer buys paired token below the oracle, K is credited at the oracle, in kind he is returned the vault's vector (less paired than he bought) and keeps part of the basis gain by selling the rest back to the vault at the oracle price. This is oracle/pool market exposure (it changes sign with `beta`), not the haircut defect, and no share-pricing rule over a single oracle removes it, but R2's proportional deployment makes his paired leg match what he bought and cancels it (R3 -59). This is the reason R3 and not R1 is recommended. Whether sAVAX can in fact be redeemed at the oracle rate was not tested.

(iv) Replenishment: sequence 4 and the cycling runs above add idle paired token between operations; R1/R3 show 0 violations; (v) conservation: the token ledger (wallets + idle + position + signed pool net = issued) is asserted to be exactly 0 for both tokens after **every** operation of every sequence, grid case and a 256-run fuzz over random operation sequences on all four rules.

### 4.3 (iii) mixed cash and in-kind exits: a finding, not "zero"

The deployed cash `redeem` pays `floor(shares (V + 1)/(S + 1))` at the **haircut** NAV, takes the liquidity slice into idle, and sells whatever idle paired token is needed. Exact asserted identity (12 operations per vault): the sum of the stayers' changes (including the exiter's retained shares) equals `entitlement of the exited shares - cash paid - swap cost`. The first difference is `h` times the paired part of the slice: **a cash exit at the haircut basis is an exit fee in favour of the remaining holders**, never a gain for the exiter. It is not neutral and it is not removed by R1/R3. Alternative (R-CASH in the model, `CashMode.REALIZED`): pay the exiter his own pro-rata slice with his paired leg sold at his own cost, the haircut NAV serving only as a minimum (revert if the proceeds fall below it; ERC-4626 permits paying at least the preview). That moves nothing to or from the others beyond rounding (asserted in sequence 3: 0 violations). Which of the two is intended is the owner's decision.

### 4.4 Residual that R1/R3 do not remove: valuation tick versus spot

`totalAssets` values the position at the TWAP tick; in-kind pays at spot. In the model this is exact: with a valuation skew the transfer equals `H1 (Nv1 - Nv0)/Nv1 - Hk` (test_06; the skew size and the 10 bp pool/oracle gap are illustrative constants, not measured). On the fork (haircut mutated to 0, which is R1's mint without the other changes) the residual is **+1 ppm (USDC, restored) to +8 ppm (USDC 100%, tick 3 above the TWAP) and -4 to -3 ppm (WAVAX)** for the incumbent, up to -43 ppm of D for a 10% newcomer. R1 on the TWAP split leaves this; valuing N at spot would remove it but moves the manipulation question to spot (not evaluated; `_checkPrice` bounds spot to the TWAP band).

## 5. Part 3: a reserve must not subsidise a repeatable accounting defect

Setting (labels as required): **Pharaoh USDC vault**: pair USDC/USDt, deposited asset USDC, protection benchmark = holding USDC, h = 1%. **Pharaoh WAVAX vault**: pair sAVAX/WAVAX, deposited asset WAVAX, benchmark = holding WAVAX, h = 3%. A reserve pays the incumbents' loss relative to the benchmark; in the model the measured loss of the incumbents (value in kind, market static) is exactly what the reserve would pay. The cycling newcomer stakes 1% of the current vault value per cycle (deposit, in-kind exit, sell the paired leg through the pool); between cycles other flows (collected fees, other depositors' residue, keeper activity) add idle paired token worth `rho` of the starting vault value per cycle (assumption: exogenous). WAVAX/USDC (AVAX/stablecoin) exposure is not part of any number here.

**Cycles until the cumulative incumbent loss reaches a reserve of X of the starting vault value (CURRENT rule; simulated cycle by cycle up to 400; `>400` = not reached; `~` = linear extrapolation at the measured capture rate)**

| Vault | Inflow of idle paired token per cycle | 0.1% | 0.5% | 1% | 2% | 5% | Loss per unit of inflow |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Pharaoh USDC vault | 0.05% | 339 | ~1,730 | ~3,460 | ~6,920 | ~17,300 | 5,773 ppm (h/2 = 5,000) |
| | 0.2% | 85 | ~480 | ~960 | ~1,920 | ~4,800 | 5,212 ppm |
| | 1% | 17 | 97 | 197 | 396 | ~990 | 5,062 ppm |
| Pharaoh WAVAX vault | 0.05% | 72 | ~571 | ~1,142 | ~2,283 | ~5,708 | 17,511 ppm (h/2 = 15,000) |
| | 0.2% | 18 | 150 | 314 | ~633 | ~1,582 | 15,799 ppm |
| | 1% | 4 | 30 | 63 | 129 | 326 | 15,342 ppm |

Reading: every unit of idle paired token that arrives is skimmed at about **h/2** (0.5% resp. 1.5%) by a depositor who cycles once per arrival; the reserve is paid the incumbents' loss whether or not the attacker profits (the attacker's net over 400 cycles is positive in the model: +9% to +569% of his stake depending on the inflow and vault), so it subsidises the defect for as long as idle paired token keeps arriving. Without any inflow the current rule saturates (USDC 753 ppm of vault value after 10 cycles and after 60; WAVAX 2,284 ppm and 2,284 ppm), which is the earlier report's observation.

**R1 and R3, same runs (400 cycles):** cumulative incumbent loss 3 to 19 raw units (0.000003 to 0.000019 USDC; 3 to 19e-18 WAVAX) against summed rounding bounds of 75,600 to 112,353; the 0.1% reserve is never reached; the cycling depositor loses in every run (USDC R1 -23,147 to -75,560 ppm of stake, R3 -24,779 to -100,702; WAVAX R1 -62,718 to -447,319, R3 -49,252 to -209,792). Under the remedy there is no repeatable transfer for a reserve to absorb; it would only meet genuine market loss. Fork-side, this is shown only through the haircut-0 mutation (5 cycles, both vaults, loss every cycle, incumbent within 0 to +3 ppm), not through a patched vault.

## 6. Recommendation and scope of change

1. **Adopt R3** in a future vault version: (a) ownership NAV `N` for the mint and for the deposit-side previews; (b) proportional deployment of the new asset. Keep `totalAssets`, `maxDeposit`, `redeem`/`withdraw`, `rebalance` guard and every view on the haircut.
2. If only the smallest change is wanted: R1 (a single function change in the base). Accept the basis term (proportional to `|beta|` and to the vault's pair) and do not describe the deposit as free of basis risk.
3. R2 alone is the least invasive change to share math (none), but it is not rounding-only; use it only together with R1.
4. Do **not** remove the haircut everywhere (the fork mutation does that and shows the transfer disappears, but it also removes the conservative collateral and cash-exit valuation).
5. Fund no protection reserve against deposit/entry losses before the mint rule is fixed (section 5); after the fix a reserve addresses market loss only, which is the remaining item of the earlier proposal.
6. The base is immutable and pinned by the extension; the change is a new base plus a new extension. A fresh audit and an isolated-cache reproduction on fork of the *patched* code are required before any deployment; none of this is authorised here.

## 7. Open decisions

1. Cash exits: keep the haircut-basis `redeem` (an exit fee, section 4.3) or settle at the realised value with the haircut NAV as the guard.
2. Deposit-side views: override `previewDeposit`/`convertToShares` to the ownership basis (recommended) or accept that they under-state the shares by 0.5% / 1.5%.
3. Valuation tick for `N`: TWAP (as `totalAssets`) or spot (section 4.4).
4. Migration route and block (section 3.5); no timelock exists on the ProxyAdmin.
5. Whether the keeper's `deployIdle` cadence matters under R3: R3 stops deposits from shrinking an existing idle paired stock (R1-current deployment sold incumbents' idle paired token for small deposits); the stock then falls only by keeper `deployIdle`/`rebalance`.
6. The basis `beta` depends on the oracle (BENQI rate for sAVAX) versus the pool; whether sAVAX can be redeemed at the oracle rate decides how much of R1's basis residual is real.

## 8. What was not tested

Other blocks than the two pins; keeper `rebalance` and `deployIdle` on the fork (model only); the cash `redeem` on the fork (model only); a cap-size (300%) deposit and 1% round trips on the fork (model grid only; the earlier report found `T < 0` at cap size); more than 5 cycles on the fork; any run on the fork with a replenishing inflow; the remedy against deployed bytecode or a patched copy of the vault (model and a haircut-0 mutation only); a cash-exit identity on the fork; sAVAX redemption at the BENQI rate; MEV, front-running, flash loans, price manipulation inside the TWAP band; time-dependent effects (fees accruing, PHAR rewards, oracle moves); the `minimumShares` check under R1/R3; spot-valued ownership NAV. The first USDC test (attempt 06) shows a USD 10,000 deposit into the seed-only USDC vault reverts ("Too little received"); this is vault behaviour, logged, not a result.

## 9. Reproduce

From `contracts/` (zsh), pins as in `avalanche-clean-repro-52/README.md`:

```
FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_remedy FOUNDRY_CACHE_PATH=cache_remedy \
AVALANCHE_MAINNET_RPC_URL=https://api.avax.network/ext/bc/C/rpc TRACKA_PIN_BLOCK=99216397 \
forge test --threads 1 --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol \
  --skip 'test/[!Ap]*' --skip 'test/A[!v]*' --skip 'test/Av[!a]*' --skip 'test/Avalanche[!V]*' \
  --match-contract AvalancheVaultShareCheckUsdcFork -vv --rpc-url https://api.avax.network/ext/bc/C/rpc \
  --compute-units-per-second 20 --fork-retries 10 --fork-retry-backoff 1000
# WAVAX: TRACKA_PIN_BLOCK=99216312, --match-contract AvalancheVaultShareCheckWavaxFork
# model (no RPC): --match-contract AvalancheVaultSharePricingPrototype ; exact twin: python3 -I docs/.../avalanche-vault-remedy-evidence/exact_check.py
```

Results: fork 21 passed per vault (attempts 16, 17); model 22 passed (attempt 18); python exact check OK (attempt 09). Evidence index and the failed attempts: `avalanche-vault-remedy-evidence/README.md`.
