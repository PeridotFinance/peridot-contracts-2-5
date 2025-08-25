# Peridot Protocol V2 🌟

A next-generation decentralized lending protocol with enterprise-grade cross-chain capabilities, powered by **Axelar's General Message Passing (GMP)** for seamless multi-chain DeFi operations.

## 🚀 Overview

Peridot Protocol V2 is a comprehensive lending and borrowing platform that combines the security of battle-tested DeFi primitives with cutting-edge cross-chain technology. The protocol offers:

- **🔗 Cross-Chain Interoperability**: Powered by Axelar for secure cross-chain messaging and token transfers
- **📊 Reliable Price Feeds**: Enterprise-grade price oracles using Chainlink Data Feeds
- **🏗️ Hub & Spoke Architecture**: Scalable design supporting multiple blockchain networks
- **🛡️ Battle-Tested Security**: Built on proven lending protocols with additional security layers

## 🏛️ Architecture

### **Hub & Spoke Model**

- **Hub Chain** (e.g., BNB Chain): The central chain where lending pools and core logic reside.
- **Spoke Chains** (e.g., Arbitrum): Users can supply and borrow from the hub without needing a wallet on the hub chain.

### **Core Protocol Components**

```
┌─────────────────────────────────────────────────────────────────┐
│                    PERIDOT PROTOCOL V2                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐  │
│  │ Peridottroller  │    │    PTokens      │    │ Price Oracle│  │
│  │  (Core Logic)   │◄──►│ (pUSDC, pETH)   │◄──►│ (Chainlink) │  │
│  └─────────────────┘    └─────────────────┘    └─────────────┘  │
│           │                       │                      │      │
│           ▼                       ▼                      ▼      │
│  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────┐  │
│  │ Interest Rate   │    │ Cross-Chain Ops │    │ Axelar GMP  │  │
│  │     Models      │    │ (Hub & Spoke)   │    │ Integration │  │
│  └─────────────────┘    └─────────────────┘    └─────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### Cross-Chain Integration with Axelar

The protocol leverages **Axelar GMP** for all cross-chain functionality:

- **PeridotSpoke.sol** (Spoke): User-facing contract to initiate supply/borrow operations
- **PeridotHubHandler.sol** (Hub): Receives cross-chain messages and tokens from spoke chains
- **PErc20CrossChain.sol** (Hub): Modified pToken that allows hub handler to mint/borrow on behalf of users
- **Axelar Gas Service**: Pays for cross-chain transaction execution

## 🛠️ Technology Stack

### Smart Contracts

- **Solidity ^0.8.20** - Core contract development
- **Foundry** - Development framework and testing
- **OpenZeppelin** - Security-audited contract libraries

### Cross-Chain Infrastructure

- **Axelar GMP** - Cross-chain messaging and token transfers
- **Chainlink Data Feeds** - Reliable price oracles (on hub chain)

## 📋 Prerequisites

- [Git](https://git-scm.com/book/en/v2/Getting-Started-Installing-Git)
- [Node.js](https://nodejs.org/) (v16 or higher)
- [Foundry](https://book.getfoundry.sh/getting-started/installation)

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
BNB_TESTNET_RPC_URL=your_bnb_testnet_rpc_url
ARBITRUM_SEPOLIA_RPC_URL=your_arbitrum_rpc_url

# Private key for deployment
PRIVATE_KEY=your_private_key
```

### 4. Compile Contracts

```bash
forge build
```

## 🏗️ Deployment Guide

### Phase 1: Hub Chain Deployment (BNB Chain)

```bash
# Deploy core hub contracts
forge script script/DeployHub.s.sol --rpc-url $BNB_TESTNET_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Deploy cross-chain pTokens
forge script script/DeployPErc20CrossChain.s.sol --rpc-url $BNB_TESTNET_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Phase 2: Spoke Chain Deployment (Arbitrum)

```bash
# Deploy spoke contract
forge script script/DeploySpoke.s.sol --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast
```

### Phase 3: Configuration

- **Set pToken mappings** on the deployed `PeridotHubHandler`
- **Set spoke contract addresses** on the `PeridotHubHandler`

## 🧪 Testing

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-path test/CrossChainLending.t.sol
```

## 📖 Key Contracts

### Hub Chain Contracts

- **`Peridottroller.sol`** - Main risk management and governance contract
- **`PErc20CrossChain.sol`** - Modified pToken for cross-chain operations
- **`PeridotHubHandler.sol`** - Axelar message and token receiver

### Spoke Chain Contracts

- **`PeridotSpoke.sol`** - User-facing contract for supply/borrow

## 🔧 Available Scripts

### Deployment Scripts

- `DeployHub.s.sol` - Deploy all hub contracts
- `DeploySpoke.s.sol` - Deploy spoke contract
- `DeployPErc20CrossChain.s.sol` - Deploy cross-chain pTokens

### Usage Scripts

- `CrossChainLend.s.sol` - Initiate supply and borrow operations from a spoke chain

## 🛡️ Security Features

- **Spoke Contract Authorization**: Only authorized spoke contracts can call the hub
- **pToken Access Control**: Only the hub handler can mint/borrow on behalf of users
- **Axelar Security**: Inherits security from Axelar's decentralized validator network

## 🌐 Cross-Chain Operations

### Supply Flow (Arbitrum → BNB Chain)

1. User calls `supplyToPeridot()` on Arbitrum `PeridotSpoke`
2. Spoke sends tokens and message to Axelar Gateway
3. `PeridotHubHandler` on BNB Chain receives tokens and calls `mintFor()` on `PErc20CrossChain`
4. User receives pTokens on BNB Chain

### Borrow Flow (Arbitrum → BNB Chain → Arbitrum)

1. User calls `borrowFromPeridot()` on Arbitrum `PeridotSpoke`
2. Spoke sends message (no tokens) to Axelar Gateway
3. `PeridotHubHandler` on BNB Chain receives message and calls `borrowFor()`
4. `PErc20CrossChain` sends borrowed tokens to `PeridotHubHandler`
5. `PeridotHubHandler` sends tokens back to user on Arbitrum via Axelar

## 📚 Documentation

- **[Axelar GMP](https://docs.axelar.dev/dev/general-message-passing/overview)** - Axelar cross-chain documentation
- **[Foundry Book](https://book.getfoundry.sh/)** - Foundry development framework

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Links

- **Website**: [https://peridot.finance](https://peridot.finance)
- **Twitter**: [https://twitter.com/PeridotProtocol](https://twitter.com/PeridotProtocol)

## ⚠️ Disclaimer

Peridot Protocol V2 is experimental software. Use at your own risk. The protocol has not been audited and may contain bugs or security vulnerabilities. Never invest more than you can afford to lose.
