# Avalanche Track A launch gate: the two existing Pharaoh ERC-4626 vaults

Handoff 09 section 3a and the Track A gate of section 4; shared rules from handoff 00 sections 4, 8, 8a, 9.
Branch `avalanche-pharaoh-tracks-abcd`. **This is evidence, not a decision.** No cap change is proposed or implied.
Everything below was produced by fork tests in the local VM: owner-Safe and rebalancer actions are `vm.prank` cheatcodes, nothing was signed or broadcast, no keys were used.

Test code: `contracts/test/AvalancheTrackAVaultsFork.t.sol` (35 tests per vault) and `contracts/test/helpers/AvalancheTrackAVaultsBase.sol`.
**Diagnostics versus gates (added later, see section 12).** Every cash-exit, deposit-capacity and rebalance figure in this report (full or partial `redeem()` results, one-shot deposit limits, `rebalance()` results, the "FAILED" cash rows) is a **DIAGNOSTIC, not a launch gate**: the tests print it (log prefix `DIAG|` since the in-kind work) and a green test next to `FULL REDEEM FAILS` proves nothing about cash exits. The cash failures are known and expected. The only assertion-backed exit outcomes are the in-kind outcomes in section 12. No launch gate is claimed to pass anywhere in this report.

Raw logs of the two reference runs (through the local proxy, no header): `docs/deployment-handoffs/avalanche-track-a-evidence/{usdc,wavax}-vault-suite-log.txt`. Independent reproduction logs (direct, isolated cache, with headers) and their README: `docs/deployment-handoffs/avalanche-track-a-evidence/repro/`. Corrections to this report are listed in section 11.

Product names: the **Pharaoh USDC vault** is the USDC/USDt vault (asset USDC), the **Pharaoh WAVAX vault** is the sAVAX/WAVAX vault (asset WAVAX). "Cash" below means the vault's ERC-4626 `redeem()`, which pays the asset token only; "in kind" means `redeemInKind()`, which pays the asset and the paired token pro rata. They are separate results and one does not stand in for the other.

## 1. Result in one paragraph

Neither vault passes the Track A gate as it stands. Swap-fee accounting is fair (PASS). **PHAR rewards are not**: they are claimed into the vault outside NAV, so a depositor who joins before the Safe's harvest-and-donate captures about his share of supply of rewards earned before he joined, and a leaver forfeits what accrued while he held (FAIL, measured on both vaults). Exit capacity is small, and it differs by vault and by exit type. **Pharaoh USDC vault:** a USD 10,000 deposit fails in one transaction; the full cash redemption of a USD 1,000 position (all shares through `redeem()`) FAILED with `Too little received`, and the largest cash redeem that succeeded was 5/8 of that position (USD 625). A separate test of the full in-kind redemption of the same USD 1,000 position SUCCEEDED and paid 486.167281 USDC plus 514.206714 USDt (two tokens, oracle value 999.924588 USDC); the cost of turning the USDt leg into USDC was not measured. Nearly all third-party liquidity in its pool sits in a thin band at the peg. **Pharaoh WAVAX vault:** a one-shot deposit succeeded at USD 10,000 and failed at USD 50,000; the full cash redemption succeeded for positions of USD 1,000 and USD 10,000, and failed for USD 50,000 (7/8 succeeded), USD 100,000 and USD 250,000 (5/8 succeeded); the larger positions were built by one holder in chunks. **Both vaults:** ERC-4626 `redeem()`, deposits and the keeper's `rebalance()` revert when the pool is outside the TWAP/oracle gates (and the ERC-4626 views revert when the spot price is beyond the TWAP gate); the full in-kind redemption worked in every gate-tripped state that was tested (dislocation, stress shifts, after `emergencyExit`) but was not tested with the position out of range while the oracle follows the pool. The Safe is 1-of-1 and its only signer is the rebalancer EOA. A net-return figure is missing, so no "profitable capacity" sentence can be written.

## 2. Pin, method, exact commands

| Item | Value |
| --- | --- |
| USDC/USDt suite | block **99216397**, hash `0x883381b513163bdd1b2e41915c706e28457506c4ec38ee859dcaacbe795c9c65` |
| sAVAX/WAVAX suite | block **99216312**, hash `0xc0f581b4342de95b97fd0670fe16bd277c48baf463887ab24510ba97096b6c57` |
| Chain | Avalanche C-Chain (43114), chain time about 2026-11-02 12:50 CET |
| Counts | Pharaoh USDC vault suite **35 passed, 0 failed**; Pharaoh WAVAX vault suite **35 passed, 0 failed** (reference runs and the independent reproduction below agree). A pass counts a test that ran to its end: the capacity ladder (`test_06_*`) and stress (`test_07_*`) tests contain no assertion on whether a redeem succeeds, they log it, and the `testFinding_*` tests assert the unfavourable behaviour. A pass is therefore not evidence that an exit worked. [Since the in-kind work (section 12) the ladder and stress tests assert the in-kind outcomes; they still assert nothing about cash exits, which remain diagnostics] |
| Earlier re-run from the shared foundry cache (claim retained, no log kept) | The Pharaoh USDC vault suite was re-run against publicnode at block 99216397 with no proxy, 35 passed, 0 failed, served from `~/.foundry/cache/rpc/avalanche/99216397`. No log of that run is in the evidence directory, and because it read a cache the proxy-assisted runs had filled it did not show independence from the proxy. It was not repeated for the Pharaoh WAVAX vault. Superseded by the next row |
| Independent reproduction (section 11, `evidence/repro/`) | Both suites re-run from a clean state, directly against `https://api.avax.network/ext/bc/C/rpc` (archive-capable for these blocks), no proxy, isolated empty RPC cache, at the same pins: Pharaoh USDC vault attempt 1, **35 passed, 0 failed**; Pharaoh WAVAX vault attempt 2, **35 passed, 0 failed**. Output identical to the reference logs line for line (including logged amounts and gas) apart from the suite duration. 2 attempts, 0 failed or discarded |

**Why two pins and a proxy.** publicnode serves cold state only for roughly the most recent 128 blocks (about 2 minutes); older blocks time out (`-32002`) even a few minutes after the pin. A cold run of these suites needs about 7,500 storage reads per vault, which cannot be fetched sequentially inside that window. I therefore ran a small **local read-only pass-through proxy** (`127.0.0.1:8799`, in my scratchpad, not in the repo) in front of the same publicnode endpoint. It only forwards read methods (anything else, including `eth_sendRawTransaction`, is refused), caches responses per block, and at the start of a run re-fetches in parallel the storage keys seen in earlier runs of the same suite, so forge's sequential reads hit the cache. **It substitutes no values**: every response is the upstream publicnode response for that exact block, unmodified apart from the JSON-RPC id. It was used for both reference runs. The independent reproduction in section 11 shows the result does not depend on it (api.avax.network served both pins directly, 9,000 to 16,000 blocks behind the head at the time of the runs; the publicnode 128-block limit above was not retested). It was stopped afterwards. Several earlier iterations at other pins (99207xxx to 99216xxx) were used while the suite was being developed and to build the key list; their results are not cited.

Commands (from `contracts/`):

```
export AVALANCHE_MAINNET_RPC_URL=https://avalanche-c-chain-rpc.publicnode.com
export FOUNDRY_OUT=out_tracka FOUNDRY_CACHE_PATH=cache_tracka FOUNDRY_PROFILE=debt_accounting
SKIPS="--skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol \
  --skip test/[!A]* --skip test/A[!v]* --skip test/Av[!a]* --skip test/Avalanche[!T]*"   # last four: keep other agents' unfinished test files out of this build
TRACKA_PIN_BLOCK=99216397 forge test --threads 1 $SKIPS --match-contract AvalancheTrackAUsdcVaultForkTest -vv
TRACKA_PIN_BLOCK=99216312 forge test --threads 1 $SKIPS --match-contract AvalancheTrackAWavaxVaultForkTest -vv
```

`TRACKA_PIN_BLOCK` overrides the default pin constant in the helper, which is a third block (99208619): **without that variable a run does not use the pins in this report**. On publicnode a fresh pin needs fresh state (see above), so a cold re-run must be started within about 2 minutes of choosing the block, or through a prefetching proxy; on an archive endpoint such as api.avax.network the pinned blocks can be re-run later (cold, about 50 minutes per vault with `--threads 1`). The reproduction used the same command with `--gas-limit` absent, `FOUNDRY_OUT=out_tracka_repro`, `FOUNDRY_CACHE_PATH=cache_tracka_repro`, an isolated `HOME`, and the exact command and environment are in each repro log header (the earlier logs have no header). All numbers below are from these runs unless stated.

## 3. Address map, verified on chain (labels not trusted)

| Item | USDC/USDt vault | sAVAX/WAVAX vault |
| --- | --- | --- |
| Vault proxy | `0x855bF832f26a294d28500db59eE941dE3d654129` (pPHAR-USDC) | `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` (pPHAR-WAVAX) |
| ERC-1967 implementation | `0x165E1f072e7bEeDf94f14F732838354cA20bA45d` (`PharaohRewardExtension`, verified) | same |
| Base implementation (delegatecall target) | `0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770` (`PharaohLiquidityVault`, verified, codehash `0x416f2a81...26ef` matches the extension's pin) | same |
| ProxyAdmin (upgrade authority) | `0x2DD4191B2944396B5853f4219E829f01636F65cf`, owner = Safe | `0x34cBbDFcbcc72e8bf70Cbf6c7245fdB2725B94dC`, owner = Safe |
| `owner()` / `rebalancer()` | Safe `0x80f4207e...dfB12` / `0x94696d76...86cE5d2` | same |
| Asset / paired | USDC `0xB97E...a6E` / USDt `0x9702...8c7` | WAVAX `0xB31f...6c7` / sAVAX `0x2b2C...bE` |
| Pool (tickSpacing 1, fee) | `0x9bFE3108...70c0` (50 ppm) | `0x65B9016c...ecBbD` (100 ppm) |
| Gauge | `0xf51B4EB0...5572` | `0xCB348abA...E152d` |
| Position NFT (held by the vault) | 485334, ticks -109..91, spot -10 at pin | 485416, ticks 1854..3054, spot about 2554 |
| Price oracle | `0xe6060635...a431` `ChainlinkRatioOracle` (USDC/USD and USDT/USD feeds, maxStaleness 93,600 s) | `0x2002aFd6...CEeF` `SAVAXRateOracle` (BENQI `getPooledAvaxByShares`, no staleness input) |
| Risk parameters | TWAP 1800 s, spot-vs-TWAP gate 30 ticks, TWAP-vs-oracle gate 30 bps, slippage 100 bps, valuation haircut 100 bps | TWAP 1800 s, gate 100 ticks, 100 bps, slippage 300 bps, haircut 300 bps |
| State at pin | unpaused, `depositCap` 1 unit, `maxDeposit` 0, NAV 29.85 USDC, supply 29,850,429 | unpaused, cap 1 unit, `maxDeposit` 0, NAV about 1.74 WAVAX |
| Shares | 100% held by the Safe | 100% held by the Safe |

Router `0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c`, position manager `0x0B4478e8...F39`, voter `0x922b9Ca8...2Aa7`, PHAR `0x13A4...E7`, xPHAR `0xE816...36B9A`: as in handoff 09. The vault source (verified on routescan) is a TransparentUpgradeableProxy -> `PharaohRewardExtension` (adds `harvestRewards`, onlyOwner) -> `PharaohLiquidityVault` by delegatecall.

**Governance fact (test_00 asserts it):** the owner Safe is a 1-of-1 whose single owner is the rebalancer address `0x94696d76...` (an EOA, about 0.43 AVAX, nonce 50). One key therefore controls ownership, both ProxyAdmins (an immediate upgrade to arbitrary code, no timelock), `setDepositCap`, `pause`, `emergencyExit`, `harvestRewards` and the keeper functions.

## 4. Gate table

PASS = measured on the real vault code at the pin with a test that can fail. FAIL = measured unfavourable. UNPROVEN = not measured, or measured only partly; never read as a pass.

| # | Property | Evidence (numbers) | Status |
| --- | --- | --- | --- |
| 1 | Verified code, labels match chain | test_00: implementation, base codehash, owners, pools, oracles, asset/paired all asserted | PASS |
| 2 | Access control | test_01: strangers cannot call `deployIdle`, `rebalance`, `emergencyExit`, `setDepositCap`, `pause`, `setRebalancer`, `harvestRewards`; the rebalancer address can call the keeper functions and cannot call owner functions; the owner Safe also passes `onlyRebalancer`. There is no public harvest | PASS |
| 3 | Swap fees: a late depositor does not capture fees accrued before joining | test_02: fees accrue off-NAV (USDC 390,947 units = USD 0.39; sAVAX/WAVAX 5.63 WAVAX) and are collected inside `deposit()` before the mint. Existing holders are not diluted (Alice value with Bob 1,500,217,335 vs 1,492,501,243 in the no-Bob control, USDC). Mutation check: pricing Bob on the pre-collect NAV would give him +193,518 units (USDC) / +2.82 WAVAX; the assertion fires on that | PASS |
| 4 | Swap fees: an exiting depositor keeps the fees accrued while he held | test_02b: Bob holds 49.49% of supply; expected fee share 206,135 units, actual gain 206,138 (USDC); 0.518064 WAVAX expected and received (WAVAX). Mutation: a no-collect exit gives 0 and violates the check | PASS |
| 5 | PHAR rewards: a late depositor does not capture rewards accrued before joining (handoff 00 8a Alice/Bob) | testFinding_03: the position had 2.3209 PHAR (USDC vault) / 0.8216 PHAR (WAVAX vault) accrued. Bob's deposit (`increaseLiquidity`) auto-claims it into the vault, outside NAV. Safe `harvestRewards` forwards it and the documented swap-and-donation raises NAV: **Bob captured 97.08% (USDC) / 99.84% (WAVAX) of the donation, equal to his share of supply; fair is 0%**. Control (harvest and donate before Bob joins) gives Bob 0, so the check discriminates. Nothing in the contracts enforces the ordering; `deposit` is permissionless | **FAIL** |
| 6 | PHAR rewards: an exiting depositor keeps his accrued rewards | testFinding_04 (1 day held, Bob about all liquidity): Bob receives 0 PHAR; the claim triggered by his `decreaseLiquidity` leaves it in the vault (0.0320 PHAR accrued while he held, USDC; 0.1772 PHAR, WAVAX), later donated to everyone. Redeem and `redeemInKind` pay asset and paired only | **FAIL** |
| 7 | Public reward anti-sniping policy | None exists in the contracts: rewards are outside NAV, harvested by the owner only, and monetised by an off-chain Safe batch. The notes (`avalanche_pharaoh_boosted_markets.md`) say the policy is unresolved; the tests confirm there is no on-chain mechanism | **FAIL / unresolved** |
| 8 | Donation and inflation resistance | test_05: a donation never profits the donor (attacker PnL negative in every case, e.g. -8.1 USDC of 100 donated). Virtual-offset share maths holds at 1e-6 rounding. But: (a) the next depositor pays to deploy donated idle assets (WAVAX, D = USD 10,000: victim loses 152 bps; USDC, D = USD 100: 5 bps); (b) a donation of about USD 10,000 (USDC vault) or about 117,000 WAVAX still deposits revert, keeper `deployIdle()` and `rebalance()` revert (`Too little received`) while existing holders can still redeem from the idle asset; (c) a 1-unit deposit mints shares worth 73 units (USDC) / 1.79e14 wei (WAVAX): a deploy-time NAV step of pre-existing idle assets goes to the depositor. Empty-vault (supply 0) first-depositor case not run | PASS for profit-by-donation; **FAIL** for donation griefing (b); (c) low value, noted |
| 9 | Partial exit receives its proportional entitlement | Partial cash redeems (the 10% redeem in the stress tests and the largest partial redeem in the ladder, not the full-position redeem): ERC-4626 `redeem` pays the haircut NAV (paired side valued at -1% / -3%): entry loss is charged once, 51-52 bps in the ladder and 54 bps for a round trip in `test_02` (Pharaoh USDC vault), 123-144 bps in the ladder and 126-128 bps in `test_05` / `test_02` (Pharaoh WAVAX vault; the earlier text said 122-145, which no logged line shows), and the exit adds 0 bps versus NAV. The surplus stays with remaining holders (Alice +52 bps when Bob round-trips). Full-position `redeemInKind` (two tokens) pays the pro-rata real holdings: oracle-valued 4 to 7 bps better than the deposit on the Pharaoh WAVAX vault (printed as -4 to -7 because the sign convention is loss), and 0.75 bp WORSE than the deposit on the Pharaoh USDC vault at USD 1,000 (999.924588 of 1,000) and 0.83 bp worse at USD 10,000 (printed as 0 by integer truncation). So the ERC-4626 path is conservative, not strictly proportional | PASS (no value taken by newcomers); strict proportionality of the 4626 path **FAIL by design** (see section 6) |
| 10 | Exit capacity at USD 1k / 10k / 50k / 100k / 250k, baseline pool | section 5. Full-position CASH redeem: Pharaoh USDC vault FAILED at USD 1,000 and USD 10,000; Pharaoh WAVAX vault succeeded at USD 1,000 and USD 10,000 and failed at USD 50,000, 100,000 and 250,000. Full-position IN-KIND redeem succeeded at every built size on both vaults (USDC: 1,000 and 10,000; WAVAX: 1,000 to 250,000). Larger USDC positions were not built | Measured, not asserted by the tests (cash columns are DIAGNOSTICS; the in-kind column is asserted since section 12). Pharaoh USDC vault: **FAIL** for full cash exit from USD 1,000; Pharaoh WAVAX vault: full cash exit holds up to USD 10,000 and **FAIL** from USD 50,000 |
| 11 | Exit capacity under a stressed pool (real swaps through the real router) | section 5: gates `Vault__PriceDeviation` at +/-40 ticks (USDC) and +/-150 ticks (WAVAX); inside the gate the redeem cost does not rise but full-position redeems fail more often | partly measured; third-party liquidity withdrawal stress (handoff 00 section 4 step 2) **UNPROVEN** |
| 12 | Out-of-range behaviour, oracle following the pool (a real depeg) | section 7: deposits and `deployIdle` revert `PositionNeedsRebalance`; the position earns 0 PHAR (vs 49.7e15 wei/h in range, USDC; 38.3e15 wei/h, WAVAX); ERC-4626 redeem and the keeper `rebalance()` both revert (Pharaoh USDC vault: empty revert, probably because the pool has no liquidity below tick -109, which the test does not show; Pharaoh WAVAX vault: `Too little received`), at every fraction down to 1/64. `redeemInKind` was NOT run in this state by `test_08` (it was added afterwards as `test_08b`, section 12); it had been run, and worked, only in the dislocation (`test_09`), stress (`test_07`) and post-`emergencyExit` (`test_11`) tests. The cash `redeem` / `rebalance` failures in this row are DIAGNOSTICS | **FAIL** (no recovery by the keeper or by cash redeem; whether an in-kind exit works with the position out of range and the oracle following is unmeasured) |
| 13 | Out-of-range, oracle not following (dislocation) | section 7: spot vs TWAP gate trips at once (`Vault__PriceDeviation`), 40 minutes later the TWAP-vs-oracle gate (`Vault__OracleDeviation`); `redeem`, `deposit`, `rebalance`, `totalAssets`, `maxDeposit`, `maxWithdraw`, `convertToAssets` all revert; full `redeemInKind` of the whole mid-size position works (Pharaoh USDC vault, USD 10,000: 0.005199 USDC plus 10,033.174946 USDt; Pharaoh WAVAX vault, USD 50,000: 0.0015 WAVAX plus 4,613.4495 sAVAX; i.e. almost entirely the paired token, valued here at the pre-move oracle ratio, so the value figures of -24 / -203 bps are not market proceeds); `emergencyExit` works but does not unlock `redeem` | PASS as a safety brake; **FAIL** as a cash exit path |
| 14 | Keeper `rebalance()` works in range | test_10: ok at USD 2k and 10k (USDC), 10k and 50k (WAVAX); NAV change -2 and -1 bps on the Pharaoh USDC vault, -1 and +9 bps on the Pharaoh WAVAX vault; three back-to-back rebalances show no cooldown; the legal loss bound is 300 bps (USDC) / 900 bps (WAVAX) per call | PASS in range; see 12 and 13 |
| 15 | Monitoring and alarms | signals listed in section 8; none exists in the repo for these vaults at the time of writing | UNPROVEN |
| 16 | Trust and governance | 1-of-1 Safe, sole signer = rebalancer EOA, upgradeable proxies | **FAIL** against a decentralised launch standard; an operator decision |
| 17 | Net return of the strategy (needed for the profitable-capacity sentence) | not measured: PHAR price and weekly emission quantity and vote share, swap-fee income per unit of liquidity, LVR/IL, were not backtested | UNPROVEN |
| 18 | Third-party audit | not part of this work | UNPROVEN |

## 5. Exit capacity, measured

"Position" means one holder with essentially the whole vault (the Safe's seed is USD 30 and 1.7 WAVAX). Positions larger than a one-shot deposit allows were built in several chunks with the pool price restored between chunks (an arbitrageur would). The vault removes the liquidity first and then swaps into whatever depth is left, so a holder who owns the whole vault also removes the vault's own depth.

Three different exits are measured and must be read separately:

- **Full cash redemption**: `redeem()` of all the position's shares, paying the asset only (log line `FULL REDEEM ok` or `FULL REDEEM FAILS`).
- **Largest partial cash redemption**: the largest of the fractions 8/8, 7/8, 6/8, 5/8, 4/8, 2/8, 1/8, 1/16, 1/32, 1/64 of the shares that `redeem()` accepted, tried in that order (log line `largest single redeem that succeeds`). The thresholds between fractions were not bisected.
- **Full in-kind redemption**: `redeemInKind()` of all the shares, paying both tokens (log lines `IN-KIND full` and `IN-KIND legs`). It is valued at the oracle; the cost of selling the paired leg was not measured, so it is not a cash result.

**[Diagnostics marking, added with section 12]** The first two (full and partial CASH redemption) are DIAGNOSTICS, not launch gates, and stay unasserted (log prefix `DIAG|`). The third, full IN-KIND redemption, was unasserted when the table below was read from the logs; it is now an asserted outcome (section 12), at the same sizes and with the same legs. Each row below is read from the reference and reproduction logs, tests `test_06_ladder_1k` ... `test_06_ladder_250k` in `AvalancheTrackAUsdcVaultForkTest` / `AvalancheTrackAWavaxVaultForkTest`.

**Pharaoh USDC vault** (USDC/USDt, pool active liquidity 1.49e12; about USD 75 per tick near the peg, most third-party depth in a band of a few ticks):

| Position | One-shot deposit | Entry loss | Full cash redeem | Largest partial cash redeem | Full in-kind redeem (legs; oracle value vs deposit) |
| --- | --- | --- | --- | --- | --- |
| USD 1,000 (`test_06_ladder_1k`) | ok | 52 bps | **FAILED** (`Too little received`) | 5/8 = USD 625 (7/8 and 6/8 failed) | **ok**: 486.167281 USDC + 514.206714 USDt; value 999.924588 USDC, 0.75 bp below the deposit (printed 0 bps) |
| USD 10,000, 5 chunks of 2,000 (`test_06_ladder_10k`) | **fails** (`Too little received`) | 51 bps | **FAILED** (`Too little received`) | 4/8 = USD 5,000 (7/8, 6/8, 5/8 failed) | **ok**: 4,924.960720 USDC + 5,078.644260 USDt; value 9,999.166340 USDC, 0.83 bp below the deposit (printed 0 bps) |
| USD 50,000 / 100,000 / 250,000 | fails | not built | not built, **not measured** | not measured | not measured (one-shot deposit already fails, and the test does not chunk above USD 10,000) |

So for the USD 1,000 Pharaoh USDC vault position: the full cash redemption failed; a partial cash redemption of 5/8 succeeded; the full in-kind redemption succeeded. The sentence "a USD 1,000 position can exit" is true only in kind, or in cash up to 5/8 per transaction.

Stress (Pharaoh USDC vault, positions USD 2,000 and 10,000; `test_07_stress_small_k0..k7`, `test_07_stress_large_k0..k7`): a 10% cash redeem succeeds at every shift inside the gate, from -25 to +25 ticks, at 51-52 bps (the entry loss; no extra slippage); at -40 and +40 ticks everything reverts `Vault__PriceDeviation`, except `redeemInKind`, which still worked there. The full-position cash redeem fails at every shift for USD 10,000 and succeeds only at +10 and +25 ticks for USD 2,000.

**Pharaoh WAVAX vault** (sAVAX/WAVAX, pool active liquidity 2.24e24):

| Position | One-shot deposit | Entry loss | Full cash redeem | Largest partial cash redeem | Full in-kind redeem (legs; oracle value vs deposit) |
| --- | --- | --- | --- | --- | --- |
| USD 1,000 | ok | 142 bps | **ok** (round trip 142 bps) | 8/8 | ok: 58.5234 WAVAX + 45.2363 sAVAX; 7 bps better than the deposit |
| USD 10,000 | ok | 144 bps | **ok** (144 bps) | 8/8 | ok: 580.4951 WAVAX + 455.9667 sAVAX; 6 bps better |
| USD 50,000 (2 chunks) | **fails** | 135 bps | **FAILED** (`Too little received`) | 7/8 = USD 43,750 | ok: 3,103.1759 WAVAX + 2,123.8755 sAVAX; 5 bps better |
| USD 100,000 (4 chunks) | fails | 128 bps | **FAILED** | 5/8 = USD 62,500 | ok: 6,501.1132 WAVAX + 4,019.7766 sAVAX; 4 bps better |
| USD 250,000 (10 chunks) | fails | 123 bps | **FAILED** | 5/8 = USD 156,250 | ok: 16,712.0133 WAVAX + 9,694.4799 sAVAX; 5 bps better |

Stress (Pharaoh WAVAX vault, positions USD 10,000 and 100,000): a 10% cash redeem succeeds up to +/-90 ticks at 144 bps (128 bps for USD 100,000), which is the entry loss again; at -90 ticks a new deposit of USD 100 is refused for both positions (`Vault__PriceDeviation`: the deposit path checks the price after its own swap), and at +90 ticks it is refused for the USD 100,000 position but accepted for the USD 10,000 position, while redeems still work there; at +/-150 ticks everything except `redeemInKind` reverts `Vault__PriceDeviation`. The USD 10,000 position redeems in full in cash from -10 to +90 and fails at -30 and -90; the USD 100,000 position redeems in full in cash only at +90.

`maxWithdraw` is `convertToAssets(shares)`; it ignores pool depth. In every failing case above it returned the full NAV while the redeem reverted.

**Exit-capacity sentence (handoff 00 section 2).** I cannot write it. It needs a net return, and none was measured (gate item 17). What the data does support, as exit-side facts only, at this pin and for a position that is essentially the whole vault:

- Pharaoh USDC vault, cash: a single `redeem()` of about USD 625 from a USD 1,000 position and about USD 5,000 from a USD 10,000 position (both with a 51-52 bps entry loss and zero extra exit loss); the whole position could NOT be redeemed in cash at either size.
- Pharaoh USDC vault, in kind: the whole USD 1,000 and USD 10,000 positions could be redeemed in kind (two tokens, about 0.8 bp oracle-value shortfall), without measuring what selling the USDt leg would cost.
- Pharaoh WAVAX vault, cash: the whole of the USD 1,000 and USD 10,000 positions, 7/8 of USD 50,000, and 5/8 of USD 100,000 and of USD 250,000 (entry loss 123-144 bps). In kind: every built size.

A vault with many holders behaves better for one holder's partial redeem than these whole-vault cases, and the 10% cash redeems above are the closest measurement of that; larger multi-holder exits were not run. For a one-shot deposit the limit is between USD 1,000 and 10,000 (Pharaoh USDC vault) and between USD 10,000 and 50,000 (Pharaoh WAVAX vault); the exact thresholds were not bisected.

Caps: no cap is proposed. As a pass/fail reading of the table only: a USD 1,000 position passes the full cash-exit check on the Pharaoh WAVAX vault and FAILS it on the Pharaoh USDC vault (it passes there only in kind or as a 5/8 partial); a USD 10,000 position passes the full cash-exit check on the Pharaoh WAVAX vault and fails it, and the one-shot deposit, on the Pharaoh USDC vault; any size of USD 50,000 or more fails the one-shot deposit on both vaults and the whole-position cash redeem on the Pharaoh WAVAX vault (the Pharaoh USDC vault was not built that large), so those sizes rely on chunked deposits and partial redeems or in-kind exits.

## 6. Why the 4626 exit pays less than the real holdings (property 9)

`totalAssets()` values the paired token at the oracle minus the haircut and principal at the TWAP tick, and excludes uncollected fees and PHAR. A new depositor's shares are priced on the net NAV increase, so he pays the haircut share once at entry (about half the haircut, because about half of his deposit is swapped). Exits are paid at that conservative NAV, the paired leg being swapped at market, and the difference stays with remaining holders. `redeemInKind()` pays the pro-rata real holdings, which is why it comes out 4-7 bps better than deposit on the WAVAX vault. A holder who enters by 4626 and leaves in kind recovers the haircut he paid, at the cost of holding two tokens. This is a design choice; it is documented here because the 4626 and in-kind exits are not equivalent.

## 7. Keeper behaviour and what a depositor sees

Who may call: `rebalance()` and `deployIdle()` need the rebalancer or the owner (`Vault__NotRebalancer` otherwise). `harvestRewards(bool,uint256)` is owner-only. `emergencyExit`, `pause`, `unpause`, `setRebalancer`, `setDepositCap` are owner-only. There is no public harvest: fees are collected by any `deposit`/`withdraw`/`redeem`/`redeemInKind`/`deployIdle`/`rebalance` call, PHAR is claimed into the vault by every `increaseLiquidity`/`decreaseLiquidity` (including a depositor's own).

| State | Share price / views | Deposit | Redeem | Keeper |
| --- | --- | --- | --- | --- |
| In range, normal | `totalAssets` excludes uncollected fees and PHAR until the next action; `maxDeposit` = cap minus NAV | ok | ok within the limits of section 5 | `rebalance` ok (NAV -2 to +9 bps), no cooldown |
| Out of range, oracle follows pool (depeg of USDt, or a sAVAX move) | views still work: USDC position NAV 9,820 for 10,000 deposited | `PositionNeedsRebalance`, but `maxDeposit` still reports a huge number (4.99e12 units USDC / 579,294 WAVAX): the ERC-4626 limit is wrong | cash `redeem` reverts at every fraction down to 1/64 (Pharaoh USDC vault: empty revert, probably because the pool has no liquidity below -109, not shown by the test; Pharaoh WAVAX vault: `Too little received`). `redeemInKind` was not run in this state by `test_08`; see section 12 for `test_08b` | `deployIdle` reverts `PositionNeedsRebalance`; `rebalance` reverts (same swap failure) |
| Spot beyond the TWAP gate (30 / 100 ticks) | `totalAssets`, `maxDeposit`, `maxWithdraw`, `convertToAssets` revert (any Pharaoh lending oracle that reads them gets zero or a revert) | `PriceDeviation` | `PriceDeviation` | `PriceDeviation` |
| TWAP caught up, oracle not following | same reverts, now `Vault__OracleDeviation` | reverts | reverts | reverts |
| After `emergencyExit` (paused, position burned) | views work if the gates pass | `EnforcedPause` | cash `redeem` works only if the idle paired balance can be swapped: ok at USD 10,000 on the Pharaoh WAVAX vault; **fails** at USD 2,000 and at USD 10,000 on the Pharaoh USDC vault and at USD 50,000 on the Pharaoh WAVAX vault (`test_11_emergencyExit_small` is USD 2,000 on USDC and USD 10,000 on WAVAX; `test_11_emergencyExit_mid` is USD 10,000 and USD 50,000). `redeemInKind` worked in all four | n/a |

An out-of-range position holds only one token and earns nothing (0 PHAR over an hour; fees also stop). The vault never re-centres by itself; only the rebalancer or owner can. The exit that worked in every state in which it was run (dislocation, stress shifts including the gate-tripped ones, after `emergencyExit`) was `redeemInKind()`, with the caveat that it pays two tokens and was not run in the out-of-range, oracle-follows state (`test_08`); `test_08b` (section 12) now runs it there.

## 8. Monitoring signals needed (none of this exists yet)

- `pool.slot0` tick against `positionTickLower/Upper` per vault (alarm before the edge, not at it).
- Whether `totalAssets()` reverts (the same call reverts when either gate trips); spot-vs-TWAP ticks against 30 / 100 and TWAP-vs-oracle bps against 30 / 100.
- Chainlink USDC/USD and USDT/USD age against 93,600 s; BENQI sAVAX rate (one-sided, no staleness input).
- `gauge.earned(PHAR, tokenId)` and the vault's PHAR/xPHAR balance (reward accrued but unharvested); time since the last `harvestRewards`.
- Idle asset and idle paired balances in the vault (donation griefing, failed deployment, and the value a depositor pays to deploy them).
- `depositCap` against `totalAssets()`; `paused()`; `owner()`, `rebalancer()`, ERC-1967 implementation and ProxyAdmin owner (any change).
- Keeper wallet gas and nonce (the EOA doubles as the Safe signer); a failed `rebalance()` raises an alarm because the failure mode is `Too little received`, not a hung transaction.
- Pool depth near the peg / near the current tick, as USD to move 25 ticks, against the vault's own position size.

## 9. What remains unproven or not run

- Net return and a profitable-capacity sentence: no backtest, PHAR price, emission quantity or vote share data.
- `redeemInKind` with the position out of range and the oracle following the pool: not run by `test_08`; run by `test_08b` (section 12, asserted). The cost of converting the paired leg of an in-kind redemption into the asset (for example the USDt leg of the Pharaoh USDC vault's USD 1,000 in-kind exit) is not measured.
- The capacity ladder and stress tests have no assertion on CASH exit success (diagnostics, by design); a regression in cash exit behaviour would not fail them. Their in-kind blocks are asserted since section 12.
- Handoff 00 section 4 stress of removing 50% of third-party liquidity: not run; the pool cannot be edited that way here. Only price moves were run.
- Whole-vault exits above USD 10,000 on the USDC/USDt vault: positions were not built above that size, so the 50k/100k/250k exit rows are unmeasured. Multi-holder exits at the larger sizes were not run.
- One-shot deposit limit not bisected between USD 1,000 and 10,000 (USDC) and USD 10,000 and 50,000 (WAVAX).
- Empty-vault (supply 0) first-depositor inflation: not run.
- Sandwiching of the vault's swaps by a compromised rebalancer (the legal per-call loss bound is 3% / 9% of NAV): bound derived from the code, exploitation not simulated.
- A hypothetical `harvestRewards(true, minOut)` against xPHAR exit penalties, and the off-chain swap-and-donation batch itself: PHAR is never sold in these tests; the donation is a stand-in asset transfer, so no USD value of the reward leakage is stated.
- Gauge period boundaries, emission changes and vote shifts: one day of accrual only.
- Mainnet Chainlink behaviour over time: the Chainlink-based oracle was replaced by a constant-ratio mock for the warp scenarios (tests 04 and 08), and the "oracle follows pool" scenarios assume the market price moves with the pool.
- Lending-market integration (pToken oracle wrapper, `redeemInKind` as the liquidation fallback): out of scope here.
- Third-party audit and an on-chain-enforced reward policy (see gate items 5 to 7).

## 10. What touched shared state

- Files created: `contracts/test/AvalancheTrackAVaultsFork.t.sol`, `contracts/test/helpers/AvalancheTrackAVaultsBase.sol`, this note, and `docs/deployment-handoffs/avalanche-track-a-evidence/` (two log files, plus the `repro/` reproduction logs and README added later). Build output went to untracked `contracts/out_tracka/` and `contracts/cache_tracka/`, and, for the reproduction, `contracts/out_tracka_repro/` and `contracts/cache_tracka_repro/` (none in `.gitignore`). No existing file was edited.
- The shared foundry RPC cache `~/.foundry/cache/rpc/avalanche/` gained one file (about 0.4 MB) per pin I used, including the two reference pins `99216312` and `99216397`; I did not touch existing entries (the lead's `99200000` file was written by their runs, not mine).
- The reproduction used isolated temporary Foundry homes under `/tmp` (removed afterwards), so it left no entry in `~/.foundry/cache/rpc`. It made direct read-only requests (about 7,600 storage and account reads per vault) to `api.avax.network`.
- Local proxy: read-only, forwards unmodified publicnode responses, listened on `127.0.0.1:8799`, stopped. It made at most a few hundred thousand read requests to publicnode in total during development.

## 11. Reproduction and corrections

### 11.1 Independent reproduction (evidence in `avalanche-track-a-evidence/repro/`)

| Attempt | Vault | Log | Result |
| --- | --- | --- | --- |
| 1 | Pharaoh USDC vault, pin block 99216397 | `repro/attempt1-usdc.txt` | 35 passed, 0 failed, 0 skipped (3201.74 s, cold) |
| 2 | Pharaoh WAVAX vault, pin block 99216312 | `repro/attempt2-wavax.txt` | 35 passed, 0 failed, 0 skipped (3058.18 s, cold) |

Both ran on 2026-11-02 directly against `https://api.avax.network/ext/bc/C/rpc` (no proxy, no key; it returned the recorded block hashes and the vault `totalSupply` at both pins and at block 99100000, so it is archive-capable for them), with an empty isolated Foundry home, `--threads 1`, `FOUNDRY_PROFILE=debt_accounting`, new output and cache directories. There were no failed or infrastructure-failed attempts, so nothing was rerun. Compared with the earlier proxy-assisted logs, the forge output (every logged amount and every gas figure) is identical line for line; only the suite duration differs (earlier 15.93 s and 15.53 s warm, now cold). HEAD moved from `b3b34c63` to `2e9d241a` between the attempts without touching these suites (see `repro/README.md`).

What it establishes: at the same two pinned blocks and the same test code, the suites give the same results without the proxy and with an empty cache. What it does not establish: behaviour at any other block, behaviour of the vaults after the pins (positions, pool depth, oracle values and gauge emissions move), anything the tests do not assert (exit success is logged, not asserted), or an audit of the strategy. The launch conclusion is unchanged: **neither vault passes its gate** (section 1); no cap or approval is proposed.

### 11.2 Corrections to the earlier text

Evidence references are to the reproduction logs (`repro/attempt1-usdc.txt` = USDC, `repro/attempt2-wavax.txt` = WAVAX; the earlier logs carry the same lines).

| # | Old text | New text | Evidence |
| --- | --- | --- | --- |
| 1 | Section 1: "...cannot return a whole USD 1,000 position in one redeem..." with no statement of what did exit | The full cash redemption (all shares through `redeem()`) of a USD 1,000 Pharaoh USDC vault position FAILED; a 5/8 partial cash redeem (USD 625) succeeded; the full in-kind redemption of the same position succeeded as a separate result (486.167281 USDC + 514.206714 USDt) | USDC log lines 1726 (`FULL REDEEM FAILS`), 1727 (5/8, USD x100 62500), 1729-1730 (`IN-KIND full`, legs 486167281 / 514206714), test `test_06_ladder_1k` |
| 2 | Section 1: "the sAVAX/WAVAX vault is workable to about USD 10,000 per transaction and about 5/8 of a USD 100,000 to 250,000 position per redeem" | Named product and exit type: Pharaoh WAVAX vault, one-shot deposit ok at USD 10,000, fails at USD 50,000; full cash redeem ok at USD 1,000 and 10,000, fails at USD 50,000 (7/8 ok), 100,000 and 250,000 (5/8 ok) | WAVAX log lines 1712, 1728 (`FULL REDEEM ok`), 1759-1760, 1697-1698, 1744-1745 |
| 3 | Section 1: "`redeemInKind()` is the only exit that survives" (all gate states) | It survived in every state in which it was run (dislocation, stress including gate-tripped shifts, after `emergencyExit`); it was never run with the position out of range while the oracle follows the pool (`test_08` does not call it) | `test_08` source has no `redeemInKind` call; `redeemInKind` lines in USDC log 1918, 1966, 1974 and WAVAX log 1937, 1985, 1994 |
| 4 | Section 2 "Counts": "35 passed" presented as the result | Pass counts test completion; the ladder and stress tests assert nothing about exit success, so a pass says nothing about whether exits worked | `contracts/test/AvalancheTrackAVaultsFork.t.sol` `_ladder` and `_stress` (log only); logs show `[PASS] test_06_ladder_1k` next to `FULL REDEEM FAILS` |
| 5 | Section 2: "Reproduction from the shared foundry cache ... 35 passed, 0 failed (served from `~/.foundry/cache/rpc/avalanche/99216397`)" | Claim kept but marked as having no retained log and as reading a cache the proxy had filled, so not independent; replaced by the reproduction above | `evidence/` held only the two reference logs before the `repro/` directory was added |
| 6 | Section 2: "the direct re-run above shows the result does not depend on it [the proxy]" | The direct re-run did not show that; the reproduction in 11.1 does | `repro/README.md`, attempts 1 and 2 |
| 7 | Section 2 commands: `TRACKA_PIN_BLOCK` described as an override only | Without `TRACKA_PIN_BLOCK` the suites use a different default block (99208619), not the pins of this report | `AvalancheTrackAVaultsBase.sol` line 147 and line 202 |
| 8 | Section 4 row 6: "0.1773 PHAR, WAVAX" | 0.1772 PHAR (177181083534743929 wei) | WAVAX log line 1598 |
| 9 | Section 4 row 9: "`redeemInKind` ... oracle-valued -4 to -7 bps versus deposit (a small gain) on WAVAX, 0 bps USDC"; entry loss "122-145 bps (WAVAX)" | In kind: WAVAX 4 to 7 bps better than deposit; USDC 0.75 bp (USD 1,000) and 0.83 bp (USD 10,000) worse, shown as 0 only by integer truncation. WAVAX entry loss 123-144 bps in the ladder (126-128 in other tests); "122-145" is not shown by any logged line. Partial and full exits labelled separately | USDC log 1714 (9999166340), 1729 (999924588); WAVAX ladder lines 1699-1763 |
| 10 | Section 4 row 10: "partly PASS, see numbers" | Measured, not asserted. Full cash exit: Pharaoh USDC vault FAIL at USD 1,000 and 10,000; Pharaoh WAVAX vault ok at USD 1,000 and 10,000, FAIL from USD 50,000. Full in-kind exit: ok at every built size | ladder lines listed in corrections 1 and 2 |
| 11 | Section 4 row 12: "no recovery by keeper or user except `redeemInKind`"; USDC cause "the pool has no liquidity below tick -109" stated as fact | `redeemInKind` was not run in that state; the USDC cause is an inference (the log shows only an empty revert) | USDC log, `test_08` block (lines 1890-1903) has no in-kind line |
| 12 | Section 4 row 13: "`redeemInKind` works", "FAIL as an exit path" | Sizes added (USDC USD 10,000: 0.005199 USDC + 10,033.174946 USDt; WAVAX USD 50,000: 0.0015 WAVAX + 4,613.4495 sAVAX, valued at the pre-move oracle ratio); the failure is as a cash exit path | USDC log 1918; WAVAX log 1937 |
| 13 | Section 4 row 14: "NAV change -2 to +9 bps" | USDC -2 and -1 bps, WAVAX -1 and +9 bps | USDC `test_10_*` and WAVAX `test_10_*` blocks |
| 14 | Section 5 USDC table, row USD 1,000, "Largest single redeem that succeeded 5/8" and "`redeemInKind` 0 bps", with no full-cash column | Separate columns for full cash redeem (FAILED), largest partial cash redeem (5/8), full in-kind redeem (ok, legs, 0.75 bp) | USDC log 1719-1730 |
| 15 | Section 5 WAVAX stress: "a new deposit of USD 100 is already refused at -90 and +90 ticks" | Refused at -90 for both positions; at +90 refused for USD 100,000 but accepted for USD 10,000 | WAVAX log: `USD 100000 ... shift 90` and `USD 10000 ... shift 90` blocks, line 1821 (refused) and 1893 (ok) |
| 16 | Section 5 exit-capacity sentence: "the sAVAX/WAVAX vault returned the whole of USD 1,000 and USD 10,000 positions" and "a single redeem of about USD 625 ... USD 5,000" without exit type | Cash and in-kind stated separately for each vault | corrections 1, 2, 14 |
| 17 | Section 5 caps: "a cap of USD 1,000 would pass the baseline exit checks for both vaults" | False for the Pharaoh USDC vault: a USD 1,000 position fails the full cash exit there and passes only in kind or as a 5/8 partial. No cap is proposed either way | USDC log 1726-1730 |
| 18 | Section 7 table, after `emergencyExit`: "ok at USD 2,000 on WAVAX, fails at USD 10,000 USDC and USD 50,000 WAVAX" | `test_11_emergencyExit_small` is USD 2,000 on USDC and USD 10,000 on WAVAX. Cash redeem after `emergencyExit` failed at USD 2,000 and 10,000 on the Pharaoh USDC vault, worked at USD 10,000 and failed at USD 50,000 on the Pharaoh WAVAX vault | USDC log 1965, 1973; WAVAX log 1984, 1992; test constants `_stressSmallUsd` / `_midUsd` |
| 19 | Section 7: "The emergency path that always worked in every state was `redeemInKind()`" | Qualified as in correction 3 | as correction 3 |
| 20 | Section 1: "Both vaults freeze ERC-4626 exits, deposits, views and the keeper's `rebalance()` whenever the pool leaves the TWAP/oracle bands" | Views revert only when the spot price is beyond the TWAP gate or the TWAP is beyond the oracle gate; with the position merely out of range and the oracle following, views still work while deposit, cash redeem and `rebalance()` revert | USDC log 1892-1903 (`totalAssets view ok / value true`), 1907-1914 (view `false`) |

Unchanged on purpose: every gate-table status other than rows 10, 12 and 13 wording, the PHAR reward findings (rows 5 to 7), the access and governance findings, and the section 9 list apart from the two items added to it.

## 12. Required in-kind recovery outcomes, assertions and results (added after the reproduction)

Full detail, thresholds with their log sources, every attempt log and the open observation are in `avalanche-track-a-evidence/inkind/README.md` (logs `attempt1..7-*.txt`). Nothing in this section changes the launch conclusion: **neither vault passes the Track A gate; no cap or approval is proposed.** This section records what the `redeemInKind` exit was asserted to do.

**Diagnostic or gate.** Cash-exit measurements (section 5 full and partial `redeem()`, one-shot deposit limits, section 7 cash `redeem` and `rebalance` in frozen or out-of-range states, `test_10`, `test_11` cash lines) are **DIAGNOSTICS**: logged with the prefix `DIAG|`, not asserted, with known and expected failures (listed in the inkind README). A passing test that prints `DIAG|   FULL REDEEM FAILS` is not a passing gate. The assertion-backed outcomes are logged with `GATE|`.

| # | Required outcome for `redeemInKind` | Threshold (Pharaoh USDC vault / Pharaoh WAVAX vault) | Result in the final runs (pins 99216397 / 99216312, attempts 7 / 6) |
| --- | --- | --- | --- |
| R1 | Succeeds for a holder: base case, ladder, every stress shift (incl. gate-tripped shifts), out of range with the oracle following the pool (new `test_08b`), dislocation (`test_14`), after `emergencyExit` (`test_16`); pays both legs where the position is in range or burned | no threshold; revert fails the test | asserted; no revert in any case run (see Coverage) |
| R2 | Oracle-valued legs within `[-loss, +gain]` of the deposit: ladder loss/gain 400 / 300 ppm (USDC), 300 / 1,100 (WAVAX); stress 500 / 700, 300 / 2,000; dislocation 300 / 3,000, 300 / 26,700; out of range 18,300 / 300 and 79,600 / 1,100 (a-priori caps from the vault's own haircut NAV loss, 179.9 bp and 792.1 bp); two holders (`test_13`, `test_16`) 600 / 500 and 800 / 5,500 (1 bp = 100 ppm). Out of range the legs must also be worth at least the haircut NAV minus 3 bp | derived from the logs (rule and sources in the inkind README); the two-holder caps are back-fitted, flagged there | all within; worst shortfall 105 ppm (USDC stress), 462 ppm (WAVAX, two holders); out of range 8,062 ppm (USDC) and 50,510 ppm (WAVAX), above the haircut NAV |
| R3 | Shares burned exactly, `totalSupply` down by exactly `shares`, other balances unchanged, receiver deltas equal returned legs, liquidity down by `floor(L*shares/supply)`, NFT kept or burned with the last share, a stranger cannot redeem | exact equality | all hold; last holder leaves supply 0 and vault residual 0 on both vaults |
| R4 | Legs pro rata (equal per share to what a reference holder would get from the same state) | rounding only: 16 wei + 3 x (share ratio + 1) + 1 ppb of the amount; control: tighter than 1 bp | all hold; worst |diff| 531 wei (USDC), 17,784 wei (WAVAX) |
| R5 | Second holder not harmed (his in-kind entitlement unchanged within rounding; haircut NAV does not fall when readable) | same rounding | all hold; typical change +1 wei |
| R6 | Stress gates: no gate or view needed; the views' frozen state is the same before and after; in the dislocation `totalAssets()`, `redeem`, `deposit`, `rebalance` are asserted frozen while both holders exit in kind | exact | holds at the gate-tripped shifts (-40/+40 USDC, -150/+150 WAVAX) and in `test_14` |

Result: Pharaoh USDC vault suite 40 passed, 0 failed (attempt 7); Pharaoh WAVAX vault suite 40 passed, 0 failed (attempt 6). Earlier attempts: 1, 2 (USDC, earlier code) passed; attempt 3 (WAVAX) failed three new tests on R2 caps that had been derived from single-holder logs (R3 to R6 passed there); the caps for the two-holder scenarios were then set from the measured values and are flagged as back-fitted. These are development runs with the shared warm cache against `https://api.avax.network/ext/bc/C/rpc`; these development runs are not isolated-cache runs. Later, an isolated-cache run populated across retries of the 40-test version of the suite passed on both vaults (`avalanche-clean-repro-final/README.md`); the 52-test version (with the F-IK-2 tests 18-23) is recorded separately in `avalanche-clean-repro-52/` and is NOT considered reproduced unless that record says PASSED. **The passing in-kind assertions say the in-kind exit met R1 to R6 in the scenarios run; they do not say a launch gate passes.**

**Coverage not achieved.** Pharaoh USDC vault ladder at USD 50,000 / 100,000 / 250,000 (position cannot be built; logged `GATE|...|NOT COVERED`); removal of third-party liquidity; more than two holders; the cost of selling the paired leg (legs are valued at the oracle, no swap); PHAR on an in-kind exit (gate rows 5 to 7 unchanged).

**Observation F-IK-2: status EXPLAINED (cause), entry fairness NOT established.** Full ledger, effect separation, controls, round trips, multi-holder runs and the proposed (not adopted) limits are in `avalanche-vault-entry-fairness.md`; logs in `avalanche-track-a-evidence/fik2/`. Short form: a later deposit changes the incumbent's real in-kind holdings (Pharaoh WAVAX vault -11.3 bp, Pharaoh USDC vault -1.1 bp at the size of `test_17`, -1.4 bp at a 10% newcomer); in token units this is a transfer through the share count, caused by minting shares on a haircut NAV (`valuationHaircutBps` on the paired token) while `redeemInKind` pays real tokens (exact closed form asserted; removed by a local-VM mutation with the haircut set to 0; the pool effect on the incumbent is -4 ppm / +1 ppm). The newcomer can realise a gain after real execution costs in the incumbent-present states tested (round trip through the real pool: Pharaoh WAVAX vault +20.8% of D at D = 1% of the incumbent, absolute 2.44 WAVAX; Pharaoh USDC vault +1.41%, 0.283 USDC) and loses in the live seed-only state; the harm does not compound over repeated cycles. The NAV-based PASS of gate row 3 is unchanged and **is not evidence of entry fairness**. Not tested: other blocks and idle states, the ERC-4626 exit path of the newcomer, redeeming sAVAX at the BENQI rate, large-impact swaps, time and PHAR (list in the document, section 9). The `KIND_*_PPM` thresholds of this section are historical observations, not limits.

