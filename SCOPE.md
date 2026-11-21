# pSPY as plain lending collateral (feat/spy-collateral, base feat/spy-margin 63633d50)

Status: SCOPE + BUILD. Nothing sent on mainnet. No key or keystore read.
Reads are at Robinhood L2 block 118544686 (Thu 2026-11-19 ~21:45 UTC) unless a row says otherwise.
Tags: **[chain]** on-chain read, **[src]** source file/function, **[assumed]** not verified yet.

Prerequisite: the SPY margin ceremony (`tools/spy/ceremony.sh`, feat/spy-margin) has run. It lists pSPY 0xa666 on controller
0x6148 with CF 0, borrowing paused, controller oracle = adapter3 0x74f1, and SPY registered in lending oracle 0x266F. This
ceremony runs AFTER that, never before (preflight refuses otherwise).

---

## 0. Decisions in one screen

| Question | Recommendation |
| --- | --- |
| Collateral factor | **30 %** on pSPY (`_setCollateralFactor`, direct Ledger). pNVDA/pUSDG stay at 80 % [chain]. |
| Stale / weekend fail-closed | **In pSPY, not in the controller oracle.** A new pSPY implementation `RobinhoodSpyCollateralDelegate` makes `getAccountSnapshot(account)` return a nonzero error code while `SpyMarginPriceSource.stockPrice()` reason != 0 (closed window, stale > 90000 s, SPY paused / oraclePaused, bad round, lending mismatch), **for accounts holding pSPY that are not isolated-margin accounts**. The controller's liquidity loop then returns `SNAPSHOT_ERROR`, so borrow / redeem / transfer / exitMarket / liquidateBorrow all fail closed for such accounts; `repayBorrow`, `mint` and `seize`-free paths read no snapshot and keep working. No second `_setPriceOracle` on live NVDA; adapter3 stays. |
| Why not "adapter returns 0" | Price 0 trips `PRICE_ERROR` for **every account that entered pSPY, whatever its balance**, and `enterMarkets` is permissionless. A pNVDA-collateral borrower could enter pSPY with zero balance and be unliquidatable all weekend while the NVDA 24/7 feed moves. The snapshot gate only bites accounts that actually hold pSPY (see risk R2 for the dust residue). It also avoids touching the controller oracle again. |
| Borrow-cap mechanism | **pSPY lending supply cap in the delegate**, applied to mints by **non-margin** minters only, measured against total pSPY supply in SPY (`totalSupply * exchangeRate`). Margin opens (the margin account is the minter [src `IsolatedMarginAccount.mint`]) are never blocked, and lending suppliers cannot block SPY margin. Admin setter `_setLendingSupplyCap` (Ledger, direct) and the initial value set atomically in `_becomeImplementation(abi.encode(cap))`. |
| Why not a pUSDG borrowCap | `borrowCaps[pUSDG]` = 1,000 USDG is market-wide and compared against `pUSDG.totalBorrows()`, which includes margin debt (98.94 USDG, of which position 6 = 97.97) [chain, src `Peridottroller.borrowAllowed`]. Tightening it throttles NVDA and SPY margin. Left at 1,000. |
| Proposed cap | **0.23 SPY** (~$165 at $716.12 [chain feed]) ⇒ SPY-backed lending borrow ≤ 0.30 × $165 ≈ **$49.5** when no margin pSPY exists. Honest bound: it is "at most ~$50", not an exact $50 cap; see R3 (margin pSPY consumes headroom; in-kind margin exits can add pSPY outside the cap). |
| Liquidation | New immutable, no-admin **`SpyCollateralLiquidator`**: flash USDG from the live flash vault 0x79d3 (5 bp, permissionless receiver [src]), `pUSDG.liquidateBorrow(borrower, repay, pSPY)`, redeem seized pSPY, swap SPY→USDG through the live router adapter 0xa32C (needs Ledger `setOperator(liquidator, true)`), repay flash, **profit to the Ledger** (immutable beneficiary). Keeper holds no inventory and pays gas only, with one fixed `to`. |
| Keeper | Margin keeper (branch off cefe964 = deployed robinhood-margin-keeper-v1) gains a lending module: discover accounts via `MarketEntered(pSPY, account)` logs (full history served in 10M-block chunks [chain]), skip while `getAccountLiquidity` errors (closed/stale), liquidate on shortfall via the helper. Lending read failures never stop margin liquidation. |
| Timelock / delay | **None.** Controller admin, pSPY admin, router-adapter owner are the Ledger directly [chain]. No mandatory 1 h delay (no config queue involved). |
| Effort | **~4.5 working days** to ceremony-ready (section 7). Ceremony: 1 deployer-funding signature + **3 setup signatures** (+ optional 6 demo), one window, weekday session with a fresh feed. |

---

## 1. How the controller treats pSPY [src `Peridottroller.sol`, identical to the frozen snapshot]

- Margin accounts (`isolatedMarginAccounts[a]`) are routed to the risk-engine hook in `borrowAllowed/redeemAllowed/transferAllowed`; `liquidateBorrowAllowed` and `seizeAllowed` refuse them outright. They never reach `getHypotheticalAccountLiquidityInternal`, so **CF and the snapshot gate do not affect SPY or NVDA margin positions**. The delegate additionally exempts margin accounts from the gate so lens/keeper reads of them are unchanged.
- The liquidity loop calls `asset.getAccountSnapshot(account)` and `oracle.getUnderlyingPrice(asset)` for every entered asset; `oErr != 0` ⇒ `SNAPSHOT_ERROR`, price 0 ⇒ `PRICE_ERROR`.
- `repayBorrowAllowed`: no liquidity, no price. **Repay always works.**
- `mintAllowed`: no supply cap, no price. Mint stays open (adds collateral).
- `liquidateBorrowAllowed` → `getAccountLiquidityInternal(borrower)` → gate ⇒ no liquidation while closed/stale. `liquidateCalculateSeizeTokens` uses adapter3's 0x266F price; that path is only reachable when the gate passed in the same transaction, and the SPY source requires `0x266F.assetPrices(SPY) == feed price` (lending parity), so the seize price equals the fresh feed.
- `_setCollateralFactor` refuses (error code, no revert) when the price is 0; adapter3 serves 0x266F's cached price, so it succeeds — the ceremony gates freshness itself and verifies `markets(pSPY)` after.
- `closeFactor` 50 %, liquidation incentive 8 %, `protocolSeizeShare` 2.8 % [chain, src].
- PToken change: `PToken.getAccountSnapshot` becomes `virtual` (one keyword; no executable change for any contract that does not override it; DeploySpyMargin's verify is identity-based, not runtime-hash, so it is unaffected).

### 1.1 Behaviour table (account = non-margin, entered in pSPY, holds pSPY)

| Operation | SPY fresh, in session | SPY closed / stale |
| --- | --- | --- |
| `pUSDG.borrow` / `pNVDA.borrow` | liquidity check at CF 30 % | **reverts / error** (SNAPSHOT_ERROR) |
| `pSPY.redeem*`, `pNVDA.redeem*`, `pUSDG.redeem*` | liquidity check | **refused** |
| pToken `transfer` from the account | liquidity check | **refused** |
| `exitMarket(pSPY)` | liquidity check | **refused** (snapshot error) |
| `pUSDG.repayBorrow` / `repayBorrowBehalf` | works | **works** |
| `pSPY.mint` | works (cap) | works (cap) |
| `liquidateBorrow(..., pSPY)` | works on shortfall | **refused** |
| pNVDA-only accounts (never entered pSPY or hold 0 pSPY) | unchanged | unchanged |
| margin accounts | unchanged | unchanged (margin's own SPY rules) |

Deviation from SPY margin: a debt-free entered account cannot redeem at weekends (margin's debt-free in-kind exit can). Borrow
and redeem cannot be told apart inside a view snapshot, so allowing it would allow new borrows on a stale price. Frontend must
not auto-enter pSPY on supply, and must show "SPY market closed: repay only".

---

## 2. What changes

**Contracts (`contracts/margin/spy/`, profile `robinhood_spy`)**
1. `RobinhoodSpyCollateralDelegate is PErc20Delegate`: the two October corrections (ZeroSharesMinted, round-up redeemUnderlying) + snapshot gate + `seize` gate + lending supply cap. Appended storage: one `uint256 lendingSupplyCap` after `implementation` (layout check in tests). Immutable `spySource`.
2. `SpyCollateralLiquidator`: immutable flash-liquidation helper (above).
3. `PToken.getAccountSnapshot` and `PToken.seize`: `virtual`.

**Keeper (new branch `margin-keeper-spy-collateral` off cefe964, worktree `RobinhoodVaults/.wt-margin-keeper-collateral`)**: lending discovery + plan + execution policy (`to == SPY_COLLATERAL_LIQUIDATOR`, fixed calldata shape), journal ids ≥ 1e12 in the existing table, margin `unresolved()` ignores them, gas cap unchanged 12M, runtime pins for the two new contracts added after deployment (pin file ships empty ⇒ module off).

**Frontend**: CF 30 %; "SPY closed / stale: repay only, no borrow/withdraw/exit"; `getAccountSnapshot` may return error code 1-8 (= SPY source reason); lending supply cap ("SPY collateral full"); do not auto-enter pSPY.

---

## 3. Risks

- **R1 Weekend gap with liquidation off.** At CF 30 % an all-SPY account goes underwater only at −70 %. Bounded by the cap (~$50 debt).
- **R2 Dust freeze/escape.** Any non-margin account holding ≥ 1 wei pSPY and entered is frozen while SPY is closed, including liquidation of its NVDA collateral. A pNVDA borrower can therefore buy weekend non-liquidatability for ~$0.01 of pSPY. Today's ordinary (non-margin) pUSDG debt is ~0.97 USDG and pNVDA debt is dust [chain]; there is no ordinary-lending liquidation keeper today anyway. A real fix needs a controller upgrade (count unpriced collateral as zero for the liquidation check). Operator sign-off requested.
- **R3 Cap is a bound, not exact.** Margin-held pSPY counts against it (a $100 SPY margin long leaves ~$65 of lending headroom); pSPY received from margin `exitDebtFreeToPTokens` or bought from a margin account is outside the mint gate. Real ceiling is also pUSDG cash (~28 USDG + 80 from the margin ceremony), shared with margin.
- **R4 Live adapter trust set.** `setOperator(liquidator)` on 0xa32C: an operator can pull tokens from any `fromAccount` that approved the adapter. The liquidator only ever passes `address(this)`, is immutable, and has no admin.
- **R5 Thin market inflation.** Dead seed 0.0001 SPY (5e5 shares). Donation to pSPY raises the exchange rate for everyone; covered by a fork test at CF 30 %.
- **R6 Keeper wallet = margin keeper wallet**; a lending tx shares its nonce. Ambiguous lending submission ⇒ operator_attention for both (correct: nonce uncertainty). Read/stale failures are isolated.
- **R8 Non-USDG debt against pSPY.** pNVDA borrowing is open, so an account can borrow NVDA against pSPY. The liquidator repays pUSDG only, so that debt has no automated liquidation path. The keeper reports it as `lending_unsupported_shortfall`. Options: accept it under the cap, or extend the liquidator later. pNVDA borrowing cannot be paused for pSPY accounts alone.
- **R9 Un-entered holders.** `seizeAllowed` has no membership check, so another market's shortfall could seize un-entered pSPY at the cached lending price at weekends. Closed by gating `pSPY.seize` itself while SPY is withheld (unit and fork tested).
- **R7 Rollback**: setting CF back to 0 makes SPY-backed borrowers instantly liquidatable (when fresh). Rollback order: cap 0 first, then CF 0 once SPY-backed debt is repaid.

---

## 7. Day estimate

| # | Item | Days |
| --- | --- | --- |
| 1 | Delegate (gate, cap, corrections), PToken `virtual`, liquidator; unit tests + mutants; size check | 1.25 |
| 2 | Fork tests on the margin ceremony: borrow at 30 %, cap, weekend/stale (borrow+redeem revert, repay works), liquidation fresh, NVDA-only parity, SPY margin unaffected, inflation | 1.25 |
| 3 | Keeper lending module + tests + anvil keeper run | 1.0 |
| 4 | `tools/spy-collateral/ceremony.sh` + anvil rehearsal on top of the margin rehearsal | 0.75 |
| 5 | Evidence README, frontend note | 0.25 |
| | **Total** | **~4.5** |

Ceremony must be in a weekday session with a fresh SPY feed (the CF call and the demo need it), after the SPY margin ceremony.

---

## 8. Draft ceremony list (after SPY margin enable; all direct Ledger calls; no timelock; no mandatory delay)

| # | Who | Target | Call |
| --- | --- | --- | --- |
| D0 | Ledger | throwaway deployer | fund ~0.0002 ETH |
| D1-2 | deployer | — | deploy `RobinhoodSpyCollateralDelegate(spySource)`, `SpyCollateralLiquidator(...)`; verify identity; sweep |
| 1 | Ledger | pSPY 0xa666 | `_setImplementation(delegate, false, abi.encode(cap))` — then verify implementation, cap, supply/rate unchanged, margin positions unchanged |
| 2 | Ledger | router adapter 0xa32C | `setOperator(liquidator, true)` |
| 3 | Ledger | controller 0x6148 | `_setCollateralFactor(pSPY, 0.30e18)` — error code, verify `markets(pSPY)` |
| demo (optional) | Ledger | SPY, pSPY, controller, pUSDG | approve, mint, `enterMarkets([pSPY])`, `borrow`, approve USDG, `repayBorrow(max)`, then `redeem` + `exitMarket` so the Ledger is not frozen at weekends. The Ledger holds only ~0.00005 SPY after the margin seed, so the demo is ~$0.01 unless it buys SPY first. |
| rollback | Ledger | pSPY / controller / adapter | `_setLendingSupplyCap(0)`; `_setCollateralFactor(pSPY,0)` once SPY-backed debt is 0; `setOperator(liquidator,false)` |

Final list, gas per step and rehearsal log: see `contracts/deployments/spy-collateral/README.md` once built.

---

## 9. Final ceremony list (built and rehearsed; `contracts/tools/spy-collateral/ceremony.sh <margin journal> <collateral journal> <phase>`)

Runs AFTER the SPY margin ceremony, in one weekday session with a fresh RHSPY feed (preflight refuses otherwise). Every
step is a **direct Ledger call**: there is no timelock operation and no mandatory delay. Compound-style calls return error
codes, so the script verifies the state after each one.

| # | Phase | Signer | Target | Call | Gas (rehearsal) |
| --- | --- | --- | --- | --- | --- |
| D0 | (before) | Ledger | throwaway deployer | fund ~0.0002 ETH | ~21,000 |
| D1-D2 | (before) | deployer | — | `DeploySpyCollateral.s.sol --broadcast`: delegate + liquidator, writes `deployments/spy-collateral/spy-collateral-mainnet.json`; sweep after | 2 txs, 0.00001 ETH |
| — | `preflight` | — | — | read-only: Ledger admins, SPY margin ceremony done, pSPY still on the plain delegate, SPY session open and feed < 1 h, deploy verify, untouched-state snapshot | — |
| 1 | `t0` | Ledger | pSPY 0xa666 | `_setImplementation(delegate, false, abi.encode(230000000000000000))` + verify impl, cap, slot 21, untouched state | 60,236 |
| 2 | `t0` | Ledger | router adapter 0xa32C | `setOperator(liquidator, true)` | 47,780 |
| 3 | `t0` | Ledger | controller 0x6148 | `_setCollateralFactor(pSPY, 300000000000000000)` + verify markets, untouched state | 79,285 |
| D1-D4 | `demo-open` (optional) | Ledger | SPY / pSPY / controller / pUSDG | approve, mint (all Ledger SPY, ~0.0000477), enterMarkets, borrow 80 % of power (~0.008 USDG) | 903,306 total |
| D5-D9 | `demo-close` (optional, same day, before Saturday) | Ledger | USDG / pUSDG / pSPY / controller | approve, repayBorrow(max), approve 0, redeem, exitMarket | 912,916 total |
| — | `verify`, `closed-check` | — | — | read-only (closed-check in the weekend window, with an ACCOUNT that holds pSPY) | — |
| R1-R3 | `rollback` | Ledger | pSPY / controller / adapter | `_setLendingSupplyCap(0)`; with ROLLBACK_CF=yes: `_setCollateralFactor(pSPY,0)`, `setOperator(liquidator,false)` | 31,418 / 35,177 / 25,868 |

Setup: 1 funding + **3 Ledger signatures**. With the demo: 12. At 0.02 gwei the whole list costs under 0.00005 ETH.

After the ceremony (keeper, `.wt-margin-keeper-collateral` branch `margin-keeper-spy-collateral`):
1. Write `deployments/spy-collateral/keeper.json` with the deployed liquidator and delegate addresses and their runtime hashes, and the ceremony block.
2. Merge onto robinhood-margin-keeper-v1.
3. Set `LENDING_LIQUIDATIONS=true`.
4. Force-rebuild the app.

None of the existing margin pins change: the keeper pins no pSPY state, and steps 1-3 change only storage on the pSPY delegator, the controller and the adapter.

Unverified / open: the operator's sign-off on R2 (the dust freeze) and R3 (the cap is a bound, not exact); live pool depth for a SPY→USDG liquidation swap at a weekend reopen (the fork pool was unmoved); and the DigitalOcean deploy of the keeper change (not done, by instruction).


## 10. Operator decisions 2026-11-21 (implemented)

1. The weekend freeze is accepted at these caps.
2. **Debt-free holders withdraw while SPY is closed or stale.**
   - Only pSPY holders with a borrow balance in any controller market are frozen.
   - Debt-free holders see SPY valued at zero, so they can redeem, transfer and exitMarket, but cannot borrow against SPY.
   - Seize stays gated.
   - This replaces the "debt-free entered holders cannot redeem" deviation in §1.1, and the frontend no longer has to avoid auto-entering pSPY.
3. **NVDA debt against pSPY is liquidated** by `SpyCollateralLiquidator.liquidateNvdaDebt` (USDG flash, USDG to NVDA, liquidate, SPY to USDG). The keeper plans and executes it. R8 is closed.
4. Cap 0.23 SPY and CF 30 % are confirmed.
5. Demo sizing: see `contracts/deployments/spy-collateral/README.md`.
   - The Ledger needs 0.045 SPY, so it buys 0.04495 SPY for ≤ 31.8 USDG.
   - That needs ~5.6 USDG more than the wallet holds after the margin t1, for example by redeeming ~6 USDG of pUSDG first.
   - ETH needed is ~0.00005.

Ceremony list unchanged: 3 direct Ledger calls (plus the optional SPY buy and demo). Remaining estimate: ~0.5 day after the parent's gate rehearsal (evidence README, frontend note refresh).
