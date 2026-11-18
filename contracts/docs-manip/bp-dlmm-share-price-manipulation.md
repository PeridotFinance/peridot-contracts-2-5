# bpPHAR-USDC: can the DLMM vault share price be manipulated to borrow more than it costs?

Status: analysis and offline PoC, 18 Nov 2026. Nothing deployed, signed or forked; no RPC was used. Branch `feat/bp-dlmm-manip` (worktree `/Users/joshua/Peridot/.wt-bp-manip`).
Labels used below: **R** = read from code (file and line), **T** = shown by an offline Foundry test in this branch (real vault source, mocked pair), **E** = estimated or assumed (not verified on chain).

## 0. Verdict

1. **Donating USDC or USDt to the vault, or tokens to the pair, cannot make borrowing profitable.** A donation is real, redeemable value: `totalAssets()` counts only token balances the vault owns plus its share of bin reserves, and `redeemInKind` pays exactly that back to share holders, pro rata. The donor gets back at most his own fraction f of what he gave; everyone else keeps the rest. At collateral factor 50 % an attacker needs the oracle to overstate his collateral by more than **2x** (more than 100 %) before borrowing beats paying for it. Nothing an attacker controls overstates it by more than a few basis points (section 3). 256-run fuzz over deposit size, donation size and the fraction c of his shares he posts as collateral (the rest he keeps and exits in kind), plus a 12-point grid including a flash-funded donation of the margin stack's 100 USDC (fee 0): the attacker loses money in every case and the lender's loss is 0 (up to 2 wei of dust) (T). With P = (D + f d)(1 - c (1 - CF)) - D - d, the best case for him is c = 0 (borrow nothing): P = -(1 - f) d, never positive.
2. **Swaps through the pool barely move the share price**, by construction: the vault is a 3-bin, 1 bp-step band, so its NAV marked at the Chainlink ratio can differ from the pool-implied NAV by at most about the band width (1 to 3 bp of the part it converts). Measured in the mock with the feeds at par: a 400,000 USDC swap moved the vault NAV by +0.46 bp (780 wei at USD 17, 9,170 at USD 200). The live pool sits about 10 bp from the oracle ratio (evaluation doc); with the USDT feed set 10 bp off the pool in both signs the same swap moves NAV by up to about **5.5 bp** (offset x converted inventory + band width, T C3). Still basis points against a 2x (10,000 bp) threshold.
3. **The only large overstatement channels are exogenous**, not attacker-controlled: a Chainlink USDT/USD glitch or lag, a USDt depeg the feed lags, a failing Pharaoh hook. With the vault half USDt (today: 49.99 %), a USDT/USD answer of 3.00 doubles `convertToAssets` (T) and exactly reaches the 2x break-even; the guard flags the leg but the share price still follows it (R, T). The USDC/USD leg works the other way round and matters for the limiter: the wrapper's x USDC/USD cancels against pUSDC's own price (the guarded oracle reads the same live feed, no peg clamp, R), so USDC borrow power is CF x `convertToAssets`; a USDC/USD answer of 0.50 raises it by 50 % while the USD share price FALLS 25 % (T F7).
4. **A share-price rate limiter is NOT needed for what was asked** (donation, composition, flash-funded swaps). It is a cheap insurance against the feed-glitch / unknown-unknown case only. A tested, optional, one-slot-per-vault design (it limits ASSETS PER SHARE, not the USD price, so it also binds on the USDC-leg glitch) and a patch file are in section 6 (`contracts/test/boosted-manip/patches/oracle-rate-limit.patch`). **Recommendation: do not put it in the 19 Nov wrapper**; ship the current wrapper, keep CF 0 until the fork liquidation test passes, then at most 50 %. If you want it, it has to be in the wrapper you deploy now: adding it later means a second oracle swap (and the operator keepers halt on any `controller.oracle()` change until the new build is on the hosts, BRIEF.md).
5. **Drop side (lenders' real exposure):** a share price that is too HIGH on exit, not too low. Two thresholds on r = realisable / oracle = 1 - w x delta (derived, section 5): liquidators who keep the shares break even only while r >= 0.926 (overstatement <= 7.4 %, because the incentive is 8 %); the lender stays solvent after the feed catches up while r >= 0.54 (CF 50 % x 1.08), i.e. w x delta up to 46 %. Between the two, liquidations are unprofitable and wait for the feed. Two operational behaviours to accept or monitor: price 0 on a stale feed freezes borrow, redeem and liquidation for every account in the share market (R, T); a reverting Pharaoh hook blocks exit while NAV still prices the shares (T).

## 1. What was read

Vault `/Users/joshua/Peridot/.wt-dlmm-int/contracts/vault-dlmm/src/PharaohDlmmVault.sol` (read only, sha256 `4eec28a7e0eaf5a5687b0ea37090f76d6e231ff5fb5f86723bafcf534959ad40`, byte-identical copy vendored in `contracts/test/boosted-manip/vault-src/`, checked by `vault-src.sha256`):

| Item | Behaviour | Where |
|---|---|---|
| `totalAssets` | `_nav(pa, pp)` = idle USDC + idle USDt + vault's pro-rata share of each band bin (`getBin` reserves x LB-share balance / bin supply, floor), USDt leg valued `pp / pa` with the two Chainlink feeds. Pending PHAR **excluded**. Reverts `FeedInvalid` only when a feed is bad or older than `maxFeedAge`; an out-of-band answer does not revert. | R lines 198-200, 679-693, 805-845 |
| Idle balances | Any ERC-20 transfer to the vault address is counted (`tokenX.balanceOf`). **A donation can lift TA above the deposit cap**; the cap only gates `deposit`/`mint`. | R 829-831, 747-750, 217-234 |
| Share price | OpenZeppelin 5.3 `ERC4626Upgradeable`, `_decimalsOffset` not overridden: shares = assets x (S+1) / (TA+1). | R (no override in the file) |
| Min supply | `_requireMinSupply`: an entry may not leave 0 < supply < 1e6. Entries only; exits are never gated. With the dead seed (1e6 shares at 0x...dEaD, from the brief) the supply can never fall below 1e6. | R 236-242, T (E1) |
| Guard | legBand 50 bp, maxFeedAge 93,600 s, pool/oracle 60 bp, cooldown 120 s, 48 re-centres/day, swap <= 60 % NAV, NAV loss <= 50 bp. Leg band and pool deviation gate **entries and rebalances only**, not `totalAssets`. `tripGuard()` is permissionless but only for the latchable bits 1, 2, 4, 8 (feed or leg); a pool-only deviation (bit 16) cannot be latched. | R 165-175, 604-615, 664-675 |
| `redeemInKind` | No oracle, swap, pause, guard or cooldown; pro-rata idle + `pair.burn`. Both legs round to 0 -> `ExitFailed` (dust shares cannot exit). | R 277-294, 321-367 |
| `redeem` / `withdraw` | USDC out: swaps the USDt part through the router with an oracle floor (`maxRebalanceLossBps`); redeemer bears the cost. | R 249-316 |
| `harvestRewards` | Claims PHAR, forwards the **whole** PHAR balance to the owner. No effect on NAV. | R 584-598 |
| Pair semantics (mock written from the verified pair source) | NAV reads bin reserves from storage, not token balances. A direct transfer sits as `balance - reserves` and is consumed by the **next swap or mint** (swap input, or credited to whoever mints). LB shares are non-transferable (hook reverts "transfers disabled"). Fees stay in the bin. | mock header; evaluation doc section on hooks |
| Flash vault `0x73B0...475b` | `SimpleFlashLoanVault(.Upgradeable).flashLoan(receiver, token, amount, data)` has **no caller check**: any contract implementing `onFlashLoan` can borrow the 100 USDC at fee 0 (owner can change fee and token list). Real contract used in the PoC. | R `contracts/margin/SimpleFlashLoanVault*.sol` |
| Other flash sources | pUSDC's own `flashLoan` (30 % of cash, 5 bp by default, `flashLoansPaused` per market; pilot value unknown) and, on chain, third-party lenders and the pair's own `flashLoan` (37 events, fee 100 % to protocol per the evaluation doc). Not tested. Irrelevant to the verdict: capital is not the constraint, backing is. | R/E |
| Wrapper | `getUnderlyingPrice` = `convertToAssets(10^shareDecimals)` x Chainlink asset/USD (maxStaleness <= 7 d, 90,000 s at listing); returns 0 on any revert, stale or bad read; no `guardState` read. | R `PharaohVaultShareOracle.sol` 113-170 |
| Lender | collateral value = pToken balance x exchange rate x oracle price x CF; borrow `nextTotalBorrows < borrowCap` (strict); `PeridottrollerAvalanche` cash floor; price 0 for **any** asset the account holds -> `PRICE_ERROR` in the liquidity calculation, which also blocks `liquidateBorrowAllowed` and `redeemAllowed`. Max any attacker can take out: `min(cap - 1 wei, cash - floor)` = min(199.999999, 224) = **USD 199.999999**. | R `Peridottroller.sol` 382-413, 526-560, 815-848, 893-896; `PeridottrollerAvalanche.sol` |
| "24 hour" mechanics | **None exists in the vault or the wrapper.** The nearest: `maxFeedAge` 93,600 s (26 h; Chainlink stable feeds heartbeat 24 h), the wrapper's 90,000 s USDC window, and the per-UTC-day re-centre counter. There is no deposit-to-redeem delay: a same-block deposit and exit works (T, E2). | R |

## 2. Rig and honesty about it

`contracts/test/boosted-manip/` is a self-contained Foundry project (solc 0.8.35, osaka, via-IR, same as the vault project) with the vault's own mocks (`MockLBPair` written from the verified Pharaoh pair source: bins, one-sided rule, `balance - reserves` consumption, non-transferable shares, hooks, fee in bin; `MockRouter`, `MockRewarder`, Chainlink mock). The REAL vault is deployed behind a `TransparentUpgradeableProxy`; the REAL `PharaohVaultShareOracle` and the REAL `SimpleFlashLoanVault` are used. **Not real**: the controller (a 25-line `LenderHarness` mirrors the three checks that bound an extraction: CF x oracle value, strict borrow cap, cash floor; pToken exchange rate abstracted to 1, see 7) and the mock pair (no variable fee and no 50 % protocol share, price per bin linear, pool depth 11 bins x USD 600k per side instead of the live USD 3.7M with a thin active bin, no standing -10-bin USDt discount). The omissions point both ways: the missing variable fee, protocol share and depth make the real attacker's cost higher (the PoC is generous to the attacker); the thin live active bin (about USD 9k) makes pushing the band out of range cheaper than in the mock, and the live 10 bp pool/oracle offset moves NAV more than the par-feed runs (covered by C3). Neither changes the order of magnitude: basis points against a 2x threshold.

Fixture = live: dead seed 1 share + operator 16 shares = USD 17, one 3-bin band opened (opening costs 13 ppm: share price 0.999987), cap 200, pUSDC cash 274, borrow cap 200, floor 50, CF 50 %. `Scale200` repeats the swap, sandwich and glitch vectors with the operator holding 199 shares (TA about 200).

## 3. Quantitative table

f = attacker's share of supply; D = his honest deposit; d = donation; B = borrow = min(CF x oracle value, 199.999999, 224). Attacker P&L = B - D - d (he abandons the shares, the lender keeps them). "Overstatement" = oracle value / value realisable by `redeemInKind`.

| # | Vector | Attacker cost | Max NAV / price effect | Extra borrow power | Extractable value (lender loss) | Basis |
|---|---|---|---|---|---|---|
| a1 | Donate USDC to the vault, deposits OPEN (TA 17, room 183, f = 91.5 %) | d, flash-fundable (100 free) | +d exactly (backed) | CF x f x d = 0.46 d | **0**. D=183, d=100: B = 137.25, P&L = -145.75. D=50, d=500: B = 199.999 (cap), P&L = -350. | T (A1, A3, fuzz A4) |
| a2 | same, deposits CLOSED (TA 200 = cap, f = 0) | d | +d | 0 (no shares) | 0. P&L = -d | T (A2, A5) |
| a3 | Donate USDt (counted at feed) | d x market price | +d x feed price; overstates by d x (1 - market/feed) only | same | 0. 1 % depeg: 1 USDC per 100 donated | T for the counting (A5); derived arithmetic for the discount (A6) |
| a4 | Donation lifts TA over the cap | d | TA > 200 | none; cap does not bound collateral value but entries close (`maxDeposit` 0) | 0 (DoS of deposits at cost d) | T (A5, E3) |
| b1 | Direct transfer to the pair | d | **0** until minted/swapped | 0 | 0 | T (B1) |
| b2 | ... then a swap | d | next swapper is credited (up to depth); donor loses | 0 | 0 | T (B2) |
| b3 | ... then a vault re-centre | d | vault's `addLiquidity` mints it to the vault (TA +5 on a 5 USDt donation) | gift to holders | 0 | T (B3) |
| c1 | Swap through the pool, USD 17 vault, feeds at par | USD 70 for a 400k swap (mock fee 0.25 bp + band slippage) | +0.46 bp (780 wei) | 0.0004 USD | 0 | T (C1) |
| c2 | same, USD 200 vault | same | +0.46 bp (9,170 wei) | 0.005 USD | 0 | T (S200) |
| c2b | same with the USDT feed 10 bp off the pool (the live standing offset, both signs) | about the same (cost versus the market is the fee, not the offset; E) | up to **+5.5 bp** (9,279 wei on 17e6) = offset x converted inventory + band width | 0.005 USD | 0 | T (C3), E for the live offset |
| c3 | Wash trading to credit fees (20 round trips of 5,000) | USD 5.00 | +141 wei | 0 | 0 (mock fee only; the real pool pays the vault less: 50 % protocol share, variable fee up to 2.25 bp) | T (C2) |
| c4 | Flash-funded: 100 USDC fee 0, no caller check | 0 | cannot exceed c1-c3: swap size is bound by the attacker's own capital and loss | 0 | 0 | R, T |
| d1 | Deposit, push price, keeper re-centre, redeem | - | share price -0.0001 % | 0 | attacker -USD 0.0032 on 150 | T (D1) |
| d2 | Sandwich the re-centre (push out, keeper, push back; 5M capital) | USD 11.99 | vault NAV -0.012 % (-2,069 wei at 17; -24,330 at 200) | 0 | attacker -USD 11.99. Hard ceiling per re-centre: 50 bp of NAV (`_checkNavLoss`) = USD 0.085 / 1.00; <= 48 per day | T (D2, S200, F5), R |
| d3 | Harvest sandwich | 0 | **0** (PHAR excluded from NAV, forwarded to the Safe) | 0 | 0 | T (D3) |
| e | Dust and supply floor | - | exit of < ~2 share-wei reverts `ExitFailed`; supply floor = dead seed | - | 2 wei | T (A4, E1) |
| f1 | Feed glitch, USDT/USD = g (exogenous) | none | assets per share x (1 + w (g - 1)), w = USDt weight (0.4999 today); **g = 3 doubles it** | CF x that | 0 up to g = 1 + 1/w = 3.0; lender loss only beyond (V_o > 2 V_r) | T (F6, S200) |
| f1b | Feed glitch, USDC/USD = a (exogenous; also breaks pUSDC itself) | none | assets per share x (1 + w (1/a - 1)); the USD share price FALLS. a = 0.50: +50 % USDC borrow power, a = 1/3: 2x | CF x that | same break-even (a = 1 / (1 + 1/w) = 0.33) | T (F7) |
| f2 | USDt real discount delta, feed lagging | none | exit/oracle r = 1 - w delta | - | liquidations unprofitable from w delta 7.4 %; bad debt only from 46 % (CF 50 % x 1.08) | derived (F1 prints the table; not a vault call) |
| f3 | Feed stale > 93,600 s | none | price 0 | blocks borrow, redeem, liquidation for accounts in the market | liveness, not theft | T (F2) |
| f4 | Hook down (`beforeBurn` reverts) | none (Pharaoh governance) | NAV unchanged, exit impossible | - | not exitable; guard bit 32 only when UNLINKED | T (F3) |
| f5 | `tripGuard` | pool push cost | pool deviation alone cannot latch; a feed/leg bit can (anyone) | - | vault entries/re-centres stop until the Safe clears | T (F4) |

Formulas (donation case, c = fraction of his shares posted):  P = B + (value of the shares he keeps) - D - d = (D + f d)(1 - c (1 - CF)) - D - d, with f = D / (TA0 + D) < 1; for c = 1: B = CF x f x (TA0 + D + d), dP/dd = CF x f - 1 < 0, best case d = 0: P = -D/2; for c = 0: P = -(1 - f) d. Always <= 0. Break-even rule for any vector: oracle value / realisable value > 1 / CF = 2. Re-centre loss per event <= `maxRebalanceLossBps` x NAV and the swap floor limits the inventory leg to 60 % of NAV at 50 bp, i.e. <= 0.3 % of NAV.

## 4. The vectors in the order asked

**(a) Donation to the vault.** Modelled with the real vault, the real flash vault and the real oracle wrapper (`FlashDonator`: flash loan 100, donate, supply shares, borrow, repay, all in one callback). The oracle price rises with the donation (A1: collateral valued 274.5 against 183 paid in), the lender hands out 137.25, and the shares are worth 274.5 on exit because the donation sits in the vault. The attacker ends -145.75. Fuzz `testFuzz_A4` (256 runs, D up to the room, d up to 1e9 USDC, c from 0 to 100 %) asserts P <= 0 and lender loss <= 2 wei every time, and that the oracle value never exceeds the in-kind exit value by more than 6 wei.
**(b) Direct transfer to the pair.** NAV reads bin reserves (storage), so it does not move (B1). The tokens are consumed by the next swap or mint (B2, B3). No path credits the donor.
**(c) Swaps.** Section 3. The flash vault only provides 100 USDC; a 400,000 swap needed 400,000 of the attacker's capital and lost USD 70 to move NAV by under USD 0.01.
**(d) Sandwiches.** NAV is oracle-marked and continuous, so entering before a re-centre buys the cost of the re-centre pro rata (D1). Pushing the pool to force a re-centre and trading behind it loses to the pool's depth (D2). Harvest does nothing to NAV (D3). A real, small LP-side loss exists: forced re-centres are bounded at 50 bp each and 48 a day (a theoretical ceiling of 21 to 24 % a day if every one could be forced at the floor, which would cost the attacker far more in pool slippage than the vault loses; E). That is a share price DROP, handled in section 5.
**(e) Mechanics.** No 24 h rule exists. Deposit cap: entries only; TA can exceed it by donation (E3, A5). Min supply: deposit side only; the dead seed is the real floor (E1). A first-depositor style attack on the vault is closed by the dead seed (rounding loss per entry <= one share-wei, i.e. 1e-6 x the share price in USD; at a USD 1M donation that is about USD 0.06; E).
**(f) Drops.** Section 5.

## 5. Share-price drops and NAV that overstates the exit (separate from the limiter)

Lenders only lose if collateral seized and exited is worth less than the debt. Debt <= CF x oracle value; liquidators receive 1.08 x repaid debt in collateral at the ORACLE price and keep the shares. With r = realisable / oracle = 1 - w x delta (derived arithmetic, T F1 prints the table; r = 0 is the hook-down case):

- **Liquidation breaks even for the liquidator** while 1.08 x r >= 1, i.e. r >= 0.926: an overstatement above 7.4 % (w delta >= 7.4 %: w = 100 % and USDt at 0.926, or w = 50 % and USDt at 0.85) means no rational liquidator acts and unhealthy positions wait until the feed reprices.
- **The lender stays solvent** after the feed catches up while r >= CF x 1.08 = 0.54, i.e. w delta <= 46 % (w = 100 % and USDt at 0.54, w = 50 % and USDt at 0.08). Below 0.54 a max-borrowed position is bad debt.

Sources:

| Source | Controlled by attacker? | Size | Remedy |
|---|---|---|---|
| Standing pool discount of USDt (about -10 bp measured 30 days) and feed lag | no | w x 10 bp, about 5 bp | none needed |
| USDt depeg, Chainlink lagging | no | see ratio table; CF 50 % holds to w delta 46 % | keep CF <= 50 %; do NOT raise it |
| One-sided band (w -> 1) | partly: pushing the price out of the band costs the attacker, the keeper re-centres to 50/50 within 120 s; `tripGuard` cannot be used on a pool-only deviation | doubles exposure to the two rows above | keeper uptime; alert on `bandState().outOfRange` older than 10 min |
| Feed glitch (USDT/USD at g x, or USDC/USD at a) | no | 1 + w (g - 1) (or 1 + w (1/a - 1)) on assets per share; break-even g = 3 or a = 0.33 | the optional limiter (section 6, on assets per share); otherwise accept |
| Price 0 (a feed older than 26 h, vault revert) | no | PRICE_ERROR for every account that entered the market: no borrow, no redeem, **no liquidation** | accept (fails closed; 26 h of stale stable feed is far beyond the 46 % buffer's horizon) or add a last-good grace (not recommended: stale-high during the very crash it would cover) |
| Hook / rewarder reverts burn | no (Pharaoh governance, not behind a timelock per the evaluation doc) | NAV priced, exit blocked (T F3) | off-chain alert: an `eth_call` of `redeemInKind` for a small holder (or a simulated `pair.burn`) must not revert; guard bit 32 fires only when the hook is UNLINKED, not when it reverts |
| Re-centre loss (forced) | partly | <= 50 bp per event, 48 a day | existing cap; alert on `NavLossTooLarge` reverts and on TA falling > 1 % per hour |
| Reading `guardState` in the wrapper | - | would return 0 or a haircut exactly when USDt moves 50 bp | **do not** do it: it freezes liquidations at the moment they are needed |

## 6. Share-price rate limiter: verdict and optional design

**Needed for donation / composition manipulation: no** (sections 3 and 4). **Useful for:** an unbacked jump in assets per share: a Chainlink glitch on EITHER feed (USDT/USD high, or USDC/USD low: the latter lowers the USD price while raising USDC borrow power, so a limiter on the USD price would never bind), a bug or upgrade in the pair, hook or vault. Not useful for drops (they pass through at once by design), nor for a USDC/USD glitch UPWARD (it cancels against pUSDC's own price; borrowing other assets is paused in the pilot).

**Design** (patch `contracts/test/boosted-manip/patches/oracle-rate-limit.patch`, base = `contracts/contracts/PharaohVaultShareOracle.sol` at `e08e5363`, identical in `.wt-bp-core` today; `git apply --check` passes; the tested copy is `tests/rl/PharaohVaultShareOracle.sol`, the same text with relative imports):

- What is limited: `convertToAssets(1 whole share)` (asset units) inside `_price`, before the USD conversion. One storage slot per vault: `Checkpoint{uint128 assetsPerShare; uint64 updatedAt}`. Constants `MAX_RISE_BPS_PER_HOUR = 100`, `MAX_ELAPSED = 24 hours`.
- View: `cap = checkpoint x (1 + 1 % x min(elapsed, 24 h) / 1 h)`; the controller reads `min(spot, cap)`. No checkpoint -> spot. A fall is returned immediately.
- **Elapsed time is clamped to 24 h**, so a checkpoint nobody pokes keeps binding: it allows +24 % and no more (stale-low only while a legitimate rise is waiting, which is ppm a day). Without the clamp a stale checkpoint would dissolve.
- `registerVault` stores the current value. `removeVault` deletes it. `poke(vaultShare)` is permissionless: stores `min(spot, cap)` at `now`, **only if the full price read is valid** (both vault feeds fresh and the wrapper's USDC feed fresh), else it does nothing. Poking cannot accelerate the rise: each poke re-bases, so an hourly poke compounds 1 % an hour (doubling takes about 70 h, 1.01^24 = +26.97 % per day, T RL2); 60 pokes in one hour give <= +1.01 % (T RL4).
- Who pays: any keeper, about 50k gas hourly (a cent on Avalanche, E). The operator/treasury keepers already running are the natural caller. Nothing in the lending path depends on it.
- Failure behaviour: feed or vault read failure -> price 0 exactly as today (T RL6), poke is a no-op; no poke for a long time -> capped at +24 % over the last checkpoint (stale-low, T RL5), never 0, never a revert.
- Parameter 100 bp/h: legitimate rises are tiny (fee income and re-centre cost move the price by ppm, T RL7; a feed returning to par is <= 0.5 % x w; an operator top-up of USD 1 on 17 is +5.9 % and is released in 6 hourly pokes). A 3x USDT/USD glitch that lasts 3 hours moves the price <= 3.04 % (T RL8); a 0.50 USDC/USD glitch leaves USDC borrow power unchanged in its block (T RL9); doubling needs about 70 hours of sustained glitch with hourly pokes, longer than a 24 h-heartbeat feed fault plausibly runs. 50 bp/h would also pass the legitimate cases; 100 is a round, conservative choice (E).
- Tests: `tests/RateLimit.t.sol` (9): checkpoint at registration, donation spike held then released at 1 %/h, drops immediate, poke cannot accelerate, stale checkpoint keeps binding, failed feed -> 0 and poke no-op, income plus a real re-centre unchanged, 3x USDT glitch held, 0.50 USDC glitch held.
- Costs: one more storage slot per vault, one public function, a keeper dependency for release of legitimate rises, a changed `getShareUsdPrice` meaning (added `getRawShareUsdPrice` for diagnostics). Not audited.

Alternatives considered and rejected: a TWAP (needs on-chain history or the pair oracle, which has size 0), `min(convertToAssets, previewRedeem)` (same function), and a borrow-power haircut (equals a lower CF: already the lever).

## 7. Assumptions, gaps, decisions

- E: dead seed 1,000,000 shares at 0x...dEaD and live parameters come from BRIEF.md, not re-read from chain. The cap, flash vault fee 0 and 100 USDC likewise.
- Pool: real depth USD 3.7M, two LPs 97 %, thin active bin, standing -10 bp (evaluation docs); the mock has 11 bins with USD 600k per side and no variable or protocol fee. Real pair source (`flashLoan`, router `addLiquidity` accounting) is **not available locally**: the "no donation path into bins" claim for the pair's flash loan rests on the evaluation doc (fees 100 % to protocol, 37 events); not verified. Router `addLiquidity` bookkeeping in the mock differs slightly from the real router (does not affect NAV).
- pToken exchange rate abstracted to 1. A donation of shares to the pToken inflates its rate by real shares (same backing argument); the empty-market rounding attack is the dead seed's job (listing ceremony, another workstream). Not tested here.
- Not modelled: read-only reentrancy during pair callbacks (NAV reads storage reserves and ERC-20 balances; USDC and USDt have no callbacks; the hook is Pharaoh's), the pUSDC pToken flash loan, third-party flash lenders.
- Decisions for you: (1) ship the wrapper unchanged (my recommendation) or with the optional limiter; (2) keep CF <= 50 %; (3) accept price-0-on-stale; (4) add the off-chain alerts of section 5 (no contract change).

## 8. Reproduce (offline, no RPC)

```
cd /Users/joshua/Peridot/.wt-bp-manip/contracts/test/boosted-manip
(cd vault-src && shasum -a 256 -c ../vault-src.sha256)      # byte-identical vendored vault
forge test --root . -vv                                       # 40 tests: Smoke 1, ShareManip 26, Scale200 4, RateLimit 9
```
`lib` and `node_modules` in that folder are git-ignored symlinks to the main repo's. The suite MUST be run with `--root contracts/test/boosted-manip`: under the main `contracts/foundry.toml` the files only COMPILE (checked once with `FOUNDRY_SRC`/`FOUNDRY_TEST` overrides; tests not run there), and `World.sol`'s `deployCodeTo("MockERC20.sol:MockERC20")` would be ambiguous against `contracts/mock/MockERC20.sol`. The symlinks inside `test/boosted-manip` would also be crawled by a main-config build in a checkout that has them: delete them first.
