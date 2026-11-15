# Avalanche (cash-only lending and vaults): operating cost estimate

Status: estimate for an operator decision. **It proposes no subscription and no additional infrastructure.** Every price below is an assumption stated next to the line, read from the public chain on 2026-11-03 or taken from a repository measurement; nothing is a quote. No production parameter, deployment or launch approval is implied.

## Inputs (measured or read)
| Input | Value | Source |
| --- | --- | --- |
| C-Chain gas price / base fee | 2.5 gwei (base fee 2.500000000 gwei, gas price 2.500000150 gwei) | `cast gas-price`, `cast block latest` on a public node, 2026-11-03 |
| AVAX/USD | 8.43 USD (Chainlink `latestAnswer` 8.4293e8) | same node |
| Cost of 1,000,000 gas | 0.0025 AVAX = **about 0.021 USD** | 1e6 x 2.5e-9 x 8.43 |
| Ordinary lending gas (mint 112k, borrow 332k, **liquidateBorrow 244k**, full repay 42k, redeem 43k) | `GAS|` lines of `testGas_OrdinaryLendingOperations` | **lower bounds**: measured inside one test transaction, so storage access is warm; separate transactions pay cold-access costs (assume up to about 1.6x) |
| Funded in-kind margin liquidation | 0.55 to 0.70M gas; flash margin liquidation 1.57M | funded-fallback and section 5 results (margin trading is paused; included only for completeness) |
| AVAX/USD feed cadence | median 121 s between rounds, max 136 s over 2.3 h (80 rounds) | public node, 2026-11-03 |
| USDC/USD feed cadence | one round per about 86,400 s (24 h heartbeat; 86,401 to 86,467 s observed) | same |

## Itemized estimate
| Item | Quantity (assumption) | Unit cost | Estimate |
| --- | --- | --- | --- |
| **Keeper / liquidator transactions** | each ordinary liquidation: 244k gas warm, up to about 390k cold | 0.021 USD per 1M gas | **0.005 to 0.008 USD per liquidation**. Even 1,000 liquidations in a month is about 5 to 8 USD; a 100x gas-price spike makes it 0.5 to 0.8 USD each. Gas is not the cost driver; the liquidator's **inventory** is (see the risk proposal), and inventory is capital, not an operating expense |
| Admin transactions (floor changes, parameter steps, pause) | a handful per quarter, 30k to 150k gas each | same | cents |
| Vault rebalancer / harvest keeper (Pharaoh vaults) | cadence not decided; gas per `rebalance` / harvest NOT measured in this repository | same | **unknown**; likely cents per call at 2.5 gwei, but not measured, so not asserted |
| **Hosting** | one small Node process (a liquidator/monitor in the style of the repository's existing containerised Telegram bot: Node 18, `restart: unless-stopped`) | **0 marginal if an existing instance has headroom** | I cannot see the AWS account. The repository contains no AWS infrastructure definition, only that Docker setup. Reuse of existing capacity is the assumption; whether headroom exists is an operator fact I do not have. A new instance would be new infrastructure and is NOT proposed here |
| **RPC** | monitoring reads: see below | public endpoints are what the repository uses today | **Not free of risk**: the public endpoint returned HTTP 429 during heavy fork-test runs (thousands of requests in minutes). Monitoring volume is orders of magnitude lower if batched (below). If a public endpoint proves insufficient, choosing a provider is an operator decision; no provider or plan is proposed |
| **Monitoring and alerting** | metric polling + alert delivery | alert delivery through the existing Telegram bot (no new subscription) | 0 marginal; the dashboards/log retention are the host's existing ones |

## RPC volume of a monitor (no subscription assumed)
A poll reads: the two feeds' `latestRoundData` (freshness), per market `getCash`, `totalBorrows`, `totalReserves`, `borrowCashFloor`, the controller's borrow-paused flags, the liquidator's balances and allowances, and `getAccountLiquidity` for each borrower with debt.
- Unbatched, N borrowers: (about 12 + N) `eth_call`s per poll. At a 30 s poll and N = 100: about 112 x 2,880 = **323k calls/day (about 9.7M/month)**.
- Batched through a single multicall (one `eth_call` per poll): about **2,880 calls/day (about 86k/month)**, plus one `eth_getLogs` per poll to discover borrowers (another 2,880/day).
- Feed freshness needs far fewer reads than liquidation scanning: the AVAX feed moves every about 2 minutes, the USDC feed daily.
Design consequence (a constraint, not a purchase): batch the reads and poll the borrower set by event logs, so the monitor stays within what a public endpoint tolerates.

## What dominates cost
Not gas, not compute: the **capital** held as liquidator inventory and the **protection capital**, both separate from operating cost and from each other (see `avalanche-funding-purposes-and-loss-reserve.md`). Operating cost on this chain is cents per transaction plus whatever existing hosting is reused.

## Not known / not measured
Existing AWS capacity and headroom; the actual RPC limits of the endpoint in use; gas of vault rebalance/harvest; cold-access gas of each operation; gas price in stress (a 10x to 100x spike is arithmetic above, not a forecast); on-call time (people cost) is outside this estimate.
