# Margin close-path interface (Avalanche), for the TP/SL keeper and range take-profit work

Status: **FIXED as of 7 Nov 2026.** Nothing here depends on code I have not yet written except the Avalanche adapter's address. Sources of truth: `feat/margin-order-interface` at `010b30ac` (`contracts/contracts/margin/orders/IMarginOrderRegistry.sol`, `docs/margin-orders/SPEC.md`) and the executor change in commit `e8f225ba`. Addresses do not exist until the margin ceremony; until then use the local fork recipe (delivered 9 Nov, with an addresses file).

## 1. What is fixed

**Order layer (unchanged from the order branch).** `IMarginOrderRegistry`: `createOrder`, `modifyOrder`, `cancelOrder`, `executeOrder(orderId, adapterData)`, `canExecute(orderId) -> (executable, oraclePriceE18, reason)`, `getOrder`, `openOrdersOf`, `adapter()`. Events `OrderCreated/Modified/Cancelled/Expired/Executed`. Reason codes and limits as in `SPEC.md` (`MAX_SLIPPAGE_BPS` 300, `MAX_ORDER_LIFETIME` 30 days, `MAX_ORDERS_PER_POSITION` 4).

**Adapter interface (`IMarginCloseAdapter`).**
```
positionOwner(uint256 positionId) view returns (address)
isActive(uint256 positionId) view returns (bool)
isLong(uint256 positionId) view returns (bool)
oraclePriceE18(uint256 positionId) view returns (uint256 priceE18, bool ok)
closeFor(uint256 positionId, address owner, uint16 closeBps, uint256 oraclePriceE18,
         uint16 maxSlippageBps, bytes adapterData) returns (uint256 returnedMargin)   // registry only
```

**Executor entry (the close path itself).**
```
struct CloseParams { uint256 positionId; uint16 closeBps; uint256 maxClosingFeePToken;
                     uint256 minDebtUnderlying; uint256 minMarginUnderlying;
                     bytes positionToDebtSwapData; bytes debtToMarginSwapData; }
closePosition(CloseParams)                     // owner only (unchanged)
closePositionFor(address owner, CloseParams)   // only the configured order executor (the adapter)
orderExecutor() view returns (address)
initializeOrderExecutor(address)               // reinitializer(2); proxy admin only, inside upgradeAndCall; one shot
positions(uint256) view returns (Position)     // id, owner, account, marginPToken, positionPToken, debtPToken,
                                               // lockedMarginPTokens, initialNotionalUsd, borrowedPrincipal,
                                               // requestedLeverageX100, side (0 LONG, 1 SHORT), status
```
`status`: 0 NONE, 1 OPENING, 2 ACTIVE, 3 CLOSING, 4 LIQUIDATING, 5 CLOSED, 6 LIQUIDATED. Executor error codes used by the order path: 24 (closeBps), 46 (owner mismatch), 47 (not active), 58 (not proxy admin), 59 (adapter has no code), 60 (caller is not the order executor).

## 2. Avalanche specifics

| Item | Avalanche value |
| --- | --- |
| Direction | **long only**: margin pUSDC, position pWAVAX, debt pUSDC. The adapter reverts for a short. Stop-loss is below the entry, take-profit above. |
| Price | the margin oracle's WAVAX price in USD with 18 decimals (Chainlink AVAX/USD, 8 decimals scaled); `ok = false` when the feed is stale, zero or invalid. Maximum age 1,200 s. |
| `adapterData` | **must be empty.** Route and recipient are fixed (the pinned Pharaoh CL pool through the swap module). |
| `closeBps` | 1..10,000; partial closes are supported by the executor. |
| Minimum output | the quoter's value of the closed assets less the **tighter** of the order's slippage and the pair's `maxSlippageBps` (100), never below debt plus flash fee. An order with `maxSlippageBps` 300 therefore executes with a 100 bp floor and can revert in a fast move; the order then stays OPEN. |
| Proceeds | margin pTokens credited to the position owner in the margin vault; the caller gets nothing. |
| Liquidation | independent; the registry is never read by it. A liquidated position cancels its orders on the next execution attempt (`reason 2`). |
| Registry admin | the Ledger (pause only). |

## 3. For the keeper and the frontend

- Decide with `canExecute`; simulate; send `executeOrder(orderId, "0x")`. `TriggerNotReached` and `OracleUnavailable` are normal waits, not errors.
- Sweep orders with `canExecute` reason 2, 3 or 4 so dead orders free their slots.
- Show the stop-loss clamp (100 bp) and that liquidation (at about -33% for a 2x long) is the backstop.
- **Fill depth varies a lot.** The pool's sell-side depth fell by 60-70% between two heads two days apart (USD to sell for -10%: 777k, then 231k; see the frontend notes). A stop-loss that cannot be filled within the 1% floor reverts and the order stays OPEN: treat that as normal, retry on the next price move, never loosen the floor. Wording for the screens and the deck: stop-loss fills depend on pool depth at the hour; funded liquidation is the mechanism.
- Position cap USD 5,000, margin up to about 2,500, one pair.

## 4. The 9 Nov package (compiled, ABIs, fork recipe)

- **Code (compiled, `debt_accounting` profile, solc 0.8.35):** `contracts/contracts/margin/orders/{IMarginOrderRegistry,MarginOrderRegistry,AvalancheMarginCloseAdapter}.sol`; the order-executor change in `IsolatedMarginExecutorUpgradeable.sol` (verbatim from `e8f225ba`; layout unchanged: `orderExecutor` takes slot 24, `__gap` 40 -> 39, end slot 63 both before and after; runtime 21,926 bytes). The registry files are copied unchanged from the order branch, so the later merge sees identical content.
- **ABIs:** `avalanche-margin-abi/*.json` (registry, close adapter, executor, liquidator, risk engine, config, vault, quoter, flash vault).
- **Fork recipe:** `operator/scripts/margin-fork-up.ts` (`node dist/scripts/margin-fork-up.js --demo-position --out margin-fork.json`). It starts a local anvil fork of the current head, runs the PW30 ceremony and the four margin stages (impersonated accounts, nothing real), replaces the two Chainlink feeds by settable mocks (`set(int256 answer8, uint256 updatedAt)`), opens one 2x position for ALICE, writes the local RPC URL and every address to `margin-fork.json` and keeps the fork alive. Needs `AVALANCHE_MAINNET_RPC_URL` in the environment and `npm run build:contracts` once (for the mock feeds).
- **Real addresses:** after the live ceremony (stage 1 prints them; `ceremony/margin-addresses.env`).
