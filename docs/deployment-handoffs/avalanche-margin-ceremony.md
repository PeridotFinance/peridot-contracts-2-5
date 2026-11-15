# Avalanche margin 2x (long WAVAX / USDC): mainnet ceremony

Status: **PREPARED, NOT EXECUTED.** The assistant signs and broadcasts nothing. Two signers are involved: a **throwaway deployer** (an unprivileged key that only pays gas for the deployments) and the **Ledger** `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` (every owner action). The wrapper `contracts/tools/avalanche-margin-ceremony.sh` is the same in rehearsal (local anvil fork, accounts impersonated) and live (Ledger, private endpoint from the environment, output redacted). Rehearsal evidence: `avalanche-margin-evidence/`. Scope and decisions: `avalanche-margin-2x-scope-and-rehearsal-plan.md`.

## 0. What is deployed and what is fixed in the code

- On top of PW30 (controller, guarded oracle, pWAVAX, pUSDC). **The PW30 guarded oracle is reused** (the risk engine, the quoter, the close adapter and the controller read the same prices); no second oracle, no emergency price.
- 17 contracts: insurance fund, config, fee distributor, vault, risk engine (proxies); quoter, swap module, account factory; executor, liquidator (proxies); flash vault; Pharaoh CL router adapter (pool `0xf01449C0…9534`, tick spacing 10); order registry (proxy) and the Avalanche close adapter.
- **Owner of everything = the Ledger from the first instruction** (every `initialize` takes it; every proxy admin is owned by it; the account factory's configurator and the flash vault owner are the Ledger). The deployer holds no role at any time. The script checks this at every stage (`verify`): no owner, no proxy-admin owner, no funded-liquidator right, no pToken, no allowance names the deployer.
- **Risk numbers are constants in the script** (not environment variables), except the cap, which is the one public input `MARGIN_CAP_USD`: 2x, initial margin 50%, maintenance **25%**, liquidation bonus 5%, max slippage 100 bp, oracle deviation 100 bp, **position cap = `MARGIN_CAP_USD` and debt cap = `MARGIN_CAP_USD`/2** (the script takes 100 to 5,000 and derives both; research size 5,000 and 2,500). Fees 0. Opens start **paused**.
- Preconditions the script checks before it deploys: chain 43114; the Ledger is the controller admin; **WAVAX borrowing is paused** (this is what makes the product long-only); both markets are priced by the controller's oracle; the deployer is not the Ledger and is not a funder; the two funders are distinct, non-zero and not the Ledger.

## 1. Inputs (public values; `contracts/ceremony/margin-pw30.env` once the addresses exist)

| Input | Value |
| --- | --- |
| `MARGIN_OWNER` | the Ledger |
| `MARGIN_DEPLOYER` | public address of the throwaway deployer; keystore name in `MARGIN_DEPLOYER_ACCOUNT` (live) |
| `CONTROLLER`, `PWAVAX`, `PUSDC` | the five PW30 addresses (from the PW30 ceremony) |
| `MARGIN_CAP_USD` | the pilot's CAP in USD, 100..5,000 (public value, from `contracts/ceremony/margin-sizing.env`, written by `contracts/tools/pilot-sizing.py`); the pair's position cap = CAP, debt cap = CAP/2. CAP is not yet known (to be confirmed with the operator before anything is signed); research size 5,000 |
| `MARGIN_FUNDERS` | the two operator addresses, comma separated |
| `MARGIN_FLASH_SEED_USDC` | 0.5 x CAP, at least CAP/2 (decision D5; `2500000000` at CAP = 5,000; in `margin-sizing.env`) |
| `MARGIN_INSURANCE_SEED_USDC` | 5% of CAP (decision D6; `250000000` at CAP = 5,000; in `margin-sizing.env`) |
| `MARGIN_ACTION_DELAY` | `86400` (24 h, decision D1) |

Balances before stage 2: the Ledger holds **0.55 x CAP in USDC** (0.5 x CAP for the flash vault, 5% of CAP for the insurance seed; 2,750 at CAP = 5,000) and AVAX for the 28 transactions. **Deployer gas:** the throwaway deployer needs the measured gas times 1.5. Stage 1 is 22 transactions and 31.9M gas used; at the current 2.5 gwei floor that is **0.08 AVAX measured and 0.12 AVAX with the 50% margin** (this replaces the earlier 2.5 AVAX); fund the deployer with **0.12 AVAX**, whatever is left goes back to you. Ledger gas measured: the PW30 ceremony is 30 transactions and 20.0M gas; margin stages 2 to 4 are 24 + 3 + 1 transactions and 1.77M gas.

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

**Counts measured in the rehearsal broadcast** (`contracts/broadcast/DeployAvalancheMarginMainnet.s.sol/`): stage 1 is **22 transactions by the throwaway deployer** (31.9M gas used, 41.5M gas-limit sum); stage 2 is **24 Ledger signatures** (1.53M gas); stage 3 is **3** (0.20M); stage 4 is **1** (0.05M): **28 Ledger signatures in all**. Stage 1 needs the Ledger for nothing.

**Order:** no calendar dependency. Stage 1 and 2 any time after the PW30 deployment (inert while paused); stage 3 at least 24 h after stage 2 (the timelock); stage 4 only after verify 3 and the operators run with the margin block enabled.

### Last step of the margin sweep: delete the throwaway deployer keystore and its password from `pilot-keeper`

**Do NOT delete the deployer keystore before stage 1 is fully verified (`STAGE=1 ... verify live` passed, all 22 transactions landed) and its leftover AVAX has been swept back to the Ledger.** Until then the keystore is the only way to finish or repair stage 1 and to move the AVAX. This is the last step, after verify 4 (or any time after stage 1 is verified and swept, if you want the key gone earlier). The deployer holds no role at any time (`verify` asserts it), so this removes a secret, not a permission.

Deployer address `0x7413c1C72BAAfFc640C00Ba759BF14826b12C8C7`; host `pilot-keeper` `68.183.219.154`; files `/mnt/pilot_keeper_data/deployer/` (the keystore `deployer.json`, and anything else in that directory) and `/root/deployer.password`. `ETH_RPC_URL` must already be set in your shell environment (never typed on a command line, never printed).

1. Check that the deployer has swept its AVAX back to the Ledger (read-only; expect `0`, or dust below the cost of one transaction, about 0.0001 AVAX; anything larger must be swept first, while the keystore still exists):
```
cast balance 0x7413c1C72BAAfFc640C00Ba759BF14826b12C8C7 --ether
```
2. Delete the keystore files and the password file on `pilot-keeper` (`shred -u` overwrites then unlinks; shred is best effort on a journaling file system and a volume, which is acceptable because the keystore is scrypt-encrypted and its password is deleted in the same command):
```
ssh -i ~/.ssh/peridot-pilot_ed25519 root@68.183.219.154 'find /mnt/pilot_keeper_data/deployer -type f -exec shred -u {} + && rmdir /mnt/pilot_keeper_data/deployer && shred -u /root/deployer.password'
```
3. Check that they are gone (both lines must say `No such file or directory`; the keeper's own keystore under `/mnt/pilot_keeper_data/keystore/` and `/etc/pilot/keeper.env` must NOT be touched and must still exist):
```
ssh -i ~/.ssh/peridot-pilot_ed25519 root@68.183.219.154 'ls -la /mnt/pilot_keeper_data/deployer /root/deployer.password; ls /mnt/pilot_keeper_data/keystore /etc/pilot/keeper.env'
```
4. On your own machine, also delete the copy you imported for stage 1 (the Foundry keystore named in `MARGIN_DEPLOYER_ACCOUNT`, and any downloaded `deployer.json`); `avalanche-pilot-hosts.md` says to delete both after use.

Not run by the assistant; you run it.

## 3. If a stage stops half-way

**Stage 1 stopped half-way (happened 10 Nov 2026: the deployer ran out of gas after 8 of 22 transactions).** The cause was the gas price: the budget assumed the 2.5 gwei floor, forge estimated 17.8 gwei (base fee 7.5 gwei at the time). Budget stage 1 at **0.8 AVAX** for the deployer, not 0.12 (31.9M gas x 25 gwei). Do NOT run `deploy live` again: it would start at the deployer's current nonce and redeploy all 22 contracts. Run `tools/avalanche-margin-ceremony.sh deploy-resume live` instead: it broadcasts only the transactions of the saved run that were not sent (`--resume`, no new simulation). `--resume` sends to the endpoint **saved in `cache_forge/DeployAvalancheMarginMainnet.s.sol/<chain>/run-latest.json`** (each saved transaction carries its `rpc`), not to the current `--rpc-url`: that file therefore holds the endpoint URL; it is git-ignored, delete it after the ceremony. Rehearsed on a mainnet fork (broadcast with 8 receipts, deployer nonce 8): nonce 22, all 16 predicted addresses have code, `STAGE=1 verify` passes.

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
- flash vault: USDC allowed, WAVAX not, fee 0, balance >= 0.5 x CAP in USDC; insurance fund holds pUSDC;
- every owner and proxy-admin owner is the Ledger; the deployer is none of them.

## 6. Operator side (before stage 4)

- The two operator wallets keep their USDC inventory (at least 0.75 x CAP each; 3,750 at CAP = 5,000) and approve the **liquidator proxy** for the exact need only (the margin step of the operator does it; see the host-setup addition).
- Pilot operating rule (decision D2): team lending borrows stay at or under 0.4 x CAP while margin is open, so about 0.49 x CAP of margin debt fits inside the CAP borrow cap and the cash floor (20% of supply). At CAP = 5,000 that is 2,000 and about 2,450. Caps are raised later by a parameter change (a Ledger transaction plus the extra supply).
- Monitor and executor (built 8 Nov): margin accounts are classified by the controller's own flag (`isolatedMarginAccounts`) and removed from the lending verdicts, the treasury figures, the keeper's input and the lending executor's candidates; they are reported as `margin.positions`. The operator's margin step liquidates only through `liquidateFunded`, break-even floor fixed at 10,000 bp, bounded allowance, daily cap, insolvent positions declined. Details and the host configuration: `avalanche-pilot-host-setup.md` section 6. Rehearsal evidence: `avalanche-margin-evidence/rehearse-margin-pipeline-run6.txt`.
