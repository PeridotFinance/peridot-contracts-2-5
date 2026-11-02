# Avalanche Track A launch gate: the two existing Pharaoh ERC-4626 vaults

Handoff 09 section 3a and the Track A gate of section 4; shared rules from handoff 00 sections 4, 8, 8a, 9.
Branch `avalanche-pharaoh-tracks-abcd`. **This is evidence, not a decision.** No cap change is proposed or implied.
Everything below was produced by fork tests in the local VM: owner-Safe and rebalancer actions are `vm.prank` cheatcodes, nothing was signed or broadcast, no keys were used.

Test code: `contracts/test/AvalancheTrackAVaultsFork.t.sol` (35 tests per vault) and `contracts/test/helpers/AvalancheTrackAVaultsBase.sol`.
Raw logs of the two reference runs: `docs/deployment-handoffs/avalanche-track-a-evidence/{usdc,wavax}-vault-suite-log.txt`.

## 1. Result in one paragraph

Neither vault passes the Track A gate as it stands. Swap-fee accounting is fair (PASS). **PHAR rewards are not**: they are claimed into the vault outside NAV, so a depositor who joins before the Safe's harvest-and-donate captures about his share of supply of rewards earned before he joined, and a leaver forfeits what accrued while he held (FAIL, measured on both vaults). Exit capacity is small: the USDC/USDt vault cannot take a USD 10,000 deposit in one transaction and cannot return a whole USD 1,000 position in one redeem, because nearly all third-party liquidity in its pool sits in a thin band at the peg; the sAVAX/WAVAX vault is workable to about USD 10,000 per transaction and about 5/8 of a USD 100,000 to 250,000 position per redeem. Both vaults freeze ERC-4626 exits, deposits, views and the keeper's `rebalance()` whenever the pool leaves the TWAP/oracle bands; `redeemInKind()` is the only exit that survives. The Safe is 1-of-1 and its only signer is the rebalancer EOA. A net-return figure is missing, so no "profitable capacity" sentence can be written.

## 2. Pin, method, exact commands

| Item | Value |
| --- | --- |
| USDC/USDt suite | block **99216397**, hash `0x883381b513163bdd1b2e41915c706e28457506c4ec38ee859dcaacbe795c9c65` |
| sAVAX/WAVAX suite | block **99216312**, hash `0xc0f581b4342de95b97fd0670fe16bd277c48baf463887ab24510ba97096b6c57` |
| Chain | Avalanche C-Chain (43114), chain time about 2026-11-02 12:50 CET |
| Counts | USDC/USDt suite **35 passed, 0 failed**; sAVAX/WAVAX suite **35 passed, 0 failed** |
| Reproduction from the shared foundry cache | USDC/USDt suite re-run directly against `https://avalanche-c-chain-rpc.publicnode.com` at block 99216397 with no proxy: 35 passed, 0 failed (served from `~/.foundry/cache/rpc/avalanche/99216397`). The sAVAX/WAVAX direct re-run was not repeated |

**Why two pins and a proxy.** publicnode serves cold state only for roughly the most recent 128 blocks (about 2 minutes); older blocks time out (`-32002`) even a few minutes after the pin. A cold run of these suites needs about 7,500 storage reads per vault, which cannot be fetched sequentially inside that window. I therefore ran a small **local read-only pass-through proxy** (`127.0.0.1:8799`, in my scratchpad, not in the repo) in front of the same publicnode endpoint. It only forwards read methods (anything else, including `eth_sendRawTransaction`, is refused), caches responses per block, and at the start of a run re-fetches in parallel the storage keys seen in earlier runs of the same suite, so forge's sequential reads hit the cache. **It substitutes no values**: every response is the upstream publicnode response for that exact block, unmodified apart from the JSON-RPC id. It was used for both reference runs; the direct re-run above shows the result does not depend on it. It was stopped afterwards. Several earlier iterations at other pins (99207xxx to 99216xxx) were used while the suite was being developed and to build the key list; their results are not cited.

Commands (from `contracts/`):

```
export AVALANCHE_MAINNET_RPC_URL=https://avalanche-c-chain-rpc.publicnode.com
export FOUNDRY_OUT=out_tracka FOUNDRY_CACHE_PATH=cache_tracka FOUNDRY_PROFILE=debt_accounting
SKIPS="--skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol \
  --skip test/[!A]* --skip test/A[!v]* --skip test/Av[!a]* --skip test/Avalanche[!T]*"   # last four: keep other agents' unfinished test files out of this build
TRACKA_PIN_BLOCK=99216397 forge test --threads 1 $SKIPS --match-contract AvalancheTrackAUsdcVaultForkTest -vv
TRACKA_PIN_BLOCK=99216312 forge test --threads 1 $SKIPS --match-contract AvalancheTrackAWavaxVaultForkTest -vv
```

`TRACKA_PIN_BLOCK` overrides the default pin constant in the helper; a fresh pin needs fresh state (see above), so a cold re-run must be started within about 2 minutes of choosing the block, or through a prefetching proxy. All numbers below are from these two runs unless stated.

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
| 6 | PHAR rewards: an exiting depositor keeps his accrued rewards | testFinding_04 (1 day held, Bob about all liquidity): Bob receives 0 PHAR; the claim triggered by his `decreaseLiquidity` leaves it in the vault (0.0320 PHAR accrued while he held, USDC; 0.1773 PHAR, WAVAX), later donated to everyone. Redeem and `redeemInKind` pay asset and paired only | **FAIL** |
| 7 | Public reward anti-sniping policy | None exists in the contracts: rewards are outside NAV, harvested by the owner only, and monetised by an off-chain Safe batch. The notes (`avalanche_pharaoh_boosted_markets.md`) say the policy is unresolved; the tests confirm there is no on-chain mechanism | **FAIL / unresolved** |
| 8 | Donation and inflation resistance | test_05: a donation never profits the donor (attacker PnL negative in every case, e.g. -8.1 USDC of 100 donated). Virtual-offset share maths holds at 1e-6 rounding. But: (a) the next depositor pays to deploy donated idle assets (WAVAX, D = USD 10,000: victim loses 152 bps; USDC, D = USD 100: 5 bps); (b) a donation of about USD 10,000 (USDC vault) or about 117,000 WAVAX still deposits revert, keeper `deployIdle()` and `rebalance()` revert (`Too little received`) while existing holders can still redeem from the idle asset; (c) a 1-unit deposit mints shares worth 73 units (USDC) / 1.79e14 wei (WAVAX): a deploy-time NAV step of pre-existing idle assets goes to the depositor. Empty-vault (supply 0) first-depositor case not run | PASS for profit-by-donation; **FAIL** for donation griefing (b); (c) low value, noted |
| 9 | Partial exit receives its proportional entitlement | ERC-4626 `redeem` pays the haircut NAV (paired side valued at -1% / -3%): entry loss is charged once, 51-52 bps (USDC), 122-145 bps (WAVAX), and exit adds 0 bps versus NAV. The surplus stays with remaining holders (Alice +52 bps when Bob round-trips). `redeemInKind` pays the pro-rata real holdings: oracle-valued -4 to -7 bps versus deposit (a small gain) on WAVAX, 0 bps USDC. So the ERC-4626 path is conservative, not strictly proportional | PASS (no value taken by newcomers); strict proportionality of the 4626 path **FAIL by design** (see section 6) |
| 10 | Exit capacity at USD 1k / 10k / 50k / 100k / 250k, baseline pool | section 5 | partly PASS, see numbers |
| 11 | Exit capacity under a stressed pool (real swaps through the real router) | section 5: gates `Vault__PriceDeviation` at +/-40 ticks (USDC) and +/-150 ticks (WAVAX); inside the gate the redeem cost does not rise but full-position redeems fail more often | partly measured; third-party liquidity withdrawal stress (handoff 00 section 4 step 2) **UNPROVEN** |
| 12 | Out-of-range behaviour, oracle following the pool (a real depeg) | section 7: deposits and `deployIdle` revert `PositionNeedsRebalance`; the position earns 0 PHAR (vs 49.7e15 wei/h in range, USDC; 38.3e15 wei/h, WAVAX); ERC-4626 redeem and the keeper `rebalance()` both revert (USDC: empty revert, the pool has no liquidity below tick -109; WAVAX: `Too little received`), at every fraction down to 1/64 | **FAIL** (no recovery by keeper or user except `redeemInKind`) |
| 13 | Out-of-range, oracle not following (dislocation) | section 7: spot vs TWAP gate trips at once (`Vault__PriceDeviation`), 40 minutes later the TWAP-vs-oracle gate (`Vault__OracleDeviation`); `redeem`, `deposit`, `rebalance`, `totalAssets`, `maxDeposit`, `maxWithdraw`, `convertToAssets` all revert; `redeemInKind` works; `emergencyExit` works but does not unlock `redeem` | PASS as a safety brake; **FAIL** as an exit path |
| 14 | Keeper `rebalance()` works in range | test_10: ok at USD 2k and 10k (USDC), 10k and 50k (WAVAX); NAV change -2 to +9 bps; three back-to-back rebalances show no cooldown; the legal loss bound is 300 bps (USDC) / 900 bps (WAVAX) per call | PASS in range; see 12 and 13 |
| 15 | Monitoring and alarms | signals listed in section 8; none exists in the repo for these vaults at the time of writing | UNPROVEN |
| 16 | Trust and governance | 1-of-1 Safe, sole signer = rebalancer EOA, upgradeable proxies | **FAIL** against a decentralised launch standard; an operator decision |
| 17 | Net return of the strategy (needed for the profitable-capacity sentence) | not measured: PHAR price and weekly emission quantity and vote share, swap-fee income per unit of liquidity, LVR/IL, were not backtested | UNPROVEN |
| 18 | Third-party audit | not part of this work | UNPROVEN |

## 5. Exit capacity, measured

"Position" means one holder with essentially the whole vault (the Safe's seed is USD 30 and 1.7 WAVAX). Positions larger than a one-shot deposit allows were built in several chunks with the pool price restored between chunks (an arbitrageur would). The vault removes the liquidity first and then swaps into whatever depth is left, so a holder who owns the whole vault also removes the vault's own depth.

**USDC/USDt vault** (pool active liquidity 1.49e12; about USD 75 per tick near the peg, most third-party depth in a band of a few ticks):

| Position | One-shot deposit | Entry loss | Largest single redeem that succeeded | First failure | `redeemInKind` (oracle value vs deposit) |
| --- | --- | --- | --- | --- | --- |
| USD 1,000 | ok | 52 bps | 5/8 (USD 625) | full redeem: `Too little received` | 0 bps |
| USD 10,000 (5 chunks of 2,000) | **fails** (`Too little received`) | 51 bps | 4/8 (USD 5,000) | full redeem | 0 bps |
| USD 50,000 / 100,000 / 250,000 | fails | not built | not measured | one-shot deposit already fails | not measured |

Stress (positions USD 2,000 and 10,000): a 10% redeem succeeds at every shift inside the gate, from -25 to +25 ticks, at 51-52 bps (the entry loss; no extra slippage); at -40 and +40 ticks everything reverts `Vault__PriceDeviation`. The full-position redeem fails at every shift for USD 10,000 and succeeds only at +10 and +25 ticks for USD 2,000.

**sAVAX/WAVAX vault** (pool active liquidity 2.24e24):

| Position | One-shot deposit | Entry loss | Largest single redeem that succeeded | First failure | `redeemInKind` (oracle value vs deposit) |
| --- | --- | --- | --- | --- | --- |
| USD 1,000 | ok | 142 bps | full | none | -7 bps |
| USD 10,000 | ok | 144 bps | full | none | -6 bps |
| USD 50,000 (2 chunks) | **fails** | 135 bps | 7/8 (USD 43,750) | full redeem `Too little received` | -5 bps |
| USD 100,000 (4 chunks) | fails | 128 bps | 5/8 (USD 62,500) | full redeem | -4 bps |
| USD 250,000 (10 chunks) | fails | 123 bps | 5/8 (USD 156,250) | full redeem | -5 bps |

Stress (positions USD 10,000 and 100,000): a 10% redeem succeeds up to +/-90 ticks at 144 bps (128 bps for USD 100,000), which is the entry loss again; a new deposit of USD 100 is already refused at -90 and +90 ticks (`Vault__PriceDeviation`: the deposit path checks the price after its own swap), while redeems still work there; at +/-150 ticks everything reverts `Vault__PriceDeviation`. The USD 10,000 position redeems in full from -10 to +90 and fails at -30 and -90; the USD 100,000 position redeems in full only at +90.

`maxWithdraw` is `convertToAssets(shares)`; it ignores pool depth. In every failing case above it returned the full NAV while the redeem reverted.

**Exit-capacity sentence (handoff 00 section 2).** I cannot write it. It needs a net return, and none was measured (gate item 17). What the data does support, as exit-side facts only, at this pin and for a position that is essentially the whole vault: the USDC/USDt vault returned a single redeem of about USD 625 from a USD 1,000 position and about USD 5,000 from a USD 10,000 position (both with a 51-52 bps entry loss and zero extra exit loss); the sAVAX/WAVAX vault returned the whole of USD 1,000 and USD 10,000 positions, 7/8 of USD 50,000, and 5/8 of USD 100,000 and of USD 250,000 (entry loss 123-144 bps). A vault with many holders behaves better for one holder's partial redeem than these whole-vault cases, and the 10% redeems above are the closest measurement of that; larger multi-holder exits were not run. For a one-shot deposit the limit is between USD 1,000 and 10,000 (USDC) and between USD 10,000 and 50,000 (WAVAX); the exact thresholds were not bisected.

Caps: no cap is proposed. As a pass/fail reading of the table, a cap of USD 1,000 would pass the baseline exit checks for both vaults; a cap of USD 10,000 passes for sAVAX/WAVAX and fails the whole-vault exit for USDC/USDt; any cap of USD 50,000 or more fails the one-shot deposit on both and the whole-vault redeem on both, so those sizes rely on chunked deposits and partial redeems.

## 6. Why the 4626 exit pays less than the real holdings (property 9)

`totalAssets()` values the paired token at the oracle minus the haircut and principal at the TWAP tick, and excludes uncollected fees and PHAR. A new depositor's shares are priced on the net NAV increase, so he pays the haircut share once at entry (about half the haircut, because about half of his deposit is swapped). Exits are paid at that conservative NAV, the paired leg being swapped at market, and the difference stays with remaining holders. `redeemInKind()` pays the pro-rata real holdings, which is why it comes out 4-7 bps better than deposit on the WAVAX vault. A holder who enters by 4626 and leaves in kind recovers the haircut he paid, at the cost of holding two tokens. This is a design choice; it is documented here because the 4626 and in-kind exits are not equivalent.

## 7. Keeper behaviour and what a depositor sees

Who may call: `rebalance()` and `deployIdle()` need the rebalancer or the owner (`Vault__NotRebalancer` otherwise). `harvestRewards(bool,uint256)` is owner-only. `emergencyExit`, `pause`, `unpause`, `setRebalancer`, `setDepositCap` are owner-only. There is no public harvest: fees are collected by any `deposit`/`withdraw`/`redeem`/`redeemInKind`/`deployIdle`/`rebalance` call, PHAR is claimed into the vault by every `increaseLiquidity`/`decreaseLiquidity` (including a depositor's own).

| State | Share price / views | Deposit | Redeem | Keeper |
| --- | --- | --- | --- | --- |
| In range, normal | `totalAssets` excludes uncollected fees and PHAR until the next action; `maxDeposit` = cap minus NAV | ok | ok within the limits of section 5 | `rebalance` ok (NAV -2 to +9 bps), no cooldown |
| Out of range, oracle follows pool (depeg of USDt, or a sAVAX move) | views still work: USDC position NAV 9,820 for 10,000 deposited | `PositionNeedsRebalance`, but `maxDeposit` still reports a huge number (4.99e12 units USDC / 579,294 WAVAX): the ERC-4626 limit is wrong | reverts at every fraction (USDC: empty revert, the pool has no liquidity below -109; WAVAX: `Too little received`) | `deployIdle` reverts `PositionNeedsRebalance`; `rebalance` reverts (same swap failure) |
| Spot beyond the TWAP gate (30 / 100 ticks) | `totalAssets`, `maxDeposit`, `maxWithdraw`, `convertToAssets` revert (any Pharaoh lending oracle that reads them gets zero or a revert) | `PriceDeviation` | `PriceDeviation` | `PriceDeviation` |
| TWAP caught up, oracle not following | same reverts, now `Vault__OracleDeviation` | reverts | reverts | reverts |
| After `emergencyExit` (paused, position burned) | views work if the gates pass | `EnforcedPause` | works only if the idle paired balance can be swapped: ok at USD 2,000 on WAVAX, **fails** at USD 10,000 USDC and USD 50,000 WAVAX | n/a |

An out-of-range position holds only one token and earns nothing (0 PHAR over an hour; fees also stop). The vault never re-centres by itself; only the rebalancer or owner can. The emergency path that always worked in every state was `redeemInKind()`, with the caveat that it pays two tokens.

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

- Files created: `contracts/test/AvalancheTrackAVaultsFork.t.sol`, `contracts/test/helpers/AvalancheTrackAVaultsBase.sol`, this note, and `docs/deployment-handoffs/avalanche-track-a-evidence/` (two log files). Build output went to untracked `contracts/out_tracka/` and `contracts/cache_tracka/` (not in `.gitignore`). No existing file was edited.
- The shared foundry RPC cache `~/.foundry/cache/rpc/avalanche/` gained one file (about 0.4 MB) per pin I used, including the two reference pins `99216312` and `99216397`; I did not touch existing entries (the lead's `99200000` file was written by their runs, not mine).
- Local proxy: read-only, forwards unmodified publicnode responses, listened on `127.0.0.1:8799`, stopped. It made at most a few hundred thousand read requests to publicnode in total during development.
