# Peridot Protocol V2 - Technical Architecture Document

**Document Version:** 1.0  
**Date:** January 2025  
**Prepared for:** Biconomy Integration  
**Protocol Version:** V2 with Hub & Spoke Cross-Chain Architecture

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Protocol Overview](#protocol-overview)
3. [Core Architecture Components](#core-architecture-components)
4. [Cross-Chain Architecture](#cross-chain-architecture)
5. [Smart Contract Details](#smart-contract-details)
6. [Integration Patterns](#integration-patterns)
7. [Security Architecture](#security-architecture)
8. [Deployment Architecture](#deployment-architecture)
9. [Biconomy Integration Opportunities](#biconomy-integration-opportunities)
10. [Technical Specifications](#technical-specifications)

---

## Executive Summary

Peridot Protocol V2 is a **decentralized lending protocol** with **native cross-chain capabilities** built on a **Hub & Spoke architecture**. The protocol enables users to supply and borrow assets across multiple blockchain networks without needing wallets or gas tokens on the hub chain.

### Key Innovation Points:

- **Cross-Chain Native**: Users can lend/borrow from any supported chain to any other chain
- **Hub & Spoke Model**: Central lending pools on BNB Chain (Hub) with user interfaces on multiple chains (Spokes)
- **Axelar-Powered**: All cross-chain functionality powered by Axelar's General Message Passing (GMP)
- **Compound Fork**: Core lending mechanics based on proven Compound V2 architecture
- **Upgradeable**: Transparent proxy pattern for seamless protocol upgrades

---

## Protocol Overview

### Architecture Philosophy

```
┌─────────────────────────────────────────────────────────────────┐
│                     PERIDOT PROTOCOL V2                        │
│                   Hub & Spoke Architecture                     │
└─────────────────────────────────────────────────────────────────┘

    SPOKE CHAINS                    HUB CHAIN                 SPOKE CHAINS
 (Arbitrum, Polygon, etc.)        (BNB Chain)            (Ethereum, Avalanche, etc.)
┌─────────────────────┐         ┌─────────────────┐        ┌─────────────────────┐
│                     │         │                 │        │                     │
│   PeridotSpoke.sol  │◄────────┤PeridotHubHandler│────────►│   PeridotSpoke.sol  │
│   (User Interface)  │         │ (Message Router)│        │   (User Interface)  │
│                     │         │                 │        │                     │
└─────────────────────┘         └─────────────────┘        └─────────────────────┘
          │                              │                           │
          │                              │                           │
          ▼                              ▼                           ▼
  ┌─────────────────┐            ┌─────────────────┐         ┌─────────────────┐
  │ Axelar Gateway  │            │ Core Lending    │         │ Axelar Gateway  │
  │ (Cross-Chain)   │            │   Protocol      │         │ (Cross-Chain)   │
  └─────────────────┘            │                 │         └─────────────────┘
                                 │ • Peridottroller│
                                 │ • PTokens       │
                                 │ • Price Oracles │
                                 │ • Interest Rates│
                                 └─────────────────┘
```

### Core Value Propositions

1. **Seamless Cross-Chain UX**: Users supply USDC on Arbitrum and borrow ETH on Polygon - all in one transaction
2. **Capital Efficiency**: All liquidity consolidated on hub chain for maximum utilization
3. **Lower Barrier to Entry**: No need for users to hold gas tokens on hub chain
4. **Multi-Chain Reach**: Protocol can expand to any Axelar-supported chain

---

## Core Architecture Components

### 1. Hub Chain Components (BNB Chain)

#### PeridotHubHandler.sol

**Role:** Central message router and cross-chain coordinator
**Key Functions:**

- Receives cross-chain supply requests from spoke chains
- Processes borrow requests and sends tokens back to users
- Manages spoke chain authorization
- Handles token-to-pToken mappings

```solidity
// Core execution flows
function _executeWithToken(...)  // Handle supply requests
function _execute(...)           // Handle borrow requests
```

#### PErc20CrossChain.sol

**Role:** Enhanced pToken with cross-chain minting capabilities
**Key Functions:**

- Standard Compound-style lending mechanics
- Cross-chain minting via `mintFor()`
- Cross-chain borrowing via `borrowFor()`
- Only callable by authorized PeridotHubHandler

```solidity
function mintFor(address user, uint256 amount)   // Cross-chain supply
function borrowFor(address user, uint256 amount) // Cross-chain borrow
```

#### Peridottroller.sol

**Role:** Risk management and governance (Compound-style)
**Key Functions:**

- Market listing and configuration
- Collateral factor management
- Liquidation threshold enforcement
- Interest rate model integration
- Price oracle integration

#### Interest Rate Models

**Components:**

- `JumpRateModelV2.sol`: Dynamic interest rates based on utilization
- Configurable base rate, multiplier, and kink parameters
- Automatic rate adjustments based on supply/demand

#### Price Oracles

**Components:**

- `SimplePriceOracle.sol`: Chainlink integration with fallbacks
- `FeedsPriceOracle.sol`: Multi-source price aggregation
- Stale price protection and circuit breakers

### 2. Spoke Chain Components

#### PeridotSpoke.sol

**Role:** User-facing interface on each supported chain
**Key Functions:**

- Asset supply initiation
- Borrow request processing
- Cross-chain gas payment handling
- Token receipt from hub chain

```solidity
function supplyToPeridot(string assetSymbol, uint256 amount)
function borrowFromPeridot(address pTokenAddress, uint256 amount)
```

### 3. Cross-Chain Infrastructure

#### Axelar Integration

- **Gateway Contracts**: Handle message and token routing
- **Gas Service**: Automated cross-chain gas payment
- **Token Standards**: Standardized asset representations across chains

---

## Cross-Chain Architecture

### Supply Flow (Spoke → Hub)

```
    SPOKE CHAIN                     AXELAR NETWORK                    HUB CHAIN
┌─────────────────┐              ┌─────────────────┐              ┌─────────────────┐
│                 │              │                 │              │                 │
│ 1. User calls   │              │ 3. Message &    │              │ 4. Hub receives │
│ supplyToPeridot │─────────────►│ tokens relayed  │─────────────►│ tokens + message│
│                 │              │ via Axelar GMP │              │                 │
│ 2. Tokens locked│              │                 │              │ 5. Hub calls    │
│ in spoke        │              │                 │              │ pToken.mintFor()│
│                 │              │                 │              │                 │
└─────────────────┘              └─────────────────┘              │ 6. User receives│
                                                                  │ pTokens on hub  │
                                                                  └─────────────────┘
```

**Technical Flow:**

1. User approves tokens to PeridotSpoke contract
2. PeridotSpoke calls `supplyToPeridot(assetSymbol, amount)`
3. Spoke contract transfers user tokens and pays Axelar gas
4. Axelar Gateway routes tokens and message to hub
5. PeridotHubHandler receives tokens via `_executeWithToken()`
6. Hub handler approves tokens to PErc20CrossChain contract
7. Hub handler calls `pToken.mintFor(user, amount)`
8. User receives pTokens on hub chain (cross-chain balance)

### Borrow Flow (Spoke → Hub → Spoke)

```
  SPOKE CHAIN                  AXELAR NETWORK                  HUB CHAIN
┌─────────────────┐          ┌─────────────────┐            ┌─────────────────┐
│                 │          │                 │            │                 │
│ 1. User calls   │          │ 2. Message      │            │ 3. Hub processes│
│ borrowFromPeridot│─────────►│ relayed via     │───────────►│ borrow request  │
│                 │          │ Axelar GMP      │            │                 │
│                 │          │                 │            │ 4. Hub calls    │
│                 │          │ 6. Borrowed     │◄───────────│ pToken.borrowFor│
│ 7. User receives│◄─────────│ tokens sent     │            │                 │
│ tokens on spoke │          │ back to spoke   │            │ 5. Tokens sent  │
│                 │          │                 │            │ back via Axelar │
└─────────────────┘          └─────────────────┘            └─────────────────┘
```

**Technical Flow:**

1. User calls `borrowFromPeridot(pTokenAddress, borrowAmount)`
2. Spoke contract sends message (no tokens) to hub via Axelar
3. PeridotHubHandler receives message via `_execute()`
4. Hub handler calls `pToken.borrowFor(user, borrowAmount)`
5. PToken contract updates user's borrow balance and transfers tokens to hub handler
6. Hub handler sends borrowed tokens back to spoke chain via Axelar
7. PeridotSpoke receives tokens and transfers to user

### Message Authentication

**Security Model:**

- Each spoke contract registered with hub via `setSpokeContract(chainName, spokeAddress)`
- Hub validates all incoming messages against authorized spoke contracts
- Cryptographic chain name and address verification
- Prevents unauthorized cross-chain calls

---

## Smart Contract Details

### Contract Inheritance & Dependencies

```
PErc20CrossChain
    ├── PErc20 (Compound-style lending)
    │   ├── PToken (core mechanics)
    │   │   ├── Interest calculation
    │   │   ├── Exchange rate management
    │   │   └── Borrow/supply accounting
    │   └── ERC20 compliance
    └── Cross-chain extensions
        ├── mintFor() function
        ├── borrowFor() function
        └── Hub handler authorization

PeridotHubHandler
    ├── AxelarExecutableWithToken
    │   ├── _execute() (message only)
    │   └── _executeWithToken() (message + tokens)
    ├── ReentrancyGuard
    ├── Pausable
    └── Access control

PeridotSpoke
    ├── AxelarExecutableWithTokenUpgradeable
    ├── ReentrancyGuard
    ├── Pausable
    ├── Initializable (proxy pattern)
    └── Cross-chain gas management
```

### Key State Variables

#### PeridotHubHandler State:

```solidity
mapping(address => address) underlyingToPToken;        // Token → pToken mapping
mapping(string => string) spokeContracts;             // Chain → spoke address
mapping(address => bool) allowedPToken;               // pToken allowlist
mapping(address => string) underlyingToAxelarSymbol;  // Token → Axelar symbol
```

#### PeridotSpoke State:

```solidity
string hubChainName;           // Target hub chain identifier
string hubContractAddress;     // Hub handler address
IAxelarGasService gasService;  // Gas payment service
```

### Proxy Architecture

**Pattern:** OpenZeppelin Transparent Upgradeable Proxy

- **PeridotTransparentProxy.sol**: Minimal wrapper around TransparentUpgradeableProxy
- **PeridotProxyAdmin.sol**: Admin contract for upgrade management
- **Upgrade Process**: Admin-controlled, allowing seamless protocol improvements

---

## Integration Patterns

### Token Standard Integration

#### Axelar Token Requirements:

- Tokens must be registered with Axelar Gateway
- Consistent token symbols across all chains
- Standard ERC20 interface compliance

#### Example Configuration:

```solidity
// On Hub: Map underlying token to pToken
hubHandler.setPToken(USDC_ADDRESS, pUSDC_ADDRESS);
hubHandler.setUnderlyingAxelarSymbol(USDC_ADDRESS, "USDC");

// On Spoke: Configure hub connection
spoke.setHubConfig("binance", hubHandlerAddress);
```

### Oracle Integration

#### Price Feed Architecture:

- **Primary**: Chainlink Data Feeds (on hub chain)
- **Fallback**: Manually set emergency prices
- **Validation**: Stale price detection and circuit breakers

#### Implementation:

```solidity
// SimplePriceOracle.sol
function getUnderlyingPrice(PToken pToken) returns (uint) {
    // 1. Try Chainlink feed
    // 2. Check price freshness
    // 3. Fallback to cached price
    // 4. Emergency manual override
}
```

### Interest Rate Integration

#### Dynamic Rate Model:

```solidity
// JumpRateModelV2 calculation
utilizationRate = totalBorrows / (totalSupply × exchangeRate)

if (utilizationRate ≤ kink) {
    borrowRate = baseRate + (utilizationRate × multiplier)
} else {
    excessUtilization = utilizationRate - kink
    borrowRate = baseRate + (kink × multiplier) + (excessUtilization × jumpMultiplier)
}
```

---

## Security Architecture

### Access Control Matrix

| Function              | Caller          | Validation                    |
| --------------------- | --------------- | ----------------------------- |
| `mintFor()`           | HubHandler Only | `onlyHubHandler` modifier     |
| `borrowFor()`         | HubHandler Only | `onlyHubHandler` modifier     |
| `_execute()`          | Axelar Gateway  | Authorized spoke verification |
| `_executeWithToken()` | Axelar Gateway  | Authorized spoke verification |
| Admin functions       | Owner Only      | `onlyOwner` modifier          |

### Security Features

#### Multi-Layer Protection:

1. **Contract Level**: ReentrancyGuard, Pausable functionality
2. **Cross-Chain Level**: Spoke contract allowlisting
3. **Protocol Level**: Peridottroller risk management
4. **Oracle Level**: Stale price detection and fallbacks

#### Emergency Controls:

- Protocol-wide pause functionality
- Individual market pause capability
- Emergency price override mechanisms
- Upgrade capabilities via proxy pattern

### Risk Management

#### Liquidation System:

- **Automated**: LiquidationBot.s.sol for MEV-resistant liquidations
- **Monitoring**: LiquidationMonitor.s.sol for health factor tracking
- **Incentives**: 8% liquidation bonus to encourage healthy liquidations

#### Collateral Management:

```solidity
// Risk parameters enforced by Peridottroller
mapping(address => uint) collateralFactorMantissa;  // 0-90% typically
uint liquidationIncentiveMantissa = 1.08e18;        // 8% bonus
uint closeFactorMantissa = 0.5e18;                  // 50% max liquidation
```

---

## Deployment Architecture

### Multi-Chain Deployment Strategy

#### Hub Chain (BNB Chain):

```bash
# 1. Deploy core infrastructure
forge script script/DeployHub.s.sol --broadcast

# 2. Deploy cross-chain pTokens
forge script script/DeployPErc20CrossChain.s.sol --broadcast

# 3. Configure token mappings
forge script script/ConfigureHubToken.s.sol --broadcast
```

#### Spoke Chains (Arbitrum, Polygon, etc.):

```bash
# Deploy spoke interface
forge script script/DeploySpoke.s.sol --broadcast
```

### Configuration Management

#### Environment Variables:

```bash
# Hub chain configuration
AXELAR_GATEWAY_HUB=0x4D147dCb984e6affEEC47e44293DA442580A3Ec0
AXELAR_GAS_SERVICE_HUB=0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6

# Spoke chain configuration
AXELAR_GATEWAY_SPOKE=0xe1cE95479C84e9809269227C7F8524aE051Ae77a
HUB_CHAIN_NAME=binance
HUB_HANDLER_ADDRESS=0x91b2cb19Ce8072296732349ca26F78ad60c4FF40
```

#### Network-Specific Addresses:

- **BNB Testnet**: Hub deployment with full protocol suite
- **Arbitrum Sepolia**: Spoke deployment for testing
- **Polygon Mumbai**: Additional spoke for multi-chain testing

---

## Biconomy Integration Opportunities

### Account Abstraction Benefits

#### 1. Gasless Cross-Chain Operations

**Current Pain Point:** Users need native tokens for gas on both source and destination chains
**Biconomy Solution:**

- Abstract gas payments through paymaster contracts
- Enable USDC-denominated gas payments
- Cross-chain gas payment abstraction

```solidity
// Example integration
function supplyToPeridotGasless(
    string calldata assetSymbol,
    uint256 amount,
    BiconomyGasPayment memory gasPayment
) external {
    // Biconomy handles gas abstraction
    // User pays gas in USDC or other supported tokens
    _executeSupplyWithBiconomyGas(assetSymbol, amount, gasPayment);
}
```

#### 2. Smart Session Management

**Use Case:** Recurring DeFi operations without repeated signatures
**Implementation:**

- Session keys for automated position management
- Scheduled rebalancing operations
- Stop-loss and take-profit automation

#### 3. Bundled Operations

**Cross-Chain DeFi Composability:**

```solidity
// Example: Supply on Arbitrum + Borrow on Polygon in one transaction
BiconomyTransaction[] memory operations = [
    supply(USDC, 1000e6, "arbitrum"),
    borrow(WETH, 0.5e18, "polygon")
];
biconomy.executeBatch(operations);
```

### Integration Architecture

```
User Interface Layer
    ├── Biconomy SDK Integration
    │   ├── Gas abstraction
    │   ├── Session management
    │   └── Transaction batching
    └── Peridot Protocol Interface
        ├── Cross-chain supply/borrow
        ├── Position management
        └── Liquidation protection

Smart Contract Layer
    ├── Biconomy Paymaster Contracts
    │   ├── Gas fee abstraction
    │   └── Multi-token gas payment
    └── Peridot Protocol Contracts
        ├── Hub & spoke architecture
        └── Cross-chain messaging
```

### Technical Integration Points

#### 1. Gas Abstraction Integration:

```solidity
interface IBiconomyIntegration {
    function executeWithGasAbstraction(
        address target,
        bytes calldata data,
        GasPayment memory payment
    ) external;
}
```

#### 2. Cross-Chain Session Keys:

- Enable users to set up automated cross-chain strategies
- Position management without manual intervention
- Risk management automation

#### 3. Multi-Chain Account Abstraction:

- Unified account across all supported chains
- Cross-chain identity management
- Seamless asset movement

### Business Value Proposition

#### For Users:

- **Zero Gas Friction**: No need to hold native tokens across multiple chains
- **Simplified UX**: One-click cross-chain DeFi operations
- **Automated Strategies**: Set-and-forget position management

#### For Protocol:

- **Higher User Adoption**: Removed technical barriers to entry
- **Increased TVL**: Easier capital deployment across chains
- **Enhanced Liquidity**: More efficient cross-chain capital flows

---

## Technical Specifications

### Supported Networks

- **Hub Chain**: BNB Chain (Primary)
- **Current Spokes**: Arbitrum, Ethereum
- **Planned Expansion**: Polygon, Avalanche, Fantom (all Axelar-supported chains)

### Token Standards

- **ERC20**: Standard fungible token interface
- **Axelar Standards**: Cross-chain token representation
- **Compound Compatibility**: cToken-style interface for integrations

### Performance Metrics

- **Cross-Chain Latency**: 2-10 minutes (depending on source/destination chain)
- **Transaction Throughput**: Limited by underlying blockchain capacity
- **Finality**: Follows underlying chain finality rules

### Integration Requirements

#### For New Spoke Chains:

1. Axelar Gateway deployment on target chain
2. PeridotSpoke deployment and initialization
3. Hub handler configuration for new spoke
4. Token symbol standardization across chains

#### For New Assets:

1. Axelar token support verification
2. PErc20CrossChain deployment on hub
3. Interest rate model configuration
4. Oracle price feed setup
5. Risk parameter configuration

### Development Tools

- **Framework**: Foundry (Forge/Anvil/Cast)
- **Language**: Solidity ^0.8.20
- **Dependencies**: OpenZeppelin, Axelar GMP SDK
- **Testing**: Comprehensive test suite with cross-chain simulation

---

## Conclusion

Peridot Protocol V2 represents a significant advancement in cross-chain DeFi infrastructure, combining the proven mechanics of Compound-style lending with cutting-edge cross-chain capabilities. The hub & spoke architecture enables unprecedented capital efficiency while maintaining security and decentralization.

The integration with Biconomy presents a unique opportunity to abstract away the remaining technical barriers to cross-chain DeFi adoption. By combining Peridot's cross-chain lending capabilities with Biconomy's account abstraction infrastructure, users can access a truly seamless, gasless, and automated DeFi experience across multiple blockchain networks.

This architecture positions Peridot as a foundational layer for the next generation of cross-chain financial applications, with Biconomy providing the essential user experience improvements needed for mainstream adoption.

---

_This document serves as a comprehensive technical reference for integration partners and developers working with Peridot Protocol V2. For the most up-to-date information, please refer to the protocol's GitHub repository and official documentation._
