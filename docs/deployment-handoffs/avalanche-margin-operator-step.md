# Margin 2x: the operators' margin step and the monitor's margin classifier (R-B) and the mutation checks (R-C)

Status: **BUILT AND REHEARSED ON A FORK OF THE LIVE HEAD, NOT RUN ON MAINNET.** Nothing here signs or sends anything on mainnet. Host configuration: `avalanche-pilot-host-setup.md` section 6. Ceremony: `avalanche-margin-ceremony.md`. Evidence: `avalanche-margin-evidence/rehearse-margin-pipeline-run6.txt` (and `.json`), `margin-mutation-check-run1.txt`.

## 1. Why the lending machinery needed to change

A margin position is a borrower of the **same pUSDC market** as lending, held in its own `IsolatedMarginAccount`. Through the lending lens (the controller's collateral factors) such an account is *always* in shortfall. Without a classification:

- the monitor raised "liquidatable, fully recoverable" for every margin account all the time, counted it in the treasury figures and could have put it in front of the **treasury keeper** (the only component that pays);
- the lending executor tried `liquidateBorrow` on it every cycle: an approve, a failing simulation (the controller refuses these accounts), a reset.

The mutation runs below show both effects with the classifier switched off (`classified 0`, `LIQUIDATABLE_RECOVERABLE` for the margin account, nonce 0 -> 2).

**The classifier is the controller's own flag** `isolatedMarginAccounts(address)`, the same one it uses to refuse `liquidateBorrow` and `seize`. It needs no configuration, is read at the snapshot block, and **fails closed** (an unreadable flag excludes the account from the lending checks and is reported). Margin accounts leave the lending verdicts, the treasury figures, the keeper's input and the lending executor's candidates; they **stay in the borrow-shares sum** (they hold pUSDC borrow shares). They are reported as `report.margin.positions`.

## 2. What the monitor now says about margin (`src/margin.ts`, `src/monitor.ts`)

Positions are read with `nextPositionId` and `positions(i)` (no `eth_getLogs`), valued by the risk engine's own `getMetrics` / `isLiquidatable`.

| Verdict | Meaning | Finding |
| --- | --- | --- |
| HEALTHY | above maintenance and above the watch level (default health 130%) | none |
| WATCH | approaching liquidation | warn, monitor-operator |
| LIQUIDATABLE | below maintenance, collateral covers debt | warn, **liquidators** (the funded operators act) |
| INSOLVENT | equity <= 0: collateral no longer covers the debt | **crit, escalating, treasury-signers: a human decision.** The operators' break-even floor declines it, the debt stays in the pUSDC market, the insurance fund is not used by the funded route (decision D3) |
| UNPRICED | the risk engine reverted (stale or unreadable price) | warn |
| STUCK | transient status (opening/closing/liquidating) at a block boundary | crit |

Also: an active position whose account the controller does **not** flag (crit), the controller's risk hook differing from the configured engine (crit), an operator that is not a funded liquidator (warn), margin accounts existing while the margin block is not enabled (warn). The margin deficit is added to the **unrecoverable-debt** figure; an unvaluable margin position makes that figure INCOMPLETE. The existing operator inventory check (0.75 x aggregate pUSDC debt) already counts the margin debt.

**Margin is never payable by the keeper.** The keeper reads `report.accounts`, from which margin accounts are removed; the rehearsal runs `keeperStep` against the reports of -35% and -55% with a signer that refuses to send: paid 0, sent 0.

## 3. The operator's margin step (`src/executor.ts`, same process, wallet and keystore)

Per cycle, before the lending accounts, at most one round per step:

1. Drift checks: the liquidator's `riskEngine()` and `config()` equal the configured addresses (else **halt**, no allowance); this operator is on the funded-liquidator allowlist (else skip and warn).
2. Positions below maintenance, largest debt first. INSOLVENT ones are **declined without sending anything** (critical alert, cooldown); this is the pre-filter, and the on-chain floor is the second layer.
3. Allowance **bounded, not exact** (the risk engine, not the wallet, chooses the repayment): `min(inventory, daily-cap remaining, per-call cap, debt + 10 bp)`, approved to the liquidator proxy, reset to 0 in every outcome. The contract refuses a larger repayment (LiquidationError 28).
4. Simulate `liquidateFunded(positionId, recipient = operator, maxRepay, 0, 0, minSeizeValueBps = 10,000)`. Code 32 = declined by the break-even floor; 28 = the wanted repayment exceeds the bound (alert which bound); 27 = not a funder.
5. Send; read back from the receipt: `FundedPositionLiquidated` names this operator as funder and recipient, USDC left == `debtRepaid` <= the bound, the seized pTokens arrived. Any mismatch **halts** the executor.
6. Seized margin pTokens (if any) are redeemed (exactly what arrived); the seized pWAVAX is redeemed and sold by the **existing** conversion (Uniswap 0.05% pool, revert-protected minimum, no fallback route).

`pending` (stage `margin`) is persisted before the first transaction; one found at start HALTS the executor. Pilot caps in the template: 1,500 USDC per call, 2,500 USDC per rolling 24 h per operator; `minSeizeValueBps` is a constant, not configuration.

## 4. Rehearsal (run 6: 50 of 50 checks, 5 of 5 mutations caught)

On a fork of the live head (block ~99.67M), real PW30 and margin stacks deployed by the real ceremony wrappers, the two operators are throwaway keystores that are the stack's funded liquidators, AVAX/USD Chainlink replaced by a settable mock on the fork.

| Scenario | Result |
| --- | --- |
| S0 healthy | `classified 1`; position HEALTHY (health 201.7%); margin account absent from the lending list; the lending borrower still evaluated; no lending finding names the margin account; **the executor sends no transaction** |
| S1 -35% | monitor: LIQUIDATABLE, warn to liquidators, no treasury finding; keeper pays 0; op-a repays **1,225.25 USDC**, receives 1,263,799,923,690 pWAVAX units, redeems and converts (6 transactions: approve, liquidateFunded, reset, redeem, router approve, swap); debt halves; allowance 0; no pWAVAX/WAVAX left; op-b finds the position back above maintenance and does nothing. *The oracle moved, the real pool did not, so the sale paid 1,977 USDC: the operator gains here; in a real fall the pool follows and the bonus is the margin (measured separately in the Foundry suite: bonus 4.98%).* |
| S2 -55% | INSOLVENT, crit escalating to the treasury signers, deficit in the unrecoverable-debt figure; keeper pays 0; op-a **declines with no transaction**, debt untouched |
| S2b -55%, pre-filter removed | the simulation reverts with LiquidationError 32; only the approve and the reset are sent; decline cooldown recorded |
| S3a per-call bound 100 | the contract refuses the larger repayment, debt untouched, allowance 0, alert |
| S3b daily cap 1,300 | first round 1,225; the second attempt is refused (remaining 75) |
| S4 op-c not a funder | no transaction, warn; the monitor warns `margin:not-funder:op-c` |
| S5 stops | an interrupted `margin` step halts at start with no transaction; a drifted liquidator halts before any allowance; the monitor raises the hook-drift critical |
| S6 lending next to margin | the margin position goes first; the next step liquidates the fragile lending borrower; the lending path is unchanged |

**Mutations (each is a deliberately broken rule that a scenario must catch):**

| Mutation | Caught by | How |
| --- | --- | --- |
| monitor classifier off | S0 | `classified 0`; the margin account appears as LIQUIDATABLE_RECOVERABLE and in a lending finding |
| executor classifier off | S0 | the lending executor sends an approve and a reset for the margin account (nonce 0 -> 2) |
| insolvent pre-filter **and** break-even floor off | S2 | op-a liquidates the insolvent position (debt 2,450 -> 0) |
| per-call allowance bound off | S3a | repays 1,225 against a 100 bound |
| daily cap off | S3b | second round repays 612 against a 75 remainder |

## 5. What the rehearsal found (all fixed, in the evidence)

1. **A full liquidation could never go through.** `maxRepayUnderlying` was the debt read *before* the call; interest accrues over the blocks before it lands, so the contract's repayment came out a few units higher and was refused (LiquidationError 28). The debt bound now carries a **10 bp margin** (the keeper's own `allowanceMarginBp`). Unit test pins it.
2. A first mutation run counted crashed scenarios as "detected". Now a crashed scenario is **inconclusive and fails the rehearsal**.
3. The per-call bound mutation was masked by the daily cap binding first (both were 100); the scenario now isolates each bound.
4. The fork's first log scan went upstream (free-tier `eth_getLogs` limit); the rehearsal scans local blocks only (on mainnet the live processes read logs from a SEPARATE log endpoint, default the Avalanche public RPC with 2,048 blocks per request; the start-up probe of that endpoint is a warning, not a refusal).
5. Behaviour kept as designed and worth knowing: with the oracle moved but the TWAP not, the treasury rule says PRICE_DIVERGENCE for lending accounts (nothing is paid); the liquidator executor is not gated by it.

## 6. Limits

- Fork only. The read-back mutation (a liquidator that lies in its event) cannot be reproduced without a tampered contract and is covered by unit-level reasoning only: the check compares three independent sources (event, USDC balance, pToken balance).
- The oracle-only shock favours the operator (it sells at the unshocked pool). The cost side of a real fall is the Foundry measurement (bonus 4.98%, insolvent -55%: operator loss about USD 225 **if it ignored the floor**, which the executor cannot).
- The conversion into USDC runs into the Uniswap 0.05% pool, whose depth was not re-measured here.
- Contract-side mutations (adapter guards, ceremony script wiring, pinned pair-risk constants): `margin-mutation-check-run1.txt` (section 7).

## 7. Contract and script mutations (`contracts/tools/margin-mutation-check.py`)

Each mutant is one exact text replacement; the harness runs the tests that own the rule on a **pinned fork block** (99,833,032), after checking that they pass unmutated, and restores the source byte-exact. **17 mutants, 17 killed, none survived, none invalid** (`avalanche-margin-evidence/margin-mutation-check-run1.txt`). Full suite on the same block: **22 of 22** (`rehearsal-fork-suite-run2-pin-99833032.txt`).

| Id | Mutation | Killed by |
| --- | --- | --- |
| A1 | adapter: owner check removed | `test_06e` |
| A2 | adapter: price equality removed | `test_06e` |
| A3 | adapter: order slippage no longer clamped to the pair's 100 bp | `test_06f` |
| A4 / A4b | adapter: long-only guard removed in `closeFor` / in `isActive` | `test_06e` |
| A5 | adapter: minimum no longer floored at debt plus flash fee | `test_06g` |
| A6 | adapter: registry-only check removed | `test_06e` |
| A7 | adapter: `adapterData` must-be-empty removed | `test_06e` |
| A8 | adapter: order slippage cap of 300 bp removed | `test_06e` |
| W1 | script: flash vault fee not set to 0 | `test_02_wire`, `test_03` |
| W2 | script: controller risk hook not the risk engine | `test_02_wire`, `test_03` |
| W3 | script: only the first operator becomes a funded liquidator | `test_02_wire`, `test_05` |
| W4 / W5 / W6 | script: maintenance 25%, position cap USD 5,000, slippage 100 bp changed | `test_02c` |
| W7 | script: no refusal when WAVAX borrowing is unpaused (long only) | `test_01b` |
| W8 | script: no refusal when the deployer is the Ledger | `test_01b` |

**What this found before it passed:** the adapter's owner, price-equality, registry-only, long-only and `adapterData` guards were **not reachable by any order-level test** (the registry only passes consistent inputs), and the pair-risk constants were checked only against themselves (the script's `verify` compares the chain with the same constants). Added `test_06e` (direct calls as the registry, a mocked short), `test_06f`/`test_06g` (exact minimum handed to the close path), and `test_02c` (the user's decisions as literals).

**Pool depth is not stable between heads** (the suite follows the head unless pinned): the same suite measured the sell side at USD 182k / 554k / 777k for -1% / -5% / -10% at block 99,670,362 and 106k / 207k / 231k at block 99,832,856 (AVAX about 5% lower). `test_06b` therefore asserts the invariant (the stop-loss fills and cancels its sibling, or stays open) and logs which one happened; at the later block it stays open (`DEPTH WALL`). Run the suite pinned for evidence and at the head on the day of the ceremony.
