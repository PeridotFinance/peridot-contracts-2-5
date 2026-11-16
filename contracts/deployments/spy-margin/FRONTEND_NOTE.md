# SPY 2x margin: note for the frontend developer

**Status:** prepared and rehearsed, **not live**. Addresses come from `deployments/spy-margin/spy-margin-mainnet.json` once the operator has run the ceremony. Until then, show nothing for SPY.

## What is new
- **New market:** `pSPY`, plain, 8 decimals, underlying SPY `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C`, on the same controller `0x6148…ac39c`.
  - Collateral factor 0: it is not lending collateral.
  - Borrowing is paused.
  - Show it only as a margin position market, not in the lending UI.
- **New margin pair (long only):** margin `pUSDG`, position `pSPY`, debt `pUSDG`.
  - Max 2x; initial margin 50%, maintenance margin 25%.
  - Caps: $250 gross and $125 debt per position. The operator may lower them to $100/$50, so read `config.getPairRisk(pUSDG, pSPY, pUSDG)` and do not hard-code.
  - There is no short pair: `getPairRisk(pUSDG, pUSDG, pSPY).enabled == false`.
- **Unchanged:** executor, margin vault, quoter, registry (TP/SL) and close adapter. The `openPosition`, `closePosition`, `createOrder` and `executeOrder` calls are the same as for NVDA, just with pSPY as the position pToken. Swap data stays `0x`.
- **Range take-profit:** NVDA only. For a SPY position, hide it (the custodian reverts `PositionNotEligible(3)`).
- **Controller oracle address changes** from `0xe4e03C2F…2A2E4` (cited in `HANDOFF-2026-11-16.md`) to the new 3-market adapter. Update any pinned address.
  - The margin oracle `assetSource` changes to the router.
  - NVDA values are unchanged; this was tested value for value.

## Market-closed states (new UI states)
SPY is priced only on weekdays with a fresh feed. Monitor with `spySource.stockPrice()`, which returns (price, reason, updatedAt):
- reason 6 `STALE`: the feed is more than 25 h old;
- reason 7 `CLOSED_WINDOW`: Saturday 00:00 UTC to Monday 01:00 UTC;
- reason 1 or 2: SPY is paused.

When the price is unavailable:

| Action | Behaviour |
| --- | --- |
| Open, add collateral, close, TP/SL execution, liquidation | **Unavailable.** They revert. Grey them out with "SPY market closed / price stale". |
| `repayWithUnderlying`, `repayWithPToken`, then `exitDebtFreeToPTokens` | **Work.** The user gets pSPY and pUSDG back in kind and can redeem pSPY for SPY at any time. Offer this as "close without trading". |
| Open TP/SL orders | Stay open and fire on the first fresh price. After a weekend gap the fill is at the gap price, not the trigger; say so next to the stop-loss field. |
| `addCollateral` | Unavailable while closed. Suggest repaying instead. |

## Sizing
Real size is limited by pUSDG cash, which NVDA and SPY share. Before opening, check `pUSDG.getCash()` against the margin plus debt, and the flash vault's `maxFlashLoan(USDG)`. Otherwise the open reverts.
