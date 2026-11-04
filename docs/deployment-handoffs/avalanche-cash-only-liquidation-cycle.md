# Cash-only lending: WAVAX -> USDC conversion routes and the complete liquidation cycle

**STATUS: FINAL for the results below. The route agent was interrupted twice by the machine sleeping; the lead completed sections 3a-3d from its full run (`avalanche-cash-only-cycle-evidence/attempt09-final-both-suites.txt`: cycle suite 8/8, route suite 38/38) and re-ran both suites (8/8 and 38/38).** Product: cash-only lending pilot (pUSDC / pWAVAX, `PW30` and `PW40` as in `avalanche-cash-only-decision-table.md`). Research only: nothing here is an approved parameter or cap. No deployment, no signing, no broadcast, no keys; `contracts/contracts/` untouched. Pinned fork: Avalanche C-Chain block 99,200,000, Chainlink AVAX/USD 8.54911 (`854911000`).

Files: `contracts/test/AvalancheWavaxUsdcRoutesFork.t.sol` (part A) with helper `contracts/test/helpers/AvalancheWavaxUsdcRoutes.sol`; `contracts/test/AvalancheCashOnlyLiquidationCycleFork.t.sol` (part B). Evidence: `avalanche-cash-only-cycle-evidence/` (every attempt kept, headers: UTC, git HEAD, command).

## 1. Routes: verified addresses (all checked on chain at the pin)
Address rule applied: no address was taken from another chain because a label matched. Sources: official repositories where reachable, then on-chain pointer checks (router -> factory -> pool; pool token0/token1; code size). The LFJ documentation site is behind Cloudflare (HTTP 403 for this client) and docs.sushi.com returned 404, so those two are verified on chain only (plus third-party registries that agree). Independent re-check with `cast`: `avalanche-cash-only-cycle-evidence/verify-addresses.sh` -> `cast-verification-addresses.txt`; the same checks as asserts: `test_A00_verifyAddresses` (`attempt01-addresses.txt`, PASS).

| Venue | Contract | Address | Source of the address | On-chain check at the pin |
|---|---|---|---|---|
| Uniswap V3 | SwapRouter02 | `0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE` | Uniswap/contracts `deployments/43114.md` | `factory()` = `0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD`; `WETH9()` = real WAVAX |
| Uniswap V3 | Factory | `0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD` | same file | `getPool(WAVAX,USDC,fee)` for 100/500/3000/10000 below |
| Uniswap V3 pools | 0.01% / 0.05% / 0.3% / 1% | `0x1951BD56E82cC1eDFEc8546c3202eCBcC5B74A29` / `0xfAe3f424a0a47706811521E3ee268f00cFb5c45E` / `0x0E663593657B064e1baE76d28625Df5D0eBd4421` / `0xd18384F4398BF5415902aD5d87eAA96549Fd4f1E` | factory lookup | token0 = WAVAX, token1 = USDC, `fee()` as named, liquidity 1.04e14 / **3.60e18** / 2.26e15 / 2.04e15 |
| Uniswap V4 | PoolManager | `0x06380C0e0912312B5150364B9DC4542BA0DbBc85` | same file (`v4PoolManager`) | pool (fee 500, ts 10, no hook) initialised but in-range liquidity 6.4e12 = about USD 19 of virtual USDC at price 8.65: **no real liquidity, not swapped** |
| Sushi V3 | SwapRouter / Factory | `0x8E4638eefee96732C56291fBF48bBB98725c6b31` / `0x3e603C14aF37EBdaD31709C4f848Fc6aD5BEc715` | sushiswap/v3-periphery and v3-core `deployments/avalanche` | router `factory()` = that factory, `WETH9()` = WAVAX |
| Sushi V3 pools | 0.01% / 0.05% / 0.3% / 1% | `0x0bA96F2F...2072` / `0x4A5c0E10...0d61B` / `0xD937a05dF90918f584A17a168026cc06f9cB099D` / `0x8EAf84001447da898054D06EdF6e4Ebc010f33a1` | factory lookup | tokens and fees verified; liquidity 4e8 / 4.6e11 / 3.9e13 / 9e10 (dust) |
| LFJ (Trader Joe) | LBRouter (V2.2; routes V1, V2, V2.1, V2.2 hops) | `0x18556DA13313f3532c54711497A8FedAC273220E` | same router used in this repository (`AvalancheRealRouteFork.t.sol`); LFJ docs page unreachable (403) | `getWNATIVE()` = WAVAX; `getFactory()` = `0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c` (V2.2); `getFactoryV2_1()` = `0x8e42f2F4101563bF679975178e880FD87d3eFd4e`; `getLegacyFactory()` = `0x6E77932A92582f504FF6c4BdbCef7Da6c198aEEf` (V2.0); `getV1Factory()` = `0x9Ad6C38BE94206cA50bb0d90783181662f0Cfa10` |
| LFJ LB V2.2 pair bin 10 | | `0x864d4e5Ee7318e97483DB7EB0912E09F161516EA` | `getAllLBPairs(WAVAX,USDC)` of the V2.2 factory | tokenX = WAVAX, tokenY = USDC, `getBinStep()` 10, active id 8363111, total reserves **28,075.7 WAVAX / USD 125,386** |
| LFJ LB other pairs | V2.2 bin 25/50/100; V2.1 bin 5/20/25/50/100; V2.0 bin 20 | see `verify-addresses.sh` | factory lists | all verified; USDC side empty or dust (V2.2 bin25: 1 raw unit; bin100: 80 raw; V2.1 bin20: USD 1.35; V2.1 bin25: USD 215.7 at a stale price) |
| LFJ V1 (constant product) | pair / Router | `0xf4003F4efBE8691B60249E6afbD307aBE7758adb` / `0x60aE616a2155Ee3d9A68541Ba4544862310933d4` | `getPair` of V1 factory; router `factory()` | router `WAVAX()` = WAVAX; reserves **23,555.9 WAVAX / USD 201,857** |
| Pangolin V2 | Router / Factory / pair | `0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106` / `0xefa94DE7a4656D787667C749f7E1223D71E9FD88` / `0x0e0100Ab771E9288e0Aa97e11557E6654C3a9665` | pangolindex/exchange-contracts README | router `factory()`, `WAVAX()`; pair.factory(); reserves 5,563.7 WAVAX / USD 47,626 |
| Sushi V2 | Router / Factory / pair | `0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506` / `0xc35DADB65012eC5796536bD9864eD8773aBc74C4` / `0x6539bF462F73fF9497054bA261C195DA8639ED61` | on chain only (note: the router address equals Sushi's address on other chains, so it was NOT trusted by label: code present, `factory()` = the factory, pair.factory() = the factory, `WETH()` = real WAVAX, a real swap executes) | reserves 364.6 WAVAX / USD 3,119 |
| Uniswap V2 | Factory / pair | `0x9e5A52f57b3038F1B8EeE45F28b3C1967e22799C` / `0x6239aE4D661379b71A90c4c79f0a95297342e391` | Uniswap/contracts | reserves 2.2 WAVAX / USD 19: not swapped |
| Pharaoh CL (reference, the venue of the earlier work) | SwapRouter / Factory | `0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c` / `0xAE6E5c62328ade73ceefD42228528b70c8157D0d` | PharaohExchange/pharaoh-docs-main contract-addresses page | router `WETH9()` = WAVAX |
| Pharaoh CL pools | ts 10 (the pool of the earlier work) / ts 5 / 50 / 100 | `0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534` / `0x1Abbf74e...4d20` / `0xb1E1Db50...43c1` / `0x2eB24B12...D3d7` | factory `getPool` | ts10 fee 0.049%, liquidity 2.22e19; ts5/50/100 in-range liquidity 0 |
| Pharaoh legacy (v1) | PairFactory / pair | `0x85448bF2F589ab1F56225DF5167c63f57758f8c1` / `0x1cca95F17Eb953cd8c3D91fe81C7e8e815ac8ADd` | same docs page | volatile pair reserves 57.1 WAVAX / USD 491: not swapped (`cast-verification-pharaoh-legacy.txt`) |

Not located / not executed: Blackhole DEX (a third-party aggregator lists a WAVAX/USDC pool of about USD 14k; no official address was verified), KyberSwap, Glacier, Vapor, Pyre (each reported under USD 1k), GMX V1/V2 and WOOFi (swap venues with different mechanics; not tried). **Aggregator APIs (1inch, Velora/ParaSwap, Odos, OpenOcean, KyberSwap aggregator, LFJ aggregator) cannot be executed on a pinned fork: UNTESTED.**

## 2. Measured conversions (real swaps on the fork, fresh snapshot of the pin for every row)
Method: trader holds the WAVAX (`deal`: funding only), calls the real router with `amountOutMinimum = 0` (measurement), balance deltas give spent and received. Slippage = (Chainlink value of the WAVAX spent - USDC received) / Chainlink value, in bp, **versus the Chainlink mid 8.54911** (it contains the venue fee, the price impact and the venue's own offset from Chainlink; a negative value means the pool paid more than Chainlink). Fee = input x fee tier (V3 / V2) or the pair's `getSwapOut` fee (LB), valued at Chainlink. Gas = gas of the router call only (cold addresses via `vm.cool`; add 21,000 base per transaction). `m0.5 / m1 / m2 / m3` = the min-out limit "Chainlink minus 0.5% / 1% / 2% / 3%" is met (whole input consumed). `FULL` means the input was fully consumed, which for dust pools is not usable (see slippage). Full log: `attempt02-routes-sweep.txt` (24 of 25 route tests pass; the failing one, the V2.0 pair, was a harness error in `_spot8` and was fixed and rerun, `attempt05`).

| Route | USD | status | fill % | USDC out | eff price | fee USDC | impact bp | slip bp | gas | m0.5 | m1 | m2 | m3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| LFJ LB V2.1 bin100 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin100 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin100 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin100 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin100 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin100 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin20 | 500 | FULL | 100.00 | 1.25 | 0.0213 | 5.89 | 9975 | 9975 | 745,060 | N | N | N | N |
| LFJ LB V2.1 bin20 | 1000 | FULL | 100.00 | 1.25 | 0.0107 | 11.79 | 9987 | 9987 | 745,060 | N | N | N | N |
| LFJ LB V2.1 bin20 | 5000 | FULL | 100.00 | 1.25 | 0.0021 | 58.99 | 9997 | 9997 | 745,060 | N | N | N | N |
| LFJ LB V2.1 bin20 | 10000 | FULL | 100.00 | 1.25 | 0.0011 | 117.99 | 9998 | 9998 | 745,060 | N | N | N | N |
| LFJ LB V2.1 bin20 | 50000 | FULL | 100.00 | 1.25 | 0.0002 | 589.99 | 9999 | 9999 | 745,060 | N | N | N | N |
| LFJ LB V2.1 bin20 | 100000 | FULL | 100.00 | 1.25 | 0.0001 | 1,179.99 | 9999 | 9999 | 745,060 | N | N | N | N |
| LFJ LB V2.1 bin25 | 500 | FULL | 100.00 | 9.07 | 0.1552 | 1.25 | 11 | 9818 | 129,425 | N | N | N | N |
| LFJ LB V2.1 bin25 | 1000 | FULL | 100.00 | 18.11 | 0.1548 | 2.53 | 33 | 9818 | 158,907 | N | N | N | N |
| LFJ LB V2.1 bin25 | 5000 | FULL | 100.00 | 89.74 | 0.1534 | 13.77 | 119 | 9820 | 217,871 | N | N | N | N |
| LFJ LB V2.1 bin25 | 10000 | FULL | 100.00 | 178.72 | 0.1528 | 29.37 | 159 | 9821 | 247,373 | N | N | N | N |
| LFJ LB V2.1 bin25 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 291,318 | N | N | N | N |
| LFJ LB V2.1 bin25 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 291,318 | N | N | N | N |
| LFJ LB V2.1 bin5 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin5 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin5 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin5 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin5 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin5 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin50 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin50 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin50 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin50 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin50 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.1 bin50 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 58,781 | N | N | N | N |
| LFJ LB V2.2 bin10 | 500 | FULL | 100.00 | 499.71 | 8.5442 | 0.25 | 9 | 5 | 136,971 | Y | Y | Y | Y |
| LFJ LB V2.2 bin10 | 1000 | FULL | 100.00 | 999.17 | 8.5420 | 0.51 | 12 | 8 | 152,309 | Y | Y | Y | Y |
| LFJ LB V2.2 bin10 | 5000 | FULL | 100.00 | 4,982.85 | 8.5198 | 2.91 | 37 | 34 | 228,939 | Y | Y | Y | Y |
| LFJ LB V2.2 bin10 | 10000 | FULL | 100.00 | 9,932.03 | 8.4910 | 7.69 | 69 | 67 | 320,787 | N | Y | Y | Y |
| LFJ LB V2.2 bin10 | 50000 | FULL | 100.00 | 47,210.27 | 8.0721 | 186.98 | 531 | 557 | 2,345,853 | N | N | N | N |
| LFJ LB V2.2 bin10 | 100000 | FULL | 100.00 | 88,655.55 | 7.5793 | 456.98 | 1102 | 1134 | 3,308,577 | N | N | N | N |
| LFJ LB V2.2 bin100 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 72,980 | N | N | N | N |
| LFJ LB V2.2 bin100 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 72,980 | N | N | N | N |
| LFJ LB V2.2 bin100 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 72,980 | N | N | N | N |
| LFJ LB V2.2 bin100 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 72,980 | N | N | N | N |
| LFJ LB V2.2 bin100 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 72,980 | N | N | N | N |
| LFJ LB V2.2 bin100 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 72,980 | N | N | N | N |
| LFJ LB V2.2 bin25 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 73,020 | N | N | N | N |
| LFJ LB V2.2 bin25 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 73,020 | N | N | N | N |
| LFJ LB V2.2 bin25 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 73,020 | N | N | N | N |
| LFJ LB V2.2 bin25 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 73,020 | N | N | N | N |
| LFJ LB V2.2 bin25 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 73,020 | N | N | N | N |
| LFJ LB V2.2 bin25 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 73,020 | N | N | N | N |
| LFJ LB V2.2 bin50 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 61,090 | N | N | N | N |
| LFJ LB V2.2 bin50 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 61,090 | N | N | N | N |
| LFJ LB V2.2 bin50 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 61,090 | N | N | N | N |
| LFJ LB V2.2 bin50 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 61,090 | N | N | N | N |
| LFJ LB V2.2 bin50 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 61,090 | N | N | N | N |
| LFJ LB V2.2 bin50 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 61,090 | N | N | N | N |
| LFJ V1 (constant product) | 500 | FULL | 100.00 | 498.44 | 8.5225 | 1.50 | 24 | 31 | 103,886 | Y | Y | Y | Y |
| LFJ V1 (constant product) | 1000 | FULL | 100.00 | 994.43 | 8.5015 | 3.00 | 49 | 55 | 103,890 | N | Y | Y | Y |
| LFJ V1 (constant product) | 5000 | FULL | 100.00 | 4,876.06 | 8.3372 | 15.00 | 241 | 247 | 103,892 | N | N | N | Y |
| LFJ V1 (constant product) | 10000 | FULL | 100.00 | 9,522.11 | 8.1406 | 30.00 | 471 | 477 | 103,896 | N | N | N | N |
| LFJ V1 (constant product) | 50000 | FULL | 100.00 | 40,052.96 | 6.8483 | 150.00 | 1984 | 1989 | 103,899 | N | N | N | N |
| LFJ V1 (constant product) | 100000 | FULL | 100.00 | 66,842.84 | 5.7145 | 300.00 | 3311 | 3315 | 103,903 | N | N | N | N |
| Pangolin V2 | 500 | FULL | 100.00 | 493.97 | 8.4460 | 1.50 | 103 | 120 | 105,795 | N | N | Y | Y |
| Pangolin V2 | 1000 | FULL | 100.00 | 977.79 | 8.3593 | 3.00 | 205 | 222 | 105,798 | N | N | N | Y |
| Pangolin V2 | 5000 | FULL | 100.00 | 4,517.93 | 7.7249 | 15.00 | 948 | 964 | 105,801 | N | N | N | N |
| Pangolin V2 | 10000 | FULL | 100.00 | 8,252.96 | 7.0555 | 30.00 | 1732 | 1747 | 105,805 | N | N | N | N |
| Pangolin V2 | 50000 | FULL | 100.00 | 24,371.61 | 4.1671 | 150.00 | 5117 | 5125 | 105,808 | N | N | N | N |
| Pangolin V2 | 100000 | FULL | 100.00 | 32,243.30 | 2.7565 | 300.00 | 6770 | 6775 | 105,811 | N | N | N | N |
| Pharaoh CL ts10 | 500 | FULL | 100.00 | 500.11 | 8.5510 | 0.24 | 0 | -2 | 121,517 | Y | Y | Y | Y |
| Pharaoh CL ts10 | 1000 | FULL | 100.00 | 1,000.21 | 8.5509 | 0.49 | 0 | -2 | 121,563 | Y | Y | Y | Y |
| Pharaoh CL ts10 | 5000 | FULL | 100.00 | 5,000.74 | 8.5504 | 2.45 | 0 | -1 | 130,309 | Y | Y | Y | Y |
| Pharaoh CL ts10 | 10000 | FULL | 100.00 | 10,000.57 | 8.5496 | 4.90 | 1 | 0 | 166,047 | Y | Y | Y | Y |
| Pharaoh CL ts10 | 50000 | FULL | 100.00 | 49,911.36 | 8.5340 | 24.50 | 19 | 17 | 282,638 | Y | Y | Y | Y |
| Pharaoh CL ts10 | 100000 | FULL | 100.00 | 95,716.99 | 8.1830 | 49.00 | 430 | 428 | 4,446,121 | N | N | N | N |
| Pharaoh CL ts100 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,308,394 | N | N | N | N |
| Pharaoh CL ts100 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,308,394 | N | N | N | N |
| Pharaoh CL ts100 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,308,394 | N | N | N | N |
| Pharaoh CL ts100 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,308,394 | N | N | N | N |
| Pharaoh CL ts100 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,308,394 | N | N | N | N |
| Pharaoh CL ts100 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,308,394 | N | N | N | N |
| Pharaoh CL ts5 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 4,139,175 | N | N | N | N |
| Pharaoh CL ts5 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 4,139,175 | N | N | N | N |
| Pharaoh CL ts5 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 4,139,175 | N | N | N | N |
| Pharaoh CL ts5 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 4,139,175 | N | N | N | N |
| Pharaoh CL ts5 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 4,139,175 | N | N | N | N |
| Pharaoh CL ts5 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 4,139,175 | N | N | N | N |
| Pharaoh CL ts50 | 500 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,042,547 | N | N | N | N |
| Pharaoh CL ts50 | 1000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,042,547 | N | N | N | N |
| Pharaoh CL ts50 | 5000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,042,547 | N | N | N | N |
| Pharaoh CL ts50 | 10000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,042,547 | N | N | N | N |
| Pharaoh CL ts50 | 50000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,042,547 | N | N | N | N |
| Pharaoh CL ts50 | 100000 | REVERT | 0.00 | 0.00 | 0.0000 | 0.00 | 0 | 0 | 1,042,547 | N | N | N | N |
| Sushi V2 | 500 | FULL | 100.00 | 430.00 | 7.3522 | 1.50 | 1378 | 1400 | 103,886 | N | N | N | N |
| Sushi V2 | 1000 | FULL | 100.00 | 755.78 | 6.4613 | 3.00 | 2423 | 2442 | 103,889 | N | N | N | N |
| Sushi V2 | 5000 | FULL | 100.00 | 1,918.81 | 3.2808 | 15.00 | 6152 | 6162 | 103,892 | N | N | N | N |
| Sushi V2 | 10000 | FULL | 100.00 | 2,375.80 | 2.0311 | 30.00 | 7618 | 7624 | 103,896 | N | N | N | N |
| Sushi V2 | 50000 | FULL | 100.00 | 2,935.02 | 0.5018 | 150.00 | 9411 | 9412 | 103,899 | N | N | N | N |
| Sushi V2 | 100000 | FULL | 100.00 | 3,024.00 | 0.2585 | 300.00 | 9696 | 9697 | 103,902 | N | N | N | N |
| Sushi V3 0.01% | 500 | FULL | 100.00 | 0.00 | 0.0000 | 0.05 | 9999 | 9999 | 7,632,490 | N | N | N | N |
| Sushi V3 0.01% | 1000 | FULL | 100.00 | 0.00 | 0.0000 | 0.10 | 9999 | 9999 | 8,043,193 | N | N | N | N |
| Sushi V3 0.01% | 5000 | FULL | 100.00 | 0.00 | 0.0000 | 0.50 | 9999 | 9999 | 8,999,383 | N | N | N | N |
| Sushi V3 0.01% | 10000 | FULL | 100.00 | 0.00 | 0.0000 | 1.00 | 9999 | 9999 | 9,410,610 | N | N | N | N |
| Sushi V3 0.01% | 50000 | FULL | 100.00 | 0.00 | 0.0000 | 5.00 | 9999 | 9999 | 10,372,703 | N | N | N | N |
| Sushi V3 0.01% | 100000 | FULL | 100.00 | 0.00 | 0.0000 | 10.00 | 9999 | 9999 | 10,786,175 | N | N | N | N |
| Sushi V3 1% | 500 | PARTIAL | 0.01 | 0.06 | 6.3796 | 0.00 | 2215 | 2537 | 292,570 | N | N | N | N |
| Sushi V3 1% | 1000 | PARTIAL | 0.00 | 0.06 | 6.3796 | 0.00 | 2215 | 2537 | 292,570 | N | N | N | N |
| Sushi V3 1% | 5000 | PARTIAL | 0.00 | 0.06 | 6.3796 | 0.00 | 2215 | 2537 | 292,570 | N | N | N | N |
| Sushi V3 1% | 10000 | PARTIAL | 0.00 | 0.06 | 6.3796 | 0.00 | 2215 | 2537 | 292,570 | N | N | N | N |
| Sushi V3 1% | 50000 | PARTIAL | 0.00 | 0.06 | 6.3796 | 0.00 | 2215 | 2537 | 292,570 | N | N | N | N |
| Sushi V3 1% | 100000 | PARTIAL | 0.00 | 0.06 | 6.3796 | 0.00 | 2215 | 2537 | 292,570 | N | N | N | N |
| Sushi V3 0.3% | 500 | FULL | 100.00 | 9.58 | 0.1637 | 1.50 | 9808 | 9808 | 669,736 | N | N | N | N |
| Sushi V3 0.3% | 1000 | FULL | 100.00 | 9.58 | 0.0819 | 3.00 | 9904 | 9904 | 677,151 | N | N | N | N |
| Sushi V3 0.3% | 5000 | FULL | 100.00 | 9.58 | 0.0164 | 15.00 | 9980 | 9980 | 690,954 | N | N | N | N |
| Sushi V3 0.3% | 10000 | FULL | 100.00 | 9.58 | 0.0082 | 30.00 | 9990 | 9990 | 698,349 | N | N | N | N |
| Sushi V3 0.3% | 50000 | FULL | 100.00 | 9.58 | 0.0016 | 150.00 | 9998 | 9998 | 714,155 | N | N | N | N |
| Sushi V3 0.3% | 100000 | FULL | 100.00 | 9.58 | 0.0008 | 300.00 | 9999 | 9999 | 721,579 | N | N | N | N |
| Sushi V3 0.05% | 500 | FULL | 100.00 | 1.38 | 0.0235 | 0.25 | 9973 | 9972 | 584,684 | N | N | N | N |
| Sushi V3 0.05% | 1000 | FULL | 100.00 | 1.38 | 0.0118 | 0.50 | 9986 | 9986 | 621,710 | N | N | N | N |
| Sushi V3 0.05% | 5000 | FULL | 100.00 | 1.38 | 0.0024 | 2.50 | 9997 | 9997 | 717,951 | N | N | N | N |
| Sushi V3 0.05% | 10000 | FULL | 100.00 | 1.38 | 0.0012 | 5.00 | 9998 | 9998 | 755,035 | N | N | N | N |
| Sushi V3 0.05% | 50000 | FULL | 100.00 | 1.38 | 0.0002 | 25.00 | 9999 | 9999 | 851,497 | N | N | N | N |
| Sushi V3 0.05% | 100000 | FULL | 100.00 | 1.38 | 0.0001 | 50.00 | 9999 | 9999 | 887,671 | N | N | N | N |
| Uniswap V3 0.01% | 500 | FULL | 100.00 | 1.37 | 0.0233 | 0.05 | 9972 | 9972 | 4,157,131 | N | N | N | N |
| Uniswap V3 0.01% | 1000 | FULL | 100.00 | 1.37 | 0.0117 | 0.10 | 9986 | 9986 | 4,552,954 | N | N | N | N |
| Uniswap V3 0.01% | 5000 | FULL | 100.00 | 1.37 | 0.0023 | 0.50 | 9997 | 9997 | 5,483,286 | N | N | N | N |
| Uniswap V3 0.01% | 10000 | FULL | 100.00 | 1.37 | 0.0012 | 1.00 | 9998 | 9998 | 5,883,019 | N | N | N | N |
| Uniswap V3 0.01% | 50000 | FULL | 100.00 | 1.37 | 0.0002 | 5.00 | 9999 | 9999 | 6,817,457 | N | N | N | N |
| Uniswap V3 0.01% | 100000 | FULL | 100.00 | 1.37 | 0.0001 | 10.00 | 9999 | 9999 | 7,219,190 | N | N | N | N |
| Uniswap V3 1% | 500 | FULL | 100.00 | 461.09 | 7.8838 | 5.00 | 769 | 778 | 115,943 | N | N | N | N |
| Uniswap V3 1% | 1000 | FULL | 100.00 | 592.63 | 5.0665 | 10.00 | 4068 | 4073 | 192,822 | N | N | N | N |
| Uniswap V3 1% | 5000 | FULL | 100.00 | 597.17 | 1.0211 | 50.00 | 8804 | 8805 | 200,121 | N | N | N | N |
| Uniswap V3 1% | 10000 | FULL | 100.00 | 597.43 | 0.5108 | 100.00 | 9402 | 9402 | 207,322 | N | N | N | N |
| Uniswap V3 1% | 50000 | FULL | 100.00 | 597.62 | 0.1022 | 500.00 | 9880 | 9880 | 207,282 | N | N | N | N |
| Uniswap V3 1% | 100000 | FULL | 100.00 | 597.64 | 0.0511 | 1,000.00 | 9940 | 9940 | 207,310 | N | N | N | N |
| Uniswap V3 0.3% | 500 | FULL | 100.00 | 464.37 | 7.9399 | 1.50 | 701 | 712 | 108,640 | N | N | N | N |
| Uniswap V3 0.3% | 1000 | FULL | 100.00 | 865.80 | 7.4018 | 3.00 | 1331 | 1342 | 209,656 | N | N | N | N |
| Uniswap V3 0.3% | 5000 | FULL | 100.00 | 1,015.42 | 1.7362 | 15.00 | 7966 | 7969 | 465,557 | N | N | N | N |
| Uniswap V3 0.3% | 10000 | FULL | 100.00 | 1,015.67 | 0.8683 | 30.00 | 8983 | 8984 | 472,823 | N | N | N | N |
| Uniswap V3 0.3% | 50000 | FULL | 100.00 | 1,015.83 | 0.1737 | 150.00 | 9796 | 9796 | 487,315 | N | N | N | N |
| Uniswap V3 0.3% | 100000 | FULL | 100.00 | 1,015.85 | 0.0868 | 300.00 | 9898 | 9898 | 493,587 | N | N | N | N |
| Uniswap V3 0.05% | 500 | FULL | 100.00 | 500.10 | 8.5508 | 0.25 | 0 | -1 | 110,635 | Y | Y | Y | Y |
| Uniswap V3 0.05% | 1000 | FULL | 100.00 | 1,000.15 | 8.5504 | 0.50 | 0 | -1 | 110,619 | Y | Y | Y | Y |
| Uniswap V3 0.05% | 5000 | FULL | 100.00 | 4,998.84 | 8.5471 | 2.50 | 4 | 2 | 140,553 | Y | Y | Y | Y |
| Uniswap V3 0.05% | 10000 | FULL | 100.00 | 9,992.95 | 8.5431 | 5.00 | 9 | 7 | 164,232 | Y | Y | Y | Y |
| Uniswap V3 0.05% | 50000 | FULL | 100.00 | 49,775.82 | 8.5108 | 25.00 | 47 | 44 | 353,784 | Y | Y | Y | Y |
| Uniswap V3 0.05% | 100000 | FULL | 100.00 | 99,079.97 | 8.4705 | 50.00 | 94 | 92 | 448,395 | N | Y | Y | Y |

Rows for dust pools (Uniswap 0.01% / 0.3% / 1%, Sushi V3 and V2, LFJ V2.1, V2.2 bin25/50/100, Pharaoh ts5/50/100, ...) are in the log: all fail every limit (slippage above 700 bp or revert).

### Ranking (slippage vs Chainlink; gas of the swap call)
| Rank | Route | USD 1k | USD 5k | USD 10k | USD 50k | USD 100k | Gas at 1k / 10k |
|---|---|---|---|---|---|---|---|
| 1 | Uniswap V3 0.05% | -1 bp | 2 bp | 7 bp | 44 bp | 92 bp | 111k / 164k |
| 2 | Pharaoh CL ts10 | -2 bp | -1 bp | 0 bp | 17 bp | 428 bp | 122k / 166k |
| 3 | LFJ LB V2.2 bin10 | 8 bp | 34 bp | 67 bp | 557 bp | 1134 bp | 152k / 321k |
| 4 | LFJ V1 | 55 bp | 247 bp | 477 bp | 1989 bp | 3315 bp | 104k / 104k |
| 5 | Pangolin V2 | 222 bp | 964 bp | 1747 bp | 5125 bp | 6775 bp | 106k / 106k |
| - | Sushi V2/V3, Uniswap 0.01/0.3/1%, other LFJ, Pharaoh ts5/50/100 | fail every limit | | | | |

### Depth limits (largest size with slippage vs Chainlink at or below the threshold; bisection on real executions, resolution about 3%)
| Route | <= 1% (100 bp) | <= 3% (300 bp) |
|---|---|---|
| Uniswap V3 0.05% | USD 109,411 | USD 323,261 |
| Pharaoh CL ts10 | USD 84,088 | USD 98,675 (the wall: it falls off a cliff above) |
| LFJ LB V2.2 bin10 | USD 14,439 | USD 35,560 |
| LFJ V1 | USD 1,924 | USD 6,129 |
| Pangolin V2 | below USD 500 | USD 1,396 |
| Sushi V3 0.3%, Sushi V2, Uniswap V3 0.3% | below USD 500 | below USD 500 |

### Best split of the larger sizes (10% grid, both swaps executed for real)
| Pair | USD 50,000 | USD 100,000 |
|---|---|---|
| Uniswap V3 0.05% + Pharaoh ts10 | best 30% / 70%: USD 49,946 out (vs 49,776 Uniswap alone) | best 40% / 60%: USD 99,719 out (vs 99,080 Uniswap alone) |
| Uniswap V3 0.05% + LFJ LB bin10 | best 90% / 10%: 49,802 | best 90% / 10%: 99,189 |
| Uniswap V3 0.05% + LFJ V1 / Pangolin | 100% Uniswap | 100% Uniswap |
(`attempt05-lb20-depth-split.txt`; the Uniswap depth rerun after a transient RPC reset: `attempt06-depth-uni3-500.txt`.)

**Route verdict so far.** Uniswap V3 0.05% is the only deep route (1% slippage at about USD 109k) and meets a Chainlink-minus-0.5% min-out at every size up to USD 50k and minus 1% at USD 100k; Pharaoh ts10 is as cheap up to USD 50k and is the natural second route (independent pool) but has a wall near USD 98k. LFJ is third (bin10, USD 125k of total USDC), the rest are dust.

## 3. Liquidation cycle (part B): results available at the time of writing
Setup and conventions: borrowers borrow 100% of their borrowing power while the feed is mocked UP (price at borrowing = pin / (1 - gap)); the mock is then cleared, so liquidation, seizure value and the conversion all run at the real pinned price and the real pool state (the gap is 35% unless stated). The operator holds a USDC inventory (`deal`, the only outside USDC), repays 50% of the debt (close factor) per round, receives pWAVAX (seize identity asserted: value = repay x 1.08 x 0.972), redeems pWAVAX -> WAVAX from the market's cash (identity asserted), converts through Uniswap V3 0.05% with min-out = Chainlink value minus 1.00% (`limitBp` 100; revert-protected), and the next round is funded from the inventory as it then stands. Gas priced at 2.5 gwei and AVAX 8.549 (about USD 0.01 per round).

PW40, one borrower, gap 35% (two rounds; `attempt07-cycle-case1-PW40-first.txt`, test PASS):
| Cap (research) | Debt | Total repaid | Round 1 / 2 net (bp of repaid) | Conversion output vs oracle | Funding WITHOUT recycling | Funding WITH recycling (peak need) | Difference |
|---|---|---|---|---|---|---|---|
| USD 1,000 | 1,000.00 | 750.00 | +494 / +494 | 99.97% / 99.96% | USD 750.00 (0.75 x debt) | USD 500.00 (0.50 x debt) | 250.00 |
| USD 5,000 | 5,000.00 | 3,750.00 | +493 / +489 | 99.95% / 99.91% | USD 3,750.00 | USD 2,500.00 | 1,250.00 |
| USD 10,000 | 10,000.00 | 7,500.00 | see log | see log | USD 7,500.00 | USD 5,000.00 | 2,500.00 |
Gap 10% (one round), cap 5,000: both numbers are USD 2,500 (no difference, recycling cannot help a single round). The funding numbers were TESTED, not just computed: a run with exactly the requirement funds every step, one unit less leaves a step unfunded. Net per round = conversion proceeds - repaid - gas; theory is 1.08 x 0.972 - 1 = +497.6 bp before swap cost and gas; measured +489 to +494 bp.

### 3a. Concurrent borrowers (case 2), gap 35%, interleaved by two operators (each holds cap/2), identical for PW30 and PW40
| Cap | Borrowers | Recycling | Rounds | Total repaid | Peak need operator A / B (USDC) | Unfunded steps | Bad debt |
|---|---|---|---|---|---|---|---|
| 1,000 | 3 | yes | 6 | 750 | 167 / 167 | 0 | 0 |
| 1,000 | 3 | no | 6 | 750 | 417 / 333 | 0 (inventory 500 each suffices) | 0 |
| 1,000 | 5 | yes | 10 | 750 | 100 / 100 | 0 | 0 |
| 1,000 | 5 | no | 10 | 750 | 400 / 350 | 0 | 0 |
| 5,000 | 3 | yes / no | 6 | 3,750 | 833 / 833 (yes); 2,083 / 1,667 (no) | 0 | 0 |
| 5,000 | 5 | yes / no | 10 | 3,750 | 500 / 500 (yes); 2,000 / 1,750 (no) | 0 | 0 |
| 10,000 | 3 / 5 | yes / no | 6 / 10 | 7,500 | 1,667 / 1,667 and 1,000 / 1,000 (yes); 4,167 / 3,333 and 4,000 / 3,500 (no) | 0 | 0 |
With recycling the peak need falls with the number of borrowers (each round needs only 0.5 x one borrower's debt because proceeds return between rounds); without recycling it is the cumulative repayment (0.75 x debt in total, split across operators). A single operator working all borrowers in sequence behaves the same (`SEQ-1op`). Conversion output was 99.91 to 99.97% of the oracle value in every swap, net per round +489 to +494 bp.

### 3b. One operator unavailable (case 3): operator B alone, 35% gap, then a second fall to -60% from the pin (stage 2)
| Cap | Borrowers | Inventory of B | Recycling | Outcome |
|---|---|---|---|---|
| 1,000 / 5,000 | 3 or 5 | cap/2 | **yes** | all rounds funded (6 / 10), 0 accounts left in shortfall at stage 1, repaid 0.75 x debt, bad debt 0; at stage 2 the accounts are in shortfall again but bad debt is 0 |
| 1,000 / 5,000 | 3 or 5 | cap/4 | **yes** | still fully funded (recycling restores the inventory every round) |
| 1,000 | 3 | cap/2 | **no** | 4 of 6 rounds funded (repaid 0.50 x debt), 1 account left in shortfall; at stage 2 its bad debt is USD 44.3 |
| 1,000 | 5 | cap/2 | **no** | 7 of 10 rounds funded, 2 accounts left in shortfall, 5 unfunded steps; bad debt at stage 2 USD 26.6 |
| 5,000 | 5 | cap/2 | **no** | 5 unfunded steps, 2 accounts in shortfall; bad debt at stage 2 USD 133.0 |
So an unavailable operator is covered ONLY if the remaining operator recycles successfully or holds the no-recycling requirement (0.75 x debt in this gap) alone; with half-cap inventory and no recycling, accounts stay unliquidated and the later fall turns them into bad debt (identical for PW30 and PW40).

### 3c. Route blocked by the min-out limit (case 5): adverse pool move, limit Chainlink minus 1%
- Adverse pool move 300 bp, limit 100 bp, **no fallback route**: the swap is blocked every time (the liquidator holds the WAVAX); with inventory cap/2 only the first round is funded (repaid 0.50 x debt, 1 account left in shortfall, 2 unfunded steps); with inventory = cap both rounds are funded without any swap (repaid 0.75 x debt, the liquidator ends holding about 460 WAVAX). Five borrowers, inventory cap/2: 7 blocked swaps, 5 unfunded steps, 2 accounts left in shortfall.
- Same event **with a fallback route** (a second venue within the limit): all 10 rounds funded and converted at 99.96% of the oracle.
- Adverse move 30 bp, limit 100 bp: swaps proceed (output 99.54% of the oracle), both rounds funded.
Reading: the limit protects the liquidator from a bad fill but turns the swap into a hard stop; the funding then has to cover the no-recycling requirement or a second route must exist.

### 3d. Funding summary (PW30 and PW40 are identical in these cycles; amounts in USDC)
| Cap (research) | First-round need per operator (with recycling) | No-recycling requirement, 35% gap (0.75 x debt) | No-recycling requirement, 30-day outage worst case (about 0.88 x debt incl. interest) |
|---|---|---|---|
| 1,000 | 500 | 750 | about 890 |
| 5,000 | 2,500 | 3,750 | about 4,440 |
| 10,000 | 5,000 | 7,500 | about 8,890 |
Recycling works at these sizes through Uniswap V3 0.05% with a 1% min-out limit, so the minimum is the first-round column; it is not ASSUMED anywhere in the capital tables of the qualification document, which carry the no-recycling requirement alongside it. Gas per round about USD 0.01 at 2.5 gwei.

### 3e. Not tested
Aggregators; swaps larger than USD 10,000 per round in the cycle (the route table covers up to 100,000); competing liquidators and MEV; a pool state other than the pin; real operator latency; WAVAX held through price moves between redemption and conversion (conversion is modelled in the same block); the interplay with a stale feed during the cycle (covered separately by the outage tests).
