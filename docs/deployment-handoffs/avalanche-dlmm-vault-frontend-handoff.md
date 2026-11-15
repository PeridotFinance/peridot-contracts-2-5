# Avalanche Pharaoh DLMM USDC/USDt vault: frontend handoff

Status: **NOT DEPLOYED. SPEC-STAGE HANDOFF, written from the frozen interface before any contract code exists.** Nothing here has been run on a fork or on mainnet. The vault address, ABI JSON, feeds and the USDt address do not exist yet (marked **TBD**); a machine-readable entry (key `vaultDlmm` in `avalanche-pilot-addresses.json`) and the compiled ABI file are added after the ceremony (`avalanche-dlmm-vault-ceremony.md`). Where this document cannot tell from the frozen spec, it says **unverified** (the margin handoff's convention): re-check each one against the W2 source and the fork tests before coding against it.

**Updated with the W6 mainnet-fork findings** (local fork of block 100420249, nothing sent; `contracts/vault-dlmm/test/fork/RUN.md`; MEASURED at that block): sections 3.1, 3.2, 3.3, 4.1, 4.2, 5.3, 6, 8.3 and 11 carry them. Sources, in order of authority: `contracts/vault-dlmm/src/IPharaohDlmmVault.sol` (FROZEN; wins on any signature), `avalanche-pharaoh-dlmm-vault-spec.md` (FROZEN; section 7 is the frontend contract this file implements), `avalanche-pharaoh-dlmm-vault-second-measurement.md` and `avalanche-pharaoh-dlmm-vault-evaluation.md` (numbers and the hook facts). Everything not listed in the interface (ERC-4626 views, `pause`, roles, `harvest` details) is **inherited from R3** (`vault-r3/src/r3/PharaohLiquidityVaultR3.sol`) and is marked **unverified until W2 lands**. Do not copy R3 names where the interface differs: R3 has `Vault__DepositCapExceeded`, `DepositCapUpdated`, `RewardsHarvested`, `harvestRewards(bool,uint256)`; this vault has `CapExceeded`, `DepositCapSet`, `PharHarvested`, `harvestRewards()`.

## 0. The three rules that override everything else in the UI

1. **No projected APY, no annualised number, no "per year" figure derived from a short window, anywhere** (not in a tooltip, not on the marketing page, not in a share card). The only return numbers allowed are: (a) the **realised PHAR rate** of section 5, shown with its window length and harvest count; (b) the **realised change of the share price** of section 6, shown with its start and end date. Neither is multiplied, extrapolated or labelled "APY", "APR", "yield" or "rate of return". The measurement documents contain annualised percentages; they are research figures about a simulation, they are not product numbers, and they must not appear in the frontend.
2. **Say the weekly-vote dependence plainly** (section 5.3): PHAR comes from a weekly vote and can be zero in any week.
3. **Say the hook caveat plainly** (section 8.3): a failure on Pharaoh's side can block every exit, including the in-kind exit.

## 1. The product in one paragraph

An ERC-4626 vault: the user deposits **USDC**, receives vault shares, and the vault places the money in the **Pharaoh DLMM USDC/USDt pool** (pool `0x16888EE58E706C253b821EAA637ae9b2cFeA255C`, bin step 1, 0.01 % per bin) in **3 bins** (the active bin and one bin each side, even by value). When the active bin leaves the 3-bin band a keeper **re-centres** the band. The vault earns the pool's swap fees (they stay inside the bins and are part of the share price) and **PHAR**, Pharaoh's reward token, which the pool pays only to the active bin. **Pilot size: deposit cap USD 200.** The contracts are public: anyone can call them directly, so the cap is the real limit, not the UI.

Differences from the Pharaoh CL vaults already in the app (state them if the same screen shows both): fees are **inside the bin reserves and included in the share price** (R3 excluded uncollected fees); the vault holds **two tokens** (USDC and USDt) and its share price depends on two Chainlink feeds; a user can exit in **both tokens** (`redeemInKind`).

## 2. Units and conventions

| Thing | Unit |
| --- | --- |
| USDC | 6 decimals, address `0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E` |
| USDt | 6 decimals (unverified), address **TBD** (read `pair.getTokenX()`; token X is USDt, token Y is USDC per the evaluation section 5, MEASURED) |
| Vault shares | `decimals()` **TBD** (read it; the spec's `convertToAssets(1e6)` is one share only if `decimals() == 6`; otherwise use `10 ** decimals()`) |
| PHAR | 18 decimals (unverified; read the token) |
| Cap values | USDC units: `200000000` = USD 200 |
| Bin ids | `uint24`; the peg bin is 8,388,608; price of USDt in USDC = 1.0001^(id - 8,388,608) (bin step 1). The pool trades at a standing USDt discount of about 0.10 % (MEASURED, 30 days), so the active bin sits about 11 below the peg bin (median): this is normal, not a depeg |
| Chainlink feeds | 8 decimals, addresses **TBD** (USDC/USD and USDT/USD); the UI does not read them directly, `guardState()` does |
| Token X / Y in events and in-kind amounts | `amountX` = USDt, `amountY` = USDC (to be confirmed by the post-deploy read-back `pair.getTokenX()`) |

Contract addresses (all **TBD** until the ceremony): vault proxy, implementation, ProxyAdmin, keeper wallet, Safe. Known: owner Safe `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` (Ledger 1-of-1, the same Safe as the two CL vaults; this is Peridot's Safe, not Pharaoh's), pool above. The vault is a transparent proxy: call the proxy with the ABI of the implementation.

## 3. States the UI must model

Read all of these in one multicall at one block; none of them reverts except where marked.

| Read | Returns |
| --- | --- |
| `guardState()` | `(bool unsafe, bool latched, uint256 reasons)`. **Never reverts**: a bad or stale feed is a reason bit |
| `bandState()` | `(uint24 lowerId, uint24 upperId, uint24 activeId, bool hasBand, bool outOfRange)` |
| `depositCap()`, `DEPOSIT_CAP_CEILING()`, `totalAssets()`, `maxDeposit(user)` | cap and headroom (section 4) |
| `paused()` | inherited from R3 (unverified) |
| `rebalanceAllowed()` | `(bool ok, uint256 reasonBits, uint256 readyAt)`: informational ("re-centre pending, ready at ..."); `reasonBits` encoding is not defined in the interface (unverified) |
| `guardParams()` | the live limits (read them, do not hard-code the defaults: they are ESTIMATED until calibration, see `avalanche-dlmm-guard-calibration/`) |
| `rebalancesToday()`, `lastRebalanceAt()` | optional diagnostics |

### 3.1 Guard (three independent facts, not one switch)

`unsafe` is the live evaluation now. `latched` is a stored flag set by anyone calling `tripGuard()` while a latchable bit held; it **stays set after prices recover** until the owner (the Safe) calls `clearGuard()`. They are independent: `unsafe == false && latched == true` is a real state and **still blocks deposits**. The guard blocks deposits, mint, `openBand` and `rebalance`. **It never blocks an exit.**

| `reasons` bit | Meaning | Latchable | Show the user |
| --- | --- | --- | --- |
| 1 | USDC price feed reverted, non-positive, older than `maxFeedAge` or round incomplete | yes | "A price feed is unavailable" |
| 2 | USDt price feed, same | yes | "A price feed is unavailable" |
| 4 | USDC feed outside 1.00 +- `legBandBps` | yes | "USDC is trading away from its peg" |
| 8 | USDt feed outside 1.00 +- `legBandBps` | yes | "USDt is trading away from its peg" |
| 16 | pool price differs from the feed-implied price by more than `maxPoolOracleDevBps` | no (live only) | "The pool price is away from the market price" |
| 32 | the pool's reward hook is not linked or its implementation changed from the pinned code | no (live only) | "Pharaoh changed its reward contract; exits may be blocked" (also show section 8.3 text prominently) |

States and copy:

| State | Deposit button | Banner |
| --- | --- | --- |
| `!unsafe && !latched` and the exit probe passes | enabled (subject to cap, pause) | none |
| exit probe fails (whatever `guardState()` says) | **disabled** | the section 8.3 error text |
| `unsafe && !latched` | disabled | "Deposits are paused by the safety guard (price check). Withdrawals are not affected." plus the reason text |
| `latched` (whatever `unsafe` says) | disabled | "Deposits are paused by the safety guard until the Peridot team releases it. Withdrawals are not affected." |
| `paused()` | disabled | "Vault paused. Withdrawals are not affected." (inherited pause does not gate exits per spec section 3; unverified until W2) |
| any state | **exits stay enabled** | |

**The guard does not see a failing Pharaoh hook (W6 MEASURED).** With the pair's `beforeBurn` hook reverting, `guardState()` still reads `unsafe = false, latched = false, reasons = 0` (bit 32 checks linkage and code hash only), deposits are still accepted, and `redeemInKind`, `redeem`, `withdraw` and `rebalance` all revert (the hook's own revert data is bubbled; pool swaps and mints still work). So `guardState()` alone must never be the signal that "everything is fine". **Exit probe (required):** before enabling the deposit button, and on every page load, run an `eth_call` of `redeemInKind(N, holder, holder)` from an address that holds shares (the team seed holder, address TBD, or a state-override balance), with `N` of at least 10 shares (1 to 2 shares always revert, see 4.2) and only when `bandState().hasBand` (with no band the exit does not burn and works anyway). If the probe fails, or cannot be run, **hide or disable deposits** (fail closed) and show the section 8.3 error text. A probe that succeeds proves the exit works at that block only.

Anyone may call `tripGuard()`; the UI does not need to offer it (a monitoring page may). It reverts `GuardUnsafe(0)` when nothing latchable holds.

### 3.2 Band

| State | Condition | Copy |
| --- | --- | --- |
| No band | `hasBand == false` | "Not invested in the pool yet." Assets are idle and earn nothing until the first band opens |
| In range | `hasBand && !outOfRange` | "Invested in 3 pool price bins (ids `lowerId` to `upperId`)". Fees are earned; PHAR only while the active bin (`activeId`) is the one the pool rewards (section 5.3) |
| Out of range | `hasBand && outOfRange` | "The pool price has left the vault's range; the keeper re-centres it, usually within minutes. While out of range the vault earns no fees and no PHAR." Show "re-centre pending" only from `rebalanceAllowed()`; do not promise a time |

**Deposits earn nothing until the next `openBand` or `rebalance` (W6 MEASURED): a deposit is idle USDC until the keeper next builds the band.** The UI must not say "your deposit is earning"; show "deposited; invested at the next re-centre" and, if it shows an idle share, read the vault's idle USDC (`USDC.balanceOf(vault)`). A band that is in range can therefore be earning on less than the vault's NAV.

### 3.3 Cap

| UI field | Source |
| --- | --- |
| Pilot cap | `depositCap()` (expect `200000000` = "USD 200 pilot cap") |
| Deposited in the vault | `totalAssets()` |
| Headroom | `max(0, depositCap() - totalAssets())`; the per-user limit is `maxDeposit(user)` (never offer more than it returns) |
| Hard ceiling | `DEPOSIT_CAP_CEILING()` (implementation immutable, `200000000`); the owner cannot raise the cap above it (`CapAboveCeiling`); a higher cap needs a new implementation that the Safe signs |

Cap rules (spec section 2): enforced in `deposit`, `mint`, `maxDeposit`, `maxMint` and the `openBand` funding path: `totalAssets()` after the call must be at most the cap, else `CapExceeded(cap, totalAssetsAfter)`. The cap counts the **whole vault**, first come first served; a direct token donation to the vault only reduces headroom. From the R3 fork rehearsal: **`maxDeposit` can overstate the room by a few units** because fees are collected inside `deposit` first; do not build a transaction for the last unit of headroom (leave 0.01 USDC) and handle `CapExceeded` as a normal outcome ("the pilot cap was reached while you were depositing"). **`totalAssets()` can exceed the cap (W6 MEASURED): only entries are capped, and fees raise NAV above `depositCap()`.** Headroom is then 0 and `maxDeposit` is 0; do not draw "deposited / cap" as an error or clamp the displayed NAV to the cap, show "Pilot cap reached". Copy: "Pilot: the vault accepts at most USD 200 in total."

## 4. Call sequences (exact signatures)

Signatures below are from the frozen interface or are the standard ERC-4626 forms inherited from R3 (**unverified until W2**). Selectors computed with `cast sig`.

### 4.1 Deposit
1. Read section 3 state; refuse if `latched || unsafe || paused() || maxDeposit(user) == 0` **or the exit probe of 3.1 fails**.
2. `USDC.approve(vault, assets)` (exact amount).
3. Preview: `previewDeposit(uint256 assets)(uint256 shares)` (R3's preview is on the ownership NAV and is a lower bound after an entry-loss allowance; unverified).
4. `deposit(uint256 assets, address receiver)(uint256 shares)`, selector `0x6e553f65`. Send with an explicit gas limit; the R3 vault's first deposit into a position used about 2.4M gas and a raw estimate was not safe (`avalanche-pilot-vault-opening.md`); the DLMM figure is **TBD** from the rehearsal.
5. Read back `balanceOf(user)`.
`mint(uint256 shares, address receiver)` is listed in the spec's cap rules but R3's `maxMint` is 0 (exact-share minting disabled): **do not offer mint**; read `maxMint(user)` and offer it only if it is greater than 0 (unverified).

Errors to show: `CapExceeded(cap, totalAssetsAfter)` (0xf480e285) "The pilot cap is full"; `GuardLatched()` (0xc3ee26c7) or `GuardUnsafe(reasons)` (0xc26d0c7c) the section 3.1 banner; a paused-vault revert (OpenZeppelin `EnforcedPause()` if R3 keeps its `Pausable`, unverified) "Vault paused"; ERC-20 insufficient allowance or balance from the token. Decode revert data against the merged ABI of the vault and the tokens.

### 4.2 Exit (three paths; offer all three)
1. **Withdraw to USDC**: `redeem(uint256 shares, address receiver, address owner)(uint256 assets)` selector `0xba087652`, or `withdraw(uint256 assets, address receiver, address owner)(uint256 shares)` selector `0xb460af94`. Preview with `previewRedeem`. This path **needs the vault's NAV (both feeds) and a swap of the USDt leg**; it is not gated by pause, guard or latch, but it **can revert** when a feed reverts or is stale, or when a depegged pool cannot fill the swap within its oracle minimum. R3 also keeps one share out of `maxWithdraw` for a sole holder (use `redeem` for a full exit; unverified).
2. **Withdraw in both tokens (`redeemInKind`)**: `redeemInKind(uint256 shares, address receiver, address owner_)(uint256 amountX, uint256 amountY)` selector `0xa4bfc6b6`; event `RedeemedInKind(owner, receiver, shares, amountX, amountY)`. It burns the vault's bins pro rata, pays both tokens (USDt `amountX`, USDC `amountY`), reads **no oracle** and makes **no swap**, and is **not gated** by pause, guard, latch, cooldown, daily cap, keeper, the rewarder codehash pin or any oracle. It has **no minimum-out parameter**: the split between USDt and USDC depends on where the pool price sits. Show the exact amounts first with an `eth_call` of `redeemInKind` from the user's address (the simulation returns both amounts at that block); the user gets what the pool bins hold at execution. Copy: "You receive USDC and USDt in the proportion the vault holds them. You can swap the USDt yourself afterwards."
3. A third party redeeming for a holder needs the holder's share allowance (R3 behaviour, `owner_ != msg.sender`).

**Routing rules measured on the real pool (W6, block 100420249):**
- **`redeem` and `withdraw` can be vetoed by the oracle floor while the pool is fine.** When the oracle moves without the pool, for example the USDC feed at 0.98 or the USDT feed at 1.02 (the oracle values USDt more than 0.5 % above USDC), the swap minimum of the USDt leg is above what the pool pays and both revert, latched or not. `redeemInKind` paid in all four such cases. So **always offer `redeemInKind` next to the USDC exit, on every screen, in every state**, and make it the primary button as soon as the `redeem` simulation reverts.
- **Dust:** 1 to 2 shares revert in both exits (`ExitFailed`); `redeemInKind` pays from 3 shares; `redeem` pays from 6 (3 to 5 shares revert inside the pair's swap). A reverted exit keeps the shares. At about 1 raw unit per share these are far below one cent: disable the button under 10 shares and say "amount too small to withdraw"; for a tiny holder show only the in-kind route. The same simulation-first logic applies.

Decision logic for the exit screen (all reads at one block):
- Always show both buttons. Default to path 1 when `reasons` has no bit 1, 2, 4 or 8 and an `eth_call` of `redeem` succeeds.
- If the `redeem` simulation reverts, or `reasons & (1|2|4|8) != 0`: promote path 2 and say why ("USDC withdrawal is unavailable right now; you can withdraw in both tokens").
- If the `redeemInKind` simulation itself reverts with no vault custom error (and the amount is at least 10 shares) (empty revert data or an error from another contract): show the hook caveat of section 8.3 as an error state ("Withdrawals are currently blocked on Pharaoh's side"), not a generic "transaction failed". Also show it, as a standing warning, whenever bit 32 is set.

### 4.3 Reads for the position screen
`balanceOf(user)` (shares), `convertToAssets(shares)` (USDC value at the oracle NAV; **may revert when a feed reverts: show "price unavailable", not an error page**, unverified), `totalSupply()`, `totalAssets()`, `maxRedeem(user)` (R3).

### 4.4 Keeper and owner functions (the UI does not call them; shown so the activity feed can label them)
Rebalancer: `rebalance(uint24,uint24,bool,uint256,uint256,uint256,uint256,uint256)` `0x2b3210d2`, `openBand(uint24,uint24,uint256,uint256,uint256,uint256)` `0x376ea59a`, `harvestRewards()` `0x2be11ae2`. Permissionless: `tripGuard()` `0x0d85e6e3`. Owner (Safe): `clearGuard()` `0xa32e9571`, `setGuardParams((uint16,uint32,uint16,uint32,uint16,uint16,uint16))` `0x44d7adac`, `setDepositCap(uint256)` `0x86651203`, `setRebalancer(address)` `0x6cfd1553`, `pause()` `0x8456cb59` and `unpause()` (inherited).

### 4.5 ABI fragments the frontend needs (verbatim from the interface)
```
function depositCap() view returns (uint256)
function DEPOSIT_CAP_CEILING() view returns (uint256)
function bandState() view returns (uint24 lowerId, uint24 upperId, uint24 activeId, bool hasBand, bool outOfRange)
function guardState() view returns (bool unsafe, bool latched, uint256 reasons)
function rebalanceAllowed() view returns (bool ok, uint256 reasonBits, uint256 readyAt)
function guardParams() view returns (tuple(uint16 legBandBps, uint32 maxFeedAge, uint16 maxPoolOracleDevBps, uint32 rebalanceCooldown, uint16 maxRebalancesPerDay, uint16 maxSwapBps, uint16 maxRebalanceLossBps))
function rebalancesToday() view returns (uint16)
function lastRebalanceAt() view returns (uint48)
function redeemInKind(uint256 shares, address receiver, address owner_) returns (uint256 amountX, uint256 amountY)
```
Plus the standard ERC-4626 and ERC-20 ABI. The compiled JSON is added to `avalanche-pilot-abis/` after the build (**TBD**).

## 5. The "earns PHAR" display (spec section 7)

### 5.1 Who receives PHAR (read before writing any copy)
`harvestRewards()` claims PHAR and **forwards it to the vault owner (the Safe)**, as R3 does (spec section 1); **the share price does not include pending or harvested PHAR**. A depositor's shares therefore do not automatically receive PHAR. The spec's required copy is "earns PHAR"; taken literally to a depositor it over-promises. **Open question 1 for the operator**: is PHAR (a) kept by Peridot as the vault's income, (b) distributed to holders by some later mechanism, or (c) not paid to depositors at all? **Status: the operator decision is still pending; keep the neutral wording below.** Until answered the UI must use the neutral wording "**This vault earns PHAR** (Pharaoh's reward token). PHAR is collected by the vault owner and is not part of the share price." and must not say "you earn PHAR" or show PHAR as the user's balance.

### 5.2 Realised PHAR rate: definition (literal, from the spec)
Realised PHAR rate = **sum of `PharHarvested.amount` over a trailing window, divided by the share supply (`totalSupplyShares` in the event), per day.**

Implementation, per vault, from the indexed events `PharHarvested(address indexed token, uint256 amount, uint256 totalSupplyShares, uint256 totalAssets)` (topic `0x8da2a2ae983c75be28db60db20b04c2152a502b3bc6af0c99d49f8746d17a111`):
- Keep only events whose `token` is the PHAR token (the event is per token; unverified whether a second reward token can appear).
- Window = the last `W` days ending now (`W` selectable among 7, 14, 30; **proposal: default 14**, which covers two weekly emission cycles; this is a UI choice the operator may change). `H` = the number of harvests inside the window.
- Rate (PHAR per share per day) = `( sum over harvests i of amount_i / totalSupplyShares_i ) / W`, with `amount` in PHAR units and `totalSupplyShares` in share units (both scaled by their decimals). When the supply was constant this is exactly `sum(amount) / totalSupplyShares / W`; when it changed, each harvest is divided by the supply of its own event (**open question 2**: confirm this per-event normalisation, or use the latest event's supply, with the operator).
- Display it per 1,000 shares so the number is readable: "**X PHAR per 1,000 shares per day, over the last W days (H harvests)**". No conversion to USD in v1 (the PHAR price fell 51 % in the 30-day measurement window, MEASURED, so any dollar figure would be a forecast in disguise). Never multiply by 365, never show "per year", never show a rate while `H == 0`: show "**No PHAR was harvested in the last W days**" and the date of the last harvest (or "never").
- Harvest timing is not regular (the keeper or owner triggers it) and a harvest pays everything accrued since the last one, including days before the window: **the rate is lumpy, can read low between harvests and high after one.** Show the harvest count and the date of the last harvest next to it. Accrued-but-not-harvested PHAR is not visible through this vault's ABI; do not estimate it.

### 5.3 The weekly-vote dependence: required text and data
Required text, shown wherever the PHAR rate is shown: "**PHAR comes from a weekly vote on Pharaoh. The amount can fall to zero in any week, and the vault only earns it while its price range contains the pool's active price bin.**" Also state: "Pharaoh's owners can change which bins are rewarded and can stop the reward without notice."

Show the **last eight weekly emissions to this pool** next to the rate, as a small table or bar list of PHAR per week. Source: the weekly notification from the Pharaoh voter to the pool's reward contract (the `notifyRewarder` call in the evaluation section 7); the reward contract is the pair's hook (`init.rewarder`, address **TBD**). **The on-chain event or token transfer to index for this is not named in the evaluation (TBD, to be settled by reading the rewarder implementation or the first week's transactions); do not guess an event name.** A backend job produces the eight numbers; the page must not hard-code them. Reference values (MEASURED by the second measurement, 15 Nov 2026, last 8 epochs, PHAR to this pool per week, oldest first): 447, 356, 237, 4,713, 4,488, 9,649, 5,390, 6,249. Use them as a test fixture only. Note for the copy and for QA: this series stepped up about 20 times between epochs 2962 and 2963 with no floor in the contracts; in the evaluation four of the last 23 weeks had no transfer at all.

A second reason the rate can read zero or low (W6 MEASURED): anyone can call `redeemInKind` with a tiny amount, which touches the vault's bins and makes Pharaoh forfeit the PHAR accrued since the last touch (a 10-share burn at 100 s cost the first 100 s of accrual in the test); repeated every 111 s or less it could deny the vault PHAR. The UI cannot detect it; it is one more reason the rate is shown with its window and harvest count and never as a promise.

### 5.4 What the PHAR rate must not be compared to
Do not show it next to the pool's fee income, the pUSDC lending rate or any other product's rate as "better than". Different units, different risk.

## 6. Fee income: how to show it without an APY

**Rule: realised fee income is the change of the share price over a stated period, and nothing else.** Share price = `convertToAssets(1e6)` (USDC units per one share if `decimals() == 6`; use `10 ** decimals()` otherwise). It is the vault's own NAV per share at the oracle price: it already contains the pool fees earned (they sit inside the bins), net of the vault's rebalancing swap costs and adverse-selection losses, and it also moves with the oracle price of the USDt leg and with deposits' entry effects, so **it can fall as well as rise** and part of any move is mark-to-oracle rather than cash.

Computation:
1. Index `convertToAssets(10**decimals)` at block samples (at least daily, and at each `Rebalanced`, `PharHarvested`, `RedeemedInKind` event) or call it at historical blocks.
2. For a chosen start and end (the user's first deposit and now, or 7/30 days), show: `P_start`, `P_end` and the **difference in USDC per share, plus the same difference as a plain percentage of `P_start` for that exact period**, labelled "**Change in share price, from <date> to <date> (N days)**".
3. Expect small steps down: the real pool charged the vault about 24 ppm of NAV for the first `openBand` and 41 to 264 ppm for each re-centre in the fork test (W6 MEASURED; the decomposition is not done, see the risk register row 10), so with several re-centres a day the share price can fall in a quiet period even when the pool earns fees. Do not hide it and do not explain it as a fee. Do **not** scale to a year, do not average daily changes into a rate, do not show it at all for a window under 24 hours (**proposal**: show "too early to say"), and always show it beside the same sentence: "Past change in share price; not a forecast. It can be negative."
4. A user-specific figure is `convertToAssets(balanceOf(user))` minus the user's deposits plus withdrawals (from the `Deposit` and `Withdraw` events): "Your position is worth X; you deposited Y".

## 7. Copy blocks (all required unless marked optional)

- Product line: "USDC vault on Pharaoh's USDC/USDt pool. Pilot, limited to USD 200 in total."
- What it does: "Your USDC is placed in three narrow price bins around the current USDC/USDt price. When the price leaves them, an automated keeper moves them. The vault earns the pool's trading fees and PHAR."
- Fees included: "Trading fees stay inside the pool bins and are included in the share price."
- PHAR: the section 5.1 sentence, then the section 5.2 line, then the section 5.3 sentence and the weekly table.
- Share price change: section 6 line.
- Risks (always visible, collapsible): "Pilot, new contract, not yet reviewed by a human auditor. The owner (a 1-of-1 Safe controlled by the Peridot team) can pause deposits, change safety limits and upgrade the contract immediately, without a delay. The vault holds both USDC and USDt and its price depends on two price feeds. Fee and PHAR income can be zero and the share price can fall."
- Guard: sections 3.1 banners.
- Exits and the hook caveat: section 8.

## 8. Exit paths and the hook caveat

### 8.1 What the vault code guarantees
`redeemInKind` is not gated by pause, the guard, the latch, the cooldown, the daily cap, the keeper, the rewarder codehash pin or any oracle (spec section 3). `withdraw` and `redeem` are not gated by pause, guard or latch either, but need NAV and a swap and can revert on a bad feed or a depegged pool (4.2).

### 8.2 What nothing we write can guarantee
Pharaoh's pair calls its reward contract (the "hook") on every burn. The vault's exits burn bins. **If that reward contract, or the Pharaoh voter it reads, reverts, every burn reverts, so every exit, including `redeemInKind`, reverts until Pharaoh's factory owner removes the hook.** LB shares cannot be transferred, so there is no other way out. The hook is a beacon proxy that Pharaoh's access hub can upgrade; MEASURED today: the pair's hook flags (0x151) include before-burn (evaluation section 7). Peridot cannot remove or bypass it. Bit 32 of `guardState().reasons` reports that the hook is unlinked or its code changed, which is the early warning, not a fix.

### 8.3 Required text (state it plainly; do not soften)
Shown on the vault page, the deposit confirmation and the withdraw screen:

> "Withdrawals depend on Pharaoh's contracts. The pool calls a Pharaoh reward contract every time liquidity is withdrawn. If that contract fails or is changed by Pharaoh, **all withdrawals from this vault, including withdrawing in both tokens, can be blocked until Pharaoh fixes it.** Peridot cannot unblock them. Only deposit what you can leave there for an unknown time."

The failure is silent on chain: `guardState()` reads 0 and deposits stay open while it lasts (section 3.1), which is why the exit probe hides deposits. Error-state variant (section 4.2): "Withdrawals are currently blocked on Pharaoh's side. Your funds are still in the vault; try again later."

## 9. Events to index

Vault events (from the interface; all emitted by the vault proxy):

| Event | Topic0 | Use |
| --- | --- | --- |
| `PharHarvested(address indexed token, uint256 amount, uint256 totalSupplyShares, uint256 totalAssets)` | `0x8da2a2ae...d17a111` | realised PHAR rate (5.2), harvest count, last harvest |
| `BandOpened(uint24 lowerId, uint24 upperId, uint24 activeId, uint256 amountX, uint256 amountY)` | `0xf5e14a5d...e17c75` | band history |
| `Rebalanced(uint24 oldLowerId, uint24 oldUpperId, uint24 newLowerId, uint24 newUpperId, uint24 activeId, bool swapXForY, uint256 swapIn, uint256 swapOut, uint256 navBefore, uint256 navAfter)` | `0x2cdd58f9...da7f6` | activity feed; `navAfter - navBefore` per re-centre is the realised cost of that move |
| `GuardTripped(address indexed by, uint256 reasons)` | `0x64787add...1d0cc` | banner history |
| `GuardCleared(address indexed by)` | `0x78636dab...e77645` | banner history |
| `GuardParamsSet(GuardParams params)` | `0x7b731eea...ab9346` | refresh `guardParams()` |
| `DepositCapSet(uint256 oldCap, uint256 newCap)` | `0x296bce53...7a167` | cap display |
| `RedeemedInKind(address indexed owner, address indexed receiver, uint256 shares, uint256 amountX, uint256 amountY)` | `0xad8daceaf...63f90` | in-kind exits |

Inherited, unverified until W2: ERC-4626 `Deposit` and `Withdraw`, ERC-20 `Transfer` (shares), `Paused`/`Unpaused`, the role-change event (R3 names it `RebalancerUpdated`), ownership events, and the proxy's `Upgraded` and the ProxyAdmin's `OwnershipTransferred` (an implementation upgrade is an immediate Safe action and the activity feed should surface it). Chain-event scans on a public endpoint must use 100-block chunks.

## 10. Not available and not to be implied

- A return forecast, an APY, an annualised or "projected" figure of any kind (rule 1).
- A guarantee of USDC withdrawal, of in-kind withdrawal (section 8.2), of any price range, or of any PHAR.
- A deposit above the cap, a cap change by the user, or a transfer of shares to another chain.
- A way to choose the band, the bins or the swap route.

## 11. Open questions for the main thread (the frontend cannot ship the final copy until these are answered)

1. Who receives PHAR: owner only, depositors, or a later distribution (section 5.1). Blocks the "earns PHAR" wording.
2. Per-event versus latest-event supply in the PHAR rate (section 5.2).
3. The on-chain source of the weekly emission numbers (section 5.3).
4. `mint`: spec lists it, R3 disables it (`maxMint = 0`).
5. Whether `maxDeposit` returns 0 when the guard is unsafe, latched or the vault is paused (the UI checks `guardState()` regardless).
6. ~~Whether deposits into an existing band are invested at once or sit idle~~: answered by W6, they sit idle until the next `openBand` or `rebalance` (section 3.2). Remaining: the probe holder address and who runs the probe server-side.
7. Share `decimals()` and the USDt address (read-backs after deploy).
8. Whether `convertToAssets` and `previewRedeem` revert when a feed reverts (assumed yes in this document).
