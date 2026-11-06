# Avalanche cash-only pilot: setup of the three hot wallets and their hosts (build step 4)

Status: **DRAFT checklist for the operator to RUN.** Nothing here was run by the assistant; no key exists in the repository or in the assistant's session. You create three Foundry keystores, put each password in its host's secret store, fund the wallets, and **send back only the three public addresses.** After that the assistant fills the three host configurations (`operator/config/`), and the deployment ceremony document refers to them.

| Wallet | Host | Process | Holds | Funding (fixed by the pilot decisions) |
|---|---|---|---|---|
| **Operator 1** (`op-1`) | your machine **or** a separate DigitalOcean app | `main.js run` with `executor.enabled` | USDC inventory + AVAX gas | **4,440 USDC** (target; the floor is 3,750) + gas |
| **Operator 2** (`op-2`) | the existing DigitalOcean app | same | same | **4,440 USDC** + gas |
| **Treasury keeper** (`keeper`) | a **dedicated** DigitalOcean app (not operator 2's) | `main.js run` with `keeper.enabled` | the protection USDC + gas | **1,191 USDC** + gas |

Rules that hold for all three: the Ledger is **not** an operator; none of the three has any admin right on any contract (the operators call the permissionless `liquidateBorrow`, the keeper calls `repayBorrowBehalf`); three keystores, three hosts, three different passwords; never two of the three on one host; the password never appears in a chat, a file, a command line or a log.

## 0. Gas amounts (proposal, you decide)
Gas per liquidation round is about USD 0.01 at 2.5 gwei (cycle document 3). Proposal: **2 AVAX per operator, 1 AVAX for the keeper**; the monitor warns below 0.5 AVAX (`minGasWei`). At those prices a wallet can run hundreds of rounds before it needs a refill.

## 1. Per wallet (repeat three times, on the machine that will keep the file, or on a clean machine and move it)
1. **Create the keystore** (Foundry 1.x; the password is asked for interactively and hidden, so it does not enter shell history):
   `cast wallet new ~/pilot-keystores op-1` (then `op-2`, `keeper`). It prints the address and writes the encrypted JSON `~/pilot-keystores/op-1`. Use a long random password (for example from your password manager, 32+ characters).
2. **Read-back** (the address must be the one printed): `cast wallet address --keystore ~/pilot-keystores/op-1` (asks for the password). Write down the address (public). Check the file mode: `chmod 600 ~/pilot-keystores/*`.
3. **Back up the encrypted file and the password separately** (a password manager entry for the password; the file in a second place). Losing either means losing the wallet; the funds in it are bounded (see section 5), so a lost wallet is an inconvenience, not a catastrophe.
4. **Send me the public address.** Nothing else.

## 2. Host: DigitalOcean App Platform (one worker component per wallet; `operator/Dockerfile`)
The image is built from `operator/` (`Dockerfile`; **not built or run by the assistant: no Docker in its environment, so the first build is a test of the file**). Environment of the component, all marked ENCRYPTED/secret in the app spec:
- `AVALANCHE_MAINNET_RPC_URL` the private endpoint (never in the repository).
- `KEYSTORE_JSON_B64` the encrypted keystore file, base64: `base64 < ~/pilot-keystores/op-1 | tr -d '\n'`. The container writes it to `/run/secrets/keystore.json` with mode 600 at start (`scripts/entrypoint.sh`). It is encrypted, but treat it as a secret anyway.
- `KEYSTORE_PATH=/run/secrets/keystore.json`.
- The password: `OPERATOR_KEYSTORE_PASSWORD` (operators) or `KEEPER_KEYSTORE_PASSWORD` (keeper), **encrypted environment variable**, entered in the DigitalOcean console.
- `OPERATOR_CONFIG=/app/config/host.json` (the assistant provides the file for each role once the addresses are known; it contains only public data) and the alert variables of the chosen channel (none for the `log` channel).
**Persistent state is a real issue on App Platform: its filesystem is ephemeral.** Everything the processes keep in `state/` (borrower index cursor, alert state, keeper payment ledger, halt flags, pending markers, cooldowns) is lost on every restart or redeploy. What this costs and what has been done about it:
- the **keeper's daily spend cap** no longer depends on the file: it is computed from the chain's own `RepayBorrow` events of the keeper wallet (tested: a lost ledger does not unblock the cap);
- the borrower index is rebuilt from the deployment block (slower first cycle, same result);
- a **standing allowance** from an interrupted payment is detected on chain before the next payment and halts the keeper (tested);
- **lost for good on a restart:** a `halted` flag, a `pending` marker, the 2-evaluation confirmation counter (it simply starts over, which only delays a payment), cooldowns. A restart after a halt therefore "forgets" the halt, but the next payment still re-verifies everything and refuses on a standing allowance.
**Recommendation: for the keeper, use a DigitalOcean Droplet with a Block Storage volume mounted at `/data` instead of App Platform** (persistent halt flags; the same image, `docker run -v /data:/data`, and `monitor.statePath` set to `/data/state.json`); the operators can stay on App Platform. You asked for an app, so the steps above are the default; say if you want the Droplet.

## 3. Funding checklist (you execute from your own funding wallet; the assistant signs nothing)
Order: AVAX gas first, then USDC. For each of the three wallets:
1. Send the AVAX gas amount to the address. Read-back: `cast balance <address> --rpc-url $AVALANCHE_MAINNET_RPC_URL -e` (shows AVAX).
2. Send USDC (native USDC `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E`): 4,440 to each operator, 1,191 to the keeper. Read-back: `cast call 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E 'balanceOf(address)(uint256)' <address> --rpc-url $AVALANCHE_MAINNET_RPC_URL` (units of 1e-6; 4,440 USDC = 4440000000).
3. **Do not send USDC to a wallet before its address is confirmed by the read-back of section 1 step 2.** A typo in an address loses the funds.
4. The keeper's USDC comes from the cold reserve (the Safe) in the live design; for the pilot you may fund it from any wallet you control. Only the protection capital goes there: the keeper's balance is the limit of what a compromised host can lose.

## 4. After the process starts (read-backs)
- `docker logs` / the app's runtime logs show one JSON report per cycle (secrets are masked). `node dist/src/main.js check` (run once in a console) prints the full report and exits 0 when no finding is critical.
- Expected on a healthy start: no `inventory:` or `gas:` finding, no `treasury:capital` finding, `reference` ok, no `drift:` finding, `monitor:blind` absent.
- The process refuses to start (exit 78, reason printed, no secret) if the keystore password is wrong, the signer address differs from the configured one, the RPC is missing or the configuration still has a placeholder.

## 5. What each wallet can lose, and what to do if a host is compromised
- Operator wallets: their USDC and WAVAX inventory (4,440 USDC each at most); they have no right on any contract. Keeper: its USDC (1,191 at most); the daily cap (1,500) is software and does not bind an attacker with the key and the password. The monitor raises `treasury:unexplained-outflow` (critical) if the keeper's USDC leaves without a recorded payment.
- If a host or a password is exposed: pause borrowing and minting from the Ledger (runbook in `avalanche-cash-only-deployment-rehearsal.md`), move the remaining funds out with the keystore on a clean machine, create a new keystore, update the config. A wallet is replaced; nothing on chain needs to change (the roles are not on chain).
