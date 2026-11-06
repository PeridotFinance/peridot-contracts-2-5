# Margin take-profit / stop-loss orders: one-page spec

Interface: `contracts/contracts/margin/orders/IMarginOrderRegistry.sol` (registry plus `IMarginCloseAdapter`). One
registry implementation per chain behind a proxy (append-only storage); one adapter per chain's close path. Field names
are shared so the frontend uses one component on Robinhood, Avalanche and the Stellar port.

## Order

| field | type | rule |
| --- | --- | --- |
| `positionId` | uint256 | the chain's margin position id |
| `owner` | address | position owner at creation; re-checked at execution |
| `kind` | `TAKE_PROFIT` or `STOP_LOSS` | fixed after creation |
| `triggerAbove` | bool | `true`: fires when price >= trigger; `false`: when <= |
| `triggerPriceE18` | uint256 | USD, 18 decimals, > 0 |
| `closeBps` | uint16 | 1..10,000; a partial (< 10,000) only if the adapter's close path supports it |
| `maxSlippageBps` | uint16 | 1..`MAX_SLIPPAGE_BPS` (registry constant, suggested 300) |
| `expiry` | uint64 | in the future, at most `MAX_ORDER_LIFETIME` ahead (suggested 30 days); never 0 |
| `createdAt`, `updatedAt` | uint64 | set by the registry |
| `status` | `OPEN`, `EXECUTED`, `CANCELLED`, `EXPIRED` | |

**Direction check at create and modify:**
- **Long position:** `TAKE_PROFIT` needs `triggerAbove = true` and `STOP_LOSS` needs `false`.
- **Short position:** the reverse.
- A mismatch reverts `InvalidOrder(1)`.

`MAX_ORDERS_PER_POSITION` is 4, so a TP and an SL ladder fit and the mutual-cancellation loop stays bounded.

## Functions

| function | who | effect |
| --- | --- | --- |
| `createOrder` | position owner | new `OPEN` order; `OrderCreated` |
| `modifyOrder` | owner, `OPEN` only | new trigger, size, slippage and expiry; kind, position and direction fixed; `OrderModified` |
| `cancelOrder` | owner, `OPEN` only | `CANCELLED` (reason 0); `OrderCancelled` |
| `executeOrder` | anyone (keeper) | see below |
| `canExecute` | view | executable now, the oracle price used, and the reason code if not; never reverts |

`executeOrder(orderId, adapterData)`, in this order:
1. **Not `OPEN`:** revert `OrderNotOpen`.
2. **Past expiry:** set `EXPIRED`, emit `OrderExpired`, return `false`.
3. **Position inactive, or `positionOwner` changed:** set `CANCELLED` (reason 2 inactive, 3 owner changed), return `false`.
   This is how a liquidation or a direct owner close cancels open orders.
4. **Oracle price:** `adapter.oraclePriceE18`. If `ok` is false, revert `OracleUnavailable`; the order stays open and
   waits.
5. **Trigger:** if not crossed, revert `TriggerNotReached`.
6. **Close:** `adapter.closeFor(positionId, owner, closeBps, price, maxSlippageBps, adapterData)`. If it reverts, the
   order stays `OPEN`, for example on slippage or an unsupported partial.
7. **Record:** `EXECUTED`, emit `OrderExecuted`. If the position is now inactive (a full close, or a partial that ended
   it), cancel every other `OPEN` order on it with reason 1 (sibling executed).

## Authorization

- Create, modify and cancel: `msg.sender == adapter.positionOwner(positionId)`.
- Execute: anyone. The executor receives nothing; proceeds follow the existing close path to the owner. `adapterData`
  only routes the swap and can never name a recipient.
- On the margin engine, the registry's adapter is the only extra caller allowed to close for an owner. On Robinhood that
  is a timelocked executor upgrade adding `closePositionFor(owner, params)`, callable only by the configured order
  executor.
- Registry admin: the timelock, via upgrade, pause and limits. There is no admin path to execute, modify or redirect
  an order.

## Liquidation independence

- **Separate paths:** the registry never holds the position, its margin or its debt. Liquidation never reads or calls
  the registry, and the registry adds no check to the liquidation path.
- **No interference:** an order cannot make a position harder to liquidate, and a pending order cannot block a
  liquidation.
- **After a liquidation:** the position is inactive, so step 3 cancels its orders on their next execution attempt.
  A frontend should show them as "position closed".
- **Pause:** pausing the registry stops only order execution. Owner closes and liquidations are unaffected.

## Execution guarantees

- **Fresh price:** the oracle the margin engine already uses. Stale, paused or invalid prices revert, and the order
  waits.
- **Accrued interest:** included, because the close path accrues debt before repaying (`borrowBalanceCurrent` on
  Robinhood).
- **Bounded slippage:** the adapter derives the close path's minimum outputs from the oracle price and
  `maxSlippageBps`, and the close path enforces them.
- **Partial fills:** only through the close path's own partial support (Robinhood: `closeBps` 1..10,000). Each order
  executes once; for a ladder, use several orders.
- **Expiry:** checked first. An expired order can only become `EXPIRED`.

## Reason codes

- **`InvalidOrder(code)`:**
  - 1: direction mismatch
  - 2: zero or excessive `closeBps`
  - 3: slippage out of range
  - 4: expiry in the past, 0, or too far ahead
  - 5: zero trigger
  - 6: too many open orders on the position
- **`OrderCancelled.reason`:** 0 owner, 1 sibling executed, 2 position inactive, 3 owner changed.
- **`canExecute.reason`:** 0 executable, 1 not open, 2 expired, 3 position inactive, 4 owner changed,
  5 oracle unavailable, 6 trigger not reached.

## Deployment convention (the Robinhood deploy script depends on it)

- **Constructor:** takes no arguments and calls `_disableInitializers()`.
- **Initializer:** `initialize(IMarginCloseAdapter adapter_, address admin_)`. `admin_` is the chain's timelock; it holds
  every admin power (pause, limits). `adapter()` returns `adapter_` from then on.
- **Proxy:** OpenZeppelin 5 `TransparentUpgradeableProxy(implementation, timelock, initData)`. Its own `ProxyAdmin` is
  then owned by the timelock. Storage stays append-only across upgrades.
- **Address order:** the adapter needs the registry address, and the registry needs the adapter's. The deploy script
  predicts the adapter address from the deployer nonce, initializes the proxy with it, then deploys the adapter and
  asserts the two match.
- **One-time wiring on Robinhood:** the executor's `orderExecutor` is set once, inside the timelocked upgrade
  (`reinitializer(2)`), and the adapter's `registry` is immutable.
  - The registry can be upgraded behind its proxy at any time.
  - Replacing the adapter needs another executor implementation with a `reinitializer(3)` setter.
