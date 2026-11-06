# Avalanche cash-only pilot: setup of the hot wallets and their hosts (build step 4)

Status: **DRAFT checklist for the operator to RUN.** Nothing here was run by the assistant; no key exists in the repository or in the assistant's session. Decision of 2026-11-06: **three DigitalOcean Droplets, each with its own volume, one Docker image, the keystore on the volume. App Platform is not used for anything that holds a key.** You create the keystores, put each password where section 3 says, fund the wallets, and **send back only the public addresses** (three now, a fourth for the rebalancer module on 15 Nov). The assistant then fills the host configurations (`operator/config/`).

| Wallet | Droplet (+ volume) | Process | Holds | Funding |
|---|---|---|---|---|
| **Operator 1** (`op-1`) | Droplet `pilot-op1` | `main.js run` with `executor.enabled` | USDC inventory + AVAX gas | **4,440 USDC** (target; floor 3,750) + gas |
| **Operator 2** (`op-2`) | Droplet `pilot-op2` | same | same | **4,440 USDC** + gas |
| **Treasury keeper** (`keeper`) | Droplet `pilot-keeper` | `main.js run` with `keeper.enabled` | the protection USDC + gas | **1,191 USDC** + gas |
| **Rebalancer** (`rebalancer`, from 15 Nov) | the keeper Droplet, **separate keystore** | rebalancer module (built with R3, not yet) | AVAX gas only, **no USDC** | ~1 AVAX; becomes the `rebalancer()` of both vaults through a Safe transaction |

Rules: the Ledger is **not** an operator; none of the wallets has any admin right on any contract; three Droplets, three different passwords; two keystores on one Droplet (keeper + rebalancer) is a decision of yours, noted in section 5; the password never appears in a chat, a file in the repository, a command line or a log.

## 0. Gas amounts (proposal, you decide)
Gas per liquidation round is about USD 0.01 at 2.5 gwei. Proposal: **2 AVAX per operator, 1 AVAX for the keeper, 1 AVAX for the rebalancer**; the monitor warns below 0.5 AVAX (`minGasWei`).

## 1. Droplet (repeat three times)
1. **Create**: Ubuntu 24.04 LTS, the smallest size (1 vCPU / 1 GB is enough; the processes are idle most of the time), a region of your choice, **SSH key only**, no password login, backups off (a snapshot copies the encrypted keystore; keep it that way only if you want that). Attach a **Block Storage volume** (1 GB is plenty), format ext4, mount at `/mnt/pilot_data`, add it to `/etc/fstab`.
2. **Harden before anything else**: `ufw default deny incoming`, `ufw allow from <your IP> to any port 22`, `ufw enable`; `apt install unattended-upgrades fail2ban`; a non-root user in the `docker` group; `PermitRootLogin no`, `PasswordAuthentication no` in `sshd_config`. The Droplet runs nothing else and exposes no port other than SSH: the processes only make **outbound** calls (the RPC endpoint, the alert channel).
3. **Install Docker** (`apt install docker.io`). Get the image onto the Droplet: build it on your machine (`cd operator && docker build -t pilot-operator:<git sha> .`) and `docker save pilot-operator:<sha> | ssh pilot-xxx docker load` (or a private DigitalOcean registry). The same image runs all three roles; the role is the configuration. **The Dockerfile has not been built by the assistant (no Docker in its environment): the first build is the test of the file.**

## 2. Keystore (on the Droplet, on the volume)
1. Create it **on the Droplet** so the key never travels: `docker run --rm -it -v /mnt/pilot_data:/data ghcr.io/foundry-rs/foundry cast wallet new /data/keystore keeper` (the official Foundry image; pin the tag you trust) (name `op-1`, `op-2`, `keeper`, later `rebalancer`). It asks for a password (hidden), prints the address and writes the encrypted JSON `/data/keystore/<name>`. Use a long random password from your password manager (32+ characters).
2. The image's process runs as uid 1000: `sudo chown -R 1000:1000 /mnt/pilot_data && sudo chmod 700 /mnt/pilot_data/keystore && sudo chmod 600 /mnt/pilot_data/keystore/*`. The process refuses a keystore that is readable by other users.
3. **Read-back** (the address must be the printed one): `docker run --rm -it -v /mnt/pilot_data:/data ghcr.io/foundry-rs/foundry cast wallet address --keystore /data/keystore/<name>` (asks for the password). **Send me the public address.**
4. **Back up** the encrypted file (offline copy) and the password (password manager) separately. Losing either loses the wallet; what the wallet holds is bounded (section 5).

## 3. Password and start-up
The password is read by the process from an environment variable (`KEEPER_KEYSTORE_PASSWORD` or `OPERATOR_KEYSTORE_PASSWORD`; for the fourth keystore the module will name its own). Two ways, with their cost:
- **A. Env file (restarts by itself, recommended for the keeper and operators).** `/etc/pilot/<role>.env`, owner root, mode 600, containing `KEEPER_KEYSTORE_PASSWORD=...` and `AVALANCHE_MAINNET_RPC_URL=...` (and `OPERATOR_ALERT_*` when the alert channel needs them). Docker reads it with `--env-file`; it is not in the image, not in the volume, not in the repository. **A root compromise of the Droplet gives the attacker the keystore and the password together**; that is the accepted risk of automatic restart. Mitigations: no inbound ports, SSH from one IP, key-only, nothing else installed, small balances, the monitor's `treasury:unexplained-outflow` tripwire.
- **B. Typed at start (stronger, no automatic restart).** `docker run -it` and type the password; a reboot or crash needs you. Use it if you prefer security over availability.
systemd unit (`/etc/systemd/system/pilot.service`), same for all roles:
```
[Unit]  Description=pilot operator process   After=docker.service  Requires=docker.service
[Service]  Restart=always  RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f pilot
ExecStart=/usr/bin/docker run --name pilot --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges \
  --env-file /etc/pilot/<role>.env -e KEYSTORE_PATH=/data/keystore/<name> -e OPERATOR_CONFIG=/data/config/host.json \
  -v /mnt/pilot_data:/data pilot-operator:<sha> run
ExecStop=/usr/bin/docker stop pilot
[Install]  WantedBy=multi-user.target
```
**The rebalancer module (from the R3 upgrade, 15 Nov; keeper Droplet).** A second systemd unit on the keeper Droplet (`pilot-rebalancer.service`), same image, **its own config, env file, keystore and state**: container name `pilot-rebalancer`; `--env-file /etc/pilot/rebalancer.env` containing `REBALANCER_KEYSTORE_PASSWORD=...` and `AVALANCHE_MAINNET_RPC_URL=...` (a different password from the keeper's); `-e KEYSTORE_PATH=/data/keystore/rebalancer -e OPERATOR_CONFIG=/data/config/rebalancer.json`; the argument at the end of the command is **`rebalance`** instead of `run`. `rebalancer.json` has `rebalancer.enabled: true`, `keeper.enabled: false` (the configuration refuses a process that is both), and its own `monitor.statePath` (`/data/state/rebalancer.json`; the module keeps its halt flag, pending marker and action log in `/data/state/rebalancer-rebalancer.json`). The wallet needs about 1 AVAX and **no USDC**; give it AVAX **before** the Safe rotates the vaults' `rebalancer()` to it (`avalanche-pilot-r3-upgrade.md` section 5, step 3). Read-back that it is alive: the container log prints one JSON line per poll (`{"rebalancer":{"done":[],"skipped":["USDC vault: in range, nothing idle", ...],"halted":false}}`).

`host.json` lives on the volume (`/data/config/host.json`; public data only; I provide it per role once I have the addresses); `monitor.statePath` is `/data/state/state.json` on the **volume**, so halt flags, pending markers, the confirmation counters, cooldowns and the keeper ledger **survive restarts and redeploys** (the reason for Droplets). The keeper's daily cap is in addition computed from the chain's own repayment events.

## 4. Funding checklist (you execute from your own wallet; the assistant signs nothing)
Order: AVAX gas first, then USDC. For each wallet:
1. AVAX to the address. Read-back: `cast balance <address> -e` (with `ETH_RPC_URL` set in the environment, not as an argument).
2. USDC (native `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`): 4,440 to each operator, 1,191 to the keeper. Read-back: `cast call 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E 'balanceOf(address)(uint256)' <address>` (4,440 USDC = 4440000000).
3. **Do not send USDC to a wallet before its address is confirmed by the read-back of section 2.3.** A typo loses the funds. The rebalancer wallet gets AVAX only.
4. Only the protection capital goes to the keeper: its balance is the limit of what a compromised Droplet can lose. Top-ups come from the cold reserve (the Safe).

## 5. After the process starts; what each wallet can lose; compromise
- `docker logs pilot` shows one JSON report per cycle (secrets masked); `docker exec pilot node dist/src/main.js check` prints the full report. Healthy: no `inventory:`/`gas:`/`treasury:capital`/`drift:` finding, `monitor:blind` absent, `reference` ok. The process refuses to start (exit 78, reason, no secret) if the password is wrong, the signer address differs from the configured one, the RPC is missing or does not allow `eth_getLogs` over `logChunkBlocks`, or the configuration holds a placeholder.
- Operators: their inventory (4,440 USDC each). Keeper: 1,191 USDC; the cap (1,500/day) is software and does not bind an attacker with the key and the password. Rebalancer: gas only, but it holds a role on both vaults (what that role can do is analysed with the R3 work, section "rebalancer module" there). **Keeper and rebalancer keystores on one Droplet: a compromise of that Droplet exposes both.**
- If a Droplet or a password is exposed: pause borrowing and minting from the Ledger (runbook in `avalanche-cash-only-deployment-rehearsal.md`), move the funds out with the keystore on a clean machine, create a new keystore, update the configuration. A wallet is replaced; nothing on chain changes (the operator and keeper roles are not on chain; the rebalancer role is, and rotates with one Safe transaction).
