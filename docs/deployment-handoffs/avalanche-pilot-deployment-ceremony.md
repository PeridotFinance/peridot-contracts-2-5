# Avalanche cash-only lending, PW30: mainnet deployment ceremony (target 11 Nov)

Status: **PREPARED, NOT EXECUTED.** The assistant signs and broadcasts nothing: every transaction below is signed by the Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` in the operator's hands. The same wrapper (`contracts/tools/avalanche-ceremony.sh`) was REHEARSED end to end on a local fork of the current mainnet head with the Ledger address impersonated; results in section 6. No launch approval is implied by this document; the operator decides. Pilot caps stay: **USDC borrow cap USD 5,000, WAVAX borrowing disabled, WAVAX collateral factor 30%, USDC collateral factor 0%.**

## 0. What goes live, in one paragraph
A fresh controller (Unitroller + `PeridottrollerAvalanche`, opt-in **no reward token**), the guarded Chainlink oracle, one rate model, pWAVAX and pUSDC (plain delegates), single-use bootstrapper, all administered by the Ledger. Nothing of the vault, PHAR or margin code is touched; both margin hooks stay unset. USDC suppliers earn the borrow interest; **WAVAX deposits earn nothing** (WAVAX borrowing is disabled, so no one pays interest on WAVAX): WAVAX is collateral only.

## 1. Inputs: PROPOSED values for you to confirm (`contracts/ceremony/pilot-pw30.env`, public values only)
| Input | Proposed | Why / what to check |
|---|---|---|
| `DEPLOYER` = admin = signer | the Ledger `0x064e...B2dD` | the wrapper refuses any other deployer. Needs ~0.1 AVAX of gas for about 30 transactions (it holds 1.57 AVAX today at 2.53 gwei), **plus the seed tokens below** |
| `PERIDOT_TOKEN`, `LENDING_ALLOW_NO_REWARD_TOKEN` | `0x0`, `true` | the explicit no-reward-token choice (`claimPeridot` reverts; nothing else reads the token). Confirm: no PERIDOT rewards on this deployment |
| `PAUSE_GUARDIAN` | the Ledger | the guardian can only pause; the Ledger (admin) can pause AND unpause. A separate hot guardian would pause faster but adds a key; **your decision** |
| Seeds | 12 WAVAX (about USD 100) and 100 USDC, **in the Ledger before the ceremony** | held by the market forever (anti-donation seeding); they are not your supply |
| USDC borrow cap | 5,000 USDC (`5000000000`) | the controller's check is strict (`<`): the last borrowable unit is 4,999.999999 |
| WAVAX borrow cap | 120 WAVAX (about USD 1,000) | only bounds a mistake: WAVAX borrowing stays **paused** |
| Reserve factor / close factor / incentive | 10% / 50% / 108% | the study's values; the cycle suite and the truth table were run with exactly these |
| Rate model | base 2% per year, slope 10% **reached at the kink**, kink 80%, jump 100% per year | jump-rate V2 form: borrow APR = 2% + 10% x (utilisation / 80%) up to the kink, then + 100% x (utilisation - 80%). **Supply APR to depositors = borrow APR x utilisation x 90%.** Measured on the real contracts in the rehearsal (USD 4,900 borrowed of USD 6,350 in the market, utilisation 77.2%): **borrow 11.65%, supply 8.09%**. By utilisation: 50% -> borrow 8.3% / supply 3.7%; 60% -> 9.5% / 5.1%; 70% -> 10.8% / 6.8%; 80% -> 12% / 8.6%; 90% -> 22% / 17.8%. More deposits dilute the yield (USD 10,000 supplied with USD 5,000 borrowed = 50% utilisation = 3.7%). No borrowers, no yield. Borrowers pay these rates: "team may borrow" means the team pays depositors |
| `LENDING_BLOCKS_PER_YEAR` | **33,500,000** (not the study's 31,536,000) | Avalanche mines a block every 0.936 to 0.944 s (measured over 14 days and again today); the rate model divides the yearly rate by this number, so 31.5 million would pay about 6% MORE than the stated rate. The study's loss figures were computed at 31.5 million; the difference in 30-day interest is small and goes the other way for bad debt only by about 6% of the interest |
| Feed max ages | AVAX 1,200 s, USDC 90,000 s | the AVAX/USD feed's largest age in a 14-day sample was 138 s, so 1,200 s will not starve the market |
| Cash floor | USDC 1,250 (20% of the intended supply of 6,250), WAVAX 0 | new borrows are refused when they would take the market's cash below the floor |

Supply side ("seeded by the operator"): **USD 6,250 USDC** from your supplier wallet in step E.2, **before** borrowing is enabled. Say if you want another amount; the floor above follows it (20%).

## 2. Before the day (read-only checks I can repeat on request)
1. The Ledger shows the right address: `cast wallet address --ledger` (must print `0x064e...B2dD`; if not, the derivation path differs: use `--mnemonic-derivation-path`/`--hd-paths` and tell me).
2. Ledger Ethereum app: **blind signing / contract data enabled** (contract creation transactions are not decodable on the device).
3. Balances in the Ledger: `cast balance 0x064e...B2dD -e` >= 0.3 AVAX; WAVAX >= 12; USDC >= 100 (+ the 6,250 supply if the Ledger is also the supplier).
4. `AVALANCHE_MAINNET_RPC_URL` is set and the endpoint allows `eth_getLogs` over the monitor's `logChunkBlocks` (**the current endpoint is a free tier limited to 10 blocks: upgrade it before the monitor, executors and keeper go live**; the ceremony itself does not need `getLogs`).
5. `git status` clean on the commit that this document names; `contracts/ceremony/pilot-pw30.env` is the file you confirmed.

## 3. The ceremony (operator terminal, Ledger connected; the assistant is not in this loop)
```
cd contracts
source ceremony/pilot-pw30.env
export ETH_RPC_URL="$AVALANCHE_MAINNET_RPC_URL"       # cast reads it from the environment: the URL is never an argument
tools/avalanche-ceremony.sh check-env live            # 20 inputs set, DEPLOYER is the Ledger
tools/avalanche-ceremony.sh deploy live               # the Ledger asks to confirm each transaction (about 30); the script ends by verifying itself
```
Record the five addresses printed at the end (controller, implementation, guarded oracle, pWAVAX, pUSDC) and send them to me. Then, **before enabling anything**:
```
export CONTROLLER=<controller> PWAVAX=<pWAVAX> PUSDC=<pUSDC> EXPECTED_ADMIN=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD
tools/avalanche-ceremony.sh verify live               # read-only: admin, oracle, markets, seeds, floors, caps, hooks unset, borrowing paused, CFs zero
```
Expected: the script finishes without a revert. (It deliberately fails after step E.3, because it asserts "borrowing paused" and "collateral factors zero": run it before E, never after.)

## 4. Enabling (Ledger transactions, in this order; each followed by its read-back)
| # | Transaction (from the Ledger unless stated) | Read-back (read-only) |
|---|---|---|
| E.1 | `cast send $CONTROLLER '_setCollateralFactor(address,uint256)' $PWAVAX 300000000000000000 --ledger --from 0x064e...B2dD` | `cast call $CONTROLLER 'markets(address)(bool,uint256,bool)' $PWAVAX` = `true, 300000000000000000, false`; same for `$PUSDC`: collateral factor `0` |
| E.2 | supply side, from your supplier wallet: `cast send 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E 'approve(address,uint256)' $PUSDC 6250000000` then `cast send $PUSDC 'mint(uint256)' 6250000000` | `cast call $PUSDC 'getCash()(uint256)'` = 6350000000 (6,250 + the 100 seed); `cast call $PUSDC 'balanceOf(address)(uint256)' <supplier>` > 0 |
| E.3 | **enable borrowing**: `cast send $CONTROLLER '_setBorrowPaused(address,bool)' $PUSDC false --ledger --from 0x064e...B2dD` | `cast call $CONTROLLER 'borrowGuardianPaused(address)(bool)' $PUSDC` = `false`; and `$PWAVAX` still `true` |
| E.4 | none: `cast call $CONTROLLER 'borrowCaps(address)(uint256)' $PUSDC` = `5000000000`; `'borrowCashFloor(address)(uint256)' $PUSDC` = `1250000000`; `'pauseGuardian()(address)'` = the Ledger | |
Why this order: the collateral factor and the supply exist before the first borrow is possible; borrowing is enabled last. "Team may borrow" from E.3 on.

## 5. After enabling
1. The addresses and ABIs for the **Stellar agent (TP/SL registry and keeper)**: I write `docs/deployment-handoffs/avalanche-pilot-addresses.json` and export the ABIs (`forge inspect <contract> abi`) the day you send me the five addresses.
2. The three hosts start (host setup document): operators and keeper with their inventory; `check` prints no critical finding; the monitor shows `pilot.label PW30`.
3. **Stop conditions** (any one: do not proceed to the next step): a verify revert; an address in the output that is not code on chain; a read-back that differs; the monitor reporting a critical finding.
4. **Abort / pause** at any time (Ledger): `cast send $CONTROLLER '_setBorrowPaused(address,bool)' $PUSDC true` and `'_setMintPaused(address,bool)' $PUSDC true` (runbook: `avalanche-cash-only-deployment-rehearsal.md`).

## 6. Rehearsal evidence (local fork of the CURRENT mainnet head, block 99,580,340, Ledger address impersonated; nothing real was signed)
`operator/scripts/rehearse-ceremony.ts` runs the wrapper exactly as section 3 does (`check-env`, `deploy`, `verify`, with `rehearsal` instead of `live`), then E.1 to E.4 and a smoke test; report: `avalanche-cash-only-operator-evidence/ceremony-rehearsal.json`.
- **30 transactions, 19,981,702 gas** (0.06 AVAX at 3 gwei; forge's own estimate for the script is 26.3 million gas, 0.17 AVAX at 6.3 gwei: keep >= 0.3 AVAX in the Ledger). Every transaction needs a Ledger confirmation.
- `verify` **passes before enabling** (admin, oracle chain, markets, seeds, floors, caps, hooks unset, borrowing paused, collateral factors zero).
- After E.1 to E.3 the read-backs are: admin = the Ledger; pWAVAX collateral factor `300000000000000000`, pUSDC `0`; pUSDC borrowing enabled, pWAVAX borrowing **paused**; USDC borrow cap `5000000000`; cash floor `1250000000`; pUSDC cash `6350000000` (6,250 supplied + the 100 seed).
- **Smoke test on the deployed bytecode**: a borrower deposits 400 WAVAX, borrows 500 USDC, repays in full; a borrow beyond the borrowing power is refused; **a WAVAX borrow is refused (paused)**; a second borrower takes the market to 77.2% utilisation with USD 4,900 and **a further USD 200 (over the USD 5,000 cap) is refused**.
- Measured yield at that load: borrow 11.65%, supply 8.09% (table in section 1).
Not covered by the rehearsal: the Ledger device itself (derivation path, blind-signing setting, per-transaction confirmation), the real endpoint's behaviour during a broadcast, gas price on the day, and the first real liquidation.
