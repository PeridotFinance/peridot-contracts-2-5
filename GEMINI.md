# GEMINI KNOWLEDGE BASE

> **Purpose**: This document gives Google **Gemini** (or any LLM agent) the high–level context it needs to answer questions about _Peridot Protocol V2_. Keep it updated whenever the codebase changes significantly.

---

## 1 Project at a Glance

| Item                 | Value                                                                       |
| -------------------- | --------------------------------------------------------------------------- |
| **Name**             | **Peridot Protocol V2**                                                     |
| **Type**             | Decentralised money–market (Compound-style) with cross-chain extensions     |
| **Languages**        | Solidity ^0.8.20 (smart-contracts), JavaScript/TypeScript (Hardhat helpers) |
| **Frameworks/Tools** | Foundry, Hardhat, OpenZeppelin, Chainlink CCIP/Data Feeds/VRF               |
| **Repo root**        | `.`                                                                         |
| **License**          | MIT (MIT → in LICENSE) + some BSD-3 SPDX headers                            |

### Value Proposition

1. Classic lending/borrowing core (forked & modernised Compound).
2. Cross-chain liquidity via **Chainlink CCIP**.
3. Tamper-proof prices via **Chainlink Data Feeds**.
4. MEV-resistant VRF liquidations.

---

## 2 Directory Map

```
.
├── contracts/         # 💾 All on-chain logic
│   ├── *core*         # PToken, Peridottroller, Unitroller, Interest models
│   ├── *oracle*       # SimplePriceOracle, FeedsPriceOracle, PluginDirectOracle, etc.
│   ├── *governance*   # GovernorAlpha, Timelock (if added later)
│   ├── Lens/          # Read-only helper views
│   └── interfaces/    # Solidity interfaces shared across modules
├── script/            # 🛠  Foundry broadcast & helper scripts (deployment, config, upgrade)
├── test/              # ✅ Forge unit & integration tests
├── docs/              # 📚 Long-form technical explanations & research
├── out/               # Build artifacts (autogen – git-ignored)
├── broadcast/         # Deployed tx bundles (autogen by `forge script --broadcast`)
├── cache*/            # Foundry caches (autogen)
├── node_modules/      # JS deps (autogen)
├── *.md               # Misc spec & planning docs (README, Technical_Architecture, etc.)
└── foundry.toml       # Foundry project config
```

> **Tip for Gemini**: treat `contracts/` as source-of-truth; everything else supports it.

---

## 3 Key Solidity Components

| Contract                                   | Location     | TL;DR                                                                      |
| ------------------------------------------ | ------------ | -------------------------------------------------------------------------- |
| `Peridottroller.sol`                       | `contracts/` | Risk engine & admin; mirrors Compound's **Comptroller** with extensions.   |
| `Unitroller.sol`                           | `contracts/` | Proxy for upgradeability (delegate-call to Peridottroller implementation). |
| `PToken.sol`                               | `contracts/` | Abstract interest-bearing token (ERC-20 wrapper).                          |
| `PErc20.sol / PEther.sol`                  | `contracts/` | Concrete PTokens for ERC-20 assets vs native ETH.                          |
| `PErc20Immutable.sol`                      | `contracts/` | Gas-optimised non-delegatable variant (immutable params).                  |
| `PErc20Delegator.sol / PErc20Delegate.sol` | `contracts/` | Classic delegate proxy pair (Compound-style).                              |
| `JumpRateModelV2.sol`                      | `contracts/` | Interest rate curve (kink model).                                          |
| `SimplePriceOracle.sol`                    | `contracts/` | Manual admin-set prices (testing).                                         |
| `FeedsPriceOracle.sol`                     | `contracts/` | Production oracle – pulls Chainlink feeds.                                 |
| `FlashLoanExample.sol`                     | `contracts/` | Example of built-in flash-loan logic.                                      |

Auxiliary libraries: `SafeMath`, `ExponentialNoError`, `ErrorReporter`.

---

## 4 Deployment & Configuration Flow

Deployment is orchestrated via **Foundry scripts** under `script/`. Each script can be broadcast to chain (`forge script <script> --rpc-url <RPC> --private-key <PK> --broadcast`).

1. **Oracle** – `DeploySimplePriceOracle.s.sol` or `DeployFeedsPriceOracle.s.sol`.
2. **Core Controller** – `DeployPeridottroller.s.sol` → yields `Unitroller` + `Peridottroller`.
3. **Markets**
   - ERC-20: `DeployPErc20.s.sol` or specialised variants like `DeployPTokenWithOptimizedReserves.s.sol` (sets an 8 % reserve factor for higher supplier APY).
   - Native ETH: `DeployPEther.s.sol`.
4. **Market Support** – `SupportMarket.s.sol` (calls `_supportMarket` on the controller).
5. **Oracle Wiring / Factors** – e.g. `ConfigureSimplePriceOracle.s.sol` or CCIP scripts.
6. **Upgrades** – `UpgradePErc20Delegate.s.sol` for delegate-call implementations.

> For placeholders like `0x...` inside scripts, replace with actual deployed addresses before broadcasting.

### Environment Variables

```
PRIVATE_KEY        # EOA that pays gas
<CHAIN>_RPC_URL    # each network RPC endpoint (Sepolia, Fuji, …)
ETHERSCAN_API_KEY  # optional for verify
```

`forge script` will read them via `vm.envUint/string`.

---

## 5 Testing

- **Unit tests** live in `test/` and are executed with `forge test`.
- Key suites:
  - `SimplePriceOracleTest.sol`
  - `FlashLoanTest.sol`
- CI locally: `forge test -vvv` for verbose traces.

---

## 6 Important Documents

| File                            | Insight                                                                 |
| ------------------------------- | ----------------------------------------------------------------------- |
| `README.md`                     | Quick-start, features, deployment cheat-sheet.                          |
| `Technical_Architecture.md`     | 500-line deep-dive into Chainlink integration and system diagrams (C4). |
| `FLASHLOAN_IMPLEMENTATION.md`   | Flash-loan design rationale and invariants.                             |
| `CHAINLINK_INTEGRATION_PLAN.md` | Phased rollout strategy for CCIP/Data-Feeds/VRF.                        |
| `dev_summary.md`                | Sprint-level progress journal (useful for timeline queries).            |
| All files in `docs/`            | Oracle comparison, optimisation notes, etc.                             |

Gemini should reference these for extended answers but keep responses concise.

---

## 7 Common Q&A Reference

| Question                        | Pointer                                                                                                                                   |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| **How to add a new market?**    | Deploy a new `PErc20Delegator` (or `PErc20Immutable`), then `_supportMarket` + set collateral/reserve factors in `Peridottroller`.        |
| **How are interest rates set?** | Via `InterestRateModel` contract (e.g. `JumpRateModelV2`). Controller calls it each block to accrue interest.                             |
| **Price source?**               | `Peridottroller` queries `PriceOracle` interface → implementation could be `FeedsPriceOracle` (Chainlink) or `SimplePriceOracle` (tests). |
| **Upgrade path?**               | `Unitroller` admin sets pending implementation, then calls `_become` on `Peridottroller` implementation.                                  |
| **Cross-chain read**            | `PeridotCCIPReader` on destination chain receives message; queries state and replies through CCIP network.                                |
| **Flash-loan fee?**             | Defined in `PToken.sol::flashFeeBips`; configurable by admin.                                                                             |

---

## 8 Known Gotchas / Linter Notes

- Scripts contain `address constant 0x...` placeholders → compilation fails until replaced.
- Some duplicate mock files (`MockErc20.sol` & `MockERc20.sol`) – choose one.
- `SafeMath` is redundant in Solidity ≥0.8, kept for back-compat.

---

## 9 Keeping This File Up-To-Date

1. After **every significant PR**, add a short note here if interface or workflow changes.
2. Keep the _Directory Map_ and _Key Solidity Components_ tables in sync.
3. If you add new chains or upgrade scripts – document them in _Deployment & Configuration Flow_.

---

_Last updated: <!-- YYYY-MM-DD -->_
