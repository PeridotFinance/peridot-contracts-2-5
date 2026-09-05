# Robinhood Boosted Markets

## Scope

Two lending markets, one on each side of the paired Stock/USDG vault deployed on
Robinhood Chain (chain ID `4663`), plus leveraged margin on top of them.

| Market | Underlying | Vault role |
| --- | --- | --- |
| `bpUSDG` | USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | `usdgAccount` of the `NVDA/USDG` pair |
| `bpNVDA` | NVDA `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` | `stockAccount` of the same pair |

The vault accepts deposits only from those two addresses, so both sides must be
pTokens before the production pair can be registered. The vault returns each
side's principal in its **native** token and shares impermanent loss pro-rata
across both sides, so a USDG supplier carries a share of NVDA divergence loss.
That is deliberate and has to be disclosed rather than assumed.

Vault repository: `../../RobinhoodVaults` (`LP_VaultsUniswap`, branch
`robinhood-vault-canary`). Its `deployments/README.md` is the authoritative
record of what is live.

## Current live state

The vault system is deployed, upgraded and verified on Robinhood Chain mainnet.
Read-only checks at block `54270320`:

| Component | Proxy | Notes |
| --- | --- | --- |
| Vault | `0x280825b2d856706Ff7E0d6351CcB2e935E1a9A2f` | links `SettlementLib` at `0x813AbFeC0DE50f8674798CbaB72Ed7b5D8CcB9cB` |
| Adapter | `0xadA73211711e4790bc83B5d6B39f47fE04D276f3` | one zero-hook v4 PoolKey per pair |
| Oracle guard | `0xaE4D4DdB8dD646951d54fE9B13BE23DcB61C6741` | allocation bound 300 bps, exit bound 600 bps |
| Loss reserve | `0x806b182B050f7EcF908758dD6bBF91DB8B2212aF` | per-event, daily and coverage-ratio limits |
| Timelock | `0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498` | self-administered, minimum delay 3600s |

Only the `NVDA/USDG/CANARY` pair exists. It is drained, both pause flags set,
emergency mode false. The production `NVDA/USDG` pair has never been registered.

**The timelock's proposer, canceller and executor are still the single bootstrap
EOA `0x94696d767e65a75581145646960FA0eC886cE5d2`.** Migrating those roles to the
approved multisig gates production TVL for the markets as much as for the vault.

## Prerequisite: the lending core is not on Robinhood Chain

An earlier draft of this plan assumed a Peridottroller and interest-rate model
already existed on 4663. They do not. Neither does a price oracle or any pToken.
The boosted markets cannot be deployed until the lending base is standing, so
that base is step one rather than an assumed input.

Model it on `DeployAvalancheFujiLendingMarkets.s.sol`, which deploys and wires:

| Component | Robinhood equivalent |
| --- | --- |
| `Peridot` governance token | fresh deployment |
| Price oracle | `StockSimplePriceOracle`, not `AvalanchePriceOracle` — it carries the per-asset stock flag and separate staleness threshold |
| `Unitroller` | unchanged |
| Chain-pinned controller | `PeridottrollerRobinhood` (added alongside this plan) |
| `PErc20Delegate` | unchanged, for any plain market |
| `ConfigurableJumpRateModelV2` | unchanged, parameters below |
| Market bootstrapper | Robinhood equivalent of `AvalancheFujiMarketBootstrapper` |

`PeridottrollerRobinhood` mirrors `PeridottrollerAvalancheFuji`: `Peridottroller`
plus a chain-id guard and an immutable PERIDOT token address. The guard matters
more here than on a testnet — this implementation backs markets whose underlying
is a tokenized equity priced by a feed that only updates while its market is
open, so the staleness policy chosen for 4663 must not be reachable elsewhere.

**`LENDING_BLOCKS_PER_YEAR` must be changed from the Fuji default.** Measured
over 200,000 blocks on 4663: 20,163 seconds, or **0.1008s per block**, which is
**312,810,593 blocks per year**. The Fuji default is `31_536_000`, assuming one
block per second.

`ConfigurableJumpRateModelV2` derives `ratePerBlock = ratePerYear /
blocksPerYear`. Deploying with the Fuji default on a chain producing ten times
as many blocks makes interest accrue at roughly **ten times the intended annual
rate**. Re-measure at deployment time rather than copying the number above, and
assert it in the deploy script rather than leaving it an env default.

## Markets to build

`RobinhoodBoostedDelegate` already exists (522 lines) and is **token-agnostic**:
every vault call routes through `underlying`, and `_validateVault` asserts
`sideAccount(pairId, underlying) == address(this)`. Only its comments and the
`PUSDG_DELEGATOR` env name are USDG-specific. `bpNVDA` is therefore a second
deployment of the same implementation, not a second contract.

1. **`bpUSDG`** — deploy the delegator, register the production `NVDA/USDG` pair
   with it as `usdgAccount`, configure while the pToken is paused, unpause vault
   allocation through governance, then enable the pToken's vault integration.
   `ConfigureNvdaPair` enforces that ordering by requiring `vaultPaused()` at
   registration.
2. **`bpNVDA`** — same implementation, `UNDERLYING` set to NVDA, registered as
   `stockAccount`. Worth a comment and env-name pass so the delegate reads as
   side-neutral; the bytecode is unchanged.
3. **Oracle** — register both underlyings on `StockSimplePriceOracle`, flag NVDA
   as a stock asset, and size `stockChainlinkPriceStaleThreshold` against
   measured feed behaviour rather than a guess (see below).
4. **Exposure dial — decided.** One vault-wired market per asset, with each
   side's LP exposure set by that market's own `vaultBufferMantissa`. No separate
   plain market per asset. `rebalance` deploys `min(stockValue, usdgValue)`, so
   splitting each asset into plain and boosted markets would let whichever
   boosted market is smaller throttle the entire pair, even with plenty of the
   other asset sitting unused next door.

   The consequence is that supplying to either market means accepting a bounded
   amount of LP exposure with no opt-out. That has to be stated plainly in the
   market documentation rather than left implicit.

`DeployRobinhoodBoostedDelegator.s.sol` currently reads
`vm.envUint("PRIVATE_KEY")`. The vault repository forbids plaintext key env vars
and binds every broadcast to an explicit public address with `--account`. Bring
this script to that standard before it touches mainnet.

## Feed availability

The RHNVDA/USD feed `0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15` is
deviation-triggered at 0.5% with **no off-hours heartbeat**. Over its first nine
weeks (886 rounds from 2026-06-22):

| Staleness bound | Wall-clock time stale |
| --- | ---: |
| 6h | 34.2% |
| 12h (vault's configured bound) | 25.9% |
| 24h | 17.8% |
| 48h | 4.2% |

Weekend gaps run ~52h and occurred in ten of ten weekends; the July 4 holiday
produced a 76h gap. LP-backed exits fail closed during those windows. Exits from
a pair with **no open LP liquidity** need no oracle and stay available, which is
why keeper policy should close liquidity ahead of known session gaps.

## Leveraged margin

The isolated margin stack is chain-agnostic. A position names three markets
(`marginPToken`, `positionPToken`, `debtPToken`), so it works against boosted
markets unmodified. Robinhood Chain lacks two chain-specific seams:

- **`RobinhoodV4RouterAdapter`** implementing `IMarginRouterAdapter.swap` over
  the Universal Router, modelled on `QuickSwapV4RouterAdapter` (owner-set router,
  pair whitelist, operator gate, deadline buffer). Robinhood's deployed Universal
  Router uses the newer v4 swap ABI carrying `minHopPriceX36`, which the pinned
  PositionManager predates — copy
  `UniswapV4PairedAdapter.RouterExactInputSingleParams` from the vault repo,
  which mirrors the deployed encoding, rather than deriving it from the pinned
  library. Otherwise every swap reverts on decode.
- **`IMarginPriceOracle`** wrapper. It needs only `getPrice(asset)` in USD 1e18
  and `marketAsset(pToken)`. Wrap the same `StockSimplePriceOracle` used by the
  markets so margin and lending cannot drift onto different prices.

Then deploy through `DeployMarginStackWithProxies.s.sol` and set `PairRiskConfig`.

## Hardening: the exchange-rate fallback

**Not a blocker.** An earlier draft of this document called it one, on the
assumption that a feed outage could trigger it. That is wrong and is corrected
below.

`RobinhoodBoostedDelegate._vaultAccountedAssets()` returns `0` when the vault
read reverts, and `exchangeRateStoredInternal` computes:

```solidity
uint256 managedCash = super.getCashPrior() + _vaultAccountedAssets();
```

A failed read therefore removes the entire vault claim from the exchange rate.
That is correct for redemption — never over-credit a withdrawer — and wrong for
collateral. `IsolatedMarginRiskEngineUpgradeable.pTokenValueUsd` values a
position as:

```solidity
underlyingFromPToken(pTokenAmount, PErc20(pToken).exchangeRateStored()) * price(asset)
```

So a vault read failure would price every boosted-pToken collateral position at
close to nothing, making every margin account backed by one liquidatable at a
valuation that is not real.

**How often can that actually happen? Rarely.** `accountedAssets` is a pure
ledger read:

```solidity
function accountedAssets(bytes32 pairId, address token) external view returns (uint256) {
    (, uint256 principal) = _sideAmounts(pairId, token);
    return principal;
}
```

It touches no oracle and reverts only on `UnknownPair` or `UnsupportedToken`. A
stale feed does **not** trigger it. The failure needs a genuine vault fault: an
unregistered pair, a token that is not one of the pair's two, or the vault proxy
pointing at broken code. Collateral valuation is therefore oracle-independent,
and the 25.9% stale window above does not put margin positions at risk of
wrongful liquidation.

The oracle-dependent read is `withdrawableAssets`, which feeds `getCashPrior`.
That governs borrow and redeem availability, and a liquidator's ability to exit
seized collateral — not valuation.

Fix it anyway, as defense in depth: if the vault ever is broken, mass wrongful
liquidation should not compound the failure.

The strict path already exists. During `mint` the delegate sets
`mintVaultAssetsValidated`, which makes the same read revert instead of
degrading, so a new supplier cannot mint at a fake-cheap rate. The asymmetry is
already recognized; it was simply never extended to collateral valuation.

**Fix: oracle-side.** Have the Robinhood `IMarginPriceOracle` return
`address(0)` from `marketAsset(pToken)` when that pToken's vault read is
currently failing. `pTokenValueUsd` already reverts `PriceUnavailable` on a zero
asset, so the valuation fails closed instead of computing a collapsed number.
This is per-pToken, chain-local, and needs **no changes to the shared margin
core**.

Rejected alternative: an `exchangeRateStoredStrict()` on the delegate. The risk
engine reads `exchangeRateStored()` from `pTokenValueUsd`, the quoter, the
executor and the liquidator, all shared with the Avalanche markets, so a strict
variant means editing every one of those call sites for a Robinhood-specific
problem. Note also that `getPrice(asset)` cannot carry the fix: it only sees the
asset, so returning zero there would poison USDG for every market that uses it.

The deliberate tradeoff is that liquidations on these markets are blocked during
a vault outage rather than executing at a fake price. A wrongful mass liquidation
is unrecoverable and a delayed one is not, and this is consistent regardless:
`StockSimplePriceOracle`'s staleness check already blocks NVDA liquidations in
the same window.

## Risk parameters

| Parameter | Value | Reasoning |
| --- | --- | --- |
| Collateral factor | 80% | Impermanent loss is not the binding constraint. Measured: the NVDA earnings print cost ~0.12% IL; a full 2x move costs ~4.6% at a 20% buffer. |
| `vaultBufferMantissa` | 30% | Must survive a full weekend unreplenished — `_rebalanceVault` cannot refill from the vault while the oracle is stale. |
| Borrow cap | hard cap | Nothing else stops borrowing from draining local cash below the weekend buffer. The IRM kink only discourages it. |
| Liquidation incentive | 10% | Seizing a pToken needs no oracle; redeeming it does. A liquidator may hold seized pTokens across a gap. |
| Reserve factor | 10–20% on borrow interest | Keep separate from the vault's `reserveFeeBps` (20% of LP fees). Different pots; do not double-tax. |
| `maxLeverageX100` | 200 (2x) initially | Loss is recognized in discrete steps at `checkpoint`, so positions at maximum leverage feel the jump. Raise only after a full earnings cycle of observed exchange-rate behaviour. |

## Sequencing

1. **Lending base on 4663.** `Peridot` token, `StockSimplePriceOracle`,
   `Unitroller` + `PeridottrollerRobinhood`, `PErc20Delegate`, rate model, close
   factor and liquidation incentive. Nothing below can start until this exists.
2. **Both boosted pTokens**, deployed by the now side-neutral
   `DeployRobinhoodBoostedDelegator` with `UNDERLYING` set per side, then listed
   on the controller with collateral factors and borrow caps.
3. **Register the production `NVDA/USDG` pair** in the vault with each pToken as
   its side account, everything paused, then configure the delegates.
4. Production pair canary **with the reserve funded** — this also closes the one
   waterfall leg the vault's post-upgrade canary could not reach, since the
   reserve was empty and the deficit went straight to the settlement swap.
5. Markets live for supply and borrow, with the parameters above.
6. Margin adapter and oracle, with a pinned fork test against the live Universal
   Router the way the vault's adapter has one.
7. Margin stack deployment and a single conservative pair at 2x.

## Open decisions

- **Governance multisig address.** Gates production TVL. The two-phase migration
  tooling in the vault repo is written and tested and waits only on an address.
  Deferred for now; the timelock's roles remain with the deployer EOA.
- **Rate model parameters**, and in particular the real block time on 4663, which
  sets `LENDING_BLOCKS_PER_YEAR`.
- **Seed amounts and borrow caps** for the first two markets.
- **Confirm the oracle-side fix** for the blocking finding, rather than a strict
  delegate method. The recommendation is above; it needs a sign-off because it
  means liquidations fail closed during a vault outage.
- **Disclosure wording** for the bounded-exposure model now that the dial is
  settled. Neither market offers an opt-out, so the risk statement has to be
  explicit at the point of supply, not buried in docs.
