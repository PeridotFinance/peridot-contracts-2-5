# bpPHAR-USDC listing: the exact Ledger calls, ordering and analysis (18 Nov 2026)

Market: the share token of the Peridot Pharaoh DLMM USDC/USDt ERC-4626 vault (`0x278B1b625C74B1926C5F989ddE601f3C5Ba27f7D`, 6 decimals, asset USDC), listed on the LIVE Avalanche pilot controller `0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A` (admin = the Ledger EOA `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`, not the Safe). Everything below is PREPARED, NOT RUN. The tool is `contracts/tools/bp-dlmm-ceremony.sh`; the script is `contracts/script/DeployPharaohBoostedMarketsAvalanche.s.sol`.

## 1. What is deployed (stage 0, signer: a throwaway deployer, no role kept)

| contract | notes |
|---|---|
| `PharaohBoostedDelegate` | market implementation. Changes vs the plain PErc20Delegate: (a) `flashLoansPaused = true` set at `_becomeImplementation`; (b) while the pToken supply is 0 only the pToken admin can `mint` (`PharaohBoosted__SeedPending`). |
| `PErc20Delegator` | underlying = vault share, controller = live controller, rate model `0xe5a8...6263`, **initial exchange rate 2e14** (0.02 x 10^(18+6-8), the pilot pUSDC rule; pUSDC reads 200000577777828 today), name `Peridot Boosted Pharaoh DLMM USDC/USDt`, symbol `bpPHAR-USDC`, 8 decimals, **admin = the Ledger from the constructor** (the delegator assigns `admin = admin_` last, so no `_setPendingAdmin`/`_acceptAdmin` round trip, no second signature, and the deployer is never admin after its transaction). become-data `(vault, 1_000_000)`. |
| `PharaohDlmmShareOracle` | wrapper, stateless and ownerless: immutables `baseOracle` (the live guarded oracle `0x7BAB...aFC0`), `market`, `vault`, `vaultAsset`. No function adds or replaces a vault or changes the base oracle; rollback is `controller._setPriceOracle(baseOracle)`. |

Runtime sizes (ceremony profile `debt_accounting`, solc 0.8.35, via_ir, runs 1; limit 24,576): delegate 19,379, delegator 6,251, wrapper 2,258, BorrowAccountingModule 2,752. Delegate and module carry an immutable (PToken creates its BorrowAccountingModule in its constructor), so the pinned hashes are over the runtime with immutables zeroed: `tools/bp-dlmm-ceremony.sh verify-deployed` does that comparison and checks the module's own code.

### Vault compatibility (read from `/Users/joshua/Peridot/.wt-dlmm-int/contracts/vault-dlmm/src`)
The delegate and wrapper call only: `asset()`, `decimals()`, `totalSupply()`, `convertToAssets(10^decimals)` (and the view helpers `totalAssets()`, `convertToAssets`). The pToken itself only does ERC-20 `transferFrom`/`transfer` on the share. All satisfied by the DLMM vault: decimals = asset decimals = 6 (OZ ERC4626 offset 0); `asset()` = USDC; `convertToAssets` = floor(1e6 x (totalAssets+1)/(supply+1)), about 1.0 USDC today; `totalAssets()` REVERTS (`FeedInvalid`) on a stale/bad Chainlink feed, which the wrapper and the delegate treat as "price unavailable" (wrapper returns 0, never reverts; `_becomeImplementation` reverts `InvalidVault`, so a listing build fails closed); `paused()` blocks only deposit/mint/openBand/rebalance, never a share transfer, so a paused vault does not freeze pToken mint/redeem; the deposit cap and the min-supply rule (`MIN_SUPPLY = 1e6`, deposit side only) are not touched by the pToken (it never deposits); shares are a plain ERC-20 (no hooks, no fee). `convertToAssets` OVERSTATES the realisable USDC (swap fee and the pool's standing discount fall on the redeemer; vault NatSpec says so): at CF 50% that haircut is covered, but the oracle prices the NAV, not the exit value. No CL-vault-specific call is made (the old script's `depositCap == 1` assertion is gone; the script asserts asset, owner = Safe, EIP-1967 admin slot = ProxyAdmin `0x7037...`, ProxyAdmin owner = Safe, implementation slot = `0x7F20...`, not paused, price available, Ledger holds >= the seed). The share's PHAR rewards are an OFF-CHAIN distribution by share balance: shares held by the pToken accrue to the pToken contract address, which cannot claim (integrator decision: attribute or exclude).

## 2. Every on-chain consumer of the oracle, and what the swap does

Source: grep of `contracts/contracts` for `oracle`, `getUnderlyingPrice`, `getPrice`, `marketAsset`.

| consumer | pointer | functions | after `_setPriceOracle(wrapper)` |
|---|---|---|---|
| Peridottroller (live impl `PeridottrollerAvalanche`) | storage `oracle` | `getUnderlyingPrice(pToken)`: in `borrowAllowed` (borrowed market), `getHypotheticalAccountLiquidityInternal` (EVERY asset the account entered, even at zero balance), `liquidateCalculateSeizeTokens` (both markets), `_setCollateralFactor` (CF != 0 refused on price 0) | reads the wrapper: identical values for every existing pToken; PRICE_ERROR semantics unchanged |
| PeridotLens | `peridottroller.oracle()` per call | `getUnderlyingPrice(pToken)` | wrapper, identical |
| IsolatedMarginRiskEngineUpgradeable | OWN storage `oracle` (set at initialize = guarded oracle) | `marketAsset(pToken)`, `getPrice(asset)` | unaffected (still the guarded oracle) |
| IsolatedMarginLiquidatorUpgradeable | `riskEngine.oracle()` | `marketAsset`, `getPrice` | unaffected |
| IsolatedMarginQuoter | immutable `oracle` | `marketAsset`, `getPrice` | unaffected |
| AvalancheMarginCloseAdapter | immutable `oracle` | `getPrice(underlying)` | unaffected |
| executor, config, margin vault, order registry, swap module, flash vault (`SimpleFlashLoanVault`) | none | (price via quoter / risk engine / adapter) | unaffected |
| off-chain: `operator/src/chain.ts` line 85 | reads `controller.oracle()` and throws if it differs from its configured oracle; then `getUnderlyingPrice(pToken)` | | **every operator/treasury keeper halts after the swap unless the build accepting the wrapper is already on the hosts** |
| scripts/tests that assert `controller.oracle() == guarded oracle` | | | `script/DeployAvalancheMarginMainnet.s.sol` lines 152/228/269 (`d.oracle` equals the controller's) would fail if re-run after the swap; fork tests at pinned blocks are unaffected |

Because the margin stack holds its own pointers, the wrapper's `getPrice`/`marketAsset` are forwarded VERBATIM to the base oracle for every argument (parity for read tooling and a future repoint). The share market is deliberately NOT a margin market: `marketAsset(bpPHAR)` stays 0.

Wrapper identity (tested, fuzzed): for every pToken other than the one market, `getUnderlyingPrice` = `baseOracle.getUnderlyingPrice(pToken)` through a plain external call (same value, a base revert is the wrapper's revert, an address without code is not special-cased; the old CL wrapper probed `underlying()` first and would have reverted there). Nothing on that path reads the vault, the market or storage.

Share price: `convertToAssets(1 share) x baseOracle.getPrice(USDC)`, scaled 10^(36-6), i.e. 1 share = 1.0 USDC = 1e30 at par. Using the base oracle's USDC price (the one pUSDC is priced with) removes a second feed configuration and makes the USDC price cancel in a bpPHAR/pUSDC health comparison. Fail closed (returns 0, never reverts) on: vault revert or short return, `asset()` changed, zero/oversized value, base USDC price 0 or reverting. Extension point for a rate limiter: `_guardPrice(rawPrice)` (identity today, `internal virtual`, applied only to the share market).

## 3. The ordered Ledger calls (`tools/bp-dlmm-ceremony.sh print-ledger-calls <rehearsal|live> [1|2|3|4|rollback]` prints each as `cast call --from Ledger` (simulate FIRST) + calldata + `cast send` + read-back)

Preconditions: `pin` equals this document; `deploy` done and `verify-deployed` OK; the keepers' build that accepts the wrapper is on the hosts BEFORE T1; `check` passes (vault feeds fresh). Return codes: `_supportMarket`, `_setPriceOracle`, `_setCollateralFactor` RETURN an error code (0 = success) instead of reverting, so read the simulation.

| # | transaction (signature) | arguments | expected | exists on Avalanche |
|---|---|---|---|---|
| T1 | `controller._setPriceOracle(address)` | wrapper | returns 0; `oracle()` = wrapper; `verify-listing 1` | yes |
| T2 | `controller._supportMarket(address)` | market | returns 0; listed, CF 0 | yes |
| T3 | `controller._setBorrowPaused(address,bool)` | market, true | returns true | yes |
| T4 | `controller._setMarketBorrowCaps(address[],uint256[])` | [market], [1] | `borrowCaps` = 1 (0 means UNLIMITED; 1 fails every borrow); `verify-listing 2` | yes |
| T5 | `vault.approve(address,uint256)` | market, 1000000 | exact seed, not unlimited | |
| T6 | `market.mint(uint256)` | 1000000 | returns 0; Ledger pToken = 5,000,000,000; supply 5,000,000,000; cash 1,000,000; exchange rate still 2e14 | |
| T7 | `market.transfer(address,uint256)` | 0x...dEaD, 5000000000 | the WHOLE seed to the dead address; Ledger keeps 0 pTokens | |
| T8 | `controller._setMintPaused(address,bool)` | market, true | `verify-listing 3` | yes |
| (activation, only after the fork liquidation test passes and `verify-listing 3` is OK) | | | | |
| T9 | `controller._setMintPaused(address,bool)` | market, false | skip if supply must stay closed | |
| T10 | `controller._setCollateralFactor(address,uint256)` | market, 0.5e18 | returns 0 (the controller refuses CF != 0 with PRICE_ERROR if the oracle prices the market 0); `verify-listing 4` | yes |
| R1 | `controller._setPriceOracle(address)` | 0x7BAB5406Cb4929f9b9492e1b2a43b65BF93AaFC0 | the ONE-transaction rollback | |

- Flash loans of the share market: paused from birth by the delegate (no transaction); `verify-listing` asserts `flashLoansPaused()`.
- `_setBorrowCashFloor(pToken,uint256)` exists in `PeridottrollerAvalanche`; I do NOT use it for the share market (pause + cap 1 already stop every borrow; each extra Ledger signature is a cost). It can be added as a third lock (e.g. `type(uint128).max`) if wanted.
- Pause/cap are set BEFORE the seed, and the wrapper is installed BEFORE listing, see section 4.
- The existing 200 USDC pUSDC borrow cap and the 50 USDC pUSDC cash floor are not touched (`verify-listing` logs them).

## 4. Ordering decision and the windows

**Oracle swap FIRST (T1), listing after.** Alternative (swap last) leaves the market listed while the OLD oracle prices it 0. Because `enterMarkets` needs no balance and no condition, any account (for example an existing pUSDC borrower) can enter a listed market for free; once entered, every liquidity computation of that account runs `getUnderlyingPrice(bpPHAR)`, and price 0 returns PRICE_ERROR, which blocks borrow, redeem, pToken transfer, `exitMarket` AND the account's own liquidation (`liquidateBorrowAllowed` returns the error). Swap-first closes that window completely; before listing nobody can enter. The wrapper is verified read-only against the live state before T1 (`verify-deployed`: identity for every listed market and the margin surface), so the swap is no riskier early than late, and a failure before T2 is a clean one-transaction rollback with nothing listed.

**Window between `_supportMarket` (T2) and the seed (T6): can an outsider mint?** No, by code: while the pToken supply is 0 `mint` reverts for everyone except the pToken admin (the Ledger), whatever shares the outsider holds. The vault's own ~183 USDC of open deposit headroom therefore does NOT make the listing unsafe, and the vault does NOT need to be closed first. An atomic helper is not possible (the controller admin is an EOA; a helper would have to be the controller admin) and not needed. A direct share donation to the pToken before the seed does not change what the seed mints (supply 0 means rate = initial rate); it only raises the post-seed exchange rate, which `verify-listing 3` would catch (`exchangeRateStored == 2e14`), and the dead seed owns the donation. Between T2 and T3/T4 the market is listed and priced but borrowing it fails because its cash is 0; T3/T4 come before any shares enter it (T6).

**Seed size: 1,000,000 share-wei (1 whole share, about 1 USD), minting 5,000,000,000 pToken-wei, all to the dead address.** The Ledger holds 16,000,000 of 17,000,000 shares; the seed costs 6% of that and leaves 15 shares for the fork test and the first supply. Justification (first-depositor / donation inflation of the pToken exchange rate): at the initial rate 1 pToken-wei = 2e-4 share-wei, so the pToken is 5,000 times finer than the share; the exchange rate after a donation D is (seed + D) x 1e18 / 5e9. The vault's own hard ceiling is `DEPOSIT_CAP_CEILING` = 200,000,000 share-wei (raising it needs a Safe-signed implementation upgrade), so D can never exceed about 2e8 and the rate can never exceed about 4e16 (0.04 share-wei per pToken-wei): a mint or redeem loses less than 1 pToken-wei, under 4e-8 USD, and the truncating `redeemUnderlying` profit (Hundred-style) needs a rate above 1e18, 25 times beyond the maximum. The dead seed also owns 100% of any donation, so a donor only pays. The test `testDonationAfterTheSeedCannotHarmALaterSupplierMaterially` checks it. If the vault ceiling is ever raised, keep the same margin with seed (share-wei) >= ceiling (share-wei) / 200 (today 200,000,000 / 200 = 1,000,000; a 20,000 USDC ceiling would need 100 shares).

**Mint pause after the seed (T8).** Nobody else supplies until activation (CF 0 gives a supplier nothing; this removes the free-entry exposure of section 5 until the product is live). T9 reopens supply at activation.

## 5. What freezes if the OLD oracle prices the new pToken at 0 (rollback), and in a price outage

The guarded oracle returns 0 for the share market (`marketAsset(bpPHAR)` = 0), and the wrapper returns 0 whenever the vault cannot price (its `totalAssets` reverts on a stale feed). The controller's reaction to a 0 price is identical in both cases. For an account that ENTERED the market (`enterMarkets`, unconditional and free): `getHypotheticalAccountLiquidityInternal` returns PRICE_ERROR, so `borrowAllowed` for any of its borrows, `redeemAllowedInternal` (redeem, pToken transfer, `exitMarket`) and `liquidateBorrowAllowed` against it all fail until a price returns. Its funds are not lost; `repayBorrow` (no liquidity check) keeps working; accounts that never entered the market are completely unaffected (liquidity only iterates the entered assets). Consequences:
- Rollback with nobody in the market (check `tools/bp-dlmm-ceremony.sh members`) freezes nobody. Before activation (T9/T10) rollback is harmless.
- After activation a rollback to the old oracle freezes every entered account, including its liquidation. The remedy is to roll FORWARD (re-install the wrapper, or a fixed wrapper), not back; the rollback is for a defect in the wrapper's identity behaviour, which the live pre-checks make very unlikely.
- A vault feed outage (USDC/USDT Chainlink guard of the vault, 26 h) has the same effect on entered accounts without any transaction, and during it a pUSDC borrower who entered the market cannot be liquidated (the pilot's pUSDC borrow cap is 200 USDC, so the exposure is bounded). This is the cost of fail-closed pricing; it is a design decision for the integrator whether to keep it (my recommendation: yes, matching the guarded oracle's convention).

## 6. Ledger signature count
Stage 1: 1. Stage 2: 3. Stage 3: 4. Activation: 2 (1 if supply stays closed). Rollback: 1. Total listing 8; with activation 10.
