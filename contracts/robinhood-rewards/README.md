# Robinhood Chain: RAM rewards of the Ramses SPY/USDG vault to depositors (design A port)

Status: **built, tested offline, rehearsed on an anvil fork. NOT deployed. Nothing was signed or sent to mainnet.**
Ceremony list: [`COMMANDS.md`](COMMANDS.md). Operator approval: 2026-11-16.

This is a port of the Avalanche design A distributor (`contracts/vault-dlmm/src/rewards/PharRewardsDistributor.sol`, branch
`feat/dlmm-rewards-distributor`, commits 3b74e668..6ee4c310). The design is kept:
- a 24 h challenge window in which the owner can cancel;
- claims by Merkle proof, which anyone may submit for the account in the leaf;
- a 180-day claim deadline, then a sweep;
- no pause, so nothing can block claims;
- a per-epoch `--user-bps` (default 9000) that is a generator argument and not an on-chain constant.

The vault is not touched.

## 1. Flow

```
keeper 0x9eaF..031E: vault.harvest(pair)  -> RAM stays in the vault: externalRewards[pair][RAM]   (event ExternalRewardHeld)
off chain, anyone:  tools/robinhood-ram-root.mjs  -> epoch.json (holders, weights, exclusions, leaves + proofs), manifest.json
Ledger -> timelock 0x6797..2498: schedule  vault.forwardExternalReward(pair, RAM, DIST, heldSum)   (1 h delay, public)
Ledger -> timelock:              execute   -> RAM moves vault -> distributor (unallocated)
Ledger: DIST.publishEpoch(root, total, fromBlock, toBlock, dataHash)  -> reserves `total` of the unallocated RAM
  24 h: Ledger may cancelEpoch (the RAM is released to unallocated, and a corrected root can be republished without a new forward)
claims: DIST.claim(epochId, account, amount, proof)   (anyone submits; RAM always goes to `account`)
  180 days after publication: Ledger may sweepUnclaimed -> the rest is released to unallocated (only a NEW epoch can commit it)
```

## 2. The one deliberate change: funding

The Avalanche contract pulled `total` from the owner (`transferFrom`). On Robinhood, RAM can leave the vault only through
`RamsesBoostedVault.forwardExternalReward(pair, token, receiver, amount)`, which is `onlyRole(CONFIG_ROLE)`. That role is
held by the timelock. Forwarding to the Ledger and then running approve + publish would cost one more signature, and the
RAM would sit on the Ledger in between. So the timelock forwards **straight to the distributor**, and:

- `publishEpoch` commits `total` out of `unallocated() = balance - reserved` and reverts with `InsufficientUnallocated`
  when that is not enough. It pulls nothing.
- `cancelEpoch` (inside the window) and `sweepUnclaimed` (after the deadline) **release** the epoch's open amount back to
  unallocated. Neither transfers anything.
- **Tokens leave the contract only through `claim`.** There is no refund, rescue or withdrawal. The protocol's share
  (10 %, the excluded holders' slices, rounding and dust) is an ordinary leaf for the protocol recipient, so the published
  total equals the forwarded amount exactly. Nothing is stranded, and RAM sent directly is not lost.
- Avalanche checked `toBlock <= block.number`. That check is **removed**, because on Robinhood Chain (Arbitrum Orbit)
  `block.number` is the L1-derived number (about 26M) while the epoch range is in L2 heights (about 116M). Anvil's
  `block.number` is the L2 height, so a fork rehearsal would NOT have caught this. Unit test:
  `test_l2BlockRangeAboveTheEvmBlockNumberIsAccepted`. Mutant M07 re-adds the check and is killed.
- Rejected alternative: forward to the Ledger, then approve + publish. That is 4 Ledger signatures instead of 3, and RAM
  custody on an EOA.

Contract: `src/MerkleRewardsDistributor.sol`. It is token-agnostic (`REWARD_TOKEN` immutable) and chain-agnostic (no
chainid, no block-number check). It uses solc 0.8.26, EVM cancun, via-IR, optimizer 200 and OpenZeppelin 5.3.0
(`Ownable2Step`, `ReentrancyGuard`, `SafeERC20`, `MerkleProof`). Leaf =
`keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))))`, which is unchanged.

## 3. Decisions

### (1) Owner and publisher: the Ledger directly (recommended, implemented)

The Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` is the owner, set by the deploy script. The script refuses the old
signer and refuses the Ledger as deployer.

Why the Ledger and not the timelock:
- **Funding already goes through the timelock.** The amount is public in the queued call one hour before it executes.
- **The 24 h challenge window is the root's safety.** A wrong root is cancelled inside it.
- **It matches the Avalanche role**, where the Safe (owned by the same Ledger) publishes.
- **It saves time and signatures.** A timelock publisher would add 2 signatures and an hour per epoch, and a cancel would
  need its own hour. That cancel would have to be scheduled before the window closes, which makes cancelling a
  timelock-published epoch fragile.

Ownership is two-step and cannot be renounced. A later move to a Safe or the timelock is
`transferOwnership` + `acceptOwnership`.

### (2) Entitlement across the two markets: market split by vault principal USD, then time-weighted shares

**The rule:**

```
For every RAM ExternalRewardHeld(pair, amount) in (start, end]:
    cp       = the latest PairCheckpoint(pair) before it (the harvest tx checkpoints first; same tx in all 16 live harvests)
    usdgUSD  = cp.usdgAccountedAssets * 1e12                 (the guard values USDG at exactly 1e18)
    stockUSD = cp.benchmarkUSDG + cp.pnlUSDG - usdgUSD       (= USD value of the post-checkpoint principals in all three
                                                              checkpoint branches: loss, gain, unchanged)
    toRpSPY  = floor(amount * stockUSD / (stockUSD + usdgUSD)),   toRpUSDGs = amount - toRpSPY
    (no checkpoint yet, or zero principal: the amount is "unattributed" and goes to the protocol leaf)
For each market m:  pool_m = floor(RAM_m * userBps / 10000)
    W_h  = integral over [ts(start), ts(end)] of h's pToken balance   (Transfer events; mint = market->h, redeem/seize = h->market)
    W    = integral of the market's pToken totalSupply = sum of all W_h (incl. 0xdEaD, the timelock and other excluded holders)
    amount_m(h) = floor(pool_m * W_h / W)
leaf(h) = amount_rpSPY(h) + amount_rpUSDGs(h)      (one leaf per account)
leaf(protocolRecipient) += heldSum + extra - sum of holder leaves
```

**Why this rule and not the alternative.** The public endpoint prunes state after about 10 minutes, but events are kept.
- The alternative (each holder weighted by `balance x exchangeRate x oracle price`, time-weighted) needs historical
  exchange rates and historical prices at every instant. Neither can be recovered after the fact, so nobody could
  re-derive a published root later.
- The chosen split needs only events:
  - `PairCheckpoint` carries the vault principal of both sides and their USD value, using the oracle price in the
    harvest transaction itself.
  - The time-weighting inside a market needs only `Transfer` events and block timestamps.
- It is also the economically right split. Both sides' principals scale together on a loss, so each side owns the
  LP (and its gauge RAM) in proportion to its principal USD.
- A pToken share is a pro-rata claim on everything the market owns. Time-weighting shares within a market therefore
  pays every share equally per second.

**Measured on mainnet (read-only, public endpoint, `tools/robinhood-ram-root.mjs --to-harvest last`):**
- epoch 0 = blocks (110177000, 115782882], 16 harvests = **96,799,596,213,810,175 wei RAM**, which equals
  `externalRewards[pair][RAM]` exactly;
- split: rpSPY 59,412,073,559,420,704 and rpUSDGs 37,387,522,654,389,471 (stock $7.90 vs USDG $5.00 of principal);
- only 0xdEaD and the timelock hold either market today, so the epoch has **one leaf**: everything goes to the Ledger.

Known limits:
- RAM is attributed by holding time inside the epoch, not by when the gauge accrued it.
- Market cash that is not deployed in the vault still shares its market's RAM.
- A transfer of pTokens moves the entitlement from that second.

### (3) Exclusions and the protocol recipient

Excluded holders' weight **stays in the denominator**, so excluding a holder never raises anyone else's amount. Their
slice goes to the protocol leaf and is listed per address with its reason in `epoch.json` `exclusions`.

| Address | Reason label |
| --- | --- |
| `0x000000000000000000000000000000000000dEaD` | `dead-seed` (1e8 raw shares in each market) |
| `0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498` | `timelock` (5e6 rpSPY and 4.99e10 rpUSDGs seed rest) |
| `0x67e7742922f4CC88C545e5aB5Df402b22DB4830b` | `vault` |
| `0x1E8eAE33d7c2Fc5E8061476099bE2b9E930DA2CC` | `vault-router` |
| `0x128eF69e4D697291BA88F45544f49B85Ac6ac1a7` | `in-kind-redeemer` |
| `0x92740aEC3ac91AEC3b964b04233e005FCDd75778` | `loss-reserve` |
| `0x0C6e8a9f43aAB3D6Be780Ac3778a0EDE525da6bE` | `adapter` |
| `0xA322CB665B69732F3Ab6A0136bc636EAF81927a3` | `controller` |
| `0xC35bA3864245Bf89F95Af315100Dd65EBFD5E5cd` | `coverage-guard` |
| `0x27D44914976640bc9176AcF112D538513D04498d` | `extension` |
| `0xdaF7672706076e9da1ad6104E0D43f9EeD6cA494` | `oracle-guard` |
| rpSPY `0x14CC..EA8B`, rpUSDGs `0x2117..ac6B` | mint/burn sentinel of their own market; `market` as a holder of the other |
| any other address with code at the end block (`eth_getCode` falls back to `latest`, recorded as `checkedAt`) | `contract`, unless `--allow-contract`. EIP-7702 designators (`0xef0100` + 20 bytes) count as EOAs. |
| `0x94696d767e65a75581145646960FA0eC886cE5d2` (old signer) | `old-signer-never-paid`. It is also refused as `--protocol-recipient` / `--allow-contract`. |
| `--exclude ADDR` | `explicit` |

**Protocol recipient:** the Ledger by default; `--protocol-recipient ADDR` makes it configurable per epoch, and it is
written in `epoch.json`. It receives ONE leaf, made up of:
- the `(10000 - userBps)` part;
- the excluded slices;
- rounding and dust;
- unattributed RAM;
- `--extra-reward`;
- plus its own holder amount, if it holds pTokens.

The leaf can be claimed for it by anyone, so no Ledger signature is needed to collect it.

## 4. Files

| File | What |
| --- | --- |
| `src/MerkleRewardsDistributor.sol` | the distributor |
| `test/*.t.sol` | 78 Foundry tests: 49 unit, 8 odd-token, 8 fuzz, 4 invariants, 5 JS-vs-Solidity cross-check, 4 deploy-script |
| `tools/robinhood-ram-root.mjs` | the root generator (Node, ethers v5: `ETHERS_DIR=.../node_modules/ethers`) |
| `tools/test/*.mjs` | 17 offline generator tests + the synthetic fixture; golden files in `test/fixtures/` |
| `tools/rehearsal_expected.py` | independent Python recomputation of one account's amount from raw logs (rehearsal assertion) |
| `tools/rehearse_ram_epoch.sh` | the anvil fork rehearsal of one full epoch |
| `script/DeployRamRewardsDistributor.s.sol` | throwaway-deployer deploy (owner = Ledger), journal, `verify(string)` |
| `mutation/mutants.py` | hand-mutant round |
| `COMMANDS.md` | ceremony list + frontend section |

Run from `contracts/robinhood-rewards`:
- `forge test`
- `ETHERS_DIR=... node --test tools/test/robinhood-ram-root.test.mjs`
- `python3 mutation/mutants.py`
- `bash tools/rehearse_ram_epoch.sh` (needs the RobinhoodVaults `.wt-inkind/ramses-vaults/out-v3` FreshFeedMock artifact)

`lib/` holds two gitignored symlinks: `forge-std` and `openzeppelin-contracts` (5.3.0), both from
`/Users/joshua/Peridot/RobinhoodVaults/lib`.

## 5. Generator notes (public endpoint behaviour, measured)

- **One query per `(address, topic0)`.** `eth_getLogs` with an address list or a topic list is limited to 100,000
  blocks on the public endpoint ("send one value per position"). Single-value filters were served over 5.7M blocks.
- **Chunking.** Chunks are 2,000,000 blocks and halve on error. The first full scan from the vault's creation took
  about 28 s.
- **Resumable cache.** The cache lives in `--cache-dir`.
- **Network.** `--rpc-url` accepts only the public endpoint or a loopback `http://127.0.0.1` fork.
- **Determinism.** The output is deterministic, so a second machine can compare `sha256 epoch.json`.
  `dataHash = keccak256(epoch.json)`.
- **Epochs.** Epochs run from harvest block to harvest block (`--to-harvest TX|N|last`). `--previous-manifest` chains the
  start block to the previous epoch's end.

## 6. Evidence

- **Foundry:** `forge test` gives 78 passed, in 6 suites:
  - 49 unit tests, covering every window boundary at t-1/t/t+1, funding, cancel and republish without a forward, sweep
    release, over-commit, ownership, renounce, and the L2 range above `block.number`;
  - 8 odd-token tests (fee-on-transfer, over-delivering, false-returning, no-return, blacklisting, hook re-entrancy
    into claim / claimMany / publish);
  - 8 fuzz tests;
  - 4 invariants: `reserved` equals the open obligations and is covered by the balance; tokens leave only through
    claims and never to the owner; `claimed <= total` and matches the ghost accounting; no over-pay;
  - 5 JS-vs-Solidity cross-check tests over two chained golden epochs;
  - 4 deploy-script tests.
- **Generator:** 17 offline tests (`node --test tools/test/robinhood-ram-root.test.mjs`). They include an independent
  hand recomputation of five holders and the protocol leaf, the three checkpoint branches, the chained epoch, chunk
  splitting on a range limit, the loopback-only RPC rule and old-signer refusal.
- **Gas** (`forge test --isolate --match-test test_gasNumbers -vv`, each call its own transaction):

  | Call | Gas |
  | --- | --- |
  | `publishEpoch` | 137k to 171k (the first epoch of a fresh contract is the highest) |
  | `claim` | 87k (empty proof) to 104k (10 proof nodes) |
  | `cancelEpoch` | 40k |
  | `sweepUnclaimed` | 40k |

- **Mutation round** (`mutation/mutants.py`, 78 hand mutants, fuzz seed 0x2a): **74 killed, 4 equivalent, 0 unexplained
  survivors.** The equivalent mutants are:
  - M26: cancel releases `total` instead of `total - claimed`, but `claimed` is always 0 inside the window;
  - M58: effects after the transfer while the guard holds; M38/M39 show that the guard is what protects;
  - M66: saturation at `>=`, which also returns 0 at equality;
  - M73: `verifyLeaf` on an unknown epoch with root 0, which needs a keccak preimage of 0.

  M37 (renounce enabled) did not compile in the first pass and was rewritten; the rewritten mutant is killed. M07, which
  re-adds the Avalanche `toBlock <= block.number` check, is killed by 20+ tests because every test publishes L2 heights
  above the L1-derived `block.number`.

## 7. Fork rehearsal (`tools/rehearse_ram_epoch.sh`, log `deployments/rehearsal/rehearsal.log`)

**Setup.** Anvil fork of mainnet at L2 115953238. The Ledger, timelock, keeper, pool and throwaway deployer were unlocked
on anvil only. The SPY feed was held by FreshFeedMock, and `accrualBlockNumber` (slot 9) was aligned before the mints.

**Steps:**
1. The test user minted 0.02 SPY into rpSPY and 100 USDG into rpUSDGs. The funds came from the Ramses SPY/USDG pool,
   on the fork only.
2. After 21,600 s, keeper `0x9eaF..031E` ran `harvest`. It accrued about 0.0139 RAM, which brought
   `externalRewards` to 0.110748 RAM.
3. Throwaway deploy: one creation, owner = Ledger. `verify` passed, and the old signer as deployer was refused.
4. Root generation from the fork's events: epoch 0 = (110177000, 115953246], 17 harvests, 2 leaves. All checks were
   `true`, and `dataHash == keccak256(epoch.json)`.
5. The Ledger scheduled `forwardExternalReward(pair, RAM, DIST, 110748405391358194)` on the timelock:
   - an early execute was refused (`TimelockUnexpectedOperationState`);
   - a direct Ledger call was refused (`AccessControlUnauthorizedAccount`);
   - after 3,601 s the execute succeeded, moving all of `externalRewards` (0) into the distributor.
6. Publish: a stranger was refused (`OwnableUnauthorizedAccount`); the **Ledger** published (`reserved == total`).
   A claim inside the window was refused (`ClaimsNotOpen`).
7. After 86,401 s, the user claimed **14,286,665,861,623,942 wei**. That is equal to the **independent Python
   recomputation from raw logs** (`tools/rehearsal_expected.py`).
8. Bad claims were refused:
   - a double claim (`AlreadyClaimed`);
   - another account using the proof (`InvalidProof`);
   - an unknown epoch (`EpochNotOpen`).
9. A third party claimed the protocol leaf of **96,461,739,529,734,252 wei** for the Ledger. That is
   10 % part 11,074,840,539,135,820 + excluded holders (0xdEaD, timelock) 85,386,898,990,598,430 + rounding 2.
10. The depositor pools were 90 % of each market's RAM: 99,673,564,852,222,374 of 110,748,405,391,358,194.

**Result.** The distributor is empty and `reserved == 0`. **3 Ledger signatures** (schedule, execute, publish).
