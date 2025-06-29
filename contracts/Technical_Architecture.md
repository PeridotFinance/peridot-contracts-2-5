# Peridot Protocol - Chainlink Integration Technical Implementation

## Table of Contents

1. [Introduction](#introduction)
2. [High-Level Overview](#high-level-overview)
3. [Definitions, Acronyms and Abbreviations](#definitions-acronyms-and-abbreviations)
4. [Architecture Constraints](#architecture-constraints)
5. [Architecture Overview](#architecture-overview)
6. [Deliverables](#deliverables)
7. [Contract Overview](#contract-overview)
8. [Technology Stack](#technology-stack)

---

## Introduction

### High-Level Overview

The Peridot Protocol Chainlink Integration represents a comprehensive enhancement to the existing Peridot lending and borrowing platform, introducing enterprise-grade cross-chain functionality, reliable price oracles, and MEV protection mechanisms. This integration leverages Chainlink's industry-leading infrastructure to transform Peridot from a single-chain protocol into a truly interoperable multi-chain DeFi ecosystem.

Built following a "skateboard to car" approach, the integration progresses through five distinct phases, each adding incremental value while maintaining system stability and security. The architecture enables users to interact with Peridot markets from any supported blockchain, access real-time price data from Chainlink's decentralized oracle network, and benefit from fair liquidation mechanisms powered by verifiable randomness.

**Core Integration Components:**

- **CCIP (Cross-Chain Interoperability Protocol)**: Enabling secure cross-chain communication and state synchronization
- **Data Feeds**: Providing tamper-proof, high-quality price data for all supported assets
- **VRF (Verifiable Random Function)**: Ensuring fair and transparent liquidation processes
- **Automation Network**: Facilitating automated protocol operations and maintenance

The integration maintains Peridot's core value propositions while extending its reach across the multi-chain ecosystem, providing users with unprecedented flexibility and capital efficiency.

---

## Definitions, Acronyms and Abbreviations

| Term / Acronym          | Definition                                                                                           |
| ----------------------- | ---------------------------------------------------------------------------------------------------- |
| **CCIP**                | Chainlink Cross-Chain Interoperability Protocol - secure messaging and token transfer infrastructure |
| **VRF**                 | Verifiable Random Function - cryptographically secure randomness generation                          |
| **MEV**                 | Maximal Extractable Value - profit extraction opportunities in blockchain transactions               |
| **DON**                 | Decentralized Oracle Network - network of independent nodes providing consensus                      |
| **RMN**                 | Risk Management Network - additional security layer for cross-chain operations                       |
| **OCR**                 | Off-Chain Reporting - consensus mechanism used by Chainlink networks                                 |
| **Data Feeds**          | Chainlink's price reference data aggregated from multiple sources                                    |
| **Lane**                | CCIP term for a unidirectional messaging pathway between two blockchains                             |
| **Router**              | CCIP smart contract that handles message routing and validation                                      |
| **OnRamp/OffRamp**      | CCIP contracts managing token transfers to/from specific chains                                      |
| **Peridottroller**      | Core Peridot smart contract managing lending/borrowing logic                                         |
| **PToken**              | Interest-bearing token representing deposits in Peridot markets                                      |
| **Cross-Chain Adapter** | Smart contract facilitating cross-chain operations                                                   |
| **Fair Liquidation**    | VRF-powered liquidation system preventing front-running                                              |
| **Gas Abstraction**     | Mechanism allowing users to pay fees in different tokens                                             |
| **Chain Selector**      | Unique identifier for blockchain networks in CCIP                                                    |

---

## Architecture Constraints

### Regulatory Constraints

- **Permissionless Design**: Integration maintains Peridot's permissionless nature without KYC/AML requirements
- **Cross-Jurisdictional Compliance**: Users remain responsible for local regulatory compliance across all supported chains
- **Data Privacy**: No personal data collection or storage in cross-chain operations

### Technical Constraints

- **CCIP Network Limitations**: Integration limited to CCIP-supported blockchain networks
- **Finality Requirements**: Cross-chain operations must respect each chain's finality characteristics
- **Gas Cost Optimization**: All operations designed to minimize cross-chain transaction costs
- **Oracle Dependency**: Price feed availability constrains supported asset markets

### Security Constraints

- **Defense in Depth**: Multiple security layers including allowlists, rate limiting, and validation
- **Immutable Core Logic**: Critical lending logic remains unchanged to preserve security guarantees
- **Upgrade Mechanisms**: Controlled upgrade paths for non-critical components only
- **Emergency Controls**: Circuit breakers and pause mechanisms for incident response

### Performance Constraints

- **Latency Tolerance**: Cross-chain operations designed to handle network latency gracefully
- **Throughput Limitations**: System designed within CCIP throughput constraints
- **State Synchronization**: Eventual consistency model for cross-chain state updates

---

## Architecture Overview

### C4 L1 Diagram: High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              PERIDOT CHAINLINK ECOSYSTEM                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐             │
│  │   ETHEREUM      │    │   AVALANCHE     │    │    POLYGON      │             │
│  │   MAINNET       │    │     FUJI        │    │    MUMBAI      │             │
│  │                 │    │                 │    │                 │             │
│  │ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │             │
│  │ │  Peridot    │ │    │ │ CCIP Sender │ │    │ │ CCIP Sender │ │             │
│  │ │ Controller  │ │    │ │ Controller  │ │    │ │ Controller  │ │             │
│  │ │             │ │    │ └─────────────┘ │    │ └─────────────┘ │             │
│  │ └─────────────┘ │    │                 │    │                 │             │
│  │ ┌─────────────┐ │    │ ┌─────────────┐ │    │ ┌─────────────┐ │             │
│  │ │ CCIP Reader │ │    │ │   Users     │ │    │ │   Users     │ │             │
│  │ │  Adapter    │ │    │ │             │ │    │ │             │ │             │
│  │ │             │ │    │ └─────────────┘ │    │ └─────────────┘ │             │
│  │ └─────────────┘ │    │                 │    │                 │             │
│  │                 │    └─────────────────┘    └─────────────────┘             │
│  └─────────────────┘                                                           │
│           │                        │                        │                  │
│           └────────────────────────┼────────────────────────┘                  │
│                                    │                                           │
│  ┌─────────────────────────────────┼─────────────────────────────────────────┐ │
│  │              CHAINLINK INFRASTRUCTURE                                     │ │
│  │                                 │                                         │ │
│  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐ │ │
│  │  │    CCIP     │    │ Data Feeds  │    │     VRF     │    │ Automation  │ │ │
│  │  │   Network   │    │   Network   │    │   Network   │    │   Network   │ │ │
│  │  │             │    │             │    │             │    │             │ │ │
│  │  │ ┌─────────┐ │    │ ┌─────────┐ │    │ ┌─────────┐ │    │ ┌─────────┐ │ │ │
│  │  │ │ Router  │ │    │ │ Oracle  │ │    │ │Coordinator│    │ │Registry │ │ │ │
│  │  │ │         │ │    │ │ Nodes   │ │    │ │         │ │    │ │         │ │ │ │
│  │  │ └─────────┘ │    │ └─────────┘ │    │ └─────────┘ │    │ └─────────┘ │ │ │
│  │  │ ┌─────────┐ │    │ ┌─────────┐ │    │ ┌─────────┐ │    │ ┌─────────┐ │ │ │
│  │  │ │   RMN   │ │    │ │Aggregator│    │ │   Key   │ │    │ │ Upkeep  │ │ │ │
│  │  │ │         │ │    │ │         │ │    │ │  Hash   │ │    │ │Manager  │ │ │ │
│  │  │ └─────────┘ │    │ └─────────┘ │    │ └─────────┘ │    │ └─────────┘ │ │ │
│  │  └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘ │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### C4 L2 Diagram: Zoom into the Peridot CCIP System

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           PERIDOT CCIP INTEGRATION SYSTEM                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│ ┌─────────────────────────────────────────────────────────────────────────────┐ │
│ │                              SOURCE CHAIN                                  │ │
│ │                                                                             │ │
│ │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                     │ │
│ │  │    User     │───▶│ Peridot CCIP│───▶│ CCIP Router │                     │ │
│ │  │  Interface  │    │ Controller  │    │             │                     │ │
│ │  └─────────────┘    └─────────────┘    └─────────────┘                     │ │
│ │                            │                   │                           │ │
│ │  ┌─────────────┐           │            ┌─────────────┐                     │ │
│ │  │   Peridot   │           │            │   LINK      │                     │ │
│ │  │CCIP Sender  │◀──────────┘            │   Token     │                     │ │
│ │  └─────────────┘                        └─────────────┘                     │ │
│ └─────────────────────────────────────────────────────────────────────────────┘ │
│                                         │                                       │
│                                         ▼                                       │
│ ┌─────────────────────────────────────────────────────────────────────────────┐ │
│ │                           CHAINLINK CCIP NETWORK                           │ │
│ │                                                                             │ │
│ │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │ │
│ │  │   Commit    │    │   Execute   │    │     RMN     │    │   Token     │   │ │
│ │  │     DON     │    │     DON     │    │   Network   │    │   Pools     │   │ │
│ │  └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘   │ │
│ └─────────────────────────────────────────────────────────────────────────────┘ │
│                                         │                                       │
│                                         ▼                                       │
│ ┌─────────────────────────────────────────────────────────────────────────────┐ │
│ │                           DESTINATION CHAIN                                 │ │
│ │                                                                             │ │
│ │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                     │ │
│ │  │ CCIP Router │───▶│ Peridot CCIP│───▶│Peridottroller│                    │ │
│ │  │             │    │   Adapter   │    │             │                     │ │
│ │  └─────────────┘    └─────────────┘    └─────────────┘                     │ │
│ │                            │                   │                           │ │
│ │  ┌─────────────┐           │            ┌─────────────┐                     │ │
│ │  │  Chainlink  │           │            │   Peridot   │                     │ │
│ │  │Price Oracle │◀──────────┘            │   Markets   │                     │ │
│ │  └─────────────┘                        └─────────────┘                     │ │
│ │                                                │                           │ │
│ │  ┌─────────────┐                        ┌─────────────┐                     │ │
│ │  │ VRF Liquidator                       │   PTokens   │                     │ │
│ │  │             │◀───────────────────────│             │                     │ │
│ │  └─────────────┘                        └─────────────┘                     │ │
│ └─────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Integration Flow Diagram

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Phase 1   │───▶│   Phase 2   │───▶│   Phase 3   │───▶│   Phase 4   │───▶│   Phase 5   │
│   Basic     │    │  Read-Only  │    │   State     │    │   Price     │    │    VRF      │
│    CCIP     │    │ Integration │    │  Changing   │    │   Oracle    │    │ Liquidation │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
       │                  │                  │                  │                  │
       ▼                  ▼                  ▼                  ▼                  ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│ CCIPSender  │    │PeridotCCIP  │    │PeridotCCIP  │    │ Chainlink   │    │PeridotVRF   │
│CCIPReceiver │    │   Reader    │    │  Adapter    │    │PriceOracle  │    │ Liquidator  │
└─────────────┘    │PeridotCCIP  │    │PeridotCCIP  │    └─────────────┘    └─────────────┘
                   │   Sender    │    │ Controller  │
                   └─────────────┘    └─────────────┘
```

---

## Deliverables

### Deliverable 1: Basic CCIP Infrastructure (Phase 1)

**User Story:**
As a protocol developer, I want to establish secure cross-chain communication infrastructure, so that I can build advanced cross-chain features on a solid foundation.

**Acceptance Criteria:**

- ✅ `CCIPSender` contract deployed and configured with allowlists
- ✅ `CCIPReceiver` contract deployed with security validations
- ✅ Cross-chain message transmission tested between two testnets
- ✅ Gas estimation and fee calculation mechanisms implemented
- ✅ Emergency pause and allowlist management functions operational

### Deliverable 2: Read-Only Cross-Chain Integration (Phase 2)

**User Story:**
As a DeFi user, I want to query my Peridot account status from any supported blockchain, so that I can monitor my positions without switching networks.

**Acceptance Criteria:**

- ✅ `PeridotCCIPReader` contract integrated with Peridottroller
- ✅ `PeridotCCIPSender` contract enabling cross-chain queries
- ✅ `getAccountLiquidity` function accessible cross-chain
- ✅ Event emission for cross-chain query responses
- ✅ Gas-optimized query mechanisms implemented

### Deliverable 3: State-Changing Cross-Chain Operations (Phase 3)

**User Story:**
As a multi-chain DeFi user, I want to manage my Peridot positions from any supported blockchain, so that I can optimize my capital efficiency across chains.

**Acceptance Criteria:**

- ✅ `PeridotCCIPAdapter` contract enabling cross-chain state changes
- ✅ `PeridotCCIPController` contract with user authorization mechanisms
- ✅ Cross-chain `enterMarkets` and `exitMarket` functions operational
- ✅ Comprehensive security controls and validation implemented
- ✅ User authorization and permission management system deployed

### Deliverable 4: Chainlink Data Feeds Integration (Phase 4)

**User Story:**
As a protocol user, I want reliable and tamper-proof price data for all supported assets, so that I can trust the protocol's liquidation and borrowing calculations.

**Acceptance Criteria:**

- ✅ `ChainlinkPriceOracle` contract implementing PriceOracle interface
- ✅ Multiple price feed configurations for major assets
- ✅ Staleness checks and fallback mechanisms implemented
- ✅ Integration with existing Peridottroller price validation
- ✅ Admin controls for price feed management

### Deliverable 5: VRF-Powered Fair Liquidation (Phase 5)

**User Story:**
As a borrower, I want fair and transparent liquidation processes that prevent MEV extraction, so that I'm protected from unfair liquidation practices.

**Acceptance Criteria:**

- ✅ `PeridotVRFLiquidator` contract with verifiable randomness
- ✅ Liquidator registration and selection mechanisms
- ✅ Time-based MEV protection with configurable delays
- ✅ Integration with Chainlink VRF v2 subscription model
- ✅ Emergency controls and liquidation monitoring

---

## Contract Overview

### Phase 1: Basic CCIP Contracts

#### CCIPSender

**Purpose:** Foundational cross-chain message sender with security controls

```
Key Methods:
├── sendMessage(destinationChain, receiver, message, feeToken)
├── allowlistDestinationChain(chainSelector, allowed)
├── getFee(destinationChain, message)
└── withdraw(beneficiary)

Security Features:
├── Destination chain allowlists
├── Owner-only administrative functions
├── Fee calculation and validation
└── Emergency withdrawal mechanisms
```

#### CCIPReceiver_Unsafe

**Purpose:** Basic message receiver with source validation

```
Key Methods:
├── _ccipReceive(message) [internal]
├── allowlistSourceChain(chainSelector, allowed)
├── allowlistSender(sender, allowed)
└── getLastReceivedMessageDetails()

Security Features:
├── Source chain validation
├── Sender address allowlists
├── Router-only execution
└── Message storage and retrieval
```

### Phase 2: Read-Only Integration Contracts

#### PeridotCCIPReader

**Purpose:** Cross-chain query processor for Peridot protocol data

```
Key Methods:
├── _ccipReceive(message) [internal]
├── _handleAccountLiquidityRequest(messageId, requestData)
├── getAccountLiquidity(account) [local]
├── allowlistSourceChain(chainSelector, allowed)
└── allowlistSender(chainSelector, sender, allowed)

Integration Points:
├── Peridottroller.getAccountLiquidity()
├── Cross-chain request/response pattern
├── Event emission for query results
└── Gas-optimized data encoding
```

#### PeridotCCIPSender

**Purpose:** Cross-chain query initiator with fee management

```
Key Methods:
├── requestAccountLiquidity(destinationChain, account, feeToken)
├── getFeeForLiquidityRequest(destinationChain, account, feeToken)
├── setReceiver(destinationChain, receiver)
└── allowlistDestinationChain(chainSelector, allowed)

Features:
├── Automated fee calculation
├── Receiver address management
├── Query result event handling
└── Gas limit optimization
```

### Phase 3: State-Changing Integration Contracts

#### PeridotCCIPAdapter

**Purpose:** Cross-chain state modification executor with authorization

```
Key Methods:
├── _ccipReceive(message) [internal]
├── _handleEnterMarketsRequest(messageId, sourceChain, user, requestData, sender)
├── _handleExitMarketRequest(messageId, sourceChain, user, requestData, sender)
├── enterMarkets(pTokens) [local]
└── exitMarket(pToken) [local]

Authorization Model:
├── Source chain allowlists
├── Sender contract validation
├── User permission verification
└── Operation-specific access controls
```

#### PeridotCCIPController

**Purpose:** Cross-chain operation initiator with user authorization

```
Key Methods:
├── requestEnterMarkets(destinationChain, user, pTokens, feeToken)
├── requestExitMarket(destinationChain, user, pToken, feeToken)
├── authorizeUserForChain(destinationChain, authorized)
├── getFeeForEnterMarketsRequest(destinationChain, pTokens, feeToken)
└── getFeeForExitMarketRequest(destinationChain, pToken, feeToken)

User Experience Features:
├── Self-authorization mechanisms
├── Operator delegation support
├── Fee estimation and optimization
└── Transaction status tracking
```

### Phase 4: Price Oracle Integration

#### ChainlinkPriceOracle

**Purpose:** Chainlink Data Feeds integration for reliable price data

```
Key Methods:
├── getUnderlyingPrice(pToken) [PriceOracle interface]
├── setPriceFeed(pToken, priceFeed)
├── removePriceFeed(pToken)
├── setFallbackOracle(fallbackOracle)
├── getPriceFeedInfo(pToken)
├── hasPriceFeed(pToken)
└── _getChainlinkPrice(priceFeed) [internal]

Price Validation Features:
├── Staleness checks (1-hour maximum)
├── Price positivity validation
├── Round completeness verification
├── Fallback oracle support
└── Decimal scaling (8 to 18 decimals)

Administrative Controls:
├── Price feed management
├── Admin role transfer
├── Emergency price feed removal
└── Fallback oracle configuration
```

### Phase 5: VRF Liquidation System

#### PeridotVRFLiquidator

**Purpose:** Fair liquidation system using Chainlink VRF for MEV protection

```
Key Methods:
├── requestFairLiquidation(borrower, pTokenBorrowed, pTokenCollateral, repayAmount)
├── fulfillRandomWords(requestId, randomWords) [internal]
├── registerLiquidator()
├── unregisterLiquidator()
├── setAuthorizedCaller(caller, authorized)
├── getLiquidationRequest(requestId)
├── getLiquidatorCount()
└── emergencyCancel(requestId)

VRF Integration:
├── Chainlink VRF v2 subscription model
├── Configurable gas limits and confirmations
├── Random liquidator selection algorithm
├── Request fulfillment tracking
└── Emergency intervention capabilities

MEV Protection Features:
├── Minimum liquidation delay (1 minute)
├── Maximum liquidation window (10 minutes)
├── Liquidator pool randomization
├── Time-based execution windows
└── Front-running prevention mechanisms
```

---

## Technology Stack

### Smart Contract Platform

- **Solidity ^0.8.20** - Smart contract programming language
- **Foundry** - Development framework and testing suite
- **OpenZeppelin Contracts** - Security-audited contract libraries

### Chainlink Infrastructure

```
CCIP (Cross-Chain Interoperability Protocol)
├── Router Contracts - Message routing and validation
├── OnRamp/OffRamp - Token transfer mechanisms
├── Risk Management Network - Additional security layer
└── Decentralized Oracle Networks - Consensus and execution

Data Feeds
├── Price Reference Data - Real-time asset prices
├── Aggregator Contracts - Price data aggregation
├── Heartbeat Mechanisms - Regular price updates
└── Deviation Thresholds - Price change triggers

VRF (Verifiable Random Function)
├── VRF Coordinator - Randomness request management
├── Subscription Model - Gas and LINK management
├── Key Hash Configuration - Cryptographic parameters
└── Callback Gas Limits - Execution cost management

Automation Network
├── Registry Contracts - Upkeep management
├── Keeper Network - Automated execution
├── Conditional Logic - Custom trigger conditions
└── Gas Optimization - Cost-efficient operations
```

### Development Tools

- **Forge** - Smart contract compilation and testing
- **Cast** - Command-line interaction with contracts
- **Anvil** - Local blockchain simulation
- **Git** - Version control and collaboration

### Network Configuration

```
Supported Testnets:
├── Ethereum Sepolia (Chain ID: 11155111)
│   ├── CCIP Router: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59
│   ├── LINK Token: 0x779877A7B0D9E8603169DdbD7836e478b4624789
│   ├── VRF Coordinator: 0x8103B0A8A00be2DDC778e6e7eaa21791Cd364625
│   └── Chain Selector: 16015286601757825753
│
├── Avalanche Fuji (Chain ID: 43113)
│   ├── CCIP Router: 0xF694E193200268f9a4868e4Aa017A0118C9a8177
│   ├── LINK Token: 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846
│   ├── VRF Coordinator: 0x2eD832Ba664535e5886b75D64C46EB9a228C2610
│   └── Chain Selector: 14767482510784806043
│
└── Additional Networks (Polygon, Arbitrum, Optimism)
    ├── Router addresses from CCIP Directory
    ├── LINK token addresses
    ├── VRF coordinator addresses
    └── Unique chain selectors
```

### Security Framework

```
Access Control:
├── Owner-based administration
├── Role-based permissions
├── Multi-signature requirements
└── Time-locked operations

Validation Mechanisms:
├── Allowlist enforcement
├── Source chain verification
├── Message integrity checks
└── Gas limit validations

Emergency Controls:
├── Circuit breakers
├── Pause mechanisms
├── Emergency withdrawals
└── Upgrade safeguards
```

### Deployment Architecture

```
Deployment Scripts:
├── DeployChainlinkIntegration.s.sol - Comprehensive deployment
├── ConfigureChainlinkCCIP.s.sol - Configuration management
├── Phase-specific deployment functions
└── Network-specific parameter management

Configuration Management:
├── Network-specific addresses
├── Chain selector mappings
├── Gas limit configurations
└── Security parameter settings

Testing Framework:
├── Unit tests for individual contracts
├── Integration tests for cross-chain flows
├── Gas optimization tests
└── Security validation tests
```

This technical implementation provides a comprehensive foundation for integrating Chainlink's infrastructure with the Peridot Protocol, enabling secure, reliable, and fair cross-chain DeFi operations while maintaining the protocol's core security and usability principles.
