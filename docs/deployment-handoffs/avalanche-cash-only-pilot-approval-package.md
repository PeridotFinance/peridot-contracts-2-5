# Cash-only lending pilot: approval package (one page, consolidation only)

**For a decision; nothing here is approved.** No merge, deployment, parameter change, borrowing activation or treasury commitment follows from it. One direction: borrow USDC against WAVAX. All amounts USD, at the **$5,000 research borrow cap only**. No new scenarios: every figure comes from `avalanche-cash-only-pilot-qualification.md` and the documents it cites. Vault and PHAR work are frozen.

## 1. PW30 and PW40 side by side ($5,000 cap; borrowers at 100% of capacity; 30 days of interest; close factor 50%; incentive 1.08)
| | **PW30** (WAVAX CF 30%) | **PW40** (WAVAX CF 40%) |
|---|---|---|
| Borrower capacity | 30% of collateral value | 40% |
| Zero-bad-debt one-step AVAX fall | -67.3% | -56.4% |
| Worst observed move survived with zero bad debt (30 days: -42.9%) | yes | yes |
| Year peak-to-trough (-67.6%) as one step | about 1% loss (USD 49) | 26% loss (USD 1,299) |
| **Protection capital, tail -60%** (dedicated, treasury; not committed) | **0** | **420** |
| **Protection capital, tail -75%** | **1,191** | **2,156** |
| Supplier supply (not our capital) / of which 20% cash floor | 6,250 / 1,250 | 6,250 / 1,250 |
| **Operator inventory, each operator, no recycling** (rule: at least 0.75 x cap debt; about 0.88 x in a 30-day outage tail) | **at least 3,750; about 4,440** | **at least 3,750; about 4,440** |
| Unrecoverable debt if the treasury is unfunded at -75% (share of supply) / worst supplier recovery | 19.0% / 0% | 34.4% / 0% |
| Operating cost | under USD 1/month gas (about USD 0.005-0.008 per liquidation); hosting, alerts reused | same |
Protection capital buys a bounded tail only (PW40: 20% of cap covers a -65% step; 50% covers -78%). Conversion back to USDC works at this size through Uniswap V3 0.05% (-1 to +7 bp vs Chainlink at 1k-10k; net +489 to +494 bp per round after gas); recycling is NOT assumed in the inventory rule.

## 2. Treasury `repayBorrowBehalf` procedure (qualified, no funds committed; detail in `avalanche-cash-only-treasury-repayment.md`)
- **Roles:** monitor (reads only, no funds); treasury multisig (holds the protection USDC and gas only, no admin power; `repayBorrowBehalf` is permissionless so authorization = who holds the funds); two liquidator operators (separate keys, each holding the inventory above); admin/guardian separate. The Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` is the intended initial admin/signer (the script is run with `--ledger --sender`).
- **Detection rule:** repay only when all oracle and reference prices are non-zero, the account is in shortfall, debt > 0, collateral value x 1e18 < debt value x LI (a full liquidation cannot clear it) and collateral <= USD 0.01 (liquidation exhausted); amount = the debt at the repay transaction (`type(uint256).max` sentinel).
- **Timings (proposals, not derived from tests):** repay within 1 hour of detection; escalate at 4 hours; outer bound 24 hours. Interest on the unrecoverable debt is small (at most 0.52% of the loss after 30 days); the real exposure is the first-come-first-served exit window while unrepaid.
- **If under-funded:** the last suppliers in the withdrawal queue absorb the loss; each USDC repaid removes exactly one USDC of shortfall; late funding heals; at tails of -67.6% or deeper some supplier recovers 0% even at 50% funding.

## 3. Provisional parameters (to be re-tested together with the selected route and operators)
Liquidation incentive **1.08**; close factor **50%**; reserve factor **10%** (replenishment only, about 1.19% of borrows per year at 80% utilisation); cash floor **20%** of supply (guards new borrows only); rate shape: 2% base, 10% slope, jump 100% above an 80% kink (borrow APR about 12% at 80% utilisation). Oracle guards unchanged (AVAX max age 1,200 s, USDC 90,000 s); secondary oracle deferred.

## 4. Reference-price requirement (monitor-side, independent of Chainlink; fails closed when absent). **Two candidates; I have NOT selected one.**
| | **A. Uniswap V3 WAVAX/USDC 0.05% 30-minute TWAP** (on-chain `observe`) | **B. Pyth AVAX/USD** (feed id `93da3352...7bb7`, "AVALANCHE / US DOLLAR") |
|---|---|---|
| Verified | pool `0xfAe3...c45E`, observation cardinality 8,500, a 1,800 s TWAP is readable; one reading on 2026-11-05: TWAP 8.6703 vs Chainlink 8.6562 (+16 bp) | feed exists (public metadata listing HTTP 200). **Its price endpoint returned HTTP 401 without credentials from this client**: keyless public access is NOT confirmed |
| Cost | no subscription; one extra `eth_call` per check inside the batched read (cents per month); engineering for the window and a deviation tolerance | **unknown**: possible keyed or paid access (plan and price not verified here); an on-chain pull-update fee only if used on-chain (not needed for a monitor-side reference) |
| Independence | on-chain, different from Chainlink's feed but the same market the liquidators trade in; moves with it in a market-wide crash; manipulation costs roughly the pool depth over the window (1% slippage depth about USD 109k) | different publisher network and aggregation from Chainlink; adds an external service dependency |
You choose; either is a monitor-side input to the detection rule, not a change to the on-chain oracle.

## 5. Audit and open items (all UNAUDITED)
Borrow cash floor in `PeridottrollerAvalanche` (+ `Peridottroller.borrowAllowed` made `public virtual`); `AvalancheMarketBootstrapper` and `DeployAvalancheCashOnlyLending` (rehearsed on a local fork only); the optional no-reward-token constructor if you opt in (test-only prototype exists; production wrapper unchanged); `GuardedAvalanchePriceOracle` and the Avalanche controller wrapper. Not built: operator liquidation, monitoring, the reference-price integration. Not chosen: PW30 vs PW40, the cap, the tail gap, the operators, the reference source, the PERIDOT wrapper choice, the governance handover (the Safe is 1-of-1). Outside the pilot but noted: the vaults' `rebalancer` role is still the previous signer (only the Safe can change it). Separate scaling proposal: audited reserve-first write-off.

## 6. Evidence status
Suites at git `6c584f6d`: cold single-run results are recorded in `avalanche-cold-repro/` (see its README). Fixtures are mocked-feed, pinned block 99,200,000, one year of price history; short feed-delay samples; the figures are research, not forecasts.
