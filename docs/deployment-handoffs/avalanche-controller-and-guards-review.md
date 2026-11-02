# Avalanche: controller wrapper, oracle consumers, swap guard and recovery-path definitions

Branch `avalanche-pharaoh-tracks-abcd`. Companion to `avalanche-section5-fork-results.md` and `avalanche-capacity-matrix.md`.
Tests only; nothing signed or broadcast.

## 1. Three different "recoveries" (use these names; earlier text mixed them)

| Name | Who funds what | Swap needed | Market cash needed | Exists / tested |
| --- | --- | --- | --- | --- |
| **Normal swap-based close** (`closePosition`) | Flash loan funds the repay; position is swapped to repay the flash loan | yes (pool, oracle bounds) | yes for the redeemed collateral market | exists; tested (long and short) |
| **Owner-funded repay + debt-free exit** (`repayWithUnderlying`, then `exitDebtFreeToPTokens`) | The owner supplies the debt asset | no | no (returns pTokens, not underlying) | exists; tested with zero cash and with a stale feed |
| **Normal flash liquidation** (`liquidate`) | Flash loan funds the repay | yes | yes | exists; fails in the pool-wall and zero-cash scenarios (capacity matrix) |
| **Funded in-kind forced liquidation** | A funded liquidator supplies the debt asset and takes pTokens atomically | no | no | being built; see `avalanche-funded-fallback.md` |

"Voluntary close" in earlier text meant the second row; it is not a swap-based close and is not a substitute for liquidation.

## 2. Protocol seizure share (2.8%): formula and denominator

From `PToken.seizeInternal` (`protocolSeizeShareMantissa = 2.8e16`):

- `seizeTokens` = collateral **pTokens** computed by the controller: `repay x liquidationIncentive(1.08) x priceBorrowed / (priceCollateral x exchangeRateCollateral)`.
- `protocolSeizeTokens = seizeTokens x 2.8%` (denominator: **the seized pToken amount of the collateral market**, not the repay amount and not the underlying value).
- The liquidator receives `seizeTokens - protocolSeizeTokens` (97.2%). The borrower loses 100% of `seizeTokens`. The protocol share is removed from `totalSupply` and its underlying value is added to the collateral market's `totalReserves`.
- Net liquidator premium on the repaid value is therefore `1.08 x 0.972 - 1 = 4.98%`, not 8%. The fork test asserts seized value = `repay x 1.08 x (1 - 2.8%)` within 0.5%.
- This applies to ordinary `liquidateBorrow` only. The margin liquidator pays its keeper from `liquidationBonusBps` of the repaid value out of the swap surplus (5% in the tested config) and has no protocol seize share.

## 3. Oracle zero sentinel: every consumer

`GuardedAvalanchePriceOracle` returns 0 when a price is unavailable. Fork test `testOracleZeroSentinel_allConsumers` kills the AVAX feed, then the USDC feed, and checks each consumer (each fails closed, none computes with 0):

| Consumer | Behaviour with a dead feed |
| --- | --- |
| Controller `getAccountLiquidity` | returns error `PRICE_ERROR` (13), no numbers |
| `liquidateCalculateSeizeTokens` | returns `PRICE_ERROR`, no division by zero |
| Ordinary borrow, liquidation, redeem, transfer | rejected with `...PeridottrollerRejection(PRICE_ERROR)` |
| Margin `RiskEngine.getMetrics` / `isLiquidatable` | reverts `PriceUnavailable(asset)` |
| `IsolatedMarginQuoter` (open sizing, `expectedOut`) | reverts "price unavailable" |
| Margin liquidation and close | revert `PriceUnavailable` |
| `IsolatedMarginSwapModule.executeSwap` | reverts (quoter) |

Decimals: the controller price is `10^(36-decimals)` scaled (USDC `~1e30`, WAVAX `~1e18 x USD`); the guarded oracle equals the inner oracle's scaling on a good round (`testGuardedOracleFailsClosedOnBadRounds`). USDC at 0.98 and 0.90: USDC debt is valued at the feed price (`testUsdcDepeg_valuationFollowsFeed`: debt USD 4,898.9 -> 4,803.0 -> 4,410.9), no revert, no use of 1.0. A USDC depeg has not been run through the margin liquidation matrix; that is open.

## 4. Stale feed by account class

`testStaleFeed_accountClassMatrix` (AVAX stale, emergency price set on the inner oracle):

| Account | Redeem / borrow / transfer | Repay |
| --- | --- | --- |
| Never entered a market, no debt | redeem works | n/a |
| Entered, zero debt | **blocked** (liquidity is computed across all entered markets) | n/a |
| Entered, debt in one market, collateral in both | **blocked** in both markets (no collateral-check bypass), borrow blocked, pToken transfer blocked | works |
| Same account after full repay but still entered | still blocked | n/a |

Consequence for operators: during an AVAX feed outage, suppliers who entered markets cannot withdraw even without debt. That is a UX/availability cost of failing closed; exiting the market first (needs the same valuation) does not help.

## 5. Swap guard: what `IsolatedMarginSwapModule` actually enforces

Source: `IsolatedMarginSwapModule.executeSwap`. For each swap:

1. `expectedOut` = oracle-valued output for the input (both token prices from the guarded oracle).
2. `protocolMinOut = expectedOut x (1 - maxSlippageBps)`; a caller minimum below it is rejected (`SwapError(5)`); the effective minimum is the larger of the two.
3. The effective minimum is passed to the adapter and then the router, so the first failure is the router's `"Too little received"`.
4. After the swap: `SwapError(7)` if output < effective minimum, `SwapError(8)` if `oracleValue(out) < oracleValue(in) x (1 - oracleDeviationBps)`.

So the check is **one-sided and relative to the oracle**: only execution that is *worse* for the margin account than the oracle-valued trade (by more than `maxSlippageBps`) is refused. Pool prices that are *better* than the oracle always pass. It is not a symmetric spot-price deviation check. With the candidate guards (slippage 100, deviation 100) `SwapError(8)` is redundant with step 3.

Measured with the real module at the pin, USD 5k notional (fee 490 ppm; actual execution is about 5.7 bps worse than pool spot in both directions). `delta` = oracle price relative to pool spot. Prices are USD per AVAX x 1e8; pool spot 855,522,072.

| Direction | Oracle vs pool | Oracle | Pool | Expected out | Min out | Actual out | Exec price | Result |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| sell WAVAX | -300 bps | 829,856,410 | 855,522,072 | 4,852,060,671 | 4,803,540,064 | 4,997,165,828 | 855,037,132 | pass (favourable) |
| sell WAVAX | 0 | 855,522,072 | 855,522,072 | 5,002,124,402 | 4,952,103,157 | 4,997,165,828 | 855,037,132 | pass |
| sell WAVAX | +50 | 859,799,682 | 855,522,072 | 5,027,135,022 | 4,976,863,671 | 4,997,165,828 | 855,037,132 | pass |
| sell WAVAX | +99 | 863,991,740 | 855,522,072 | 5,051,645,430 | 5,001,128,975 | 4,997,165,828 | 855,037,132 | **revert "Too little received"** (actual < min) |
| sell WAVAX | +300 | 881,187,734 | 855,522,072 | 5,152,188,133 | 5,100,666,251 | 4,997,165,828 | 855,037,132 | **revert "Too little received"** |
| buy WAVAX | -300 | 829,856,410 | 855,522,072 | 602,257,985,812,268,414,001 | 596,235,405,954,145,729,860 | 584,107,176,537,765,873,510 | 856,007,287 | **revert "Too little received"** |
| buy WAVAX | -99 | 847,052,404 | 855,522,072 | 590,031,558,425,280,143,588 | 584,131,242,841,027,342,152 | 584,107,176,537,765,873,510 | 856,007,287 | **revert "Too little received"** |
| buy WAVAX | -50 | 851,244,462 | 855,522,072 | 587,125,875,480,879,193,079 | 581,254,616,726,070,401,148 | 584,107,176,537,765,873,510 | 856,007,287 | pass |
| buy WAVAX | +300 | 881,187,734 | 855,522,072 | 567,174,996,559,813,666,221 | 561,503,246,594,215,529,558 | 584,107,176,537,765,873,510 | 856,007,287 | pass (favourable) |

The generated full table (13 deltas x 2 directions, plus the altered-guard diagnostic) is in `avalanche-capacity-matrix.md`. Trigger points: selling fails once the oracle is more than about +0.9% above the pool; buying fails once the oracle is more than about -0.7 to -0.99% below it (between the -50 and -99 rows).

Altered-guard diagnostic (slippage 300, deviation 50; **not a candidate configuration**): selling with the oracle +250 and +100 bps above the pool reverts `SwapError(8)` (the deviation check, after the router minimum passed); +40 passes.

### Why the oracle-only long liquidation passed

A long liquidation sells WAVAX for USDC. The test lowered the oracle (to 66% of pin and below) while the pool stayed at pin, so the pool paid *more* than the oracle expected: the sell leg was far on the favourable side of the table (-300 bps row and beyond) and always passed. That scenario therefore overstated robustness; it contains no pool movement, no execution loss beyond the 5.7 bps, and no depth limit. The pool-follows and lag scenarios in the capacity matrix are the consistent tests.

A short liquidation has two legs: buy WAVAX with the seized USDC (collateral to debt) and sell surplus WAVAX back to USDC (debt to margin). With the oracle raised and the pool unchanged the buy leg is favourable but the sell leg is not, so it reverts. Real moves (oracle lagging the pool) hit the same one-sided condition in whichever direction the pool pays less than the oracle expects.

## 6. Mainnet controller wrapper review (`PeridottrollerAvalanche`)

- **Diff versus `PeridottrollerAvalancheFuji`:** chain-id constant 43113 -> 43114, constant and revert-string names, comments. Nothing else.
- **Chain-id check:** constructor only (deployment on any other chain reverts). Behind `Unitroller` the delegatecall does not re-check, which is intended; the implementation address is what is pinned. Test: `testMainnetControllerWrapper_*` (wrong chain id and token without code revert; `getPeridotAddress()` through the proxy returns the token).
- **Storage layout:** adds only `address public immutable peridotToken` (bytecode, not storage). Layout is identical to `Peridottroller`, so it is storage-compatible with the `Unitroller` proxy and with the Fuji implementation. A `forge inspect storage-layout` diff is recorded in the PR description when the shared build is free.
- **Reward-token configuration:** the base `Peridottroller.getPeridotAddress()` hardcodes `0x507f0F5E58d21f07d133722e038067248fe4ecBE` (another chain's token). No PERIDOT token is recorded on Avalanche mainnet (`addresses.MD`). The wrapper therefore *requires* an operator-supplied token with code. In the fork test it is a freshly deployed test token. **Open decision:** deploy a PERIDOT token (or a no-supply placeholder) before the controller implementation; with all comp speeds at zero (default) no claim path moves tokens, and the test checks `claimPeridot` is a no-op.
- **Margin hooks:** `_setIsolatedMarginRiskHook` / `_setIsolatedMarginRegistrar` are inherited and exercised by every margin test.
- **Not a deployment rehearsal:** the fork tests wire markets and the margin stack inline. The Fuji deployment path (`AvalancheFujiMarketBootstrapper` atomic list + seed + pause, pending-admin hand-off, `DeployIsolatedMarginAvalanche` verification) is chain-id gated and has no mainnet counterpart. A mainnet bootstrapper/deploy script and a rehearsal on a local fork *using that script* are not written and are not authorized by this work. Operator signs every transaction.
