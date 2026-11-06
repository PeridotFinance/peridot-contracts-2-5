# Cash-only lending: deployment script and local-fork rehearsal

Status: DRAFT. A script and a rehearsal on a **local fork only**. Nothing was signed, broadcast or deployed to any network, no production value was chosen, the production PERIDOT token is **unresolved**, borrowing is paused in every configuration the script can produce, margin hooks stay unset. This is not a deployment authorization and implies no launch approval.

## Files
- `contracts/script/DeployAvalancheCashOnlyLending.s.sol`: `DeployAvalancheCashOnlyLending` (the script), `VerifyAvalancheCashOnlyLending` (read-only verifier) and the shared `CashOnlyLendingChecks`.
- `contracts/contracts/deployment/AvalancheMarketBootstrapper.sol`: single-use, atomic list + seed + pause for the two markets (mainnet mirror of the Fuji bootstrapper, chain id 43114; the Fuji one is chain-gated and cannot be used). A second use reverts; the seeding is in the same transaction as the listing, so an empty-market donation cannot be staged in between.
- `contracts/contracts/PeridottrollerAvalanche.sol`: the controller implementation with the optional borrow cash floor.
- `contracts/test/AvalancheCashOnlyDeployRehearsalFork.t.sol`: the rehearsal (12 tests).
- `contracts/test/AvalancheRewardTokenOptInFork.t.sol`: the opt-in no-reward-token constructor of the wrapper (8 tests).

## What the script deploys
Source oracle (`AvalanchePriceOracle`, owner = deployer) + `GuardedAvalanchePriceOracle` (the controller uses the GUARDED one, never the source oracle), `Unitroller` + `PeridottrollerAvalanche(PERIDOT_TOKEN)`, a `ConfigurableJumpRateModelV2`, one plain `PErc20Delegate`, two `PErc20Delegator` markets (pWAVAX, pUSDC) administered by the bootstrapper during the atomic step, seeded, then handed back to the deployer. It sets close factor, liquidation incentive, pause guardian, reserve factor, borrow caps and (optionally non-zero) borrow cash floors from explicit inputs. It then runs the verifier checks and reverts on any deviation.

It does **not**: set a collateral factor (they stay 0, so the deployment cannot lend), unpause borrowing, unpause pToken flash loans, deploy or reference any margin contract (both controller hooks stay `address(0)`), deploy or select a PERIDOT token, or hand administration to governance.

## Inputs: every operator decision is explicit, none has a default
`DEPLOYER` (broadcasting account = the operator's Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`; sign with `--ledger --sender` <that address>, never a raw key; the previous signer is not used), `PERIDOT_TOKEN` (must be an existing contract; the script never deploys or defaults one) together with `LENDING_ALLOW_NO_REWARD_TOKEN` (`true` or `false`, no default: `true` is the explicit choice to deploy WITHOUT a reward token and requires `PERIDOT_TOKEN` to be `address(0)`; `false` requires an existing contract; any other combination is refused), `PAUSE_GUARDIAN`, `LENDING_WAVAX_SEED_AMOUNT`, `LENDING_USDC_SEED_AMOUNT`, `LENDING_WAVAX_BORROW_CAP`, `LENDING_USDC_BORROW_CAP`, `LENDING_RESERVE_FACTOR`, `LENDING_CLOSE_FACTOR`, `LENDING_LIQUIDATION_INCENTIVE`, `LENDING_BLOCKS_PER_YEAR`, `LENDING_BASE_RATE_PER_YEAR`, `LENDING_MULTIPLIER_PER_YEAR`, `LENDING_JUMP_MULTIPLIER_PER_YEAR`, `LENDING_KINK`, `AVAX_FEED_MAX_AGE`, `USDC_FEED_MAX_AGE`, `LENDING_WAVAX_BORROW_CASH_FLOOR`, `LENDING_USDC_BORROW_CASH_FLOOR` (0 = disabled). An empty or missing variable makes the script revert (tested for all 20). Fixed in the script because they are facts of the chain, each re-checked on chain: native WAVAX (18 decimals) and native USDC (6), the Chainlink AVAX/USD and USDC/USD feeds (8 decimals, descriptions "AVAX / USD" and "USDC / USD", fresh within the given max age).

## Checks (run by the script at the end, by `VerifyAvalancheCashOnlyLending` any time, and by the tests)
Chain id 43114; controller admin == expected admin, no pending admin, implementation recorded with no pending implementation; the implementation's PERIDOT token and `getPeridotAddress()` equal the input; pause guardian, close factor, incentive as given; **both margin hooks unset**; controller oracle is the guarded oracle over the recorded source oracle, whose owner is the expected admin and whose feed configuration (address, max age, enabled) matches; both prices available; market admin == expected admin, no pending admin; underlyings; one plain delegate; controller and rate-model links; rate-model owner; 8 decimals; reserve factor; seeded; no borrows; both markets listed; **collateral factors zero**; **borrowing paused on both markets**; pToken flash loans paused; borrow caps; borrow cash floors.

## Rehearsal results (local fork, pinned block 99,200,000; 12 tests pass)
Happy path with the verifier and independent assertions; post-deploy behaviour (supply works, redeem works, a borrow reverts "borrow is paused" even after SYNTHETIC collateral factors are applied by the admin, a stranger can neither unpause nor change a floor); refusal without a PERIDOT token decision (zero address without the opt-in, address without code); the explicit no-reward-token opt-in deploys and verifies (borrowing paused, hooks unset, `claimPeridot` and `_grantPeridot` revert), and an opt-in flag together with a token address is refused as contradictory; refusal on a wrong chain id, zero seed, cap not above seed, reserve factor too high, close factor and incentive out of range, insufficient seed balance, stale feeds; the one env-driven test proves `run()` reads all 20 inputs and each empty variable stops it, and that the opt-in works and is refused in the two contradictory combinations through the environment; the verifier detects post-deploy tampering (borrowing unpaused, a collateral factor enabled, a margin hook installed, the controller pointed at the unguarded source oracle, a pending admin left behind, a changed floor, a changed borrow cap, a wrong expected admin); the single-use bootstrapper cannot be run twice; **the pause guardian** (see the runbook entry below): with `PAUSE_GUARDIAN` set to the Ledger, the Ledger pauses minting and borrowing on both markets (four calls, four `ActionPaused` events, read-backs, real reverts "mint is paused" / "borrow is paused"), repayment and redemption keep working while paused, and the Ledger as admin lifts a pause; a guardian that is a different account can pause but never unpause, and a stranger can do neither. Two mutants (guardian may unpause; mint pause not stored) are each caught. The rehearsal's PERIDOT stand-in (`TestOnlyPeridotTokenStandIn`) exists only inside the test file and is labelled; it is not a proposal. All rehearsal values are SYNTHETIC.

## Not done / limits
- The "market touched before bootstrap" refusal is inherited from the Fuji bootstrapper design and is NOT separately tested here.
- No gas or transaction-count figures for a real broadcast; no dry run against a live node other than the pinned fork.
- The administration handover to governance/timelock is a separate step that is neither scripted nor rehearsed; the verifier supports checking it (`EXPECTED_ADMIN`).
- Collateral factors, unpausing borrowing and any parameter values remain operator decisions; the production PERIDOT-token decision remains open (candidates: an existing token, a purpose-built token, or a deliberately inert token; the script supports any contract and picks none).
- Not audited.

## Signer and admin (updated 2026-11-05)
The operator reported that the previous signer may be compromised and moved control to a Ledger, address `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` (an account with no contract code on Avalanche C-Chain; checked read-only). Nothing in this repository signs or sends transactions, and nothing here used the previous signer. Consequences for this deployment path: `DEPLOYER` is the Ledger address and is the initial admin/owner (controller, both markets, source oracle, rate model); the verifier's `EXPECTED_ADMIN` is the same address; a later handover to a timelock or multisig is a separate, verified step. The rehearsal test now runs the script as the Ledger address inside the forge VM only.
**On-chain state checked read-only on 2026-11-05 (block 99,497,425), for the already-deployed Pharaoh vaults:** the vaults' Safe `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` now has the Ledger as its only owner (threshold 1; the previous signer is no longer an owner); both ProxyAdmins and both vaults are owned by that Safe. At that block the `rebalancer` role of both vaults (`0x855bF832...` and `0xe9a53f00...`) was still the previous signer.

**Update, read-only, tip block 99,507,199 (2026-11-05): the rebalancer role has since been moved to the Ledger by the operator, not by this work.** Both vaults now return `rebalancer() = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`. Found by bisection of `rebalancer()` over the blocks 99,497,500 to 99,507,199, then confirmed from the transactions: the Ledger called the Safe's `execTransaction` twice, each executing `setRebalancer(0x064e...B2dD)` (selector `0x6cfd1553`) on one vault; both succeeded.

| Vault | Block | Transaction |
|---|---|---|
| USDC vault `0x855bF832f26a294d28500db59eE941dE3d654129` | 99,499,274 | `0xb504b7351705b960ef22aceda96ed8a094754b5a9ef5e2ea521621383b334d3d` |
| WAVAX vault `0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8` | 99,499,277 | `0x7f3ae03b873efcb52e964f0618fc0ed835a5168ba54dd3ec5dcb36d6ea860e79` |

Read-back at the tip: Safe `0x80f4...dfB12` version 1.4.1, owners = [Ledger], threshold 1, nonce 12; both vaults' `owner()` = the Safe; both `rebalancer()` = the Ledger. Nothing in this repository signed or sent any of it. The previous signer therefore holds no role on either vault and is no longer an owner of the Safe. The Safe is still 1-of-1 (a single Ledger is a single point of failure and of loss; adding a second owner and raising the threshold is the operator's decision and was not done).
Read-back commands (read-only): `cast call <vault> 'rebalancer()(address)'`, `cast call <vault> 'owner()(address)'`, `cast call 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12 'getOwners()(address[])'` and `'getThreshold()(uint256)'`.

## Runbook: pause minting and borrowing from the Ledger (added 2026-11-06)
**Purpose.** Stop new supply (minting) and new debt (borrowing) on both markets fast, without touching exits. **Who.** The Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD` can do it in two ways: as the controller **admin** (deployer; also the only account that can UNPAUSE) and, if the deployment was run with `PAUSE_GUARDIAN` = the Ledger address, as the **pause guardian**. The script takes `PAUSE_GUARDIAN` as an explicit input; setting it to the Ledger is a deployment-time decision (the rehearsal covers both a Ledger guardian and a different guardian). A guardian that is not the admin can only pause. This is written for a deployment that does not exist yet; every address below is a placeholder from the deployment output. Nothing here was signed or sent.

**Inputs (from the deployment output / verifier):** `UNITROLLER` (the controller proxy; every call goes to it), `PWAVAX`, `PUSDC`.

**0. Before (read-only).**
- `cast call $UNITROLLER 'admin()(address)'` must be the Ledger; `cast call $UNITROLLER 'pauseGuardian()(address)'` is the Ledger or the configured guardian.
- Current state: `cast call $UNITROLLER 'mintGuardianPaused(address)(bool)' $PWAVAX` (and `$PUSDC`), and the same with `borrowGuardianPaused(address)(bool)`. A fresh deployment reports borrowing paused and minting NOT paused.
- The Ledger holds AVAX for gas (each call is one transaction).

**1. The calls (four transactions, each from the Ledger, each to `$UNITROLLER`):**

| # | Function | Selector | Arguments |
|---|---|---|---|
| 1 | `_setMintPaused(address,bool)` | `0x3bcf7ec1` | `$PWAVAX`, `true` |
| 2 | `_setMintPaused(address,bool)` | `0x3bcf7ec1` | `$PUSDC`, `true` |
| 3 | `_setBorrowPaused(address,bool)` | `0x18c882a5` | `$PWAVAX`, `true` |
| 4 | `_setBorrowPaused(address,bool)` | `0x18c882a5` | `$PUSDC`, `true` |

Hardware-wallet form (the operator runs it; one line per call): `cast send --ledger --from 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD --rpc-url avalanche_rpc $UNITROLLER '_setMintPaused(address,bool)' $PWAVAX true` and so on (`avalanche_rpc` is the operator's own endpoint alias; never put a keyed URL in a command line or a log). Order does not matter; if only borrowing is the emergency, do 3 and 4 first. Each call returns `true` and emits `ActionPaused(pToken, "Mint" | "Borrow", true)`.

**2. Read-backs (read-only), all must be `true`:** `cast call $UNITROLLER 'mintGuardianPaused(address)(bool)' $PWAVAX`, same for `$PUSDC`, and `borrowGuardianPaused(address)(bool)` for both. Optionally confirm the effect with a **simulation** (`cast call --from <any funded account> $PUSDC 'mint(uint256)(uint256)' 1000000` reverts with "mint is paused"; `borrow(uint256)` reverts with "borrow is paused").

**3. What stays open (tested):** repayment and redemption work while paused; ordinary liquidation is not affected by these two pauses (the separate `_setSeizePaused` / `_setTransferPaused` switches were NOT used and are not part of this entry).

**4. Lifting a pause** is admin-only (the Ledger): `_setMintPaused(market,false)` / `_setBorrowPaused(market,false)`. A pause guardian that is not the admin cannot do it ("only admin can unpause"). Unpausing borrowing is a risk decision tied to the pilot's caps and inventory, not a routine step.

**5. If the Ledger is unavailable:** nobody else can pause unless a different `PAUSE_GUARDIAN` was configured at deployment (then that account can pause but not unpause). This is a reason to decide the guardian input deliberately; the Safe on the Pharaoh vaults (1-of-1) does not control these lending markets.

**Test evidence:** `AvalancheCashOnlyDeployRehearsalForkTest`: `testRehearsal_Ledger_AsAdminAndGuardian_PausesMintAndBorrow_OnBothMarkets_ReadBacksAndEffects`, `testRehearsal_DistinctGuardian_CanPauseNeverUnpause_Stranger_Neither_LedgerAdminUnpauses` (12/12 on the pinned fork).
