# Avalanche margin 2x (long WAVAX / USDC): mainnet ceremony

Status: **PREPARED, NOT EXECUTED.** The assistant signs and broadcasts nothing. Two signers are involved: a **throwaway deployer** (an unprivileged key that only pays gas for the deployments) and the **Ledger** `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` (every owner action). The wrapper `contracts/tools/avalanche-margin-ceremony.sh` is the same in rehearsal (local anvil fork, accounts impersonated) and live (Ledger, private endpoint from the environment, output redacted). Rehearsal evidence: `avalanche-margin-evidence/`. Scope and decisions: `avalanche-margin-2x-scope-and-rehearsal-plan.md`.

## 0. What is deployed and what is fixed in the code

- On top of PW30 (controller, guarded oracle, pWAVAX, pUSDC). **The PW30 guarded oracle is reused** (the risk engine, the quoter, the close adapter and the controller read the same prices); no second oracle, no emergency price.
- 17 contracts: insurance fund, config, fee distributor, vault, risk engine (proxies); quoter, swap module, account factory; executor, liquidator (proxies); flash vault; Pharaoh CL router adapter (pool `0xf01449C0…9534`, tick spacing 10); order registry (proxy) and the Avalanche close adapter.
- **Owner of everything = the Ledger from the first instruction** (every `initialize` takes it; every proxy admin is owned by it; the account factory's configurator and the flash vault owner are the Ledger). The deployer holds no role at any time. The script checks this at every stage (`verify`): no owner, no proxy-admin owner, no funded-liquidator right, no pToken, no allowance names the deployer.
- **Risk numbers are constants in the script** (not environment variables): 2x, initial margin 50%, maintenance **25%**, liquidation bonus 5%, max slippage 100 bp, oracle deviation 100 bp, **position cap USD 5,000, debt cap USD 2,500**. Fees 0. Opens start **paused**.
- Preconditions the script checks before it deploys: chain 43114; the Ledger is the controller admin; **WAVAX borrowing is paused** (this is what makes the product long-only); both markets are priced by the controller's oracle; the deployer is not the Ledger and is not a funder; the two funders are distinct, non-zero and not the Ledger.

## 1. Inputs (public values; `contracts/ceremony/margin-pw30.env` once the addresses exist)

| Input | Value |
| --- | --- |
| `MARGIN_OWNER` | the Ledger |
| `MARGIN_DEPLOYER` | public address of the throwaway deployer; keystore name in `MARGIN_DEPLOYER_ACCOUNT` (live) |
| `CONTROLLER`, `PWAVAX`, `PUSDC` | the five PW30 addresses (11 Nov) |
| `MARGIN_FUNDERS` | the two operator addresses, comma separated |
| `MARGIN_FLASH_SEED_USDC` | `2500000000` (decision D5) |
| `MARGIN_INSURANCE_SEED_USDC` | `250000000` (decision D6) |
| `MARGIN_ACTION_DELAY` | `86400` (24 h, decision D1) |

Balances before stage 2: the Ledger holds **2,750 USDC** (2,500 for the flash vault, 250 for the insurance seed) and AVAX for about 30 transactions. The deployer holds AVAX for 17 deployments (estimate from the rehearsal broadcast: see the evidence; fund about 1.5x).

## 2. Stages

| Stage | Signer | Command | What it does |
| --- | --- | --- | --- |
| check | none | `tools/avalanche-margin-ceremony.sh check-env live` | all inputs set; owner is the Ledger; the deployer is not |
| 1 deploy | throwaway deployer | `... deploy live` | deploys everything, writes `ceremony/margin-addresses.env`; runs `verify` stage 1 inside |
| verify 1 | none | `STAGE=1 ... verify live` | owners, proxy admins, oracle identity, hooks still unset, opens paused, fees 0 |
| 2 wire | Ledger | `... wire live` | factory/risk engine/vault/fee distributor/insurance roles; vault token allowlist; flash vault (USDC only, fee 0, funded with the seed); insurance seed (mint pUSDC, transfer the minted amount); **controller hooks**; **one-shot order-executor wiring** (`upgradeAndCall` with `initializeOrderExecutor`); **queues** pair risk, each funded liquidator and the unpause. The 24 h clock starts here. |
| verify 2 | none | `STAGE=2 ... verify live` | everything above read back |
| 3 execute | Ledger | `... execute live` (>= 24 h later) | pair risk and the funded-liquidator allowlist. Opens stay paused. |
| verify 3 | none | `STAGE=3 ... verify live` | the pair risk read back equals the constants; both operators are funders |
| 4 enable | Ledger | `... enable live` | re-checks prices, flash liquidity, insurance, WAVAX borrowing still paused; executes the queued unpause |
| verify 4 | none | `STAGE=4 ... verify live` | opens live |

Stage 2 is about 22 Ledger signatures, stage 3 about 3, stage 4 one. Stage 1 needs the Ledger for nothing.

**Order in the calendar:** stage 1 and 2 any day after the PW30 deployment (inert while paused); stage 3 the next day; stage 4 only after the monitor and operators are running with the margin step (14 Nov build) and `verify 3` passed. Latest dates: stage 2 on 16 Nov, stage 3 on 17 Nov, stage 4 on 18 Nov.

## 3. If a stage stops half-way

Do not re-run `wire` blindly: the queues revert with "already queued" and some calls already happened. Run `verify` at the last stage that passed, read the Ledger's nonce, and list which transactions landed (`cast tx`/the broadcast file under `contracts/broadcast/`). Every unfinished action is a separate call that can be sent by hand from the printed script; report the state to me. Nothing is live until stage 4, so a stopped ceremony costs time and gas, never exposure.

## 4. Brakes after enable (all Ledger, all immediate)

| Brake | Call | Effect |
| --- | --- | --- |
| stop new positions | `config.pauseOpens()` | opens refused; closes, repays, liquidations unaffected |
| disable the pair | `config.disablePair(pUSDC, pWAVAX, pUSDC)` | risk-increasing operations stop |
| remove an operator | `config.removeFundedLiquidator(op)` | immediate |
| stop order execution | `registry.setPaused(true)` | only order execution; owner closes and liquidations unaffected |
| stop USDC borrowing | `controller._setBorrowPaused(pUSDC, true)` | also stops lending borrows (shared market) |

## 5. Read-backs the operator should see after stage 4 (also printed by `verify`)

- hooks: `controller.isolatedMarginRiskHook() == riskEngine == isolatedMarginRegistrar()`;
- `executor.orderExecutor() == closeAdapter`; `registry.adapter() == closeAdapter`; `closeAdapter.registry() == registry`;
- `config.opensPaused() == false`; pair risk equals the constants; both operators `fundedLiquidators == true`;
- flash vault: USDC allowed, WAVAX not, fee 0, balance >= 2,500 USDC; insurance fund holds pUSDC;
- every owner and proxy-admin owner is the Ledger; the deployer is none of them.

## 6. Operator side (before stage 4)

- The two operator wallets keep their USDC inventory (at least USD 3,750 each) and approve the **liquidator proxy** for the exact need only (the margin step of the operator does it; see the host-setup addition).
- Pilot operating rule (decision D2): team lending borrows stay at or under 2,000 USDC while margin is open, so about 2,450 of margin debt fits inside the USD 5,000 cap and the 1,250 cash floor. Raising the cap to 7,500 later needs a Ledger transaction and 2,500 USDC more supply.
- Monitor: margin accounts must be classified before the margin step goes live (14 Nov build); until then the lending executor must not be started with margin open.
