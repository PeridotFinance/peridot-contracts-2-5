# Avalanche pilot: frontend handoff for listing the two lending markets (pWAVAX, pUSDC)

Audience: the frontend engineer who lists the two lending markets on Avalanche C-Chain mainnet. Companion to `avalanche-pilot-frontend-notes.md` (screen wording, exit-cost text, vault and margin notes: read it, it is not repeated here). Only lending is live; see section 4 for what is not.

Sources of truth: `avalanche-pilot-addresses.json` (status `enabled`), ABIs in `avalanche-pilot-abis/`, parameters in `contracts/ceremony/pilot-pw30.env` (CAP = 200).

**Every "current value" below was read from chain at block 99,848,578 (2026-11-09 12:12:17 UTC).** They are a snapshot for checking your reads, not constants: always read them live.

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

ABI files (bare JSON arrays): `PeridottrollerAvalanche.json` (controller), `PErc20Delegator.json` (both pTokens; the proxy exposes the full pToken interface, `PErc20Delegate.json` is the implementation ABI and adds nothing the UI needs), `GuardedAvalanchePriceOracle.json` (`getUnderlyingPrice(address pToken)`), `Unitroller.json` (proxy admin only, not for the UI). Plain ERC-20 `approve/allowance/balanceOf/decimals` for the underlyings: use a generic ERC-20 ABI.

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

## 4. NOT live yet: do not list

- Pharaoh vaults (USDC and WAVAX): **deposit caps are closed** (`depositCap` 1). No vault addresses are in the JSON (`vault.usdcVault` / `vault.wavaxVault` are `null`). Vault deposits come with a later handoff.
- Margin 2x: **not deployed** (all `margin.*` addresses are `null`). Margin comes with a later handoff.
- Everything under `margin` and `vault` in the addresses JSON is null: do not render those sections.

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
