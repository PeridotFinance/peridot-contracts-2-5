# Handoff 09: Avalanche v1: deposit products, cash-only USDC/WAVAX lending, AVAX trading, later Pharaoh allocation

Audience: the implementation LLM working in `PeridotFinance/peridot-contracts-2-5`, branch **`boosted-findings-remediation`** (newest, 2026-10-19 `2b6e4828`), folder `contracts/`.
Written: 2026-10-31, revised twice the same day after review. Read `00-shared-risk-model-and-rollout.md` first; it overrides this file where they differ. Then read handoff 01 and PeridotV2-Robinhood `feat/ramses-vaults` (`ramses-vaults/README.md`): Pharaoh's CL contracts are labelled RamsesV3, so the Robinhood Ramses paired vault and delegate are the **reference** for track D. Compatibility is something to verify on an Avalanche fork, not to assume.

## 0. Products and independent delivery tracks

| Track | What users do | Leverage | Activation requirement |
| --- | --- | --- | --- |
| **A. Stable Earn** (USDC/USDt strategy vault) | Deposit **USDC** into the existing vault | None; shares cannot collateralize borrowing | Public-deposit accounting, reward fairness around harvests, exits at the proposed caps, keeper operation proven |
| **A. AVAX Earn** (sAVAX/WAVAX strategy vault) | Deposit **WAVAX** into the existing vault | None | Same as Stable Earn. Depositors carry AVAX price exposure in dollar terms plus sAVAX/WAVAX divergence |
| **B. Cash-only lending** (fresh USDC/WAVAX group) | Supply or borrow USDC and WAVAX; all cash stays local | None beyond ordinary borrowing | Guarded oracle, borrowing, ordinary liquidations with a working liquidator, monitoring proven |
| **C. AVAX trading** (legacy isolated margin) | Capped AVAX long/short, borrowing from track B's local cash, executing against Pharaoh's existing WAVAX/USDC liquidity | 2x candidate | Margin lifecycle, stressed liquidations, flash funding and the funded fallback proven |
| **D. Pharaoh allocation** (paired WAVAX/USDC strategy behind strategy-capable USDC/WAVAX markets) | Same deposit interface, but **suppliers' risk changes**: eligible idle cash enters a volatile-pair strategy and suppliers bear its losses under the defined accounting and reserve rules. Requires an explicit transition from track B's plain markets (3b) | None | Paired accounting, reward ownership, net returns and per-token withdrawal capacity proven |
| Later | Leveraged LP, Earn shares as collateral, collateral-preserving margin on mainnet, LP + vote (xPHAR / p33) | | Separate handoffs |

The tracks have **independent gates**. Trading (C) does not wait for allocation (D); it borrows from cash-only markets and trades against Pharaoh's existing liquidity. D can fail its economic gate without affecting A, B or C: Track A stays invested in its own strategies; only B and C remain cash-only.

Two statements the UI and docs must make plainly:

1. **AVAX trading is not leveraged LP.** A long borrows USDC to buy WAVAX; a short borrows WAVAX to sell it for USDC.
2. **USDC in track B is not Stable Earn.** Once D is active, track B suppliers bear the WAVAX/USDC strategy's losses under the defined accounting and reserve rules; a finite reserve does not guarantee principal. Stable Earn never funds track B or absorbs its losses. Balances, reserves and liabilities are separate.

## 1. What already exists (verified in the repo)

| Piece | Where | Use |
| --- | --- | --- |
| Two Pharaoh ERC-4626 strategy vaults | USDC/USDt `0x855bF832f26a294d28500db59eE941dE3d654129` (asset **USDC**), sAVAX/WAVAX `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` (asset **WAVAX**); owner Safe `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` (1-of-1), rebalancer `0x94696d767e65a75581145646960FA0eC886cE5d2`; tiny seeds, `maxDeposit` 0 at last check; LP-Vaults source with `onlyRebalancer` `rebalance()` / `deployIdle()` | Track A |
| `PharaohBoostedDelegate` + `PharaohVaultShareOracle` | `contracts/boosted/`, `contracts/PharaohVaultShareOracle.sol` | Not used in v1 (they list vault shares as a market, which only matters for collateral use) |
| Legacy isolated margin | `contracts/margin/IsolatedMargin*.sol`, flash vault, insurance fund, fee distributor | Track C, the only margin engine on mainnet |
| `PharaohCLRouterAdapter` | `contracts/margin/PharaohCLRouterAdapter.sol` | Implements `IMarginRouterAdapter`, pins one direct Pharaoh CL pool, verifies identity, clears approvals, rejects partial consumption. Reuse for track C, subject to the full legacy-margin lifecycle tests |
| `AvalanchePriceOracle` | `contracts/margin/AvalanchePriceOracle.sol` | Chainlink with max age, **but `getPrice` (and therefore `getUnderlyingPrice`) falls back to an owner-set `setEmergencyPrice` value when the feed is stale**. Must be wrapped for both lending and margin (section 3b) |
| Collateral-preserving margin | `CollateralPreserving*.sol`, mock Fuji deployment (activated 2026-10-09) | Deferred; stays on Fuji |
| Avalanche mainnet Peridot deployment | none recorded (`addresses.MD`, broadcasts checked 2026-09-21) | Fresh deployment |

Fork-test addresses: USDC `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`, WAVAX `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7`, Chainlink AVAX/USD `0x0A77230d17318075983913bC2145DB16C7366156`, USDC/USD `0xF096872672F44d6EBA71458D74fe67F9a77a23B9`.

## 2. Pharaoh facts (docs.phar.gg contract page and `gateway.kingdom.dev/avalanche/api/pools`, read 2026-10-31; verify on-chain)

| Contract | Address |
| --- | --- |
| RamsesV3Factory | `0xAE6E5c62328ade73ceefD42228528b70c8157D0d` |
| Pool deployer | `0x6a4113ed0915bCf5E48e758e8f4cEBFFC07C66f9` |
| Position manager | `0x0B4478e810D48B5882D4019D435A2f864Bab4F39` |
| SwapRouter / QuoterV2 | `0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c` / `0xB7297301b7CC659BB96D51754643A0Df6eEA2138` |
| Voter / CL GaugeFactory | `0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7` / `0xE565310BAa582C768a77a3BB7F86a892eF07D04e` |
| PHAR / xPHAR / p33 | `0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7` / `0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A` / `0x26e9dbe75aed331e41272bece932ff1b48926ca9` |
| AccessHub / FeeCollector | `0x3176f6E4Be2448C53EDD59C27651EDFaA74bf483` / `0x1e1e2a861205767D69A51edf03cf5e3a278437bc` |
| Team multisig / Timelock | `0xd1b27ccAF2A4dDcA0Ac32181374C70282492d843` / `0x12d54ad6daf65d55b029df1b34b260c68fc0ddcf` |

**WAVAX/USDC pool** `0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534` (token0 WAVAX, token1 USDC): fee 490 ppm now (800 at the September fork pin), tick spacing 10, ~$4.33M TVL, ~$31.6M 24 h volume, ~31% of TVL in range, PHAR LP emissions ~$94.2k per period, voter fees ~$93.5k per period, API `feeProtocol = 1`, PHAR ~$0.0507.

- It is the first candidate for track D because the same pool executes track C's trades, not because the displayed APR proves a higher net return. The headline APRs in the thousands come from the API's narrowest "Degen" range row; ±2.5% shows ~259% reward APR, ±50% ~13%. Neither is a realized return.
- **Fees go to voters** on gauged pools by Pharaoh's default, so our traders' swaps do not automatically produce fee income for our LP depositors. Strategy income is PHAR emissions, a pot our liquidity dilutes.
- **Emissions are variable**: Pharaoh documents variable weekly emissions, and each pool's share depends on vote allocation, which can move week to week. Stress the **quantity** of emissions to our pool and the vote share, not only PHAR's price.

## 3. Architecture by track

### 3a. Track A: Stable Earn and AVAX Earn

- Deposit assets are what the ERC-4626 vaults record: **USDC** for the USDC/USDt vault and **WAVAX** for the sAVAX/WAVAX vault. Accepting USDt or sAVAX needs a separately specified and reviewed conversion route; the pair name does not make `deposit` accept both tokens.
- Opening deposits is **not yet proven** to be owner settings only. The LP-Vaults notes leave the public reward anti-sniping policy unresolved; Safe-only harvesting controls who harvests, not whether a newcomer can capture earlier depositors' rewards. Before raising `maxDeposit`, prove with tests on the actual vault code at a pinned fork:
  - fair entry and exit around harvests and reward compounding (the Alice/Bob case of shared risk model section 8a, applied to these vaults);
  - usable exits at the proposed caps (redemption through the pool at stressed liquidity);
  - working rebalancer operation and monitoring (out-of-range liquidity earns nothing until rebalanced).
  If these already pass, cap activation may be the only remaining transaction; if not, the fixes come first.
- No lending market lists these shares in v1. If one ever does: CF 0, borrowing disabled, excluded from every margin pair config, each enforced and tested in contracts.

### 3b. Track B: cash-only USDC/WAVAX lending

- Fresh Unitroller + Peridottroller with exactly two markets, `pUSDC` and `pWAVAX`, both borrowable. Rate models, reserve factors, supply and borrow caps from the capacity analysis; small at launch.
- **Delegate (decided): plain cash-only delegates for B's first release.** Deploying the paired delegate now would make B, and therefore C, wait for its accounting, reward and margin-integration review even with allocation disabled. Plain markets keep the first trading release focused.
- **Transition to D is explicit migration work, not a routine upgrade.** The Ramses reference delegate is documented for new deployments only and is not storage-compatible with other delegates, so it has **no established safe upgrade path** from a plain market. (That does not prove every upgrade is technically impossible; it means none is designed, reviewed or tested.) Before D activates, write and review one of: (a) new strategy-capable markets with a user-driven or incentivized move from the plain markets, including how open borrows and margin positions are handled; or (b) a specifically designed, storage-verified upgrade with its own tests, rehearsal and verifier. Pick in the D design phase.
- **Oracle for lending and margin alike**: a guarded price source over `AvalanchePriceOracle` that returns a price only from a valid live Chainlink round within max age, and **never** the emergency price. Any recovery valuation is a separate, explicitly permissioned and restricted path (shared risk model section 6), not a silent fallback. Required test: *AVAX feed stale, emergency price set → borrowing USDC against WAVAX still fails* (and the same for margin opens and liquidations).
- **Reserve requirements protect new risk, not exits.** The local borrowing reserve applies to **new borrows and margin opens**. It must never block repayment or authorized recovery. Specify per path:
  - repay and repay-on-behalf: always allowed, add cash;
  - normal voluntary close and normal liquidation that need to redeem pTokens for underlying: may consume reserved local cash down to zero for the amount required, because they reduce risk. The reserve threshold itself never blocks them;
  - when local cash cannot support the normal close or liquidation, an **explicitly authorized in-kind recovery path** may settle using externally supplied debt assets. Settlement requires sufficient funding and the applicable authorization and valuation checks. If those conditions fail, it **reverts atomically** without releasing collateral or corrupting debt accounting. The two recovery paths are separate:

    | Path | Funding and settlement |
    | --- | --- |
    | **Voluntary emergency close** | The owner supplies the debt asset, repays all accrued debt, then receives the remaining pToken claims through the debt-free exit (existing `exitDebtFreeToPTokens`). Any third-party financing needs explicit terms and authorization |
    | **Forced liquidation** | A funded liquidator supplies the debt asset and atomically receives the permitted collateral pTokens at a **trustworthy** liquidation valuation, and accepts the later redemption risk. This third-party funded liquidation is **new work** (shared risk model section 10) |

    **Neither path guarantees immediate withdrawal of underlying tokens.** Required tests: zero collateral-market cash; exhausted fallback funding (reverts atomically, state unchanged); missing or untrusted valuation (forced path reverts, voluntary debt-free exit still works); successful full repayment followed by pToken release;
  - ordinary supplier withdrawals: limited by available cash as usual (not by the reserve's protection of borrowing).
  Test each path at and below the reserve.
- **Borrowing is a credit launch.** Ordinary liquidation tests (underwater accounts in both directions, close factor and incentive, stale-feed behavior) and a funded, monitored liquidator must pass **before** borrowing is unpaused, even with allocation off.

### 3c. Track C: AVAX trading (legacy isolated margin)

- Deploy the legacy isolated-margin stack bound to track B's controller: executor, liquidator, risk engine, config, margin vault, account factory, flash vault, insurance fund, fee distributor.
- Router: `PharaohCLRouterAdapter` pinned to WAVAX/USDC. Price source: the guarded source from 3b.
- Pairs, following the executor's direction rules (LONG needs margin asset = debt asset; SHORT needs margin asset = position asset) and the live Robinhood configuration: **long** = margin `pUSDC`, position `pWAVAX`, debt `pUSDC`; **short** = margin `pUSDC`, position `pUSDC`, debt `pWAVAX`. Prove both with fork tests.
- Initial pair config: **2x**, 50% / 25% (the canary profile), small per-position and aggregate caps from the liquidation-capacity tool (shared risk model section 4; once D is active, our own LP liquidity counts only where it remains in the stress scenario).
- Flash vault funded in USDC and WAVAX to the caps; insurance fund seeded; funded in-kind fallback is new work (shared risk model section 10).
- **Margin opens must not depend on a strategy unwind, enforced in contracts.** Once D is active, the paired delegate can pull strategy liquidity during outgoing transfers. Test the entire open, including redeeming the user's margin pTokens and the borrow, with **strategy withdrawals unavailable**, and assert the market's local borrowing reserve still holds afterwards. Same for closes and liquidations, which must work from local cash or the funded fallback.

### 3d. Track D: paired Pharaoh strategy behind `pUSDC` / `pWAVAX`

Port of PeridotV2-Robinhood `feat/ramses-vaults`, verifying every Pharaoh difference on an Avalanche fork:

| Robinhood component | Avalanche port |
| --- | --- |
| `RamsesBoostedVault` | `PharaohPairedVault`, pair WAVAX/USDC |
| `RamsesV3PairedAdapter` / `RamsesVaultAdapter` | `PharaohV3PairedAdapter` against the Pharaoh position manager and pool; verify manager ABI (`tickSpacing`, `positions` fields), gauge `getReward` routing through the manager, swap callback name |
| `RamsesOracleGuard` (stock feed, USDG fixed at $1, stock pause flags, sessions) | `PharaohPairOracleGuard`: **two** Chainlink feeds (AVAX/USD, USDC/USD) with freshness and deviation per feed, no stock pause or session logic, pool-vs-oracle gates |
| `RamsesBoostedDelegate` + `RamsesMarketAccounting` | `PharaohPairedDelegate` + `PharaohMarketAccounting`, with the two fixes below |
| `RamsesLossReserve` | `PharaohLossReserve` |

**Two porting tasks found in the reference code:**

1. **The loss preview assumes the stable side is $1.** `RamsesMarketAccounting.assets` reads `pricesUSD18` but discards the second (USDG) price and values the stable side as `amount × 1e12`. If only the guard switches to a real USDC/USD feed, previews and accounting disagree. Use the oracle's USDC price everywhere: previews, checkpoints, exchange rates, margin valuation. Add **USDC depeg tests** (e.g. USDC at $0.98 and $0.90) across all of them.
2. **The delegate re-applies ordinary CF checks.** `RamsesBoostedDelegate.doTransferOut` calls the controller's `getAccountLiquidity` after checkpointing a borrow, which computes ordinary CF-based liquidity. For registered isolated-margin accounts that would override the margin pair config (shared risk model section 5a). The port must keep the margin-specific health checks for margin accounts and the ordinary check for everyone else. **The borrow is already recorded when `doTransferOut` runs**, so the post-checkpoint check for margin accounts must evaluate health on the **already-recorded** debt (e.g. a risk-engine view of current metrics), and must not call `borrowAllowed` or any path that adds the same borrow amount again. Health validation must not be removed either. Required regression test for this exact sequence: margin account borrows, checkpoint changes NAV, post-checkpoint check passes or fails on recorded debt exactly once, for both account types.

Market-layer guarantees (shared risk model sections 4, 6 and 8): separate cash target and borrowing reserve per token; only capped, eligible amounts enter the strategy (per-side cap, pair value cap, capacity share of active liquidity); oracle-anchored unwinds for withdrawals and borrows; PHAR by the entitlement index of section 8a (claim-first, pass-through, quarantine), losses by the vault's pro-rata oracle-valued rule; withdrawal and liquidation capacity measured **per token**; PHAR never in NAV until sold under the implemented policy.

Range policy and keeper: the Robinhood dual-range design (handoff 01 sections 6 and 8), with a much wider starting grid for AVAX (core ±3% to ±10%, backup ±15% to ±30%), chosen by the backtest.

## 4. Gates per track

| Track | Gates |
| --- | --- |
| A | Fair-entry/exit tests around harvests on the real vault code; exits at proposed caps under stressed pool liquidity; rebalancer operation and monitoring; caps decided |
| B | Guarded oracle with the emergency-price test; plain cash-only delegates; reserve-vs-recovery path tests; ordinary liquidation tests; funded liquidator live; monitoring |
| C | Full legacy-margin lifecycle on an Avalanche fork through `PharaohCLRouterAdapter` (open, partial and full close, partial and full liquidation, both directions); stressed and correlated liquidations; flash vault and insurance funded; funded fallback; guarded-oracle tests incl. emergency price |
| D | Reviewed transition from B's plain markets (3b); fee and reward entitlement fork test (what reaches the vault, PHAR vs xPHAR, period length, mid-period mint behavior, whether the pending view equals a claim); backtest with one P&L ledger, no fee income, PHAR emissions stressed in **quantity and vote share** as well as price, our capital at several sizes, ending in a profitable-capacity sentence; ported Ramses suites plus the USDC depeg and margin-account tests above; shared risk model section 8 and 8a proofs; per-token withdrawal capacity; unwind-independence test for margin |
| All | Governance acceptance of Pharaoh's multisig, timelock and AccessHub powers (the WAVAX/USDC fee already moved from 800 to 490 ppm); adversarial review |

## 5. Next engineering checkpoint (before any mainnet date)

A reproducible Avalanche fork test (pinned block, private archive RPC if needed) demonstrating, with plain cash-only B markets and the legacy margin stack:

- supply and ordinary borrowing in both directions (USDC against WAVAX, WAVAX against USDC), and ordinary liquidations;
- AVAX long and short opens, partial and full closes, partial and full liquidations through `PharaohCLRouterAdapter`;
- stale feeds with emergency prices set still blocking normal risk-increasing actions **and** normal liquidation;
- repayment and the defined recovery paths (reserve consumption by closes and liquidations, funded fallback, debt-free exit) continuing to work;
- actual funding requirements (flash vault, insurance, liquidator), execution costs and resulting position health at the proposed caps.

The mainnet date is assessed from that demonstrated behavior and the remaining blockers.

## 6. One-week plan

Start A, B and C in parallel; D's port and fork tests run alongside. Whether each track activates within the week depends on its tests and funding; there is not enough evidence to call any of them guaranteed or impossible.

- **A:** run the fairness, exit and keeper tests against the real vaults; if they pass, raise caps.
- **B:** deploy with plain cash-only delegates, borrowing paused; unpause after the oracle and liquidation gates and with the liquidator funded.
- **C:** deploy paused; activate at 2x with small caps after its lifecycle and liquidation gates and funding.
- **D:** port, fork tests, backtest, and the transition design from 3b. Enable allocation only after its gates; if the backtest is not positive, B and C continue cash-only and A stays in its own strategies.

Leveraged margin was deliberately kept out of the initial Avalanche grant milestones because of its security surface; keep track C behind its own activation and audit scope unless the operator decides otherwise.

## 7. Working rules

Same as handoffs 01 and 06: Foundry, the repo's pinned profiles (`debt_accounting`, `--threads 1`, the documented `--skip` list for the LayerZero files), EIP-170 size gates, pinned-block fork tests with a private archive RPC when the public one prunes, mutation checks for every safeguard, adversarial second-model review, the operator signs every mainnet transaction with their own keystore, no private keys or passwords in files or chat. Never reuse BNB, Monad, Fuji or Robinhood addresses because a label matches.

## 8. Open operator decisions

1. Track D transition method (new markets plus migration, or a designed storage-verified upgrade), decided in the D design phase. (Decided: B launches with plain cash-only delegates.)
2. Track A caps, and whether USDt / sAVAX deposit routes are wanted later.
3. Track B parameters: rate models, reserve factors, caps, cash target and borrowing reserve per market.
4. Track C pair configs, caps, flash vault and insurance funding, liquidator operator.
5. Track D: PHAR handling for suppliers (claim in kind / claim-and-swap, or guarded protocol sale), and whether allocation ships if the backtest is only marginally positive.

Sources: repo files listed above on `boosted-findings-remediation`; PeridotV2-Robinhood `feat/ramses-vaults` (`RamsesMarketAccounting.sol`, `RamsesBoostedDelegate.sol`); Pharaoh contract addresses (docs.phar.gg/pages/contract-addresses); Pharaoh/Kingdom pools API (`gateway.kingdom.dev/avalanche/api/pools`).
