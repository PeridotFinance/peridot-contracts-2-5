# Cash-only pilot: operator liquidation and monitoring build plan, and audit scope

Status: DRAFT for the operator's confirmation. **Nothing in section 1-3 has been started**: no operator, monitor or Safe-tooling code exists. The build starts only after the operator confirms the audit scope (section 4). No merge, deployment, signing, broadcast, cap change or edit to either handoff 00; no launch approval is implied. Pilot configuration being planned for (operator's decision of this checkpoint): **PW30**, WAVAX CF 30%, USDC CF 0%, WAVAX borrowing disabled, USDC research borrow cap USD 5,000, protection capital sized to the -75% tail (USD 1,191), **two** liquidator operators at the no-recycling inventory (at least USD 3,750, target USD 4,440 each). Operators and treasury funding are **not committed**; the figures are requirements.

## 1. What is specified today (source of truth) and what is to be built

| Component | Specified in | Today |
|---|---|---|
| **Operator liquidation** (find liquidatable accounts, repay up to the close factor from own USDC inventory, redeem seized pWAVAX, convert WAVAX to USDC, keep inventory) | `avalanche-cash-only-liquidation-cycle.md` (cycle tests, routes, inventory rule), `avalanche-operating-cost-estimate.md` | Behaviour proven in fork tests only (8 cycle + 38 route tests). **No operator software.** |
| **Monitoring** (default detection with the reference price, oracle freshness, market health, operator inventory, escalation timers) | `avalanche-cash-only-treasury-repayment.md` section 2 (rule, truth table, reference-price spec), `avalanche-cash-only-pilot-qualification.md` | Reference rule exists only as the test helper `TreasuryDefaultDetector`. **No monitor.** |
| **Treasury repay tooling** (prepare, simulate and read back the Safe transaction for `repayBorrowBehalf`; never sign) | same treasury document, sections 3-4 | Procedure and tests only. **No tooling.** |

**No new contract is planned.** An operator liquidates with its own USDC inventory by calling the existing `liquidateBorrow` and swapping on an existing pool. An atomic or flash-funded liquidator contract would be a new audit item; the no-recycling inventory rule exists precisely so that none is needed. If the operator later wants one, it is a separate scope decision.

## 2. Design (small, off-chain, read-only by default)

Stack: **TypeScript on the repository's existing Node toolchain** (ethers v5 is already a dependency of the root package; `contracts/tools/fuji-liquidation-runner.cjs`, 959 lines plus 656 lines of tests, is the nearest precedent for a transaction runner with a request gate, simulation proxy and journal). New package `operator/` with its own lockfile, so the key-holding process has a small, pinned dependency set. Library choice (ethers v5 versus viem) is a minor open point; default ethers v5 for consistency.

1. **Chain reader / borrower index.** Incremental event scan of the pUSDC market (`Borrow`, `RepayBorrow`, `LiquidateBorrow`) from the deployment block, cursor persisted, reorg margin of a few blocks. The borrower mapping is not enumerable on chain, so events are the source of truth; a periodic full re-scan cross-checks the index.
2. **Health scanner.** Batched `eth_call` (multicall) of `getAccountLiquidity` per indexed borrower at one block; candidates sorted by shortfall.
3. **Executor (per operator, separate key and inventory).** For a candidate: amount = min(close factor x debt, inventory, collateral-limited maximum with the 0.2% margin used in the tests); simulate with `eth_call`; send `liquidateBorrow(borrower, amount, pWAVAX)`; read back; redeem the seized pWAVAX; convert WAVAX to USDC on **Uniswap V3 0.05%** with a minimum-out derived from the Chainlink price and a fixed slippage bound; **a min-out block with no fallback stops conversion and alerts** (the tested behaviour, no silent second route). Bounded allowances (exact needs, not unlimited). AVAX gas balance check before every action.
4. **Monitor (read-only, no key).** (a) the default-detection rule of the treasury document including the **reference-price check** (Uniswap V3 0.05% 30-minute TWAP, tolerance and fail-closed behaviour of treasury document section 2.3); (b) oracle health: AVAX round age against the 1,200 s guard and USDC age against 90,000 s, with alerts well inside those limits; (c) market health: utilisation, cash against the 20% floor, borrow-cap use, reserves, exchange-rate monotonicity, `totalBorrowShares` consistency; (d) operator health: each operator's USDC inventory against 0.75 x aggregate debt, AVAX gas, last-action heartbeat; (e) treasury health: protection-capital balance, approved allowance, pending Safe transactions; (f) escalation timers 1 h / 4 h / 24 h (proposals) with de-duplicated alerts through the existing Telegram bot.
5. **Treasury tooling (no key).** Generates the exact Safe transaction (calldata, `approve` plus `repayBorrowBehalf(borrower, type(uint256).max)` as a batch or two transactions), simulates it through the real Safe contract on a fork, prints the expected post-state and the read-back commands. It never signs or broadcasts; the Ledger holder executes.
6. **Configuration and secrets.** Addresses and parameters from a checked-in schema; RPC URL and signer settings only from the environment; the operator's signer is an external signer (hardware or KMS), never a key file in the repository; logs and headers mask the endpoint (the masking utility of `tools/avalanche-redact-rpc.py` is the model).

## 3. Work breakdown and size (judgment, not measurement)

Basis: the nearest existing artifacts (Fuji runner 959 + 656 test lines; `TreasuryDefaultDetector` about 100 lines of Solidity with 14 tests), and the behaviour already pinned by the fork suites. Lines are TypeScript including tests. Engineer-days are a human-equivalent range for one engineer; they are **estimates with no track record behind them**.

| # | Piece | Lines (code + tests) | Engineer-days |
|---|---|---|---|
| 1 | Chain reader and borrower index | 250 + 150 | 2-3 |
| 2 | Health scanner | 150 + 100 | 1-2 |
| 3 | Executor: liquidate, redeem, convert, inventory, allowances | 500 + 350 | 5-7 |
| 4 | Signer abstraction (hardware/KMS), nonce and gas handling | 150 + 100 | 2-3 |
| 5 | Monitor: detection rule + reference price + health checks + alerting | 1,200 + 600 | 8-12 |
| 6 | Treasury Safe-transaction tooling and simulation | 300 + 250 | 3-4 |
| 7 | Fork integration tests replaying the existing scenarios (cycle, outage, truth table, stale and zero price, min-out block) | 600 | 6-8 |
| 8 | Packaging, configuration schema, runbook, CI | 200 | 3-4 |
| 9 | Review and hardening of the signing and transaction paths | n/a | 4-6 |
| | **Total** (about 2,750 code, 2,150 tests) | **about 4,900** | **34-49** |

With the code written by an agent and the signing, allowance and transaction-building paths reviewed by a person, the realistic constraint is review, not typing: plan about 3-4 weeks of calendar time. That is a planning figure, not a commitment.

**Order (each step is useful alone and adds no key before it must):** (1) monitor and detection rule, read-only; (2) treasury tooling, no key; (3) executor on a fork against mocked feeds, reproducing the cycle suite; (4) only then, a decision on a live dry run with a minimal inventory, which is a separate approval and is not part of this plan.

**Needed from the operator before step 3:** who the two operators are and who holds each key; the signer type; the RPC provider and its limits (a private endpoint is advisable for the executor; reads can use more than one); the alert channel; the exact slippage bound.

**Acceptance criteria (tested, not asserted):** the monitor reproduces the treasury truth table verdicts on the fork; fails closed when the reference price is missing, stale or divergent; the executor clears the cycle scenarios of the cycle document within the stated inventory, stops on a min-out block, and refuses to act on a stale or zero price; the tooling's simulated Safe transaction leaves the expected post-state and nothing else changed.

## 4. Audit scope: exactly which contracts and diffs

Baseline: **`main` at the merge-base `603e26f3`**, treated as the audited baseline. **I have not seen the audit report(s); which commit the existing audit covers is an open question for the operator and the auditor.** If an earlier commit was audited, the diff below is larger. All sizes are `git diff 603e26f3` of the working tree (added / removed lines). The commit to audit is frozen only after the operator confirms this scope; the deploy path is `contracts/script/DeployAvalancheCashOnlyLending.s.sol`.

### 4.1 In scope: code that the pilot deployment actually executes

| File | Status vs main | Lines +/- | Why it matters |
|---|---|---|---|
| `contracts/PeridottrollerAvalanche.sol` | new | +92 | borrow cash floor (ERC-7201 namespaced slot, checked after the original `borrowAllowed`), chain-id gate, opt-in no-reward-token constructor |
| `contracts/Peridottroller.sol` | modified | +92 / -13 | `borrowAllowed` made `public virtual`; **isolated-margin hook branches in redeem, borrow, transfer, liquidate and seize, and the margin registrar functions**: inert while the hook and registrar are unset and no account is registered, but they are deployed bytecode |
| `contracts/PeridottrollerStorage.sol` | modified | +10 | `PeridottrollerV8Storage` (append-only margin fields); layout checked by `tools/check-controller-storage-layout.sh` |
| `contracts/PToken.sol` | modified | +102 / -1 | **unified borrow accounting (shares) enabled for every new market**, delegatecall to the module, migration entry point, repay and accrual paths |
| `contracts/BorrowAccounting.sol` | new | +21 | library state for the shares |
| `contracts/BorrowAccountingModule.sol` | new | +109 | shares arithmetic, activation, rounding reconciliation |
| `contracts/PErc20.sol` | modified | +3 / -3 | `virtual` keywords only |
| `contracts/PErc20Delegate.sol` | modified | +7 / -3 | `_becomeImplementation` can migrate legacy borrow accounting when data is supplied (unused by a fresh deployment) |
| `contracts/ConfigurableJumpRateModelV2.sol` | new | +110 | the pilot's rate model |
| `contracts/margin/AvalanchePriceOracle.sol` | new | +122 | source oracle over Chainlink feeds (lives under `margin/` but is the lending oracle) |
| `contracts/margin/GuardedAvalanchePriceOracle.sol` | new | +76 | the oracle the controller uses: returns 0 (fail closed) for a stale (AVAX 1,200 s, USDC 90,000 s), zero, negative, future-dated, reverting or malformed round. **It has no peg guard** (USDC is priced from its own feed, not assumed 1.00), **does not check aggregator min/max answer clamps**, and trusts the source owner's feed address and `maxAge` (stated in its own NatSpec); all three are points for the auditor |
| `contracts/deployment/AvalancheMarketBootstrapper.sol` | new | +156 | atomic list + seed + pause of the two markets, single-use |
| `script/DeployAvalancheCashOnlyLending.s.sol` | new | +323 | deployment script, read-only verifier and shared checks (deployment-correctness review rather than a contract audit) |

Total: about **900 added contract lines** in 12 files plus the 323-line script. The largest and newest items are the borrow-accounting module with its `PToken` integration, the oracle pair and the controller.

Unchanged versus main and deployed in the pilot (named so the auditor can confirm their status): `Unitroller.sol`, `PErc20Delegator.sol`, `PTokenInterfaces.sol`, `InterestRateModel.sol`, `ErrorReporter.sol`.

### 4.2 Out of scope for this audit (not executed by a cash-only deployment)
The isolated-margin stack (`contracts/margin/*` other than the two oracle files), the boosted and Pharaoh delegates and adapters, the Robinhood and Fuji files, `PharaohVaultShareOracle.sol`, and the removed Pancake, Folks and Vai files. Margin trading stays paused and its hooks unset; its branches inside `Peridottroller.sol` are in scope only as inert code (4.1).

### 4.3 Scope decisions the operator may want to weigh
1. **Inert margin branches in the controller.** Keeping them keeps one controller bytecode for all products and audits them once; removing them would be a different, smaller controller and a new diff to review. No change proposed.
2. **PERIDOT wrapper.** The opt-in constructor argument is a reviewable diff (section 4.1, first row), 10 lines in the constructor path, covered by 8 fork tests, mutation-checked; **not merged**.
3. **Reference-price and operator software** are off-chain: not audited as contracts. A security review of the key-handling and transaction-building code (steps 3 and 4 of section 2) is recommended before any live key is used.

### 4.4 Evidence the auditor receives
Fork suites (gate: `tools/run-avalanche-section5-gate.sh`), the deployment rehearsal (10 tests), storage-layout checks, the mutation records in the loss-handling and treasury documents, and the reproduction record (`avalanche-cold-repro/`) (the routes suite was reproduced cold once on a private archive RPC, 38/38; on the public endpoint it fails on HTTP 429).
