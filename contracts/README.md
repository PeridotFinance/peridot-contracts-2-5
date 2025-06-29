# Peridot Protocol V2 🌟

A next-generation decentralized lending protocol with enterprise-grade cross-chain capabilities, powered by Chainlink's infrastructure and designed for seamless multi-chain DeFi operations.

## 🚀 Overview

Peridot Protocol V2 is a comprehensive lending and borrowing platform that combines the security of battle-tested DeFi primitives with cutting-edge cross-chain technology. Built with a modular "skateboard to car" approach, the protocol offers:

- **🔗 Cross-Chain Interoperability**: Powered by Chainlink CCIP for secure cross-chain messaging and operations
- **📊 Reliable Price Feeds**: Enterprise-grade price oracles using Chainlink Data Feeds
- **🎲 Fair Liquidations**: MEV-protected liquidation system using Chainlink VRF
- **🏗️ Modular Architecture**: Scalable design supporting multiple blockchain networks
- **🛡️ Battle-Tested Security**: Built on proven lending protocols with additional security layers

## 🏛️ Architecture

### Core Protocol Components

```
┌─────────────────────────────────────────────────────────────────┐
│                    PERIDOT PROTOCOL V2                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐  │
│  │  Peridottroller │    │    PTokens      │    │ Price Oracle│  │
│  │   (Core Logic)  │◄──►│ (pUSDC, pETH)   │◄──►│  (Chainlink)│  │
│  └─────────────────┘    └─────────────────┘    └─────────────┘  │
│           │                       │                      │      │
│           ▼                       ▼                      ▼      │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐  │
│  │  Interest Rate  │    │   Liquidation   │    │    CCIP     │  │
│  │     Models      │    │   (VRF-based)   │    │ Integration │  │
│  └─────────────────┘    └─────────────────┘    └─────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Cross-Chain Integration

The protocol leverages **Chainlink CCIP** for comprehensive cross-chain functionality:

- **Chainlink CCIP**: Secure cross-chain messaging and state synchronization
- **Cross-Chain Operations**: Query account liquidity and manage markets across chains
- **Unified Liquidity**: Access to protocol liquidity from any CCIP-supported blockchain

## 🛠️ Technology Stack

### Smart Contracts

- **Solidity ^0.8.20** - Core contract development
- **Foundry** - Development framework and testing
- **OpenZeppelin** - Security-audited contract libraries
- **Hardhat** - Additional tooling and deployment scripts

### Cross-Chain Infrastructure

- **Chainlink CCIP** - Cross-chain messaging and token transfers
- **Chainlink Data Feeds** - Reliable price oracles
- **Chainlink VRF** - Verifiable randomness for fair liquidations

## 📋 Prerequisites

Before getting started, ensure you have:

- [Git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)
- [Node.js](https://nodejs.org/) (v16 or higher)
- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Hardhat](https://hardhat.org/getting-started/)

## 🚀 Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/PeridotFinance/PeridotV2Full.git
cd PeridotV2Full
```

### 2. Install Dependencies

```bash
# Install Node.js dependencies
npm install

# Install Foundry dependencies
forge install
```

### 3. Environment Setup

Create a `.env` file with your configuration:

```bash
# Network RPC URLs
ETHEREUM_SEPOLIA_RPC_URL=your_sepolia_rpc_url
AVALANCHE_FUJI_RPC_URL=your_fuji_rpc_url

# Private key for deployment
PRIVATE_KEY=your_private_key

# API keys
ETHERSCAN_API_KEY=your_etherscan_api_key
```

### 4. Compile Contracts

```bash
# Using Foundry
forge build

# Using Hardhat
npx hardhat compile
```

## 🏗️ Deployment Guide

The protocol follows a structured deployment approach across five phases:

### Phase 1: Core Protocol Deployment

Deploy the foundational Peridot lending contracts:

```bash
# Deploy Price Oracle
forge script script/DeployOracle.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# Deploy Peridottroller
forge script script/DeployPeridottroller.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# Deploy PTokens
forge script script/DeployPErc20.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Phase 2: Chainlink Integration

Deploy and configure Chainlink components:

```bash
# Deploy all Chainlink integration contracts
forge script script/DeployChainlinkIntegration.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# Configure CCIP allowlists and settings
forge script script/ConfigureChainlinkCCIP.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Phase 3: CCIP Configuration

Configure cross-chain allowlists and test cross-chain functionality:

```bash
# Configure CCIP allowlists for cross-chain operations
forge script script/ConfigureChainlinkCCIP.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# Test cross-chain account liquidity queries
forge script script/TestCCIPQueries.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

## 🧪 Testing

Run the comprehensive test suite:

```bash
# Run all tests
forge test

# Run tests with verbosity
forge test -vvv

# Run specific test file
forge test --match-path test/ChainlinkIntegration.t.sol

# Generate coverage report
forge coverage
```

## 📖 Key Contracts

### Core Protocol

- **`Peridottroller.sol`** - Main risk management and governance contract
- **`PToken.sol`** - Base implementation for interest-bearing tokens
- **`PErc20.sol`** - ERC20 market implementation
- **`PEther.sol`** - Native ETH market implementation

### Chainlink Integration

- **`ChainlinkPriceOracle.sol`** - Chainlink Data Feeds integration
- **`PeridotCCIPAdapter.sol`** - Cross-chain state management
- **`PeridotCCIPController.sol`** - Cross-chain operation initiator
- **`PeridotVRFLiquidator.sol`** - Fair liquidation with VRF

### CCIP Cross-Chain Components

- **`CCIPSender.sol`** - Basic cross-chain message sender
- **`CCIPReceiver_Unsafe.sol`** - Basic cross-chain message receiver
- **`PeridotCCIPReader.sol`** - Cross-chain query processor
- **`PeridotCCIPSender.sol`** - Cross-chain query initiator

## 🔧 Available Scripts

### Deployment Scripts

- `DeployPeridottroller.s.sol` - Deploy core controller
- `DeployPErc20.s.sol` - Deploy ERC20 markets
- `DeployChainlinkIntegration.s.sol` - Deploy all Chainlink components
- `DeployOracle.s.sol` - Deploy price oracle

### Configuration Scripts

- `ConfigureChainlinkCCIP.s.sol` - Configure CCIP allowlists and settings
- `FetchPrice.s.sol` - Query Chainlink oracle prices

### Testing Scripts

- `TestCCIPQueries.s.sol` - Test cross-chain account liquidity queries
- `TestCCIPOperations.s.sol` - Test cross-chain market operations

## 🛡️ Security Features

### Multi-Layer Security

- **Allowlist Controls** - Restrict cross-chain interactions to approved contracts
- **Source Validation** - Verify message origins and authenticity
- **Rate Limiting** - Prevent abuse and ensure system stability
- **Emergency Controls** - Circuit breakers and pause mechanisms

### MEV Protection

- **VRF Liquidations** - Use Chainlink VRF for fair liquidator selection
- **Time Delays** - Prevent front-running with configurable delays
- **Random Selection** - Eliminate predictable liquidation ordering

### Oracle Security

- **Staleness Checks** - Ensure price data freshness
- **Fallback Oracles** - Backup price sources for reliability
- **Deviation Monitoring** - Track and validate price movements

## 🌐 Cross-Chain Operations

### Supported Operations

- **Cross-Chain Queries** - Check account liquidity from any chain
- **Market Management** - Enter/exit markets across chains
- **Liquidation Monitoring** - Fair liquidation across all chains

### Fee Structure

- **CCIP Fees** - Paid in LINK tokens for cross-chain operations
- **Gas Optimization** - Efficient cross-chain message execution
- **Fee Estimation** - Built-in fee calculation for all cross-chain operations

## 📚 Documentation

- **[Chainlink Integration Plan](CHAINLINK_INTEGRATION_PLAN.md)** - Detailed integration roadmap
- **[Technical Implementation](PERIDOT_CHAINLINK_INTEGRATION.md)** - Architecture documentation

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Links

- **Website**: [https://peridot.finance](https://peridot.finance)
- **Documentation**: [https://docs.peridot.finance](https://docs.peridot.finance)
- **Discord**: [https://discord.gg/peridot](https://discord.gg/peridot)
- **Twitter**: [https://twitter.com/PeridotProtocol](https://twitter.com/PeridotProtocol)

## ⚠️ Disclaimer

Peridot Protocol V2 is experimental software. Use at your own risk. The protocol has not been audited and may contain bugs or security vulnerabilities. Never invest more than you can afford to lose.
