# Avalanche cash-only pilot: setup of the hot wallets and their hosts (build step 4)

Status: **DRAFT; the scripts are written, NOT yet run.** No DigitalOcean access token is available in the assistant's environment yet, so no Droplet exists and no key exists anywhere (repository, session, Droplet). Decisions of the operator, 6 and 9 Nov 2026: **four DigitalOcean Droplets, each with its own 1 GiB volume, one Docker image, the keystore on the volume. App Platform is not used for anything that holds a key.** There are no calendar dependencies: nothing waits for a date, each step waits for the previous one. The assistant creates the Droplets with `doctl` and **generates the keystores ON the Droplets** (section 1 and 2); the password never leaves the Droplet and only the public address is printed. The assistant then sends you the four public addresses plus the throwaway margin deployer address with the **scaled funding amounts**; you fund the wallets from your own wallet (section 4). Nothing is signed or broadcast by the assistant.

| Wallet | Droplet (+ volume) | Process | Holds | Funding (ratios of CAP; amounts in `avalanche-pilot-sizing-table.md`) |
|---|---|---|---|---|
| **Operator 1** (`op-1`) | `pilot-op1` (`pilot-op1-data`) | `main.js run` with `executor.enabled` | USDC inventory + AVAX gas | **0.89 x CAP** USDC + gas |
| **Operator 2** (`op-2`) | `pilot-op2` (`pilot-op2-data`) | same | same | **0.89 x CAP** USDC + gas |
| **Treasury keeper** (`keeper`) | `pilot-keeper` (`pilot-keeper-data`) | `main.js run` with `keeper.enabled` | the protection USDC + gas | **0.24 x CAP** USDC + gas |
| **Rebalancer** (`rebalancer`) | `pilot-rebalancer` (`pilot-rebalancer-data`), **its own Droplet** | rebalancer module (`main.js rebalance`) | AVAX gas only, **no USDC** | AVAX only (section 0); becomes the `rebalancer()` of both vaults through a Safe transaction |
| **Throwaway margin deployer** | no Droplet of its own: keystore generated on the keeper Droplet, files under `/mnt/pilot_keeper_data/deployer/` | the margin stage-1 deployment, run by you | AVAX gas only | **0.12 AVAX** (`avalanche-margin-ceremony.md` section 1); the leftover goes back to you |

**Sizing: one number.** The whole pilot is sized by **CAP** (USD), the USDC borrow cap of the pilot; everything is linear in it, with the same contracts and the same PW30 parameters. **CAP is not yet known:** you send the exact balances, and the generated table is shown to you before anything is signed. Caps are raised later by a parameter change. The research size was CAP = 5,000 (the earlier fixed amounts 4,440 per operator and 1,191 for the keeper were that size and are replaced by the ratios). Generator: `contracts/tools/pilot-sizing.py --cap-usd N --avax-usd P [--write]`; `--write` writes `contracts/ceremony/pilot-pw30.env`, `contracts/ceremony/margin-sizing.env`, `contracts/ceremony/pilot-sizing.json` and `docs/deployment-handoffs/avalanche-pilot-sizing-table.md` (the table is generated, not yet written). The ratios:

| Item | Ratio of CAP (value at CAP = 5,000) |
|---|---|
| team supply (USDC) | 1.25 x CAP (6,250) |
| each operator inventory | 0.89 x CAP (4,450) |
| treasury keeper | 0.24 x CAP (1,200) |
| flash vault seed (margin) | 0.5 x CAP (2,500); must be at least CAP/2 |
| insurance fund seed (margin) | 5% of CAP (250) |
| per-call liquidation cap (operator) | 0.3 x CAP (1,500) |
| daily liquidation cap, per operator | 0.5 x CAP (2,500) |
| margin position cap / margin debt cap | CAP / CAP/2 (5,000 / 2,500) |
| vault deposit caps | CAP in USDC; CAP in WAVAX value |
| team lending-borrow rule (while margin is open) | at most 0.4 x CAP (2,000) |
| lending market seeds | 2% of CAP per asset, minimum USD 10 |
| vault team seeds | 5% of CAP per vault, minimum USD 10 |
| cash floor | 20% of supply |

The values in parentheses are products of the ratios with the research size; the figures that were fixed in the earlier text (4,440, 1,191, 3,750) were targets of the same order, and the exact numbers for the real CAP come from the table.

Rules: the Ledger is **not** an operator; none of the wallets has any admin right on any contract; four Droplets, four different passwords; the keeper Droplet also holds the throwaway deployer's keystore files (section 2), a different file with its own password from the keeper's; the password never appears in a chat, a file in the repository, a command line or a log.

## 0. Gas amounts (proposal, you decide)
Gas per liquidation round is about USD 0.01 at 2.5 gwei. Proposal: **2 AVAX per operator, 1 AVAX for the keeper, 1 AVAX for the rebalancer**; the monitor warns below 0.5 AVAX (`minGasWei`). The throwaway deployer is separate: 0.12 AVAX (measured gas times 1.5, margin ceremony section 1). The amounts to send are in the sizing table; the AVAX figures there are computed from the AVAX price passed to the generator (`--avax-usd`).

## 1. The four Droplets (created by the assistant with `doctl`; nothing created yet)
1. **Create**: `operator/deploy/provision-droplets.sh` (dry run by default: it prints what it would do and creates nothing; **`--go` creates**, which costs money: four small Droplets and four 1 GiB volumes). Region `fra1`, size `s-1vcpu-1gb`, Ubuntu 24.04 LTS with Docker installed through `operator/deploy/cloud-init.yaml`, SSH key only, no password login, backups off (a snapshot copies the encrypted keystore). A DigitalOcean firewall admits **SSH from one address only** (yours) and nothing else inbound. Each Droplet gets one 1 GiB ext4 volume, mounted by DigitalOcean at `/mnt/pilot_<role>_data` (`op1`, `op2`, `keeper`, `rebalancer`).
2. **Bootstrap** (one command per Droplet): `operator/deploy/bootstrap-droplet.sh <role> <ip>`. It ships the operator sources, **builds the image on the Droplet** (the production image compiles `src` only, `tsconfig.build.json`; the same image runs all four roles, the role is the configuration), and generates the keystore (section 2). It has not been run: **the first build on a Droplet is the test of the Dockerfile and of the script.**
3. **Harden** (part of cloud-init and the firewall; check after the first login): `ufw default deny incoming`, `ufw allow from <your IP> to any port 22`; `unattended-upgrades`, `fail2ban`; `PermitRootLogin` and `PasswordAuthentication` per the cloud-init file (to be confirmed after the first run: the bootstrap script connects as root, so root login must stay key-only while it runs). The Droplet exposes no port other than SSH: the processes only make **outbound** calls (the RPC endpoints, the alert channel).

## 2. Keystore (generated ON the Droplet, on the volume)
1. `bootstrap-droplet.sh` generates a random password with `openssl` **on the Droplet**, writes it to `/etc/pilot/<role>.env` (owner root, mode 600) as `OPERATOR_KEYSTORE_PASSWORD` (op1, op2), `KEEPER_KEYSTORE_PASSWORD` (keeper) or `REBALANCER_KEYSTORE_PASSWORD` (rebalancer), and creates the encrypted keystore `/mnt/pilot_<role>_data/keystore/<role>.json` (mode 600, directory 700) in a throwaway container. **Only the public address is printed** (and saved in `address.txt` on the volume). The password is not an argument, not in the image, not in the repository and not sent to the assistant or to you. If the keystore exists, the script generates nothing and prints the stored address.
2. The image's process runs as uid 1000; it refuses a keystore that is readable by other users. If the volume ownership needs a change: `sudo chown -R 1000:1000 /mnt/pilot_<role>_data && sudo chmod 700 /mnt/pilot_<role>_data/keystore && sudo chmod 600 /mnt/pilot_<role>_data/keystore/*` (to be confirmed against the first run).
3. **Throwaway margin deployer:** generated the same way on the keeper Droplet; files under `/mnt/pilot_keeper_data/deployer/`. You retrieve them with `scp` when you run stage 1 (`avalanche-margin-ceremony.md`), use them once, and delete the files and the leftover AVAX goes back to you. It holds no role at any time.
4. **Read-back** (the address must be the printed one): `docker run --rm -it -v /mnt/pilot_<role>_data:/data ghcr.io/foundry-rs/foundry cast wallet address --keystore /data/keystore/<role>.json` (asks for the password, which is in `/etc/pilot/<role>.env` on the Droplet; read it there only). The assistant sends you the public addresses.
5. **Backup:** the encrypted file and the password exist only on the Droplet and its volume. Losing the Droplet and the volume loses the wallet; what the wallet holds is bounded (section 5). Keep an offline copy of the encrypted file and of the password only if you want one; if you do, it is a decision of yours and you retrieve them over SSH yourself.

## 3. Endpoints, password and start-up
**Two endpoints.** *No Alchemy pay-as-you-go.* A throwaway free-tier Alchemy app is the **state** endpoint: `AVALANCHE_MAINNET_RPC_URL` (deleted after a few days). **Log reads go to a separate endpoint,** `AVALANCHE_LOGS_RPC_URL`, default the Avalanche public RPC `https://api.avax.network/ext/bc/C/rpc` (its `eth_getLogs` range is 2,048 blocks); it needs no key, so it can stay unset. Built behaviour (configuration block `monitor.logs`: `chunkBlocks` 2048, `maxChunksPerCycle` 40, `behindWarnBlocks` 600, `behindCritBlocks` 3900):
- the log scan is **resumable and bounded**: the cursor advances after every chunk and a failing endpoint never throws;
- the start-up log probe is **not fatal**: a failing probe raises a warning alert `logs:probe`, the process runs, and the borrower index catches up; the finding `index:behind` is a warning at 600 blocks and critical at 3,900;
- the snapshot block is chosen **after** the log scan, so it is fresh; the daily full re-scan runs after the keeper and executor steps, never throws, and retries in 24 h;
- the keeper's 24 h spend scan uses the log endpoint with a 0.8 s per block lookback (about 108,000 blocks, 53 requests);
- the executor re-reads its snapshot after the conversion step; transaction waits time out after 180 s and the executor then halts with its pending marker.

**Nothing live depends on archive state:** non-archive nodes serve state for about the last 128 blocks, and every live state read is at the latest block or within seconds of it. Fork rehearsals and the offline `compute-min-pool-liquidity` script **do** need an archive endpoint; they are not part of the live setup.

The password is read by the process from an environment variable (names in section 2). The state endpoint URL contains a key; it goes in the same env file. How the URL reaches `/etc/pilot/<role>.env` without passing through a chat or a command line is **to be confirmed** (the bootstrap script writes the password only). Two ways of starting, with their cost:
- **A. Env file (restarts by itself, recommended).** `/etc/pilot/<role>.env`, owner root, mode 600, containing the password variable, `AVALANCHE_MAINNET_RPC_URL=...` (and `OPERATOR_ALERT_*` when the alert channel needs them; `AVALANCHE_LOGS_RPC_URL` only to override the default). Docker reads it with `--env-file`; it is not in the image, not in the volume, not in the repository. **A root compromise of the Droplet gives the attacker the keystore and the password together**; that is the accepted risk of automatic restart. Mitigations: no inbound ports except SSH from one IP, key-only, nothing else installed, small balances, the monitor's `treasury:unexplained-outflow` tripwire.
- **B. Typed at start (stronger, no automatic restart).** `docker run -it` and type the password; a reboot or crash needs you. It conflicts with the generated password, which you do not know: use it only after you have read the password on the Droplet.

systemd unit (`/etc/systemd/system/pilot.service`), same for the operators and the keeper:
```
[Unit]  Description=pilot operator process   After=docker.service  Requires=docker.service
[Service]  Restart=always  RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f pilot
ExecStart=/usr/bin/docker run --name pilot --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  --env-file /etc/pilot/<role>.env -e KEYSTORE_PATH=/data/keystore/<role>.json -e OPERATOR_CONFIG=/data/config/host.json \
  -v /mnt/pilot_<role>_data:/data pilot-operator:<sha> run
ExecStop=/usr/bin/docker stop pilot
[Install]  WantedBy=multi-user.target
```
**The rebalancer module (R3 upgrade; its own Droplet `pilot-rebalancer`, no longer the keeper's).** Same unit shape and image; container name `pilot-rebalancer`; `--env-file /etc/pilot/rebalancer.env` containing `REBALANCER_KEYSTORE_PASSWORD=...` and `AVALANCHE_MAINNET_RPC_URL=...`; `-e KEYSTORE_PATH=/data/keystore/rebalancer.json -e OPERATOR_CONFIG=/data/config/rebalancer.json`; the argument at the end of the command is **`rebalance`** instead of `run`. `rebalancer.json` has `rebalancer.enabled: true`, `keeper.enabled: false` (the configuration refuses a process that is both), and its own `monitor.statePath` (`/data/state/rebalancer.json`; the module keeps its halt flag, pending marker and action log in `/data/state/rebalancer-rebalancer.json`). The wallet needs AVAX and **no USDC**; give it AVAX **before** the Safe rotates the vaults' `rebalancer()` to it (`avalanche-pilot-r3-upgrade.md` section 5, step 3). Read-back that it is alive: the container log prints one JSON line per poll (`{"rebalancer":{"done":[],"skipped":["USDC vault: in range, nothing idle", ...],"halted":false}}`).

`host.json` lives on the volume (`/data/config/host.json`; public data only; the assistant provides it per role once the addresses exist); `monitor.statePath` is `/data/state/state.json` on the **volume**, so halt flags, pending markers, the confirmation counters, cooldowns and the keeper ledger **survive restarts and redeploys** (the reason for Droplets with volumes). The keeper's daily cap is in addition computed from the chain's own repayment events.

## 4. Funding checklist (you execute from your own wallet; the assistant signs nothing)
The assistant sends the four public addresses and the deployer address with the amounts from `avalanche-pilot-sizing-table.md`; the table is shown to you first and you confirm CAP. Order: AVAX gas first, then USDC. For each wallet:
1. AVAX to the address. Read-back: `cast balance <address> -e` (with `ETH_RPC_URL` set in the environment, not as an argument).
2. USDC (native `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`): **0.89 x CAP to each operator, 0.24 x CAP to the keeper** (the exact figures are in the table). Read-back: `cast call 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E 'balanceOf(address)(uint256)' <address>` (6 decimals: 1,000 USDC = 1000000000).
3. **Do not send USDC to a wallet before its address is confirmed.** A typo loses the funds. The rebalancer and the throwaway deployer get AVAX only.
4. Only the protection capital goes to the keeper: its balance is the limit of what a compromised Droplet can lose. Top-ups come from the cold reserve (the Safe).

## 5. After the process starts; what each wallet can lose; compromise
- `docker logs pilot` shows one JSON report per cycle (secrets masked); `docker exec pilot node dist/src/main.js check` prints the full report. Healthy: no `inventory:`/`gas:`/`treasury:capital`/`drift:` finding, `monitor:blind` absent, `reference` ok; an `index:behind` or `logs:probe` finding is expected only while the borrower index catches up after a start (section 3). The process refuses to start (exit 78, reason, no secret) if the password is wrong, the signer address differs from the configured one, the state RPC is missing, or the configuration holds a placeholder; a failing log endpoint at start is a warning, not a refusal.
- Operators: their inventory (0.89 x CAP each). Keeper: 0.24 x CAP; its daily cap is software and does not bind an attacker with the key and the password (the cap value for the real CAP is in the table, to be confirmed). Rebalancer: gas only, but it holds a role on both vaults (what that role can do is analysed with the R3 work, section "rebalancer module" there). **Each wallet is on its own Droplet: a compromise of one Droplet exposes one wallet** (the keeper Droplet also holds the throwaway deployer's keystore files until they are deleted; that key holds no role and only its gas AVAX).
- If a Droplet or a password is exposed: pause borrowing and minting from the Ledger (runbook in `avalanche-cash-only-deployment-rehearsal.md`), move the funds out with the keystore on a clean machine, generate a new keystore on a new Droplet, update the configuration. A wallet is replaced; nothing on chain changes (the operator and keeper roles are not on chain; the rebalancer role is, and rotates with one Safe transaction).

## 6. Margin 2x: what changes for the two operator wallets (built 8 Nov; enabled with stage 4, after stage 3 and the operators running with the margin block)
**One new on-chain thing:** the Ledger puts each operator wallet on the margin stack's **funded-liquidator allowlist** (`fundedLiquidators`, queued at stage 2, executed at least 24 h later at stage 3). It is not an admin right: it only lets the wallet call `liquidateFunded`, which repays a position's debt from the wallet's own USDC and pays the wallet the seized collateral (bonus at most 5%). It adds no loss beyond the wallet's own balance. The Ledger removes it at any time (`config.removeFundedLiquidator`).

**What the process does (the margin step; the same process, wallet and keystore as the lending executor, no new host):**
- Every cycle, before the lending accounts: read the margin positions (`executor.nextPositionId` and `positions(i)`: no `eth_getLogs`), take those the risk engine says are below maintenance, and liquidate one through `liquidateFunded` with `recipient` = the wallet and `minSeizeValueBps` **fixed at 10,000** (break-even).
- **Insolvent positions are declined** (collateral below the debt): nothing is sent, a critical alert goes to the treasury signers, the debt stays in the pUSDC market (decision D3).
- **The allowance is bounded, not exact** (the risk engine, not the wallet, decides the repayment): `min(USDC inventory, daily-cap remaining, per-call cap, debt)`, reset to 0 after every call; the contract itself refuses a larger repayment. Pilot caps, as ratios of CAP: **per call 0.3 x CAP (1,500 USDC at CAP = 5,000), per rolling 24 h per operator 0.5 x CAP (2,500)**; the whole margin debt is capped at CAP/2 (2,500), so these bind only on a bug. Raising either is a deliberate configuration change.
- Afterwards the seized pWAVAX is redeemed and sold by the **existing** conversion (Uniswap 0.05% pool, revert-protected minimum from the oracle, no fallback route). A blocked conversion alerts and leaves the WAVAX in the wallet, as for lending.
- A step interrupted between transactions leaves a `margin` pending marker: the executor **halts** at the next start until a human clears it (the same rule as lending).
- The lending executor now **skips margin accounts** (the controller refuses `liquidateBorrow` for them; trying would cost an approve and a reset every cycle). The monitor removes them from the lending verdicts, the treasury figures and the keeper's input, and reports them in `margin.positions`.

**Configuration (public values, `host.json`).** The template block `margin` ships with `enabled: false`. After stage 3, the assistant fills `executor`, `liquidator`, `riskEngine`, `config` from `ceremony/margin-addresses.env` and sets `margin.enabled: true`; `margin.liquidation.enabled: true` only on the operator hosts (the keeper and rebalancer processes keep it false). Both operators run the **same** numbers, taken from `contracts/ceremony/margin-sizing.env` (the same CAP).

**Inventory.** The margin step uses the same USDC as lending; the monitor's existing check (inventory below 0.75 x aggregate pUSDC debt) already counts the margin debt, so an operator that cannot fund a partial liquidation of every open position is flagged `inventory:` before it matters. The operator inventory floor is 0.75 x CAP (3,750 at CAP = 5,000; the target is 0.89 x CAP) and covers the largest single repayment, about 0.25 x CAP (1,250), which is the 50% close factor applied to the margin debt cap CAP/2.

**Start order:** stage 3 passed (`verify`), both operators running the new image with the margin block enabled, `check` shows `margin.classified` equal to the number of positions and no `margin:not-funder` finding, **then** stage 4 (unpause opens). No calendar dependency.
