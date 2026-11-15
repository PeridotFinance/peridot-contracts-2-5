# Pharaoh DLMM USDC/USDt vault: second measurement (concentrated 3 or 5 bins) and build plan

Status: research only, 15 Nov 2026. Nothing deployed, signed or broadcast. Rule fixed before any number: `avalanche-pharaoh-dlmm-evidence/v2/DECISION_RULE.md` (local evidence folder, hashes in `avalanche-pharaoh-dlmm-evidence.sha256`). Companion of `avalanche-pharaoh-dlmm-vault-evaluation.md` (the first report; its pin block 100,006,143 and method are unchanged). Four independent jobs: A1 (fees, PHAR, range, rebalances), A2 (independent re-implementation of two cases: medians agree to 0.00 %, worst day 2.7 %; plus PHAR facts), B (adverse selection), C (pUSDC rate, gas). Labels: MEASURED (chain or event data), DERIVED (formula on measured data), ESTIMATED (assumption stated).

## 0. Answer in one paragraph
**Under the rule as written the median passes, for the exit-triggered policy only, and almost all of it is PHAR.** Window: the 30 UTC days 12 Oct to 10 Nov. Position: all value in the active bin +-1 (G1) or +-2 (G2), re-centred 60 s after the active bin leaves it (P1). Net of fees, PHAR at USD 0.04643 (1.1 % sale cost), the NET 1 h markout loss, rebalance gas and the inventory swap at the base fee: **G1/P1 27.4 % a year at V = USD 2,000 and 11.7 % at V = USD 20,000; G2/P1 16.8 % and 10.0 %**, against the pUSDC model supply APY of 8.80 % at 80 % utilisation (rule) and 6.83 % at 70 %, the highest utilisation the pilot's USD 200 borrow cap allows. A daily re-centre (P2) fails at V = 20,000 (5.8 % to 7.2 %). **Without PHAR every executable case loses 1 % to 6 % a year**: fees are 1.6 % to 3.5 % a year, the net markout loss 3 % to 6.4 %. PHAR is 90 % of income, its stream was 20 times larger from epoch 2963 on, and it can be switched off by a 1-of-3 Safe with no timelock. **The absolute prize is small**: about USD 2.3k a year at V = 20,000 (about USD 1.0k above the 6.83 % comparator); at V = 50,000 income saturates and falls below that comparator (5.4 %); against a build of about 30 engineer-days. Recommendation in section 6: validate live before building.

## 1. Where the liquidity is relative to the peg (the geometry question)
MEASURED, 30 days: the active bin was **never within +-2 bins of the peg bin 8,388,608** (median 11 bins below, p1 15, p99 7 below, 77.6 % of the time at 10 or more below; the pool trades at a standing USDt discount of about 0.10 %). A vault centred on the peg earns nothing; the band must follow the active bin, which is why rebalancing is the whole cost question.

## 2. How often the active bin leaves the band, and for how long (MEASURED, A1)
| Reference | Outside +-2 bins | Outside +-1 bin |
| --- | --- | --- |
| Daily centre (P2): share of the window | 11.3 % (101 excursions: median 598 s, p90 10,127 s, max 25,818 s) | 29.8 % (267: 504 / 8,035 / 38,255 s) |
| Static centre (P3, one start) | 29.5 % | 61.9 % (max excursion 324,000 s) |
| Rolling 1 h median bin | 0.22 % (20 excursions: median 45 s, p90 907 s, max 1,795 s) | 1.83 % |
| **Exit-triggered (P1), own range, 60 s reaction** | **0.10 % (G2)**, excursions at most 60 s | **0.28 % (G1)** |
Rebalances in 30 days: G1/P1 141 (median 4 a day, max 32), G2/P1 51 (median 1, max 18), P2 1 a day. B counts 146 and 55 with a slightly different tie convention. Median share of the day in range: G1/P1 0.998, G2/P1 0.999, G1/P2 0.677, G2/P2 0.963.

## 3. Income per USD 1,000 per day, 30 days (DERIVED from replayed events; median [p10, p90])
| Case | LP fees USD | PHAR tokens (x 0.04643 = USD) | NET 1 h markout loss USD | gross markout |
| --- | --- | --- | --- | --- |
| G1/P1, V 2,000 | 0.083 [0.024, 0.135] | 17.4 [3.9, 36.7] (0.81) | 0.135 [0.020, 0.351], max 0.867 | 0.246 |
| G1/P1, V 20,000 | 0.053 [0.018, 0.085] | 9.3 [2.5, 17.9] (0.43) | 0.106 | |
| G2/P1, V 2,000 | 0.053 [0.014, 0.099] | 10.7 [2.4, 23.0] (0.50) | 0.079 [0.012, 0.221], max 0.545 | 0.156 |
| G2/P1, V 20,000 | 0.036 [0.012, 0.060] | 7.2 [1.8, 14.2] (0.33) | 0.067 | |
| G1/P2, V 2,000 | 0.051 [0.021, 0.078] | 8.0 [1.3, 27.1] | 0.086 | 0.165 |
| G2/P2, V 2,000 | 0.042 [0.014, 0.062] | 8.7 [1.0, 21.6] | 0.074 | 0.137 |
V = 1,000, 50,000 and the P3, G0 variants are in `v2/a1/fees_range.json` and `v2/b/adverse.json`. Regression: A1 reproduces the first report's daily +-3 medians (0.9554 / 0.8915 per week at V 1k / 2k) to 1e-13; B reproduces its stored gross and net.

## 4. The 1.84 figure, explained
`L1 = max(USD 0.96, 2 x median gross arbitrage loss)` was a pass line fixed before the first report's numbers: gross 1 h markout loss for the daily +-3 band was 0.92 per USD 1,000 per week, so L1 = 1.84. **Gross sums only the events where the LP lost and ignores the events where it gained**; on a noisy two-sided series that overstates the loss that was actually realised: the favourable events cancel 68 % of gross (40 % to 85 % by epoch). The NET loss for that position was 0.255 a week (0.26), so the line was **too harsh by 0.88 a week (0.126 a day) per USD 1,000**, 7.2 times the realised net. (1.84 is also the mean weekly income at V = 1k, a coincidence.) The right metric is the NET markout beside fees, which is what this report uses. Your intuition holds per event: median loss about 0, 87 % of in-range events within +-1 bp of volume. It does not hold per unit of fee: pool-wide net loss is 0.51 bp of volume against an LP fee of 0.126 bp (about 4 times); for our positions net loss is 3.0 % to 6.4 % a year against fees of 1.6 % to 3.5 %. 72 % of the net is a 0.4 bp one-bin drift on 92.5 % of the volume. Sign depends on the reference: against the Llama price fees do cover the loss; against parity the standing discount makes the number meaningless (re-basing the offset takes G2/P1 parity net from +1.44 to -0.18). Tail: the 30 Oct 11:43 to 12:13 USDt-discount episode cost G1/P1 0.21 and G2/P1 0.03 per USD 1,000 (4 % and 1 % of the 30-day net); worst day 0.87 (G1/P1).

## 5. Decision statistic against the pUSDC supply rate
Comparator (MEASURED, C): the pUSDC market pays **about 0 % today** (borrows 0, USD 274 cash; realised 0.019 % a year since 10 Nov). Model (ConfigurableJumpRateModelV2: base 2 %, multiplier 10 % to the 80 % kink, jump 100 %, reserve factor 10 %): supply APY 1.13 % at 25 %, 3.69 % at 50 %, **6.83 % at 70 %, 8.80 % at 80 %**, 18.99 % at 90 %. The USD 200 borrow cap against about USD 274 deposited limits utilisation to about 73 %, so 80 % is not reachable at pilot size; the owner (the Ledger) can change the curve in one transaction.
Cost side (MEASURED gas, C): withdraw-all plus re-add costs about 702k gas for 3 bins and 917k for 5 bins (p90 822k / 1.06M); baseFee median 2.5 gwei (p90 5.0), AVAX 8.93 USD: **USD 0.022 (3 bins) and 0.029 (5 bins) per rebalance at the median, 0.050 and 0.065 at p90**; with the swap leg and keeper overhead 0.037 and about 0.05. Today's baseFee is 7.5 gwei, about three times the window median (one rebalance about USD 0.044 now).
Net annual %, median [p10, p90], BEFORE the inventory swap, full table in `v2/COMBINED.md` (reproduce: `python3 -I v2/combine.py`):
| Case | V 2,000 | V 20,000 | PHAR 0.03, V 20,000 | No PHAR, V 20,000 |
| --- | --- | --- | --- | --- |
| G1/P1 (gas, PHAR sale cost, net markout) | 28.6 [-0.5, 54.2] | 13.7 [1.7, 28.4] | 7.9 | -1.9 |
| G2/P1 | 18.0 [1.1, 37.5] | 10.4 [1.9, 21.2] | 6.5 | -1.2 |
| G1/P2 | 10.5 | 6.3 | 3.9 | -1.3 |
| G2/P2 | 10.6 | 7.7 | 4.7 | -1.2 |
**With the inventory swap at each re-centre** (not in the rule's cost list; A1 flagged it; fee on about half the value): at the base fee 0.25 bp G1/P1 is **27.4 / 11.7 %**, G2/P1 **16.8 / 10.0 %**; at 2.25 bp (the top of the pool's variable fee) G1/P1 falls to 10.4 / **0.0 %** and G2/P1 to 9.0 / 4.7 %. The fee actually paid at each re-centre is ESTIMATED (volatile moments carry the higher fee) and it decides the V = 20,000 result.
**Verdict against the pre-registered line (median above 8.80 % at V = 2,000 and 20,000, G1 or G2, P1 or P2), with the inventory swap at the base fee: PASS for G1/P1 and G2/P1 at PHAR 0.04643 (27.4 / 11.7 % and 16.8 / 10.0 %). At today's PHAR 0.041: G1/P1 23.6 / 10.0 % passes, G2/P1 14.3 / 8.8 % is on the line. FAIL for any daily policy at V = 20,000; FAIL at PHAR 0.03 and V = 20,000 (G1/P1 7.1 %, G2/P1 6.1 %: G1 still above the 6.83 % comparator); FAIL without PHAR; FAIL at the high swap fee at V = 20,000; at V = 50,000 even the favourable case is 5.4 % to 5.9 %.** Against the live rate (about 0 %) everything with PHAR passes trivially.

## 6. What the pass rests on (UNFAVOURABLE, A1/A2)
- **PHAR is 90 % to 94 % of income.** Per week to this pool in the last 8 epochs: 447, 356, 237, then 4,713, 4,488, 9,649, 5,390, 6,249 (a 20-fold step between epochs 2962 and 2963, no floor in the contracts); the window is the high regime (34 PHAR a day for the first three days, 640 to 1,380 a day after). Epoch 2968 is estimated at about 9,770 PHAR if the votes cast hold. One voter contract holds 70 % to 78 % of all votes and 69 % to 99 % of this pool's votes. PHAR price fell 51 % over the window (0.0888 to 0.0438, today 0.041).
- **Control of the stream and range**: `setDeltaBins` (which bins are rewarded) is `onlyOwner` = Voter, then accessHub, then a **Safe with threshold 1 of 3, no timelock, no event**; the same Safe can kill the gauge and change the Minter multiplier by up to 25 % a week. The first report's R5 (hook, protocol share, rewarder upgrade in one call) is unchanged.
- **Dilution**: PHAR goes only to the active bin, whose liquidity swings from USD 1 to 2 M depending on the two whales (97 % of the pool). Whoever parks size in the active bin dilutes us; at V = 20,000 the ceiling is 29 % to 46 % of the pool's emission, executable shapes get 4 to 6 times less.
- **One regime, 30 days**, including the 30 Oct dislocation; daily means carry 12 % to 18 % standard error; p10 of the daily net is about zero or negative in most cases.
- **P1 as tested** executes the re-centre 60 s after an exit unconditionally; the re-check variant moves the median by under 0.011 a day.
- Not modelled: our own price impact beyond the v/(L+v) share, intra-block ordering, composition shifts when we hold a large share of a shallow bin (B: 6 events with a share of 50 % or more).

## 7. Build plan (the operator's rule is met, so this is the plan; the recommendation is in section 8)
**Scope**: a Pharaoh DLMM vault variant of R3 (ERC-4626 on ownership NAV unchanged), 3-bin band, exit-triggered re-centre by a keeper, reward claim module. Reusable from the first report's section 8 (function table unchanged): new interfaces, NAV over bins, `router.addLiquidity` with `activeIdDesired` and `idSlippage`, proportional per-bin burn, rebalance, `rewarder.claim`. **New for P1 (not in the first estimate):** a block-level exit watcher and rebalance keeper (4 to 5 re-centres a day, inventory swap leg, oracle-deviation halt during a depeg, daily rebalance and loss limits, host and alerts) and vault-side guards for frequent rebalancing (cooldown, per-day cap, max swap, min out).

| Workstream (agent) | Depends on | Engineer-days | Notes |
| --- | --- | --- | --- |
| W1 Interfaces, id/price/distribution helpers, pool validation | none | 1.0 | gates the rest; fixed within the first hours |
| W2 Vault variant: band state, bin NAV, deposit/withdraw/rebalance, guards, in-kind exit | W1 | 7.0 (5.5 + 1.5 new guards) | the core; sequential |
| W3 Reward module (claim ids, PHAR forwarding) | W1 | 1.5 | parallel to W2 |
| W4 Mock LB pair, unit and fuzz tests | W1 (interface) | 3.0 | parallel to W2 |
| W5 Exit-triggered rebalance keeper + host config + alerts | W1, rebalance ABI | 5.0 (3 to 8) | parallel; tested against a stub vault and a fork |
| W6 Mainnet-fork tests (real pair, router, hook, claim, forfeiture, depth, exit scenarios) | W2, W3 | 4.0 | |
| W7 Mutation checks (10 mutants) | W4, W6 | 2.0 | |
| W8 Fork rehearsal of deploy, deposit, rebalance loop, harvest, exit | W5, W6 | 3.0 | |
| W9 Docs and handoff | rolling | 1.5 | |
| W10 Review and audit-scope write-up (fresh agent, then a human) | W7, W8 | 2.5+ | the contract holds user funds: a human read is not optional |
| **Total** | | **about 30 (range 25 to 38)** | first report 24 (20 to 28) plus the keeper and guards |
Critical path: W1 (1) then W2 (7) then W6 (4) then W7 (2) then W8 (3) then W10 (2.5) is about 20 engineer-days; W3, W4, W5, W9 run beside it.
**Realistic wall-clock (ESTIMATED).** With 4 to 5 subagents in parallel and one reviewer: about 6 to 9 working days to a fork-tested, mutation-checked, rehearsed and reviewed package, if the design holds (the order keeper, a comparable build, took one day of agent time). Add your time: one Ledger ceremony for deploy and wiring (half a day), a Safe transaction for the rebalancer role, a 24 h observation at USD 200 before any cap rises. So **about 2 weeks calendar to a live vault at the USD 200 pilot cap**; the largest uncertainty is the keeper (W5) and the guard design under a depeg, not the Solidity.
Cost of the build: 30 engineer-days at the assumed day rates of USD 500 / 1,000 / 1,500 is USD 15k / 30k / 45k (assumption, not data; with agents the cash cost is lower, review time is not). Against about USD 1.0k a year above the 6.83 % comparator at V = 20,000 (USD 0.4k at V = 2,000; negative at V = 50,000, where income saturates), the payback is more than 10 years at any day rate (USD 15k to 45k). At the pilot's USD 200 the vault would earn about USD 55 a year (27.4 %).

## 8. Recommendation
1. **Do not start the vault build yet.** The statistical gate is met, but it is met by an incentive stream that one Safe signer set controls, that was 20 times smaller three epochs earlier and that is 90 % of the result; the build does not pay back on its own income at any realistic size.
2. **If the product value matters (a second vault to show in the app), do W5 first**: the keeper plus a position held by an operator wallet or the Safe, with no new contract, at the USD 200 pilot cap (or USD 2,000 if you widen it), for two weeks. About 4 to 6 engineer-days, all reusable by the vault. It turns every DERIVED figure above into a realised one, tests exit-triggered re-centring and the swap fee actually paid, and shows whether PHAR holds through the 19 Nov vote. Gate for the vault: realised net above the 8.80 % line over the 14 days **and** emission at or above 4,000 PHAR a week.
3. If you decide to build now regardless, the workstreams above start in parallel (W1 first); stop conditions: the fork tests show a depeg guard that cannot be made safe, or the realised swap fee puts V = 20,000 at or below 8.80 %.
