# Avalanche margin 2x: frontend handoff

Status: **LIVE on Avalanche C-Chain (43114) since block 100,015,218 (11 Nov 2026, 10:32:05 UTC).** Opens are unpaused. No position had been opened when this was written (`executor.nextPositionId() == 1`), so none of the flows below has been run by a user on mainnet; they were run on a mainnet fork (`contracts/test/AvalancheMarginMainnetRehearsalFork.t.sol`). Where this document cannot tell from the source, it says **unverified**.

Machine-readable addresses and live parameters: `docs/deployment-handoffs/avalanche-pilot-addresses.json`, key `margin`. ABIs: `docs/deployment-handoffs/avalanche-pilot-abis/` (listed in `margin.abis.files`; the runtime bytecode of every contract they describe was compared with the deployed code, see section 12). Every signature below was generated from those ABI files. Human-readable addresses: `contracts/addresses.MD` (margin subsection).

## 1. The product in one paragraph

A user puts **USDC** in as margin and gets a **long WAVAX position of up to 2x** (default ask: 2x). The position lives in its **own isolated account** (a minimal clone, one per position), so one position can never be liquidated by another's loss. The extra USDC is **borrowed from the pUSDC lending market** (the same market the lending pilot uses), funded in the same transaction by a USDC flash loan, and the whole open is **one transaction** through the executor. The swap WAVAX/USDC goes through **one pinned pool** (Pharaoh CL, tick spacing 10); the user cannot choose a route. Fees (open, close) are **0**. Nothing here is a yield product and nothing in the UI may promise or forecast a return.

Only one pair exists: margin = debt = USDC (as pUSDC shares), position = WAVAX (pWAVAX). Every other pair, including the reverse (short WAVAX), reads `enabled = false` on chain, and WAVAX borrowing is paused on the controller.

## 2. Units you will trip over

| Thing | Unit |
| --- | --- |
| USDC | 6 decimals |
| WAVAX | 18 decimals |
| pUSDC, pWAVAX (pTokens) | **8 decimals**; value = `pTokens * exchangeRateStored / 1e18` underlying units (pUSDC rate is about 2e14 at launch, so 1 USDC is about 5e9 raw units, i.e. 50 pUSDC) |
| Margin amount in every call | **pUSDC shares**, not USDC |
| USD values from the risk engine (`getMetrics`, caps) | 1e18 scale |
| Oracle price (`oracle.getPrice(asset)`) | USD per whole token, 1e18 scale (WAVAX about 8.70e18 when read) |
| `leverageX100` | 200 = 2.00x; accepted range is greater than 100 and at most 200 |
| `healthFactorBps` | 10,000 = 100%; see section 7 |
| Order prices | USD per WAVAX, 1e18 scale |

## 3. Addresses

All proxies are OpenZeppelin transparent proxies; call the proxy with the ABI of its implementation. Owner of everything is the Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` (an EOA, not the Safe; the config's risk-increasing changes are queued with a 24 h delay, brakes and proxy upgrades are immediate owner calls).

| Contract | Address | Purpose |
| --- | --- | --- |
| IsolatedMarginExecutorUpgradeable (proxy) | `0x445D51c8A684139e0Ec215C3Ed827D94Ee8b53af` | **Call this.** Open, add margin, repay, close, `positions(id)`. |
| IsolatedMarginVaultUpgradeable (proxy) | `0x64DD15BD97aA41AAb46B963AFcBd2120f54fe0Ce` | **Call this.** Margin deposits (pUSDC shares): `deposit`, `withdraw`, balances. |
| IsolatedMarginQuoter | `0x066328FDCB526F57E69b2Ee2C196dE7a8465023E` | Read: `quoteOpen`, `expectedOut`, prices. |
| IsolatedMarginRiskEngineUpgradeable (proxy) | `0xE022c90DB98ea8B1615c5B422Cbf46878B76a470` | Read: `getMetrics`, `isLiquidatable`; also the controller's isolated-margin risk hook. |
| IsolatedMarginConfigUpgradeable (proxy) | `0x5d59C647CC4bD6C05b4E9205c23062d490699631` | Read: `getPairRisk`, `opensPaused`, fees, funded-liquidator allowlist. |
| MarginOrderRegistry (proxy) | `0x4676C8Cf50CEd18683d255faEC4DaA882cbef440` | **Call this.** Take-profit / stop-loss orders. |
| AvalancheMarginCloseAdapter | `0x669715b4fcb5731554fF79C67931DC4f821A9de8` | Registry's close path (`executor.orderExecutor`); reads `oraclePriceE18(positionId)`. |
| IsolatedMarginLiquidatorUpgradeable (proxy) | `0xaB9B345A32a338B15C2Bde6EFB0B42CDDFee3578` | Liquidations (`liquidateFunded` for the two operators); events and errors to decode. |
| SimpleFlashLoanVault | `0x73B06542582e650925461194183C4882f6C0475b` | USDC flash lender (fee 0, 100 USDC); the executor borrows from it inside each open/close. |
| IsolatedMarginSwapModule | `0x07206bC8700Ea518c57C11AAa691Af27c060ed98` | Applies the slippage and oracle bounds to every swap; `SwapError` codes. |
| PharaohCLRouterAdapter | `0x727b6F8FAc93b200CD9e04684D72193E546A04Be` | The single swap route (Pharaoh CL WAVAX/USDC pool, tick spacing 10); swap data must be empty. |
| IsolatedMarginAccountFactory | `0xa52982C91D4dAA063820E11f9a5Dac19C53f33d2` | Deploys one isolated account per position. |
| MarginFeeDistributorUpgradeable (proxy) | `0xdEF32Cd4095907146cA977FD18C07f44cb9a8eEE` | Margin fee splitter (fees are 0 in the pilot). |
| MarginInsuranceFundUpgradeable (proxy) | `0x8CbFF3c556B182bCaf4ba02257D5f9B8f994794E` | Insurance fund (10 USDC as pUSDC); not used by the funded liquidation route. |
| GuardedAvalanchePriceOracle | `0x7BAB5406Cb4929f9b9492e1b2a43b65BF93AaFC0` | The PW30 guarded price oracle (shared with lending; `getPrice(asset)`). |
| IsolatedMarginExecutorUpgradeable (implementation) | `0xc62dF326F43AAc75fDc2Bb5FC9658C8da17736f0` | Implementation behind the executor proxy; do not call. |
| MarginOrderRegistry (implementation) | `0xA744A226C9C29586Dd949BE5d53f0D0dD503a7D3` | Implementation behind the registry proxy; do not call. |
| IsolatedMarginAccount (implementation) | `0x46Fdf5F52FF596898c9c9d1566aC338aDDddFBDC` | Cloned once per position; the position's own account is `positions(id).account`. |
| pUSDC (PErc20Delegator) | `0x0f7849CD9E54ffb027aacaEec82007cca9470098` | Margin shares, the debt market; `mint`, `approve`, `redeem`, rates. |
| pWAVAX (PErc20Delegator) | `0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1` | The position token held by each account. |
| USDC | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` | Native USDC, 6 decimals. |
| WAVAX | `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7` | 18 decimals. |
| Controller (Unitroller) | `0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A` | Lending controller; `isolatedMarginRiskHook()`, `borrowCaps`, `borrowCashFloor`. |
| Funded liquidator 1 (operator wallet) | `0xA7640fc537E2172eD6c4b4A809C9456AbD60fbF4` | May call `liquidateFunded`; not a contract. |
| Funded liquidator 2 (operator wallet) | `0xfbb137eBcBb0F7eb2Ba70F59ff0be9B0A0c5125d` | Same. |
| Owner / admin (the Ledger, EOA) | `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` | Owns config, risk engine, vault, flash vault, every proxy admin; registry admin. |
| Swap pool (Pharaoh CL) | `0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534` | The pool the adapter swaps in; router `0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c`. |

Proxy admins (OpenZeppelin `ProxyAdmin`, all owned by the Ledger; never call) and the other implementations, for explorers and indexers:

| Proxy | Proxy admin | Implementation |
| --- | --- | --- |
| insuranceFund | `0x52d97630dd4a068dCba7F682104303936A4e35Ad` | `0xe6b6A5AE4014EDe51e75aAfbeA9F7d9B00FDF9de` |
| config | `0x8181e2B29650Ae720e04921595b652270815f77D` | `0x42F851C85F8F22d09c8f961dFe2c87089a56DD12` |
| feeDistributor | `0xd6B94eB6FFD84EDE12e1e24996Ac6b3b8a58cbDA` | `0xD04446addc59Ca898b86044052176f19331E15D6` |
| vault | `0x4E8bE4DBf8cB52f177985c68Ded3bf7D35d2dA80` | `0x14cA44ad40276078E10cA654Ec5AF5083484Bc62` |
| riskEngine | `0x632eFea26E42ae95f3a6b71E622cE3AbCb6a1E2e` | `0x98B5d2b3cFC88C2a9228d4036E7938F843F714E2` |
| executor | `0x5c82dDF8DbB64Fbd9b4D8f81848e34A829aeD514` | `0xc62dF326F43AAc75fDc2Bb5FC9658C8da17736f0` |
| liquidator | `0x95B32444D03262F0AEc106f3B74101Fe5Ac3Ff39` | `0xb819F206607D448b0768081Af60bF11F0cE61B37` |
| orderRegistry | `0xCd313165f45E47ef4124ab86A314DE9B78c5A068` | `0xA744A226C9C29586Dd949BE5d53f0D0dD503a7D3` |

## 4. User flow, with the exact calls

Notation: `P_USDC` is pUSDC, `P_WAVAX` is pWAVAX (addresses under `lending.markets` in the JSON). Pool-token calls use `PErc20Delegator.json`. Margin deposit goes **through pUSDC shares and the margin vault**: the user does not hand USDC to the executor.

### 4.1 Open a position

1. **Pre-checks (reads).** Disable the button when any of these is true:
   - `config.opensPaused()` is true;
   - `config.getPairRisk(P_USDC, P_WAVAX, P_USDC).enabled` is false;
   - the controller says WAVAX borrowing is unpaused (`borrowGuardianPaused(P_WAVAX)` false: the product is long-only only while it is paused);
   - pUSDC headroom is too small (section 6: shared with lending).
2. **USDC approval and supply.** `USDC.approve(P_USDC, usdcAmount)`, then `P_USDC.mint(uint256 mintAmount) returns (uint256)` (0 on success; a rejection reverts with `MintPeridottrollerRejection`). The user receives pUSDC shares: read the pUSDC balance before and after rather than computing the shares.
3. **Approve and deposit the shares into the margin vault.** `P_USDC.approve(vault, shares)`, then `vault.deposit(address pToken, uint256 amount)` with `pToken = P_USDC`. This credits `vault.freeBalance(user, P_USDC)`.
4. **Quote.** `marginUnderlying = shares * P_USDC.exchangeRateCurrent() / 1e18` (use an `eth_call` of `exchangeRateCurrent`, a non-view function; the executor accrues interest first, so the stored rate can be slightly stale). Then
   `quoter.quoteOpen(address marginPToken, address positionPToken, address debtPToken, uint256 marginUnderlying, uint16 leverageX100) returns (uint256 flashAmount, uint256 minPositionUnderlying)`
   with `(P_USDC, P_WAVAX, P_USDC, marginUnderlying, 200)`. `flashAmount` is the USDC that will be borrowed (the debt, since the flash fee is 0); `minPositionUnderlying` is the minimum WAVAX (18 decimals) the swap must return. Example read at launch: margin 10 USDC gives a flash amount of 9.80 USDC and a minimum of 2.2533 WAVAX. The quote is **conservative** (it reserves the 1% swap bound), so the opened leverage is a little under 2x; show "up to 2x".
5. **Open.** `executor.openPosition((address marginPToken, address positionPToken, address debtPToken, uint256 marginPTokenAmount, uint16 leverageX100, uint256 maxOpeningFeePToken, uint256 minPositionUnderlying, uint8 side, bytes swapData) params) returns (uint256 positionId)` with
   - `marginPToken = P_USDC`, `positionPToken = P_WAVAX`, `debtPToken = P_USDC`;
   - `marginPTokenAmount = shares` (must not exceed `vault.freeBalance`);
   - `leverageX100 = 200` (or any value above 100 up to 200);
   - `maxOpeningFeePToken = 0` while `config.openFeeBps() == 0` (otherwise compute with `quoter.feePToken`);
   - `minPositionUnderlying` = the second quote output (a **higher** value tightens slippage but can make the swap revert; a lower non-zero value is refused with `SwapError(5)`, and 0 with `ExecutorError(11)`);
   - `side = 0` (LONG);
   - `swapData = 0x` (**must be empty**: the adapter refuses anything else).
   Always `eth_call` (simulate) the transaction first and show the decoded revert. **Quote immediately before sending.** The swap module recomputes its floor from the oracle price at execution, so if the WAVAX oracle moves down (or interest accrues) between your quote and inclusion, the quoted minimum can fall below the floor and the open reverts with `SwapError(5)` (or `SwapError(7)` if you set a tight minimum): on 5 or 7, re-quote and resend.
6. **Read the result.** The `PositionOpened` event carries `positionId`, `account`, `borrowedAmount`, `grossAssetValueUsd`, `leverageX100`, `healthFactorBps`. Then `executor.positions(positionId)`.

### 4.2 Add margin

`vault.deposit(P_USDC, shares)` (steps 2 and 3 above), then `executor.addCollateral(uint256 positionId, uint256 marginPTokenAmount)`. Only the owner of an ACTIVE position can call it. It moves free vault balance into the position's account and raises the health factor; the caps are **not** re-checked.

### 4.3 Repay debt (optional)

- With USDC: `USDC.approve(executor, amount)` (**the executor is the spender**), then `executor.repayWithUnderlying(uint256 positionId, uint256 maxUnderlyingAmount) returns (uint256 repaidAmount)` (repays at most the current debt).
- With pUSDC: `P_USDC.approve(executor, amount)`, then `executor.repayWithPToken(uint256 positionId, uint256 debtPTokenAmount) returns (uint256 repaidAmount)` (the surplus is returned as pUSDC).
- Events: `DebtRepaid(positionId, underlyingAmount, remainingDebt)`.

### 4.4 Close, partially or fully

`executor.closePosition((uint256 positionId, uint16 closeBps, uint256 maxClosingFeePToken, uint256 minDebtUnderlying, uint256 minMarginUnderlying, bytes positionToDebtSwapData, bytes debtToMarginSwapData) params) returns (uint256 returnedMarginPTokens)` with
- `closeBps` 1 to 10,000 (10,000 is a full close; 5,000 closes half of the debt and half of the WAVAX);
- `maxClosingFeePToken = type(uint256).max` is safe while `config.closeFeeBps() == 0` (display the fee from `config.closeFeeBps()`);
- `minDebtUnderlying` = the minimum USDC the WAVAX sale must return. **0 selects the protocol floor** (1% under the oracle value; this is what the fork suite uses). A non-zero value below that floor is refused (`SwapError(5)`; the floor follows the oracle at execution, so a non-zero value needs the same quote-immediately-before-sending care as an open: on 5 or 7, re-quote); a higher one is a tighter slippage limit. Compute it as `quoter.expectedOut(WAVAX, USDC, wavaxAmount) * (10000 - slippageBps) / 10000` with `slippageBps <= 100`. The close also reverts (`ExecutorError(37)`) if the sale cannot repay the flash loan;
- `minMarginUnderlying = 0` (USDC is both the debt and margin asset, so there is no second swap);
- `positionToDebtSwapData = 0x`, `debtToMarginSwapData = 0x`.

**The proceeds do not go to the wallet.** They are credited to `vault.freeBalance(user, P_USDC)` (event `PositionClosed.returnedMarginPTokens`). To get USDC the user must then call `vault.withdraw(address pToken, uint256 amount)` and `P_USDC.redeem(uint256 redeemTokens)` (or `redeemUnderlying`). The redeem needs USDC cash in the pUSDC market; its cash is shared with lending (section 6), so a redeem can fail when cash is low: show that, do not retry blindly. A partial close reverts if it would leave equity at or below 0 or lower the health factor (`RiskEngine: negative equity`, `RiskEngine: close worsened health`).

Recovery exit: if the debt is already 0, `executor.exitDebtFreeToPTokens(uint256 positionId, uint16 maxClosingFeeBps) returns (uint256,uint256,uint256)` returns the pTokens in kind **without prices or swaps** (margin pTokens to the vault, pWAVAX to the wallet). Offer it only if a close fails with `PriceUnavailable` or a swap error after full repayment.

### 4.5 Take-profit and stop-loss orders (`MarginOrderRegistry`)

Orders are stored on chain by the owner and executed by anyone (a keeper) when the oracle price crosses the trigger. The registry never holds funds; proceeds follow the normal close path to the owner's vault balance.

- Create: `createOrder(uint256 positionId, uint8 kind, bool triggerAbove, uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry) returns (uint256 orderId)`. `kind`: 0 = TAKE_PROFIT, 1 = STOP_LOSS. For a long, **take-profit needs `triggerAbove = true` and stop-loss needs `false`**, else `InvalidOrder(1)`. `triggerPriceE18` is the WAVAX price in USD, 1e18 scale.
- Limits: `closeBps` 1 to 10,000 (partial is supported); `maxSlippageBps` 1 to 300 (**the close path clamps it to the pair's 100 bp**, so show 100 as the maximum); `expiry` in the future and at most 30 days ahead; at most 4 open orders per position.
- Change: `modifyOrder(uint256 orderId, uint256 triggerPriceE18, uint16 closeBps, uint16 maxSlippageBps, uint64 expiry)`; withdraw: `cancelOrder(uint256 orderId)` (always allowed for the order's owner, even after the position closed).
- Reads: `getOrder(uint256 orderId)`, `openOrdersOf(uint256 positionId) returns (uint256[])`, `canExecute(uint256 orderId) returns (bool executable, uint256 oraclePriceE18, uint8 reason)`. Reason codes: 0 executable, 1 not open, 2 expired, 3 position inactive, 4 owner changed, 5 oracle unavailable, 6 trigger not reached, 7 execution paused.
- Execute (keeper, or an optional "execute now" button when `canExecute` is true): `executeOrder(uint256 orderId, bytes adapterData) returns (bool executed)` with `adapterData = 0x`. A close that cannot meet its floor reverts and the order **stays open**. The close floor is never below the debt plus flash fee, so in a deep fall (or a thin pool) a stop-loss may not be fillable: do not present it as a guarantee.
- A full close, a liquidation or an owner close ends the position; remaining orders are cancelled on the next `executeOrder` attempt (reason 2) or by the owner. Show orders on an inactive position as "position closed".
- **Execution needs a keeper, and the order keeper is built but not deployed** (`avalanche-order-keeper.md`: "not run on mainnet"). Until an operator starts it, an order only executes if somebody calls `executeOrder`. Say so in the UI.

## 5. What to read for the UI

Position list without logs: ids run `1 .. executor.nextPositionId() - 1`; `executor.positions(uint256 positionId) returns (uint256 id, address owner, address account, address marginPToken, address positionPToken, address debtPToken, uint256 lockedMarginPTokens, uint256 initialNotionalUsd, uint256 borrowedPrincipal, uint16 requestedLeverageX100, uint8 side, uint8 status)`. Filter by `owner`. Status: 0 NONE, 1 OPENING, 2 ACTIVE, 3 CLOSING, 4 LIQUIDATING, 5 CLOSED, 6 LIQUIDATED. Side: 0 LONG.

Live metrics (ACTIVE positions): `riskEngine.getMetrics(address account) returns ((uint256 grossAssetValueUsd, uint256 debtValueUsd, int256 equityUsd, uint256 initialRequirementUsd, uint256 maintenanceRequirementUsd, uint256 healthFactorBps, uint256 leverageX100))`, where `account = positions(id).account`. It reverts `RiskEngine: unknown account` for a non-margin address and `PriceUnavailable(asset)` when a price is stale: show "price unavailable", not an error page.

| UI field | Source |
| --- | --- |
| Position size (WAVAX) | `P_WAVAX.balanceOf(account) * P_WAVAX.exchangeRateStored() / 1e36` |
| Position value | `grossAssetValueUsd / 1e18` (it also counts pUSDC held in the account after `addCollateral`) |
| Debt | `P_USDC.borrowBalanceStored(account)` (6 decimals; `borrowBalanceCurrent` via `eth_call` includes accrual); USD value `debtValueUsd` |
| Equity (net value) | `equityUsd` (signed; negative means insolvent) |
| Health factor | `healthFactorBps / 100` percent |
| Effective leverage | `leverageX100 / 100` (`2^256-1` when equity is 0: show "n/a") |
| Margin locked | `positions(id).lockedMarginPTokens` (pUSDC shares) |
| Free vault balance | `vault.freeBalance(user, P_USDC)`; locked: `vault.lockedBalance(user, P_USDC)` |
| Liquidatable now | `riskEngine.isLiquidatable(account)` |
| Entry notional | `positions(id).initialNotionalUsd` |

**Liquidation price has no on-chain view; derive it** from the formulas in `IsolatedMarginMath.calculateMetrics` (derived here, not read from chain; re-check against `isLiquidatable` in tests). With `N` = WAVAX held, `D` = debt in USD (`debtValueUsd`), `C` = USD value of any pUSDC held by the account, and a 25% maintenance margin: liquidatable when `0.75 * (N*Pw + C) < D`, so `Pw_liq = (D / 0.75 - C) / N`. Full liquidation when `0.875 * (N*Pw + C) <= D`: `Pw_full = (D / 0.875 - C) / N`. Insolvent when `N*Pw + C < D`: `Pw_ins = (D - C) / N`. Illustration (arithmetic, not a read): margin 100 USDC at 2x gives about N = 22.5 WAVAX and D about 98 USD; at a WAVAX price of 8.70 this is liquidation at about 5.80 (down 33%), full liquidation at about 4.97 (down 43%), insolvent at about 4.35 (down 50%). Debt grows with interest, so recompute on every refresh.

Market state: `config.getPairRisk(P_USDC, P_WAVAX, P_USDC)` (returns the 12 fields `enabled, maxLeverageX100, initialMarginBps, maintenanceMarginBps, liquidationTargetBps, fullLiquidationHealthBps, maxLiquidationBps, liquidationBonusBps, maxSlippageBps, oracleDeviationBps, maxPositionValueUsd, maxDebtValueUsd`), `config.opensPaused()`, `config.openFeeBps()`, `config.closeFeeBps()`. Do not hard-code the numbers in section 6: read them.

## 6. Limits (pilot, read from chain on 11 Nov 2026)

| Limit | Value | Where it applies |
| --- | --- | --- |
| Leverage | above 1x, at most 2x (`maxLeverageX100` 200) | `ExecutorError(10)` and `(13)`; the quoter reverts `MarginQuoter: invalid opening leverage` |
| Position cap | USD 200 (gross assets) | **per position, checked at open only** (a position can drift above it with the price) |
| Debt cap | USD 100 | per position, checked at open only |
| Initial margin | 50% of gross (equity at least half the assets) | open |
| Max slippage / oracle deviation | 100 bp each | every swap (open, close, liquidation); `SwapError(7)` / `(8)` when missed |
| Minimum margin | **none enforced on chain** (the quoter accepted even 10 raw units = 0.00001 USDC); a position with debt of USD 10 or less is always liquidated in full; set a UI minimum as a product decision | |
| Open and close fee | 0 bp | read `config.openFeeBps()` / `closeFeeBps()`; changes are queued 24 h |
| Flash vault | USDC only, fee 0, 100 USDC | caps **one transaction's** debt: a margin of about 102 USDC and above is silently quoted at 100 USDC of debt (the quote saturates), and the position cap then rejects it; practical maximum margin is about **100 USDC** |
| pUSDC borrow cap | 200 USDC, **shared with lending** | `market borrow cap reached` |
| pUSDC cash floor | 50 USDC must remain in the market after a borrow, **shared with lending** | `borrow cash floor` |
| Orders | 4 open per position, 30 days, 300 bp (100 effective) | section 4.5 |

Cap and initial-margin breaches at open surface as **`BorrowPeridottrollerRejection(4)`** (INSUFFICIENT_LIQUIDITY: the risk hook said no: cap, leverage or initial margin) raised by the pUSDC market; `(14)` is REJECTION. Sizing a position near the limits: take `min(USD 100 debt, pUSDC borrow headroom = borrowCaps(P_USDC) - totalBorrows - 1, pUSDC cash - borrowCashFloor(P_USDC), flash vault balance)` as the debt ceiling, and simulate the open before sending. The pilot is deliberately small; nothing here is an APY promise and the UI must not forecast returns.

## 7. Health factor and liquidation, as the user sees it

- **Health factor** = equity / (25% x gross assets), in bps. At open it is about 200% (the fork opened at 201.7%). **Below 100% the position is liquidatable.** Colour suggestion: above 150% green, 100 to 150% amber, below 100% red.
- **Partial liquidation** (health between 50% and 100%, debt above USD 10): the liquidator repays **50% of the debt** (`maxLiquidationBps` 5,000) and takes WAVAX worth the repaid value plus a **5% bonus**. The position stays open and must end at a health of at least 125% (`liquidationTargetBps`) or at least better than before; if a partial cannot achieve that the whole debt is liquidated instead.
- **Full liquidation** (health at or below **50%**, or debt at or below **USD 10**): all debt is repaid, the liquidator takes up to repaid value plus 5%, and **the surplus goes back to the user**: on the funded route leftover **pWAVAX is sent to the owner's wallet** (the user can redeem it for WAVAX on the lending market) and any leftover margin pUSDC goes to the user's vault free balance. After it the position is LIQUIDATED.
- **Insolvent position** (assets below debt, below about -50%): the liquidator would pay more than it receives. The two funded operators **decline it** (their break-even floor), the **insurance fund is not used by the funded route**, and the shortfall stays as debt in the pUSDC market (the operator monitor escalates it as a human decision for the treasury signers). The permissionless flash route `liquidator.liquidate(...)` can draw on the insurance fund (10 USDC seed); whether it is usable in practice at pilot size is **unverified**. Show "insolvent: the position can no longer be recovered by closing".
- **Who liquidates:** only the two funded operator wallets use `liquidateFunded`. Operator limits (host configuration, commit `3af0fede`; the conclusion below is **derived** from them, not rehearsed): 60 USDC per call and 100 USDC per 24 h, per operator. A full liquidation of a debt above 60 USDC therefore **exceeds the per-call limit** (`LiquidationError(28)`: the operator alerts and does not send); raising that limit above the largest possible debt (about 100 USDC plus interest) is an operator decision. A user must not rely on liquidation timing: **manage your own health factor**.
- Liquidation does not read the order registry; an order never delays or blocks it.

## 8. Errors and what to show

Custom errors are decoded with the ABI of the contract that raised them; build one merged interface from all ABI files plus `PErc20Delegate.json` (pool-token errors) and decode revert data against it. Revert data is expected to bubble up through the executor (the fork suite observed this for `BorrowPeridottrollerRejection`; for the other errors it is **unverified** on mainnet, so keep a generic fallback message).

**`ExecutorError(uint8 code)`** (executor). Codes a user can hit:

| Code | Meaning | Show |
| --- | --- | --- |
| 8 | opens are paused | "New positions are paused" |
| 9 | zero margin | "Enter an amount" |
| 10, 13 | leverage not above 1x / above the pair maximum | "Leverage must be between 1x and 2x" |
| 11 | `minPositionUnderlying` is 0 | internal bug: re-quote |
| 12 | pair not enabled | "This market is not available" |
| 14 to 16 | wrong asset combination | internal bug |
| 17, 25, 54 | fee above your maximum | "Fee changed, refresh" |
| 18 | quoted flash amount is 0 | "Amount too small" |
| 19, 28 | flash loan failed (open / close) | "Liquidity unavailable, try later" |
| 20, 21, 22, 23 | zero collateral / zero repay / nothing to repay / zero pTokens | input error |
| 24 | `closeBps` is 0 or above 10,000 | input error |
| 26, 27 | nothing to redeem / release | "Position is empty" |
| 37 | the WAVAX sale cannot repay the flash loan | "Price moved against you, try again or add margin" |
| 46 | not the owner of the position | "Not your position" |
| 47 | position not active | "Position is closed or being liquidated" |
| 55 | debt remains (`exitDebtFreeToPTokens`) | "Repay the debt first" |
| 56 | opened leverage above the requested leverage | re-quote |
| 57 | interest accrual failed | retry |
| 60 | not the order executor | (orders only) |
| 29 to 36, 45, 48 to 53, 58, 59 | flash-callback and wiring checks | "Unexpected error" and report |

**`SwapError(uint8 code)`** (swap module, raised through the executor): 3 amount 0; 4 no adapter; 5 your minimum is below the protocol floor (1%); 6 balance mismatch; 7 output below the minimum ("Slippage too high: the pool moved"); 8 output value more than 1% below the oracle value ("Pool price differs from the oracle: try later"). The adapter's own `InvalidSwap`, `InsufficientOutput`, `UnexpectedBalance` appear only if the swap data is not empty or the pool misbehaves.

**Controller / pool-token errors** (from pUSDC, decode with `PErc20Delegate.json`): `BorrowPeridottrollerRejection(4)` cap, leverage or initial margin ("Position too large for the pilot limits"); `BorrowPeridottrollerRejection(14)`; revert strings `market borrow cap reached`, `borrow cash floor`, `borrow is paused` ("Borrowing is currently full or paused"). `RedeemTransferOutNotPossible` or a cash error on redeem: "Not enough USDC liquidity in the market right now".

**Risk-engine errors**: `InitialMarginTooLow`, `LeverageExceeded`, `PositionCapExceeded`, `DebtCapExceeded` (library errors, same meaning as above), `PriceUnavailable(address)` ("Price feed unavailable"), strings `RiskEngine: not active`, `RiskEngine: negative equity`, `RiskEngine: close worsened health`. Vault strings: `MarginVault: pToken disabled`, `zero amount`, `insufficient free balance` ("Deposit more margin first"), `exceeds free balance`, `undercollateralized`. Quoter strings: `MarginQuoter: invalid opening leverage`, `no opening capacity`, `price unavailable`.

**Order errors** (registry): `NotPositionOwner`, `PositionNotActive`, `InvalidOrder(1..6)` (1 wrong trigger side for the kind, 2 bad `closeBps`, 3 slippage out of 1..300, 4 expiry not in the next 30 days, 5 zero trigger, 6 four orders already open), `OrderNotOpen`, `TriggerNotReached(oraclePriceE18, triggerPriceE18)`, `OracleUnavailable`, `ExecutionPaused`; adapter: `InvalidClose(1..7)` (1 `closeBps`, 2 slippage, 3 owner, 4 inactive, 5 close fee above 1%, 6 price moved, 7 not a long), `AdapterDataNotSupported`.

**`LiquidationError(uint8 code)`** (liquidator; operators mostly): 8 not active; 9 bad recipient; 10 no debt; 11 repay out of range; 12 no position tokens; 13 locked-margin reduction invalid; 27 caller is not a funded liquidator; 28 the repay the risk engine needs exceeds the caller's `maxRepayUnderlying`; 30 below the minimum seized pTokens; 31 seizure above repay plus bonus; 32 below the break-even floor (insolvent); 14 to 26 and 29 are flash-route and accounting internals. Plus `RiskEngine: healthy` when the position is not liquidatable.

## 9. Events to index

Index from about block **99,920,695** (the first margin wire transaction; vault deposits are possible from the wire stage on) for the vault, from **100,015,218** (opens unpaused) for everything else. Avalanche public RPC limits `eth_getLogs` ranges; prefer a provider with a larger window, or read by id as in section 5.

| Contract | Event |
| --- | --- |
| Executor | `PositionOpened(uint256 indexed positionId, address indexed user, address indexed account, uint8 side, address marginPToken, address positionPToken, address debtPToken, uint256 marginPTokenAmount, uint256 borrowedAmount, uint256 grossAssetValueUsd, uint256 leverageX100, uint256 healthFactorBps)` |
| Executor | `CollateralAdded(uint256 indexed positionId, uint256 pTokenAmount, uint256 healthFactorBps)` |
| Executor | `DebtRepaid(uint256 indexed positionId, uint256 underlyingAmount, uint256 remainingDebt)` |
| Executor | `PositionClosed(uint256 indexed positionId, uint16 closeBps, uint256 debtRepaid, uint256 returnedMarginPTokens, uint256 closingFeePTokens, uint256 healthFactorBps, bool fullyClosed)` |
| Executor | `DebtFreePTokenExit(uint256 indexed positionId, uint256 returnedMarginPTokens, uint256 returnedPositionPTokens, uint256 returnedDebtPTokens, uint256 marginFeePTokens, uint256 positionFeePTokens, uint256 debtFeePTokens)` |
| Vault | `Deposited(address indexed user, address indexed pToken, uint256 amount)` |
| Vault | `Withdrawn(address indexed user, address indexed pToken, uint256 amount)` |
| Vault | `PositionLocked(uint256 indexed positionId, address indexed user, address indexed pToken, uint256 marginAmount, uint256 openingFee)` |
| Vault | `PositionLockIncreased(uint256 indexed positionId, uint256 amount)` |
| Vault | `PositionReleased(uint256 indexed positionId, uint256 lockedReduction, uint256 returnedAmount)` |
| Liquidator | `FundedPositionLiquidated(uint256 indexed positionId, address indexed funder, address indexed recipient, uint256 debtRepaid, uint256 positionPTokensSeized, uint256 marginPTokensSeized, uint256 positionPTokensReturnedToOwner, uint256 marginPTokensReturnedToVault, uint256 lockedMarginReduction, bool fullyLiquidated)` |
| Liquidator (flash route) | `PositionLiquidated(uint256 indexed positionId, address indexed caller, address indexed recipient, uint256 debtRepaid, uint256 collateralPTokensRedeemed, uint256 lockedMarginReduction, uint256 returnedMarginPTokens, uint256 liquidatorReward, bool fullyLiquidated)` |
| Risk engine | `AccountStatusUpdated(address indexed account, uint8 status)` |
| Risk engine | `AccountRegistered(uint256 indexed positionId, address indexed account, address indexed owner, address marginPToken, address positionPToken, address debtPToken, uint8 side)` |
| Registry | `OrderCreated(uint256 indexed orderId, uint256 indexed positionId, address indexed owner, Order order)` |
| Registry | `OrderModified(uint256 indexed orderId, uint256 indexed positionId, Order order)` |
| Registry | `OrderCancelled(uint256 indexed orderId, uint256 indexed positionId, uint8 reason)` |
| Registry | `OrderExpired(uint256 indexed orderId, uint256 indexed positionId)` |
| Registry | `OrderExecuted(uint256 indexed orderId, uint256 indexed positionId, address indexed executor, uint256 oraclePriceE18, uint16 closeBps, uint256 returnedMargin)` |
| Config | `OpensPaused(bool paused)` |
| Config | `PairRiskConfigured(bytes32 indexed pair, (...) config)` |
| Config | `ActionQueued(bytes32 indexed actionId, uint256 executeAfter)` |

Order cancel reasons: 0 owner, 1 sibling executed, 2 position inactive, 3 owner changed. `Order` is the struct returned by `getOrder` (section 4.5). Show a banner when opens are paused or the pair risk changes.

A liquidation ends with `PositionLiquidated` or `FundedPositionLiquidated` with `fullyLiquidated` true; read the owner's wallet pWAVAX and vault free balance afterwards.

## 10. Not available

- **Shorts** (the reverse pair and WAVAX borrowing are off; the order adapter also refuses shorts), **other pairs** (every other pair reads disabled), **WAVAX or AVAX as margin**, leverage above 2x, **cross margin**, changing leverage on an open position, reducing margin of an open position (margin leaves only by closing), and a **native-AVAX entry** (the user must hold USDC).
- A route choice: swap data is always empty.
- A guaranteed stop-loss, a guaranteed liquidation time, or any return or APY statement.

## 11. Pilot caveats the UI should state

- Pilot size: USD 200 position and USD 100 debt per position, one pair. Say "pilot" in the UI.
- Margin debt **shares the pUSDC borrow cap, cash floor and cash** with lending, so opens and redeems can fail for reasons unrelated to the user's position.
- Owner actions (the Ledger) can pause opens, disable the pair, pause the order registry and the flash vault, change the flash-vault fee (at most 100 bp) and upgrade proxies **immediately**; only the config's risk-increasing changes (pair risk, fees, endpoints, funded liquidators, unpause) wait 24 h after queuing. Read the flash fee live; closing and repaying stay possible unless the flash vault is paused or drained.
- Pool depth: the swap must land within 1% of the oracle price. In a fast move or a thin pool, closes and stop-losses can revert (`SwapError` 7 or 8). The rehearsal measured the sell side becoming thin roughly 10% below the head and pool depth changing a lot between blocks (`avalanche-margin-operator-step.md` section 7; rehearsal, not mainnet).
- The rehearsal fork suite asserts that a round trip returns more than 98% of the margin (open fee 0, close fee 0; the cost is the swap spread and the pool fee); it was not measured on mainnet.
- Nothing in this document is an APY promise or a yield forecast; lending interest earned by shares held in the vault is the pUSDC market's, unrelated to this product.

## 12. Verification record

Read from chain at block 100,016,420 (11 Nov 2026, 10:50:44 UTC): code present at all 17 addresses (and at the implementations and proxy admins); `config.opensPaused() == false`; `controller.isolatedMarginRiskHook() == riskEngine`; `executor.orderExecutor() == registry.adapter() == closeAdapter`; pair risk equal to the deployment script's constants; both operators are funded liquidators; flash vault USDC allowed, WAVAX not, fee 0, 100 USDC; insurance fund 10 USDC in pUSDC; the executor, config, risk engine, vault, liquidator and registry implementations and the flash vault match the build output byte for byte, and the quoter, swap module, close adapter and account factory match with their constructor immutables masked. The full record is under `margin.verification` in the JSON.
