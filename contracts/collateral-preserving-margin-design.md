# Collateral-preserving AVAX/USDC margin

Status (22 September 2026): fresh collateral-preserving executor and risk engine
integrated locally with opening quotes, partial/full closing, partial/full
liquidation and explicit cash-insurance settlement. Local scoped verification
passes (see final evidence below). Not deployed or externally scanned. The old Fuji deployment and
its tests do not validate this new stack.

## Confirmed requirements

- Isolated accounts only; AVAX/USDC long and short trading (WAVAX on chain).
- Both Pharaoh boosted markets are required at launch: USDC/USDt and
  sAVAX/WAVAX. The user explicitly confirmed these two on 21 September 2026.
  Each still requires a reliable liquidation exit.
- Allocated collateral remains invested as its original boosted pTokens while
  a position is open. Normal opening must not redeem those shares.
- Borrowing interest accrues on debt; no separate perpetual funding mechanism.
- Fees remain configurable and distributed to the same exact collateral-pToken
  pool, not pooled across unrelated pTokens or merely matching symbols.
- Withdrawals return free pTokens without mandatory redemption.
- Approved settlement policy: a closed Pharaoh deposit cap must not force a
  profitable exit to remint boosted collateral. Return remaining original
  collateral pTokens plus USDC surplus; fees stay in the original pToken pool.

Collateral preservation is not principal protection: fees, realized losses and
liquidation can consume collateral. It cannot mean that all original shares are
returned unchanged after a losing position.

## Separate collateral from trade accounting

The proposed trade-leverage convention is marked trading exposure divided by
remaining equity, not total assets divided by equity. For an idealized opening,
$100 retained collateral plus $500 borrowed and traded gives $600 assets, $500
debt, $100 equity and 5x **trade** leverage. This is a different metric from the
legacy executor's gross-asset leverage. UI/quotes must name it accordingly.

The new pure `CollateralPreservingMarginMath` library takes disjoint USD values:

    equity = eligible collateral + trading assets - accrued debt - reserved exit costs
    initial requirement = ceil(trading exposure * initial margin ratio)
    maintenance requirement = ceil(trading exposure * maintenance margin ratio)

Long trading exposure is the marked WAVAX trade holding; short trading exposure
is the marked WAVAX trading debt. Original collateral is valued separately.
If collateral and trading holdings use the same pToken, their shares must be
partitioned; never count an account balance twice. Haircuts, oracle validation,
strategy NAV and available exit liquidity are integration responsibilities, not
properties proven by this arithmetic library.

An AVAX-linked collateral position adds its own price exposure: $100 AVAX
collateral plus a $500 AVAX long has $600 of AVAX sensitivity at entry. Conversely,
the same collateral offsets part of an AVAX short. The UI must not imply that 5x
trade leverage describes total portfolio sensitivity or guarantees a common
liquidation price across all collateral types.

With stable $100 collateral, a $500 trade, 10% maintenance and no costs/interest,
the illustrative long boundary is AVAX $8.888... from a $10 entry; the short
boundary is $10.909.... These are mathematical examples, NOT approved production
parameters. Fees, price gaps, collateral losses and exit liquidity can reduce
these cushions. Opening quotes must reserve execution costs: a nominal $500 trade
that immediately loses $5 no longer satisfies a 20% initial-margin requirement.

## Integrated execution path

- `CollateralPreservingRiskEngine` is a fresh, non-proxy hook with a one-time
  executor binding. It accepts exactly the two pinned Pharaoh collateral markets
  and the two plain trading/debt markets, with a common controller and unchanged
  underlying/vault-asset identity. Collateral valuation weights are immutable
  constructor inputs, independent of spot collateral factors. Production weights
  still require approval; local fixtures use 100% only for testing.
- Opening sizing uses a bounded binary search with actual flash fees, minimum
  swap output, pToken mint rounding and two underlying units of debt-rounding
  headroom. Equity also reserves closing fees, flash repayment costs and swap
  slippage. Thus requested 5x is an upper bound, not an exact notional guarantee.
- `CollateralPreservingExecutor` retains original collateral in the isolated
  account. Flash debt is swapped, supplied to the position market, then replaced
  by a real account borrow. The controller invokes the new projected-risk hook.
  Opening asserts that the original collateral share balance did not change.
- Owner closes repay a debt fraction, redeem the matching trading-share fraction,
  settle that slice, and pay USDC surplus. Partial closes retain unused original
  collateral; consumed shares reduce the vault lock and reward eligibility.
  Remaining health cannot deteriorate. Full close requires raw zero debt and
  returns remaining original pTokens to the vault for pToken-native withdrawal.
- Permissionless liquidation first requires current maintenance failure. Partial
  liquidation respects the configured fraction cap and must strictly improve
  health. Full liquidation is allowed at the configured deep-unhealthy threshold,
  dust debt, or when remaining equity cannot cover the full proportional keeper
  bonus. Keeper compensation is in original collateral pTokens; liquidation does
  not additionally collect the ordinary closing fee.
- Full insolvency can use explicitly bounded **USDC/WAVAX cash** from the existing
  insurance fund after selling available user collateral. Unused insurance goes
  back to that fund, never to user profits. This fresh-stack liquidity requirement
  is different from the legacy pToken-funded liquidation path; pToken fee receipts
  do not automatically replenish cash insurance. Budget and treasury operations
  remain launch decisions, not authorized funding transactions.
- Flash callbacks bind lender, initiator, token, amount, fee and encoded action;
  the callback is consumed once, balances reconcile after repayment, and transient
  approvals clear. All failures revert atomically. The legacy executor, risk hook,
  swap module and existing deployments remain unchanged.

## Release work still required

1. Review this complete new execution/risk/rounding/insurance path independently.
2. Add a fresh paused deployment/configuration package; never upgrade a legacy
   proxy blindly or point old accounts at these incompatible risk semantics.
3. Test the whole intended integration on actual Avalanche asset/venue/strategy
   forks, then deploy a separately approved fresh Fuji stack and verify receipts
   and full lifecycle, including keepers. Current real-vault forks only validate
   small conversions, not this whole lifecycle or production liquidity.
4. Approve production weights, fees, caps, flash/debt liquidity, funded cash
   insurance, vault capacity, governance, keeper operation and monitoring.
5. Resolve operational exit recovery: stale prices currently block normal closes;
   there is no special stale-oracle debt-free in-kind recovery entry point yet.
   Failed Pharaoh redemption is not bypassed merely because cash insurance exists.
   Insufficient insurance reverts insolvency liquidation; no bad-debt writeoff or
   socialization mechanism is implemented. These are launch risks, not passing-test
   guarantees of solvency or universal exit liveness.

## Confirmed market inventory and deployment inputs

The user confirmed precisely these two Pharaoh markets. Other-chain implementations,
including Magma's WMON/Monad integration, are not part of this Avalanche collateral scope.

Read-only Avalanche snapshot 95834867, hash
`0xa476d7f27419e019fdc7128bb100498b0c12054a06684ed752e017653098efcb`,
21 September 2026 13:23:31 UTC:

| Vault | Address | Reported total assets | Deposit capacity |
| --- | --- | ---: | ---: |
| USDC/USDt | `0x855bF832f26a294d28500db59eE941dE3d654129` | 29.867192 native USDC | 0 |
| sAVAX/WAVAX | `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` | 1.730060717251818109 WAVAX | 0 |

Both `owner()` values are `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12`.
That Safe holds the complete existing share supply in each vault. `maxDeposit`
was zero for both the Safe and the user's deployer, and `maxMint` was zero for
the deployer. The vaults reported `maxRedeem(Safe)` equal to their share supplies;
these are view results, not executed redemptions or a guarantee at production size.
No ownership, caps, balances or other on-chain settings were changed.

Deployment planning initially required locating the Peridot pTokens/controller and
plain USDC/WAVAX borrowing markets. The address-record review below resolves the
working plan. Launch still requires vault deposit capacity and strategy liquidity;
no cap change is authorized here.

Update, 21 September: the user directed checking `addresses.MD` and stated that
they created both vaults and are the sole Safe owner. The complete address file
has no Avalanche mainnet Peridot deployment listed; no local broadcast JSON files
under chain 43114 were found. Prepare fresh markets as the working plan, not as
a proof that no unrecorded deployment exists on-chain. Do not reuse BNB/Monad/Fuji
addresses just because their labels include USDC or WAVAX.

Read-only Safe check at Avalanche 95835311, hash
`0x120f8d1ad448c264a7c4380388b52944546d8e79499d0d74e57dce694819659f`:
`getOwners()` contains only `0x94696d767e65a75581145646960FA0eC886cE5d2`,
and `getThreshold()` is 1. This resolves who can coordinate vault settings; it is
not approval to change caps or proof of multi-party governance.

## Supporting modules and approved settlement policy

- `PharaohMarginRouterAdapter`: immutable vault/base/router bindings; caller-only
  approved funds; share redemption, base-asset swap and share deposit; explicit
  capacity and output checks; measured balance changes and cleared allowances.
  It does not redeem Peridot pTokens or implement custody/position settlement.
  A restricted LFJ adapter must separately authorize this wrapper through its
  own governance. Protocol oracle/slippage enforcement remains required upstream.
- `PharaohMarginOracle`: immutable market/share bindings, actual underlying
  verification, share USD-WAD prices from `PharaohVaultShareOracle`, base-asset
  prices from the base margin oracle. Stale/unavailable share prices do not fall
  back to plain-asset prices. Does not itself prove liquidity or enable markets.

The user approved the USDC-profit fallback. The new
`CollateralPreservingSettlementModule` implements the cash-exit route without
any Pharaoh deposit or pToken mint. It preserves original collateral in kind
and collects an executor-specified closing fee through the existing distributor,
keyed by the exact original collateral pToken. This removes dependence on *new
deposits* for surplus settlement, not redemption liquidity for losses.

The module is **not an executor or a liquidation implementation**. It accepts only
caller-approved balances and returns all outputs to that caller. The new executor
must first repay the account's debt (using flash funding), redeem its trading
pTokens, authorize the user's collateral/fee limits, and supply position-specific
balances. Settlement converts trading proceeds to the debt asset, sells bounded
collateral only for a deficit, reserves the specified flash principal plus fee,
and converts surplus to USDC. The executor must repay the flash lender, return
remaining pTokens through the margin vault, update all locks/reward shares, and
pay surplus to the owner in the same atomic transaction. The new executor now
performs this integration for complete or partial position slices; the old
executor must not call this module unchanged.

Rounding exception: a WAVAX surplus valued below one USDC base unit cannot be
swapped into USDC. It is returned separately as `surplusWavaxDust`, never counted
toward the specified repayment or the user's USDC minimum. The integrating
executor must refund that dust to the owner. This prevents a one-wei remainder
from blocking a close; representable profits still use USDC.

Collateral sale sizing uses accrued pToken exchange rates and oracle conversion
with a slippage reserve. Better execution may leave a small USDC surplus from
over-redemption; that surplus is not necessarily trading profit. There is no
guarantee that every solvent position is executable: unavailable collateral exits,
stale prices, insufficient user budgets or insufficient swap output revert the
whole settlement. Partial-close health and liquidation eligibility are enforced
by the new executor/risk hook, not by this permissionless caller-funded module.
Caller-provided insurance is accounted separately and used only for the remaining
repayment deficit after the allowed collateral sale; the executor authorizes
insurance only for full liquidation and requires all available collateral first.

`CollateralPreservingSwapModule` is a separate versioned dependency; the new
settlement module rejects a legacy swap module without its version marker.
Fractional-debt fuzzing exposed a mismatch in the legacy swap module between
token-rounded output and an unrounded USD-value check. The new module applies
the stricter of the slippage/deviation limits in output base units and also
honors any stronger user minimum. Oracle output and percentage floors each
round down: their combined quantization is less than two output base units
(in addition to the oracle's USD-WAD valuation precision). Zero-output swaps
are always rejected. This is not an additional percentage slippage allowance.
The existing deployed/legacy module is unchanged. The new numerical policy and
version boundary must be included in external release review.

## Historical building-block verification

15 accounting tests plus 33 existing core regression tests passed (48 total),
including two new fuzz properties at 1,024 runs each:
equity conservation, collateral yield, debt growth, opening-cost headroom,
stable/volatile collateral liquidation examples, negative equity, rounding and
input validation. These tests do not exercise custody, trading, adapters,
settlement, market liquidity or a complete liquidation implementation.

Existing production contracts and live Fuji state are unchanged by this module.

Additional verification: 14 conversion-adapter tests (one 1,024-run fuzz property)
and 9 share-oracle tests passed. Four actual-vault local-fork tests at 95834867
passed: redeem 10% of the Safe's seed shares through each vault and reject entry
to both closed vaults without spending funds. Existing shares are transferred by
local VM impersonation only, not via live signing. The DEX mock is not invoked
in these four fork cases; they prove small share/base conversions, not production
liquidity, full cross-asset routing or the new margin lifecycle.

Final combined run: 75 tests passed, zero failures or skips (42 new foundation/
oracle/conversion cases and 33 legacy core regressions). Scoped formatting passed.

Settlement-stage verification supersedes the earlier counts above. The local
fixture uses the real Peridot controller, plain lending delegates, Pharaoh
boosted delegates, share oracle, conversion adapter, swap module, fee distributor,
account/factory and margin vault. The ERC4626 strategies, feeds, swap venue and
zero-rate interest model are mocks. It tests both collateral types and trading
directions with deposits closed, bounded losing exits, collateral yield, exact
repayment separation, configurable same-pool fees, return/withdrawal of pTokens,
atomic failure, binding changes, preserved donations and cleared allowances.
It supplies trade proceeds and repayment amounts directly: it does **not** open
leveraged positions or validate a new borrowing hook, live debt payoff, flash
callback, partial close or liquidation. The existing four actual-vault fork
conversions were rerun successfully; those are still not full margin lifecycles.

Prior settlement-stage verification: 122 local tests passed, plus four pinned actual-vault fork
conversion tests (126 scoped cases total, zero failures/skips). The 41 new
settlement/swap tests include three 1,024-run fuzz properties; accounting adds
two and the adapter adds one. Formatting and diff checks passed. Deployed runtime
sizes under `debt_accounting`: settlement 9,717 bytes; new swap module 2,861 bytes.
None of these new modules has external Almanax/Ozone scan coverage yet.

## Integrated liquidation-price checks

The local $100-margin, requested-5x fixture uses $10 AVAX entry, 20% initial
margin, 10% maintenance, 1% execution bounds, no trading/flash fees, no accrued
interest and 100% collateral NAV weights. Actual entry sizing includes execution
reserves. Binary-searching the **integrated** risk hook produces:

| Original collateral | Trade | AVAX liquidation boundary | Adverse move |
| --- | --- | ---: | ---: |
| Pharaoh USDC/USDt pToken | Long | $8.78764039 | 12.12% |
| Pharaoh USDC/USDt pToken | Short | $10.99909093 | 9.99% |
| Pharaoh sAVAX/WAVAX pToken | Long | $9.02608534 | 9.73% |
| Pharaoh sAVAX/WAVAX pToken | Short | $11.24872176 | 12.48% |

Distances are rounded down in basis points. They are regression examples, not
mainnet parameters, liquidation guarantees or a promise that every 5x-request
position has this buffer. Yield, interest, price gaps, strategy losses, haircuts,
fees and execution liquidity change the result; keeper execution occurs after
eligibility, not necessarily at the boundary.

## Final local integration verification (22 September 2026)

- 122 building-block/legacy regression tests passed, zero failures/skips.
- 26 additional lifecycle tests passed, including 16 separate 2x/3x/4x/5x
  long/short round trips across both collateral types, partial/full liquidation
  across all four combinations, interest/flash costs, fee allocation, consumed
  collateral reward accounting, price/NAV shocks, access control, callback
  rejection, paused/disabled gates and bounded failure scenarios.
- The lifecycle fuzz test ran 1,024 opening/partial/full-close combinations;
  six supporting fuzz properties also ran 1,024 cases each.
- Four pinned actual-vault conversion fork tests passed separately at block
  95834867. Total: **152 scoped tests**, without double-counting inherited fixture
  tests. This is not a whole-repository test run or a real-venue full-margin fork.
- Formatting and diff checks passed. Targeted high-severity production lint
  reported no high findings; existing Foundry configuration and dependency
  NatSpec warnings remain. Runtime sizes under the release
  `debt_accounting` profile: executor 23,127 bytes; risk engine 16,009;
  settlement 10,404; swap module 2,861. All fit EIP-170; the executor has limited
  headroom. Code-size assertions are in the lifecycle suite.

Reproduce the additional lifecycle coverage with:

```sh
FOUNDRY_PROFILE=debt_accounting forge test \
  --match-contract '^CollateralPreservingLifecycleTest$' \
  --match-test testLifecycle --threads 1 --fuzz-runs 1024 \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol \
  --skip P_OFTAdapterUpgradeable.t.sol
```

No mainnet/Fuji transaction, wallet access or existing deployment modification
was performed. External review must cover the new complete diff, not reuse the
clean Almanax result for the older `160f3585` commit.
