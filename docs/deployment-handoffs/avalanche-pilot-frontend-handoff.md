# Avalanche pilot: frontend handoff for the two lending markets (pWAVAX, pUSDC) and the two Pharaoh vaults

Audience: the frontend engineer who lists the two lending markets and the two Pharaoh vaults on Avalanche C-Chain mainnet. Companion to `avalanche-pilot-frontend-notes.md` (screen wording, exit-cost text, vault and margin notes: read it, it is not repeated here). **Lending (sections 1 to 3) and the two vaults (section 4) are live; margin 2x is not (section 4c).**

Sources of truth: `avalanche-pilot-addresses.json` (status `enabled`; the `vault` block for the vaults), ABIs in `avalanche-pilot-abis/` (`PharaohLiquidityVaultR3.json` for the vaults), parameters in `contracts/ceremony/pilot-pw30.env` (CAP = 200).

**Every "current value" in sections 1 to 3 was read from chain at block 99,848,578 (2026-11-09 12:12:17 UTC); the vault values in section 4 at block 99,856,327 (2026-11-09 14:11:08 UTC).** They are a snapshot for checking your reads, not constants: always read them live.

## 1. Network and addresses

| Item | Value |
|---|---|
| Chain | Avalanche C-Chain mainnet, chain id **43114** |
| Controller (call this) | `0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A` (Unitroller proxy; use the **PeridottrollerAvalanche** ABI on it) |
| Price oracle | `0x7BAB5406Cb4929f9b9492e1b2a43b65BF93AaFC0` (GuardedAvalanchePriceOracle; `controller.oracle()` returns it) |
| Interest rate model | `0xe5a82bF40b493cf37C06851A934370F3f0896263` (both markets) |
| pWAVAX (market) | `0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1`, symbol `pWAVAX`, **8 decimals**, ABI **PErc20Delegator** |
| pUSDC (market) | `0x0f7849CD9E54ffb027aacaEec82007cca9470098`, symbol `pUSDC`, **8 decimals**, ABI **PErc20Delegator** |
| WAVAX (underlying of pWAVAX) | `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7`, **18 decimals** (standard ERC-20; wrap AVAX with `deposit()` first: native AVAX is not accepted) |
| USDC (underlying of pUSDC) | `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`, **6 decimals** (native USDC) |

ABI files (bare JSON arrays): `PeridottrollerAvalanche.json` (controller), `PharaohLiquidityVaultR3.json` (both Pharaoh vaults, section 4), `PErc20Delegator.json` (both pTokens; the proxy exposes the full pToken interface, `PErc20Delegate.json` is the implementation ABI and adds nothing the UI needs), `GuardedAvalanchePriceOracle.json` (`getUnderlyingPrice(address pToken)`), `Unitroller.json` (proxy admin only, not for the UI). Plain ERC-20 `approve/allowance/balanceOf/decimals` for the underlyings: use a generic ERC-20 ABI.

Reward token: **none** (`getPeridotAddress()` = zero address, `peridotRate()` = 0). The controller ABI contains `claimPeridot`; **do not show a claim button or a rewards column.**

## 2. Per-market reads

Let `M` be the pToken address. All `view` unless marked.

| What | Call (exact) | Unit and handling |
|---|---|---|
| Total pTokens | `M.totalSupply()` | pToken raw, 8 decimals |
| Exchange rate | `M.exchangeRateStored()` | underlying raw per pToken raw, scaled 1e18 |
| User supply in underlying | `M.balanceOf(user)` then `balance * exchangeRateStored / 1e18` | result is underlying **raw** (6 dec USDC, 18 dec WAVAX). Display = raw / 10^underlyingDecimals. Use `balanceOfUnderlying(user)` only as a `callStatic`/simulate (it is nonpayable: it accrues interest) |
| Total supplied (underlying) | `totalSupply * exchangeRateStored / 1e18` | underlying raw |
| Cash | `M.getCash()` | underlying raw |
| Total borrows | `M.totalBorrows()` | underlying raw; stored value, lags by the interest of the blocks since `accrualBlockNumber` (the cap check on chain uses the accrued value) |
| Total reserves | `M.totalReserves()` | underlying raw |
| Utilisation | `totalBorrows * 1e18 / (cash + totalBorrows - totalReserves)` (0 when denominator is 0) | 1e18 = 100%. Same formula as the rate model's `utilizationRate(cash, borrows, reserves)` |
| Supply rate | `M.supplyRatePerBlock()` | per block, scaled 1e18 |
| Borrow rate | `M.borrowRatePerBlock()` | per block, scaled 1e18 |
| Reserve factor | `M.reserveFactorMantissa()` | 1e18 scale (1e17 = 10%) |
| User borrow | `M.borrowBalanceStored(user)` (view) or `M.borrowBalanceCurrent(user)` (simulate) | underlying raw |
| User snapshot | `M.getAccountSnapshot(user)` -> `(err, pTokenBalance, borrowBalance, exchangeRate)` | `err` must be 0 |

**APR = ratePerBlock * 33,500,000 / 1e18** (simple, not compounded). 33,500,000 blocks per year is the constant this deployment's rate model was configured with (about 0.94 s blocks): the model reads `blocksPerYear() = 33500000`, so use exactly that constant, not 365*24*3600/2. The model's own per-block rates are read the same way. Current values (block 99,848,578): `borrowRatePerBlock` 597014925 (both markets), APR = **2.00%**; `supplyRatePerBlock` 0 (no borrows), APR = **0.00%**. Show supply APR as variable and as 0% until someone borrows. For a "what you would earn" view, the rate model answers hypotheticals: `getBorrowRate(cash, borrows, reserves)` and `getSupplyRate(cash, borrows, reserves, reserveFactorMantissa)` (verified on chain): at USDC cash 160 / borrows 100 (utilisation 38.5%) borrow 6.81% / supply 2.36% APR; at the maximum the cap allows (borrows 199.999999, cash 60.000001, utilisation 76.9%) borrow 11.62% / supply 8.04% APR.

### Controller reads (call on `0xbE93...D51A`)

| What | Call | Current (block 99,848,578) |
|---|---|---|
| Listing, collateral factor | `markets(M)` -> `(isListed, collateralFactorMantissa, isComped)` | pWAVAX `(true, 3e17, false)` = **30%**; pUSDC `(true, 0, false)` = **0%** (USDC is not collateral). `isComped` is false everywhere: ignore |
| Borrow cap | `borrowCaps(M)` | pUSDC **200000000** (200 USDC); pWAVAX 5008172856064459802 (5.008 WAVAX, irrelevant while paused). 0 would mean unlimited |
| Borrow cash floor | `borrowCashFloor(M)` | pUSDC **50000000** (50 USDC); pWAVAX 0 |
| Borrow paused | `borrowGuardianPaused(M)` | pUSDC **false**; pWAVAX **true** |
| Mint paused | `mintGuardianPaused(M)` | both **false** (redeem has no pause flag in the controller) |
| Close factor | `closeFactorMantissa()` | 5e17 = **50%** |
| Liquidation incentive | `liquidationIncentiveMantissa()` | 1.08e18 = **8%** |
| Reserve factor (market) | `M.reserveFactorMantissa()` | 1e17 = **10%** |
| Account liquidity | `getAccountLiquidity(user)` -> `(err, liquidity, shortfall)` | USD scaled 1e18. `err != 0` = oracle price unavailable or similar: show "data unavailable" and disable actions. Collateral only counts markets the user has **entered**. Admin wallet (no entered markets) returns (0,0,0) |
| Markets the user entered | `getAssetsIn(user)` or `checkMembership(user, M)` | |
| Market list | `getAllMarkets()` | `[pWAVAX, pUSDC]` |

### Oracle price and decimal scaling

`oracle.getUnderlyingPrice(M)` returns USD price scaled to `10^(36 - underlyingDecimals)`, so that `underlyingRaw * price / 1e36` = USD value for any asset:

| Market | Scale | Current raw (block 99,848,578) | USD |
|---|---|---|---|
| pWAVAX (WAVAX, 18 dec) | 1e18 | 8057525960000000000 | **8.05752596** per WAVAX |
| pUSDC (USDC, 6 dec) | 1e30 | 999823060000000000000000000000 | **0.99982306** per USDC |

A price of **0** means the Chainlink feed is stale or invalid (max age 1200 s AVAX, 90000 s USDC): the controller then rejects borrow (error 13, PRICE_ERROR) and liquidity reads return err 13. Treat 0 as "price unavailable", never as free. Do not read prices from Chainlink in the UI: read the oracle the controller uses.

Total USD supplied now: pUSDC 260 USDC (about 259.95 USD); pWAVAX 1.252043214016114950 WAVAX (about 10.09 USD).

### Current snapshot (block 99,848,578)

| | pWAVAX | pUSDC |
|---|---|---|
| totalSupply (pToken raw) | 6260216070 | 1300000000000 |
| exchangeRateStored | 200000000002574184312459362 | 200000000000000 |
| Underlying supplied | 1.252043214016114950 WAVAX | 260.000000 USDC |
| getCash | 1252043214016114950 | 260000000 |
| totalBorrows / totalReserves | 0 / 0 | 0 / 0 |
| Utilisation | 0 | 0 |
| Borrow APR / Supply APR | 2.00% / 0.00% | 2.00% / 0.00% |
| Collateral factor | 30% | 0% |
| Borrow cap / cash floor | 5.008 WAVAX (paused) / 0 | 200 USDC / 50 USDC |
| Borrow paused / mint paused | true / false | false / false |
| Oracle price (USD) | 8.05752596 | 0.99982306 |

### What the UI should compute for "available to borrow" (USDC)

All in USDC raw, take the minimum, floor at 0:

1. By cap: `borrowCaps(pUSDC) - 1 - totalBorrows` (the controller requires `totalBorrows + amount < cap`, **strict**, so the last borrowable unit is 199.999999 USDC on an empty market).
2. By cash floor: `getCash - borrowCashFloor` (`cash - amount >= floor`; currently 260 - 50 = 210).
3. By the user's collateral: `liquidity * 1e18 / priceUSDC` where `liquidity` is from `getAccountLiquidity` (1e18 USD) and `priceUSDC` is the 1e30-scaled oracle price. Show about 1 to 2% less than this to absorb interest and price movement.

Now: min(199.999999, 210) = **199.999999 USDC** market-wide, before collateral.

## 3. User actions (exact calls, order)

Preconditions and facts verified in the contract source (`Peridottroller.sol`, `PToken.sol`, `PeridottrollerAvalanche.sol`):

- This pToken **reverts** on rejection; it does not return an error code. Revert reasons are strings from the controller (`"mint is paused"`, `"borrow is paused"`, `"market borrow cap reached"`, `"borrow cash floor"`) or custom errors from the pToken (`BorrowPeridottrollerRejection(uint256 code)`, `MintPeridottrollerRejection`, `RedeemPeridottrollerRejection`, `RepayBorrowPeridottrollerRejection`, `BorrowCashNotAvailable()`, `RedeemTransferOutNotPossible()`). **These custom errors are not in the ABI JSON files**; add them to your decoding ABI (selectors: Borrow..Rejection `0xad09bdfe`, Mint `0xc5c6a1c0`, Redeem `0xb7abef56`, RepayBorrow `0xd69a9c2c`, BorrowCashNotAvailable `0x48c25881`, RedeemTransferOutNotPossible `0x91240a1b`) or you will show raw hex. The `uint256 code` is the controller `Error` enum (4 = INSUFFICIENT_LIQUIDITY, 13 = PRICE_ERROR, 9 = MARKET_NOT_LISTED). Always `estimateGas`/simulate before sending so the user sees the reason before the wallet prompt.
- Return values of `mint/redeem/borrow/repayBorrow` are not meaningful for success checks (revert = failure); do not rely on them.
- **`enterMarkets` IS required for collateral.** `mint` does not enter a market. Only entered markets count in `getAccountLiquidity`. Enter **pWAVAX only**: `enterMarkets([pWAVAX])` on the controller (returns `uint256[]`, 0 = ok). You do **not** need to enter pUSDC to borrow it: `borrow` auto-enters the borrowed market (`borrowAllowed` adds it). USDC has collateral factor 0, so entering pUSDC adds nothing. `exitMarket(pToken)` returns a non-zero error code (no revert) if the user has a borrow in that market or needs it as collateral. Check `checkMembership(user, pWAVAX)` first and skip the transaction if already in.

| Action | Transactions, in order |
|---|---|
| **Supply USDC** | 1) `USDC.approve(pUSDC, amount)` (skip if `allowance >= amount`); 2) `pUSDC.mint(amount)` (amount in USDC raw, 6 dec). User receives pUSDC |
| **Withdraw USDC** | `pUSDC.redeemUnderlying(amountRaw)` for an exact amount, or `pUSDC.redeem(pTokenAmount)` to take a number of pTokens (use `redeem(balanceOf(user))` for "withdraw all": it leaves no dust). Fails with `RedeemTransferOutNotPossible` if pool cash is lower (cash is borrowed out); max redeemable = `min(balanceUnderlying, getCash)`. No approval needed |
| **WAVAX as collateral** | 0) `WAVAX.deposit{value}` if the user holds AVAX; 1) `WAVAX.approve(pWAVAX, amount)`; 2) `pWAVAX.mint(amount)`; 3) `controller.enterMarkets([pWAVAX])` (only if `checkMembership` is false) |
| **Withdraw WAVAX collateral** | `pWAVAX.redeemUnderlying(amountRaw)` or `pWAVAX.redeem(pTokens)`. Reverts (`RedeemPeridottrollerRejection(4)`) if it would leave the user in shortfall while they have USDC debt. If the user is not entered or has no debt, always allowed |
| **Borrow USDC** | (collateral already supplied and entered) `pUSDC.borrow(amountRaw)`. Pre-check against section 2 "available to borrow"; the on-chain refusals are the cap, the floor, liquidity and pool cash |
| **Repay USDC** | 1) `USDC.approve(pUSDC, amount)`; 2) `pUSDC.repayBorrow(amount)`. `repayBorrowBehalf(borrower, amount)` exists too |
| **Repay all** | `pUSDC.repayBorrow(2^256 - 1)` repays exactly the debt accrued at the mined block. Interest accrues every block, so the debt at mining is a little above what the UI showed: approve **more** than `borrowBalanceStored` (for example +0.1%, or approve a larger fixed amount), and make sure the wallet holds that much. Never send `repayBorrow(borrowBalanceStored)` as "repay all": it leaves dust debt. For a partial repay use an exact amount |

Number formats: all amounts are raw integers in the **underlying** decimals (USDC 6, WAVAX 18). `redeem` takes pToken raw (8 decimals); `mint`, `borrow`, `repayBorrow`, `redeemUnderlying` take underlying raw.

### Live caveats the screens must reflect

- **USDC borrow cap: 200 USDC for the whole market** (all users together), strict `<`: the last borrowable unit is 199.999999 USDC. Show used / cap from `totalBorrows` and `borrowCaps`.
- **Cash floor 50 USDC**: a borrow that would leave less than 50 USDC of cash is refused. Cash left after a borrow must be >= floor.
- **WAVAX borrowing is paused**: `borrowGuardianPaused(pWAVAX) == true`. The WAVAX borrow button must be disabled (a send reverts with `"borrow is paused"`). Drive it from the flag, not hard-coded, but expect it to stay paused.
- **WAVAX is collateral only**: collateral factor **30%**; WAVAX deposits earn nothing (supply APR 0 because nobody can borrow WAVAX). Label the WAVAX screen "collateral", not "supply".
- **USDC collateral factor 0**: supplied USDC does not increase borrowing power.
- Close factor **50%**, liquidation incentive **8%**, reserve factor **10%**.
- Mint is **not** paused on either market; redeem has no pause flag; transfers of pTokens and seizing are not paused.
- **No PERIDOT reward token**: no claim button, no rewards APR.
- Supply side now: **260 USDC** (250 team + 10 seed). USDC suppliers earn the borrow interest, which is currently zero (no borrows). WAVAX: 1.2520 WAVAX in the pool (the seed), earning nothing.
- Flash loans are paused on pUSDC (`flashLoansPaused() == true`): not a UI feature.
- Liquidity is read with an oracle price that can be 0 (stale feed): disable borrow and withdraw-with-debt actions and show "price unavailable".
- Refresh after every transaction and on a timer: interest accrues per block (about 0.94 s).

## 4. Pharaoh vaults: LIVE, open for deposits at a small cap

Both Pharaoh vaults are **open and on the R3 code** (verified on chain 9 Nov 2026; the opening and the two upgrades are at blocks 99,856,007 and 99,856,067, as recorded in the addresses JSON). They are ERC-4626 vaults that hold a concentrated-liquidity position on the Pharaoh pool. The team seeds are already in and deployed. The vault values in this section were read at **block 99,856,327 (2026-11-09 14:11:08 UTC)**; the lending values above are from an earlier block. Screen wording for the exit cost, gas and the price guards is in `avalanche-pilot-frontend-notes.md` section 1; this section gives the exact calls, units and error mapping and does not repeat that text.

### 4.1 Addresses and ABI

| Item | USDC vault | WAVAX vault |
|---|---|---|
| Vault (call this; it is the proxy) | `0x855bF832f26a294d28500db59eE941dE3d654129` | `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` |
| Share token | the vault itself (ERC-20), symbol `pPHAR-USDC`, **6 decimals** | the vault itself, symbol `pPHAR-WAVAX`, **18 decimals** |
| Name on chain | "Peridot Pharaoh USDC/USDt Vault" | "Peridot Pharaoh sAVAX/WAVAX Vault" |
| Asset the user deposits | USDC `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` (6 dec) | WAVAX `0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7` (18 dec; wrap AVAX first) |
| Pool partner token (not user-facing) | `0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7` (USDt) | `0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE` (sAVAX) |
| Deposit cap | 200,000,000 raw = **200 USDC** | 25,040,864,280,322,299,010 raw = **25.0409 WAVAX** |

Shared: Safe (vault owner, the only party that can pause or change the cap) `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12`; current implementation (R3 extension, read from the proxy's implementation slot) `0x92bBeec3e2F95A64494e92638420654400467F4a`; both proxies point at it. The addresses are also in `avalanche-pilot-addresses.json` under `vault` (`usdcVault.proxy`, `wavaxVault.proxy`, `safe`, `r3Extension`). The `rebalancer()` of both vaults is still the Ledger (`0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`) until the rotation to the rebalancer wallet; that does not change anything for users. Users never call `deployIdle`, `rebalance` or any owner function.

**ABI: `avalanche-pilot-abis/PharaohLiquidityVaultR3.json`** (bare JSON array, 107 entries, exported with `forge inspect` from `contracts/vault-r3`, `PharaohLiquidityVaultR3`; the proxy's extension forwards every user call to this implementation, whose code hash `0x62c312ec...d535` was checked on chain). Use it on **both** vaults. It contains the ERC-4626 functions, the ERC-20 share functions and **all** the custom errors (`Vault__*`, `ERC4626Exceeded*`, `EnforcedPause`, ...), so unlike the lending ABI it needs no extra error fragments. Use a generic ERC-20 ABI for the asset (`approve`, `allowance`, `balanceOf`). Calls the ABI lists that the UI must **not** use: `mint` (disabled: `maxMint` is 0), `withdraw` (exact-assets exit; use `redeem`), `initialize*`, `setDepositCap`, `setRebalancer`, `pause`, `unpause`, `emergencyExit`, `deployIdle`, `rebalance` and the ownership functions. The extension's own `harvestRewards` is owner-only and is not in this file.

### 4.2 Per-vault reads (exact calls and units)

Let `V` be the vault address; `A` its asset; all are `view`. Raw integers; shares use the asset's decimals (6 for the USDC vault, 18 for the WAVAX vault).

| What | Call | Unit and handling |
|---|---|---|
| Asset | `V.asset()` | address of USDC / WAVAX (check it equals the table above) |
| Decimals | `V.decimals()` | 6 (USDC vault), 18 (WAVAX vault); same for shares and asset |
| Total assets | `V.totalAssets()` | asset raw. A **conservative (haircut) valuation** of everything the vault holds, in the asset |
| Total shares | `V.totalSupply()` | share raw |
| Deposit cap | `V.depositCap()` | asset raw. `0` would mean no cap (not the case) |
| **Room** | `room = depositCap - totalAssets` (floor at 0) | asset raw. `maxDeposit(receiver)` returns the same figure on chain today but **may overstate the room by a few units** (fees are collected inside `deposit`, and the cap binds on the haircut valuation): cap the input box at **99.99% of room**, `room * 9999 / 10000`, and keep `maxDeposit` only as an upper cross-check |
| Share price | `V.convertToAssets(10**decimals)` | asset raw per one whole share. USDC vault `convertToAssets(1000000)`, WAVAX vault `convertToAssets(1000000000000000000)` |
| Preview deposit | `V.previewDeposit(assets)` | share raw. A **lower bound** of the shares the deposit mints (the transaction reverts with `Vault__InsufficientShares` if it would mint fewer); the real mint is higher. Show it as "at least". It is **not** the entry cost: see the next note |
| Preview redeem | `V.previewRedeem(shares)` | asset raw a `redeem` of those shares pays: for a partial redeem the contract pays exactly `convertToAssets(shares)` (floor), which is what `previewRedeem` returns (verified in the source and on chain: both read 1,000,279 for 1,000,000 shares); fees collected at the start of the call can only make it slightly higher. Use `previewRedeem(balanceOf(user))` as "you would receive about". Only when the redeemer holds **all** the shares does the payout come from the realized swap of the whole position instead. The entry cost is already inside the share count (a deposit mints about 99.4% of the fair shares in the USDC vault) and the haircut valuation, so an immediate deposit-then-redeem returns less than the deposit by the exit cost: show that cost on the deposit screen (frontend notes section 1), not on the redeem preview |
| User shares | `V.balanceOf(user)` | share raw. Also `V.maxRedeem(user)` (equal to the balance; use it as the redeem maximum) |
| Paused | `V.paused()` | bool. `true`: `deposit` reverts (`EnforcedPause`) and `maxDeposit` returns 0; `redeem` is **not** blocked by the pause flag |
| Waiting to be deployed (idle) | `A.balanceOf(V)` (the ERC-20 balance of the **asset token held by the vault**; there is no `idle()` function in the ABI) | asset raw. See 4.5 |

Two facts the screens must respect. **`previewDeposit` is pessimistic on purpose and cannot be used as a cost:** at block 99,856,327 `previewDeposit(100 USDC)` = 96.473507 shares (the fair figure is 99.972) and `previewDeposit(1 WAVAX)` = 0.890344 shares (the fair figure is 0.991). The vault checks the real mint against this floor; the real mint is higher (R3 document section 6: 99.43M minted vs a 96.46M preview for 100 USDC, about 99.4% of the fair figure; the WAVAX mint was not measured separately, only its round trip of about 98.7% to 98.8%). Show "minimum shares" from the preview and show the exit cost separately (frontend notes). **The vault's name says USDC/USDt and sAVAX/WAVAX** because the position is in those pools; the user deposits and withdraws only USDC (USDC vault) or WAVAX (WAVAX vault).

### 4.3 Current values (block 99,856,327, 2026-11-09 14:11:08 UTC; re-read live)

| | USDC vault | WAVAX vault |
|---|---|---|
| `totalAssets` | 39,807,124 = **39.807124 USDC** | 2,974,984,605,497,027,291 = **2.974985 WAVAX** |
| `totalSupply` | 39,795,988 shares (39.795988) | 2,948,443,108,249,258,408 shares (2.948443) |
| `depositCap` | 200,000,000 = 200 USDC | 25,040,864,280,322,299,010 = 25.040864 WAVAX |
| Room (`cap - totalAssets`) | 160,192,876 = **160.192876 USDC** (`maxDeposit` returns the same) | 22,065,879,674,825,271,719 = **22.065880 WAVAX** (`maxDeposit` returns the same) |
| 99.99% of room (input maximum) | 160.176856 USDC (160,176,856 raw) | 22.063673 WAVAX (22,063,673,086,857,789,191 raw) |
| Share price `convertToAssets(10**decimals)` | 1,000,279 = **1.000279 USDC** per share | 1,009,001,868,536,486,304 = **1.009002 WAVAX** per share |
| `previewDeposit` | 100 USDC -> 96,473,507 | 1 WAVAX -> 890,344,233,794,140,324 |
| `previewRedeem` | 1 share (1,000,000) -> 1,000,279 | 1 share (1e18) -> 1,009,001,868,536,486,304 |
| `paused` | false | false |
| Idle asset in the vault (`A.balanceOf(V)`) | 2,193 = 0.002193 USDC | 0 |
| `rebalancer()` | the Ledger | the Ledger |

(The 4b share prices quoted before the R3 upgrade, 0.999663 and 1.007711, are superseded by the table: R3 changed the mint rule, not the position.)

### 4.4 User actions, in order, with explicit gas limits

| Action | Transactions, in order |
|---|---|
| **Deposit** | 1) `A.approve(V, assets)` (skip if `allowance(user, V) >= assets`); 2) `V.deposit(assets, receiver)` with `receiver = user`, **gas limit 4,000,000**. `assets` in asset raw. The user receives shares |
| **Withdraw (redeem)** | `V.redeem(shares, receiver, owner)` with `receiver = owner = user`, **gas limit 4,000,000**. No approval is needed when the user redeems their own shares. "Withdraw all": `redeem(balanceOf(user), user, user)` (the last holder of all shares also gets any paired-token dust). The payout is in the vault's asset only |
| Fallback exit | `V.redeemInKind(shares, receiver, owner)` (ABI file): burns shares for **both pool tokens** (USDC + USDt, or WAVAX + sAVAX) without swaps or price checks. It exists as a liveness escape hatch. Offer it only as a secondary "advanced: withdraw in kind" action when `redeem` keeps failing with a price or swap error, with a plain warning that the user receives two tokens |

Never use `withdraw(assets, ...)` or `mint(...)`: `mint` is disabled and `withdraw` rounds against the user and leaves a share behind for the last holder.

**Gas limits, with the reason.** Send **every** vault transaction with an explicit gas limit of **4,000,000** (deposit and redeem), and a 120,000 limit is enough for the approval. Measured at CAP 200 on a fork of the live head: a deposit into the existing position uses about **0.8 to 0.95 million** gas (0.93M USDC vault, 0.83M WAVAX vault); the **first deposit into a position** (the team seeds in the rehearsal: the code path that mints a new position NFT inside `deposit` is `tokenId == 0`, and it adds the position creation on top) uses about **2.3 million** (2.31M and 2.28M); the live positions already exist, so ordinary user deposits are the smaller figure, and the 4,000,000 limit covers both. (The frontend notes say 4,000,000 for a first deposit and 2,000,000 for the others; this handoff deliberately uses one 4,000,000 limit for everything, which is safe because only the gas used is charged). A `redeem` was not measured separately; it frees liquidity and may swap, so give it the same 4,000,000. The limit is a ceiling: the user pays only the gas used. **Never send with the raw gas estimate:** the estimate is taken at one block, the vault reads the oracle and TWAP and collects fees, and when the transaction is mined a block later it can use a few percent more gas than estimated, so it is mined and reverts **out of gas** (reproduced; `avalanche-pilot-frontend-notes.md` section 1 and `avalanche-pilot-vault-opening.md` section 4). ethers v5 and viem do not add a margin. Set `gasLimit: 4_000_000` (ethers) / `gas: 4_000_000n` (viem) on the send, and also in the pre-flight simulation (`callStatic` / `simulateContract`), so the simulation uses the same limit. Wallets that pad the estimate are less exposed but not immune; a wallet that lowers a dapp-supplied limit must be tested.

### 4.5 What the deposit screen must show

- **Exit cost, before the user confirms** (text and source: `avalanche-pilot-frontend-notes.md` section 1): an immediate deposit-and-withdraw returns about **99.5% of the USDC (cost about 0.5%)** and about **98.8% of the WAVAX (cost about 1.2%)** at the CAP-200 rehearsal (52 and 122 basis points; the R3 rehearsal gave 0.54% and 1.27%). It is not a fee to Peridot and it is not earned back by waiting a short time. It is a measurement at one moment: label it "about" and re-measure after real flows.
- **Cap and room** (4.2): "room" and a used / cap bar from `totalAssets` and `depositCap`.
- **Minimum shares** from `previewDeposit` (4.2 note), the **share price**, and the current **realized return** (4b).
- **"Waiting to be deployed"**: read `A.balanceOf(V)`. Asset that sits idle in the vault **earns nothing until the rebalancer calls `deployIdle()`**: the Ledger by hand today, the rebalancer module after the rotation (it deploys when the idle balance is above 1 USDC or 0.1 WAVAX). Show a line "X USDC waiting to be deployed, earning nothing until it is deployed" **when the idle balance is above those thresholds**, and nothing when it is dust (today 0.002 USDC and 0). Note that a normal user deposit is not idle for long: while a position exists the vault swaps and adds liquidity **inside the deposit transaction** (what does not fit stays idle), so the idle balance is mainly the part of a deposit that did not fit, fees and donations. If the pool price has moved outside the position's range, the deposit is **refused** (`Vault__PositionNeedsRebalance`) until the rebalancer moves the position; it is not accepted into idle.
- A **paused** vault: disable the deposit button, show "deposits paused", keep redeem enabled.

### 4.6 Custom errors the UI must map

All are in `PharaohLiquidityVaultR3.json`. Decode the revert data with the ABI (selector in parentheses) and show the message in the right column; for anything else show the generic message. Run `callStatic` / `simulateContract` with the 4,000,000 gas limit before the wallet prompt so the user sees the reason first.

| Error (selector) | When | Show the user |
|---|---|---|
| `Vault__DepositCapExceeded(cap, attemptedTotal)` (`0xabd45647`) | the deposit would take `totalAssets` over the cap (checked on chain, verified on the live proxy) | "This vault is full for now. Room left: X. Try a smaller amount." (recompute the room; the cap is the limit) |
| `Vault__PriceDeviation(spotTick, twapTick)` (`0x1848c1c0`) | the pool price is more than the allowed distance from its 30-minute average (30 ticks, about 0.3%, on the USDC vault; 100 ticks, about 1%, on the WAVAX vault). Hits `deposit` **and** `redeem` | "The market is moving fast. Deposits and withdrawals pause for a short while to protect you. Try again in a few minutes." |
| `Vault__OracleDeviation(poolQuote, oracleQuote)` (`0x3bfe35e3`) | the pool's average price differs from the oracle price by more than 0.3% (USDC vault) / 1% (WAVAX vault). Hits `deposit` and `redeem` | same message as price deviation ("try again later"), not a generic error |
| `Vault__InvalidOracle()` (`0x618cf4df`) | the oracle returned no price | "Price data is unavailable right now. Try again later." |
| `EnforcedPause()` (`0xd93c0665`) | the owner paused the vault; `deposit` only | "Deposits are paused. You can still withdraw." |
| `Vault__PositionNeedsRebalance()` (`0x192d4e0c`) | the pool price left the vault's position range; `deposit` refused | "The vault is rebalancing its position. Try again shortly." |
| `Vault__InsufficientShares(actual, minimum)` (`0x944c71be`) | the deposit would mint fewer shares than `previewDeposit` (price moved between simulation and mining) | "The price moved while you confirmed. Please try again." |
| `Vault__InsufficientAssets(available, required)` (`0x52223b3d`) | a withdrawal cannot raise enough of the asset (not enough pool depth or paired token) | "The vault could not free this amount right now. Try a smaller amount or try again later." |
| `Vault__ZeroAmount()` (`0x3a5cf6ab`) | zero assets or zero shares | disable the button at 0 instead |
| `ERC4626ExceededMaxRedeem(owner, shares, max)` (`0xb94abeec`) | redeem asked for more shares than the owner holds | "You cannot withdraw more than you hold." (cap the input at `balanceOf`) |
| `ERC4626ExceededMaxWithdraw(owner, assets, max)` (`0xfe9cceec`) | only from `withdraw`, which the UI does not call | not needed |
| `ERC20InsufficientBalance`, `ERC20InsufficientAllowance`, `SafeERC20FailedOperation(token)` | the share token's own checks and the asset transfer failing | check balance and allowance before sending; otherwise "Not enough balance or approval." |
| `ReentrancyGuardReentrantCall()` (`0x3ee5aeb5`) | not reachable by a normal user | generic message |

Not user-reachable (owner or rebalancer only; do not map them): `Vault__NotRebalancer`, `Vault__ExcessiveLoss`, `OwnableUnauthorizedAccount`, `OwnableInvalidOwner`, `Vault__ZeroAddress`, `Vault__InvalidAsset`, `Vault__InvalidPool`, `Vault__InvalidConfiguration`, `InvalidInitialization`, `NotInitializing`, `ExpectedPause`, `LiquidityOverflow`, `TickOutOfBounds`, `ERC4626ExceededMaxDeposit`, `ERC4626ExceededMaxMint`.

**Reverts that are plain strings or empty, not ABI errors** (the asset token or the Pharaoh router raises them): the USDC token reverts a deposit without allowance with the string `"ERC20: transfer amount exceeds allowance"` (seen on the live proxy); the router raises `"Too little received"` when a large deposit's swap leg is too big for the pool (the vault's own slippage bound; the R3 document section 6: large deposits revert). Map `"Too little received"` or any other unrecognised revert on a deposit to "This amount is too large for the pool right now. Try a smaller amount." and anything else to "The transaction would fail. Nothing was sent." (because the simulation failed). Never show raw hex.

### 4.7 Minimal code (ethers v5, deposit and redeem)

```ts
import { ethers } from "ethers"; // v5
import addresses from "./avalanche-pilot-addresses.json";
import vaultAbi from "./avalanche-pilot-abis/PharaohLiquidityVaultR3.json"; // includes the custom errors

const V = addresses.vault;                     // V.usdcVault.proxy, V.wavaxVault.proxy
const GAS_LIMIT = 4_000_000;                   // never the raw estimate, see 4.4
const ERC20_ABI = [
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
];

export async function readVault(provider: ethers.providers.Provider, proxy: string) {
  const v = new ethers.Contract(proxy, vaultAbi, provider);
  const [asset, dec] = await Promise.all([v.asset(), v.decimals()]);
  const unit = ethers.BigNumber.from(10).pow(dec);
  const [totalAssets, totalSupply, cap, price, paused, idle] = await Promise.all([
    v.totalAssets(), v.totalSupply(), v.depositCap(), v.convertToAssets(unit), v.paused(),
    new ethers.Contract(asset, ERC20_ABI, provider).balanceOf(proxy),   // idle = asset held by the vault
  ]);
  const room = cap.gt(totalAssets) ? cap.sub(totalAssets) : ethers.constants.Zero;
  const maxInput = room.mul(9999).div(10000);                           // 99.99% of the room
  return { asset, dec, totalAssets, totalSupply, cap, room, maxInput, sharePrice: price, paused, idle };
}

export async function depositToVault(signer: ethers.Signer, proxy: string, assetRaw: ethers.BigNumber) {
  const user = await signer.getAddress();
  const v = new ethers.Contract(proxy, vaultAbi, signer);
  const asset = new ethers.Contract(await v.asset(), ERC20_ABI, signer);
  if ((await asset.allowance(user, proxy)).lt(assetRaw)) {
    await (await asset.approve(proxy, assetRaw, { gasLimit: 120_000 })).wait();
  }
  await v.callStatic.deposit(assetRaw, user, { gasLimit: GAS_LIMIT }); // throws a decoded Vault__* error
  return (await v.deposit(assetRaw, user, { gasLimit: GAS_LIMIT })).wait();
}

export async function redeemFromVault(signer: ethers.Signer, proxy: string, sharesRaw: ethers.BigNumber) {
  const user = await signer.getAddress();
  const v = new ethers.Contract(proxy, vaultAbi, signer);
  await v.callStatic.redeem(sharesRaw, user, user, { gasLimit: GAS_LIMIT });
  return (await v.redeem(sharesRaw, user, user, { gasLimit: GAS_LIMIT })).wait();
}
```

With viem: `readContract` for the reads in 4.2 with the same ABI file, `simulateContract({ ..., gas: 4_000_000n })` then `writeContract(request)`; the request carries the gas limit.

## 4b. Vault yield on the screen: show a REALIZED number, never a forecast

**There is no measured vault APY, so there is nothing true to show yet.** The two vaults earn swap fees (and possibly PHAR emissions) on a concentrated liquidity position; that depends on pool volume, the price range and the rebalancer, none of which has run on mainnet with real deposits. The only "APR" figure anywhere in the repo is a 20% **assumption** in a design tool (`avalanche-vault-phar-evidence/tools/variant_econ.py`, labelled "not measured"): **do not show it.**

What the screen may show, from chain data only (ERC-4626, both vaults):
- **Share price** = `convertToAssets(10**decimals)` (USDC vault `convertToAssets(1000000)`, WAVAX vault `convertToAssets(10**18)`). At block 99,856,327: USDC vault **1.000279** USDC per share, WAVAX vault **1.009002** WAVAX per share. The share price is conservative (a haircut valuation that includes the cost of entering and leaving the position), so it moves by the entry cost when deposits happen and is **not** a clean yield measure for the first days.
- **Realized return** = (share price now / share price N days ago) - 1, annualised **only after at least 7 days** of history, with the label "realized over the last N days, not a promise". The frontend has to store the share price itself (for example once an hour); the chain history needs an archive node, which the pilot does not have. Until 7 days exist show "new vault, no track record yet", not 0%. A negative realized number is shown as it is.
- **Cap and room** (`depositCap`, `totalAssets`, 4.2) and the **exit cost** (4.5).
- Idle deposits and "waiting to be deployed" as in 4.5.

## 4c. NOT live yet: do not list

- **Margin 2x: not deployed** (all `margin.*` addresses in the JSON are `null`). Margin comes with a later handoff; do not render a margin section.
- No other vault than the two above. `addresses.vault.rebalancerWalletPlanned` is a plan, not a contract to call.

## 4d. What must NOT be built

- **No vault APY, APR or "projected earnings" of any kind**, not even a range or an estimate from the pool's fee tier or volume. Only the realized return of 4b, after 7 days, labelled as past.
- **The cap is the limit, not the password.** The frontend is password-gated for the pilot, but the vault contracts are public: anyone can call `deposit` on the proxy directly with any wallet. The deposit cap on chain (200 USDC / 25.04 WAVAX) is the only thing that actually limits deposits. The screens must **display** the cap and the room and fail gracefully on `Vault__DepositCapExceeded`; they must not pretend that the gate enforces anything, and must not hide the cap or promise a vault "has space".
- No deposit button that sends with the raw gas estimate; no "mint" or exact-withdraw flow; no owner or rebalancer actions in the user app (`pause`, `setDepositCap`, `deployIdle`, `rebalance`).
- No guarantee wording (the vault can lose value, the contracts are not audited, see `avalanche-pilot-frontend-notes.md` section 4), and no cost computed from `previewDeposit` / `previewRedeem`.

## 5. Minimal code

Both snippets read the addresses from `avalanche-pilot-addresses.json` and the ABIs from `avalanche-pilot-abis/`; they take the provider/client from the app (no endpoint or key in code). Custom errors are added to the ABI so failures decode. Note: ethers v5 prints a harmless `Duplicate definition of ActionPaused` warning when loading the controller ABI (two overloads in the JSON); ignore it. Never use `BigNumber.toNumber()` on 1e18-scaled values (it throws on overflow); use `formatUnits`.

### ethers v5

```ts
import { ethers } from "ethers"; // v5
import addresses from "./avalanche-pilot-addresses.json";
import controllerAbi from "./avalanche-pilot-abis/PeridottrollerAvalanche.json";
import pTokenAbi from "./avalanche-pilot-abis/PErc20Delegator.json";
import oracleAbi from "./avalanche-pilot-abis/GuardedAvalanchePriceOracle.json";

const BLOCKS_PER_YEAR = 33_500_000;
const ERC20_ABI = [
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
];
const ERRORS_ABI = [ // custom errors missing from the ABI json, so failures decode
  "error BorrowPeridottrollerRejection(uint256 errorCode)",
  "error MintPeridottrollerRejection(uint256 errorCode)",
  "error RedeemPeridottrollerRejection(uint256 errorCode)",
  "error RepayBorrowPeridottrollerRejection(uint256 errorCode)",
  "error BorrowCashNotAvailable()",
  "error RedeemTransferOutNotPossible()",
];
const pTokenFullAbi = [...(pTokenAbi as any[]), ...ERRORS_ABI]; // ethers v5 accepts JSON and human-readable fragments mixed

export function contracts(providerOrSigner: ethers.providers.Provider | ethers.Signer) {
  const L = addresses.lending;
  return {
    controller: new ethers.Contract(L.controller, controllerAbi, providerOrSigner),
    oracle: new ethers.Contract(L.oracle, oracleAbi, providerOrSigner),
    markets: Object.fromEntries(
      Object.entries(L.markets).map(([sym, m]) => [sym, {
        ...m,
        pToken: new ethers.Contract(m.address, pTokenFullAbi, providerOrSigner),
        underlyingToken: new ethers.Contract(m.underlying, ERC20_ABI, providerOrSigner),
      }])
    ),
  };
}

const apr = (ratePerBlock: ethers.BigNumber) => Number(ethers.utils.formatUnits(ratePerBlock.mul(BLOCKS_PER_YEAR), 18)); // 0.02 = 2% (BigNumber.toNumber() overflows here)

export async function readMarket(provider: ethers.providers.Provider, symbol: "pWAVAX" | "pUSDC") {
  const { controller, oracle, markets } = contracts(provider);
  const m = markets[symbol];
  const [totalSupply, rate, cash, borrows, reserves, supplyRate, borrowRate, listing, cap, floor,
         borrowPaused, mintPaused, price] = await Promise.all([
    m.pToken.totalSupply(), m.pToken.exchangeRateStored(), m.pToken.getCash(), m.pToken.totalBorrows(),
    m.pToken.totalReserves(), m.pToken.supplyRatePerBlock(), m.pToken.borrowRatePerBlock(),
    controller.markets(m.address), controller.borrowCaps(m.address), controller.borrowCashFloor(m.address),
    controller.borrowGuardianPaused(m.address), controller.mintGuardianPaused(m.address),
    oracle.getUnderlyingPrice(m.address),
  ]);
  const dec = m.underlyingDecimals;
  const totalSuppliedRaw = totalSupply.mul(rate).div(ethers.constants.WeiPerEther); // underlying raw
  const denom = cash.add(borrows).sub(reserves);
  const utilisation = denom.isZero() ? 0 : Number(ethers.utils.formatUnits(borrows.mul(ethers.constants.WeiPerEther).div(denom), 18));
  const priceUsd = price.isZero() ? null : Number(ethers.utils.formatUnits(price, 36 - dec)); // null = unavailable
  return {
    symbol, totalSupplied: ethers.utils.formatUnits(totalSuppliedRaw, dec),
    cash: ethers.utils.formatUnits(cash, dec), totalBorrows: ethers.utils.formatUnits(borrows, dec),
    utilisation, supplyApr: apr(supplyRate), borrowApr: apr(borrowRate), priceUsd,
    collateralFactor: Number(ethers.utils.formatUnits(listing.collateralFactorMantissa, 18)), isListed: listing.isListed,
    borrowCap: ethers.utils.formatUnits(cap, dec), borrowCashFloor: ethers.utils.formatUnits(floor, dec),
    borrowPaused, mintPaused,
  };
}

// USDC supply: approve (if needed) then mint. `amount` is a decimal string like "25.5".
export async function supplyUsdc(signer: ethers.Signer, amount: string) {
  const { markets } = contracts(signer);
  const { pToken, underlyingToken, underlyingDecimals, address } = markets.pUSDC;
  const user = await signer.getAddress();
  const raw = ethers.utils.parseUnits(amount, underlyingDecimals);
  if ((await underlyingToken.allowance(user, address)).lt(raw)) {
    await (await underlyingToken.approve(address, raw)).wait();
  }
  await pToken.callStatic.mint(raw);              // simulate: throws a decoded revert reason if refused
  const tx = await pToken.mint(raw);
  return tx.wait();
}
```

### viem

```ts
import { createPublicClient, createWalletClient, custom, http, parseUnits, formatUnits, parseAbi, type Abi } from "viem";
import { avalanche } from "viem/chains";
import addresses from "./avalanche-pilot-addresses.json";
import controllerAbi from "./avalanche-pilot-abis/PeridottrollerAvalanche.json";
import pTokenAbiJson from "./avalanche-pilot-abis/PErc20Delegator.json";
import oracleAbi from "./avalanche-pilot-abis/GuardedAvalanchePriceOracle.json";

const BLOCKS_PER_YEAR = 33_500_000n;
const L = addresses.lending;
const erc20Abi = parseAbi([
  "function approve(address,uint256) returns (bool)",
  "function allowance(address,address) view returns (uint256)",
]);
const errorsAbi = parseAbi([
  "error BorrowPeridottrollerRejection(uint256 errorCode)",
  "error MintPeridottrollerRejection(uint256 errorCode)",
  "error RedeemPeridottrollerRejection(uint256 errorCode)",
  "error RepayBorrowPeridottrollerRejection(uint256 errorCode)",
  "error BorrowCashNotAvailable()",
  "error RedeemTransferOutNotPossible()",
]);
const pTokenAbi = [...(pTokenAbiJson as Abi), ...errorsAbi] as Abi;

// transport: your app's configured RPC (env var), not hard-coded here
const publicClient = createPublicClient({ chain: avalanche, transport: http(process.env.NEXT_PUBLIC_AVALANCHE_RPC_URL) });

const apr = (ratePerBlock: bigint) => Number(ratePerBlock * BLOCKS_PER_YEAR) / 1e18; // 0.02 = 2%

export async function readMarket(symbol: "pWAVAX" | "pUSDC") {
  const m = L.markets[symbol];
  const pToken = m.address as `0x${string}`;
  const p = (fn: string, args: unknown[] = []) =>
    publicClient.readContract({ address: pToken, abi: pTokenAbi, functionName: fn, args });
  const c = (fn: string, args: unknown[]) =>
    publicClient.readContract({ address: L.controller as `0x${string}`, abi: controllerAbi as Abi, functionName: fn, args });
  const [totalSupply, rate, cash, borrows, reserves, supplyRate, borrowRate, listing, cap, floor, borrowPaused, mintPaused, price] =
    (await Promise.all([
      p("totalSupply"), p("exchangeRateStored"), p("getCash"), p("totalBorrows"), p("totalReserves"),
      p("supplyRatePerBlock"), p("borrowRatePerBlock"),
      c("markets", [pToken]), c("borrowCaps", [pToken]), c("borrowCashFloor", [pToken]),
      c("borrowGuardianPaused", [pToken]), c("mintGuardianPaused", [pToken]),
      publicClient.readContract({ address: L.oracle as `0x${string}`, abi: oracleAbi as Abi, functionName: "getUnderlyingPrice", args: [pToken] }),
    ])) as [bigint, bigint, bigint, bigint, bigint, bigint, bigint, readonly [boolean, bigint, boolean], bigint, bigint, boolean, boolean, bigint];
  const dec = m.underlyingDecimals;
  const denom = cash + borrows - reserves;
  return {
    symbol,
    totalSupplied: formatUnits((totalSupply * rate) / 10n ** 18n, dec), // balance * rate / 1e18
    cash: formatUnits(cash, dec), totalBorrows: formatUnits(borrows, dec),
    utilisation: denom === 0n ? 0 : Number((borrows * 10n ** 18n) / denom) / 1e18,
    supplyApr: apr(supplyRate), borrowApr: apr(borrowRate),
    priceUsd: price === 0n ? null : Number(formatUnits(price, 36 - dec)), // null = price unavailable
    collateralFactor: Number(formatUnits(listing[1], 18)), isListed: listing[0],
    borrowCap: formatUnits(cap, dec), borrowCashFloor: formatUnits(floor, dec), borrowPaused, mintPaused,
  };
}

// USDC supply: approve (if needed) then mint. walletClient comes from the connected wallet.
export async function supplyUsdc(walletClient: ReturnType<typeof createWalletClient>, amount: string) {
  const [account] = await walletClient.getAddresses();
  const m = L.markets.pUSDC;
  const raw = parseUnits(amount, m.underlyingDecimals);
  const allowance = await publicClient.readContract({
    address: m.underlying as `0x${string}`, abi: erc20Abi, functionName: "allowance", args: [account, m.address as `0x${string}`],
  });
  if (allowance < raw) {
    const h = await walletClient.writeContract({ chain: avalanche, account, address: m.underlying as `0x${string}`, abi: erc20Abi, functionName: "approve", args: [m.address as `0x${string}`, raw] });
    await publicClient.waitForTransactionReceipt({ hash: h });
  }
  const { request } = await publicClient.simulateContract({ account, address: m.address as `0x${string}`, abi: pTokenAbi, functionName: "mint", args: [raw] }); // throws decoded revert if refused
  const hash = await walletClient.writeContract(request);
  return publicClient.waitForTransactionReceipt({ hash });
}
```

Collateral flow (WAVAX) uses the same pattern: `approve` on WAVAX, `mint` on pWAVAX, then `enterMarkets([pWAVAX])` on `addresses.lending.controller` with the controller ABI; borrow is `borrow(raw)` on pUSDC.

## 6. Quick verification commands (read-only)

`export ETH_RPC_URL=<your RPC>` in your shell, then for example: `cast call 0x0f7849CD9E54ffb027aacaEec82007cca9470098 "getCash()(uint256)"`; `cast call 0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A "borrowGuardianPaused(address)(bool)" 0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1` (expect `true`); `cast call 0x7BAB5406Cb4929f9b9492e1b2a43b65BF93AaFC0 "getUnderlyingPrice(address)(uint256)" 0x0f7849CD9E54ffb027aacaEec82007cca9470098`.

Vaults (section 4), same environment: `V=0x855bF832f26a294d28500db59eE941dE3d654129` (USDC vault) or `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` (WAVAX vault); `cast call $V "totalAssets()(uint256)"`, `"depositCap()(uint256)"`, `"convertToAssets(uint256)(uint256)" 1000000` (USDC vault; use `1000000000000000000` for the WAVAX vault), `"previewDeposit(uint256)(uint256)" 100000000`, `"paused()(bool)"` (expect `false`), `"decimals()(uint8)"`, `"asset()(address)"`; idle: `cast call <asset> "balanceOf(address)(uint256)" $V` with the asset from the table in 4.1; the implementation: `cast storage $V 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc` (expect `0x...92bbeec3e2f95a64494e92638420654400467f4a`). Expect `Vault__DepositCapExceeded` (`0xabd45647`) from `cast call $V "deposit(uint256,address)" 999999999999 <any address>`.
