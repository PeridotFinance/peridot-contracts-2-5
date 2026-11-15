# Avalanche handoff 09 section 5 fork checkpoint: results

Branch `avalanche-pharaoh-tracks-abcd` (from `boosted-findings-remediation`). Tests only, nothing signed or broadcast, no keys.
Test: `contracts/test/AvalanchePharaohSection5Fork.t.sol` (**35 pass, 0 fail**; the former deliberate failure `testRequirement_fundedInKindForcedFallback_UNMET` was replaced by `testAcceptance_fallback_*` tests now that the funded in-kind route exists; cold public-RPC runs may fail on rate limits until the local fork cache is warm). One independent review pass was done; its confirmed issues are fixed (vacuous liquidation blocks, weak assertions, oracle hardening). New code: `PeridottrollerAvalanche.sol`, `margin/GuardedAvalanchePriceOracle.sol`.

Run (pin block 99,200,000, chain time about 2026-11-02; the public RPC served it, a private archive RPC is better because the public one rate-limited cold runs and the cache has to be warmed):

```
AVALANCHE_MAINNET_RPC_URL=https://api.avax.network/ext/bc/C/rpc FOUNDRY_PROFILE=debt_accounting \
forge test --match-contract AvalanchePharaohSection5ForkTest --threads 1 -vv \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

All lending and margin parameters in the test (CF 60%/75%, rate model, reserve factor, caps, 2x/50%/25%, USD 50k position cap, flash fee 0) are placeholders for measuring, not recommendations (operator decisions 3 and 4).

## Coverage of section 5

| Section 5 bullet | Result |
| --- | --- |
| Supply and borrow both ways, ordinary liquidations | Pass. USDC against WAVAX, WAVAX against USDC, repay with interest, borrow paused at deploy, borrow cap, over-borrow denied, liquidation both directions; healthy account rejected; close factor 50% enforced (over-repay refused with TOO_MUCH_REPAY, debt unchanged); seized value = repay x 1.08 x (1 - 2.8% protocol share) |
| AVAX long and short open, partial and full close | Pass through `PharaohCLRouterAdapter` and the real pool. 2x requested gives 1.98x / 1.99x, health about 20,100 bps. Round trip costs about 19 bps of margin (long) |
| Partial and full liquidation | Long: **pass** with an oracle-only shock (first liquidation partial at AVAX 66% of pin, then full). Short: **pass only** with the 40%-maintenance profile against a pool really pumped +22% (`testMovedPool_ShortLiquidation_Maint4000`, partial). With the 2x/25% profile, and for the long even at 40% maintenance, the liquidation **fails against a moved pool** (findings 1 to 3) |
| Stale feed plus emergency price | Pass, mutation-checked twice (wiring the unguarded oracle makes it fail). Accounts are underwater at the emergency price and a control run proves the unguarded oracle WOULD allow the ordinary liquidation. Borrow (both directions, PRICE_ERROR), margin open, margin liquidation and close (`PriceUnavailable`), ordinary liquidation (PRICE_ERROR) all blocked. Guarded oracle also returns 0 for zero/negative/future/mismatched/malformed/reverting rounds and disabled feeds |
| Repayment and recovery paths | Pass: ordinary repay, `repayWithUnderlying` + `exitDebtFreeToPTokens` work with a stale feed. Long close works with zero pUSDC cash. **Short close and short liquidation revert with zero pUSDC cash** (`RedeemTransferOutNotPossible`); voluntary debt-free exit still works |
| Funded in-kind fallback | **Implemented** (`liquidateFunded`); acceptance tests `testAcceptance_fallback_*` (zero cash long/short, pool wall, atomic exhaustion, invalid price, authorization/repeat/ownership) pass; mechanism suite and finite-funding matrix are separate |
| Funding and costs | Measured below |

Also verified: a registered margin account cannot be liquidated through ordinary `liquidateBorrow` even though it is in ordinary shortfall and margin-liquidatable (market reverts INSUFFICIENT_SHORTFALL); the dedicated liquidator then repays debt. Plain delegates have no local borrowing reserve, so the reserve-versus-recovery tests reduce to cash exhaustion.

## Findings (things that fail or surprise)

1. **The pool's sell side is a wall.** At the pin the pool holds 513k WAVAX but only about USD 95.8k USDC. Selling WAVAX: price -1% after USD 63k, -5% after 80k, -10% after 90k, -20% after 97k, then the price falls to 5% of pin after 98.5k (no liquidity). The 2x/25% long is liquidatable only at about -34%, which the pool cannot reach without being emptied. With the pool sold to its floor and the oracle following it, **a USD 10k long cannot be liquidated** (router "Too little received"). Test `testFinding_LongLiquidationFailsWhenPoolSellSideIsExhausted` asserts this current behaviour.
2. **The buy side is also a wall, about 50% up.** About USD 4.9M of USDC buys the pool's WAVAX to +50%, then the price jumps (to about +115%). The short is liquidatable at about +51%, just past it; with the pool pumped there, **the short liquidation reverts**. Test `testFinding_ShortLiquidationFailsWhenPoolBuySideIsExhausted`.
3. **Unfavourable execution relative to the oracle blocks liquidation on the affected leg.** The swap module requires output of at least `expectedOut(oracle) x (1 - maxSlippageBps)`; favourable execution always passes. Whether a gap fails depends on the leg direction, fee, price impact and configuration (measured boundaries for USD 5k are in the controller review doc and the matrix); it is not a symmetric 100-bps rule. A short has two legs (buy WAVAX, then sell surplus WAVAX) and the sell leg fails when the oracle is above the pool (shown: oracle-only +70%, pool unchanged). In the matrix, an oracle 100 bps behind the pool in the adverse direction fails normal liquidations at every size. This argues for the funded in-kind route even with a deeper pool.
4. **Zero market cash blocks short closes and short liquidations** (revert `RedeemTransferOutNotPossible`, asserted for the close; the liquidation revert selector is logged). Long close works with zero pUSDC cash. The voluntary emergency close (`repayWithUnderlying` + `exitDebtFreeToPTokens`) works. A funded in-kind fallback is needed for the forced path (new work, shared risk model section 10). Only pUSDC was drained; pWAVAX cash exhaustion for longs was not tested.
5. **Stale price and ordinary suppliers.** With AVAX stale, a supplier who never entered markets can still redeem. A supplier who entered markets (no debt) cannot (revert). Repay always works.
6. **Gap shock in the oracle only does not exercise solvency.** At -60% (oracle-only) the long is liquidated with no insurance draw because the unmoved pool pays above the oracle. Bad-debt/insurance sizing needs the moved-pool scenarios, which currently hit finding 1; the insurance fund is therefore unmeasured.
7. **Mainnet needs non-Fuji code.** `PeridottrollerAvalancheFuji`, `AvalancheFujiMarketBootstrapper`, `DeployAvalancheFujiLendingMarkets` and `DeployIsolatedMarginAvalanche` all require chain id 43113. `PeridottrollerAvalanche` (new) covers the controller; the test wires markets and the margin stack inline. A mainnet bootstrap/deploy script is not written and not authorized by this work.
8. Pool facts at the pin: fee 490 ppm, `slot0.feeProtocol` returns 1,000,000 (handoff says 1; units differ and need checking before any fee reasoning), pool price within 7 bps of Chainlink; the test header notes a changed `PIN_BLOCK` needs a block shortly after a Chainlink update, Chainlink AVAX/USD 8.549 (AVAX is about USD 8.55 at this block).

## Measured numbers

- Adapter ladder (loss versus oracle, one way, real pool): buy WAVAX 12 / 12 / 15 / 23 / 45 / 138 / 201 bps at USD 1k / 5k / 25k / 50k / 100k / 250k / 500k. Sell WAVAX 0 / 0 / 5 / 17 / **428** / 6,171 / 8,085 bps at the same sizes. Round trip about 9 bps (buy then sell back). The pair's 100 bps slippage bound is exceeded one-way at about USD 100k on the buy side and well under USD 100k on the sell side (between 50k and 100k).
- Opens at the proposed caps (USD 24k margin, 2x): long flash need 23,525 USDC, short flash need 2,778 WAVAX (about USD 23.7k). Flash vault funded 200k USDC and 5,000 WAVAX in the test; peak need is about the debt cap per side (USD 25k), it is returned within the transaction. Flash fee sensitivity: 9 bps keeps 1.98x and health 20,181 bps.
- Gas: long open 2.62M, short open 2.75M, long liquidation 1.57M.
- Keeper reward on the partial long liquidation: 122.5 USDC on a USD 5k margin position.
- Insurance fund seeded at about 1% of each market in the test; not yet exercised by a solvent-looking scenario (finding 6).

## Capacity

Superseded by `avalanche-capacity-matrix.md`. The earlier first-order chain in this section (depth arithmetic at favourable state, divided by a stress factor and a safety factor) has been withdrawn: it was derived from the favourable-state depth curve, not from executed stressed scenarios. Result of the executed matrix: **no capacity can be established for the candidate 2x/25% profile on this pool, long or short**; no launch cap is offered.

## Not done in this checkpoint

Bad-debt/insurance sizing, pWAVAX-cash exhaustion for longs, the section 4 correlated-liquidation tool, hooking a funded liquidator, mutation checks beyond the oracle, a second review pass. Track A tests (fairness, exits, keepers on the two existing vaults), the D port and the fee/reward entitlement fork test, bad-debt/insurance sizing, funded fallback, mutation checks beyond the oracle, adversarial review beyond one pass. Mainnet date: not supported by this evidence.

## Notes on handoff files

The two handoff files in this repo are under `docs/handoffs/` with a `-2` suffix and are untracked. The operator named `docs/deployment-handoffs/` as canonical; they were not moved. Handoff files 01 and 06 are not present in this repo. The PR variant of 00 with the additional section 6a liquidity policy is not in this clone (no local or remote branch carries `docs/`; only `main` and `boosted-findings-remediation` exist), so the section 4 and 5 rules used here follow the attached 00 and the capacity chain above may need reconciliation with 6a. Robinhood and Stellar PR work (handoff 08, PR 12, 01 Phase 0) is outside this repo and was not touched.
