# 🧠 Peridot Cross-Chain Lending System

## Overview

This is a complete implementation of a cross-chain lending system using the **Hub & Spoke model** with **Axelar GMP**. The system allows users on spoke chains (Polygon, Arbitrum, etc.) to supply or borrow assets from the Peridot Compound V2 fork on the hub chain (Ethereum).

## 🏗️ Architecture

### Hub Chain (Ethereum)
- **PeridotForwarder**: Verifies signatures and forwards actions to cTokens
- **PeridotHubHandler**: Receives cross-chain messages via Axelar
- **PeridotCErc20**: Modified cToken with `mintFor` and `borrowFor` functions

### Spoke Chains (Polygon, Arbitrum, etc.)
- **PeridotSpoke**: Users initiate supply/borrow actions with signatures
- **PeridotSpokeReceiver**: Receives tokens back from hub chain

## 📋 Smart Contracts

### Core Contracts

| Contract | Purpose | Network |
|----------|---------|---------|
| `PeridotSpoke.sol` | User interface for supply/borrow | Spoke chains |
| `PeridotHubHandler.sol` | Axelar message receiver | Hub chain |
| `PeridotForwarder.sol` | Signature verification & forwarding | Hub chain |
| `PeridotSpokeReceiver.sol` | Token receiver for borrow callbacks | Spoke chains |
| `PeridotCErc20.sol` | Modified cToken with mintFor/borrowFor | Hub chain |

### Key Features
- **EIP-712** signatures for secure cross-chain intents
- **Nonce management** for replay protection
- **Deadline enforcement** for signature validity
- **Access control** limiting cToken functions to PeridotForwarder only
- **Reentrancy protection** throughout the system

## 🚀 Getting Started

### Prerequisites
- Node.js 16+ and npm/yarn
- Foundry for smart contract development
- Axelar testnet accounts and tokens

### Installation

```bash
# Install dependencies
npm install

# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Install Axelar GMP SDK
npm install @axelar-network/axelar-gmp-sdk-solidity
```

### Environment Setup

Create `.env` file:
```bash
# Axelar testnet addresses
AXELAR_GATEWAY_ETHEREUM=0xe432150cce91c13a887f7D836923d5597adD8E31
AXELAR_GATEWAY_POLYGON=0x6f015F16De9fC8791b560eA20d3C2da6bb9d5C28
AXELAR_GATEWAY_ARBITRUM=0xe432150cce91c13a887f7D836923d5597adD8E31

AXELAR_GAS_SERVICE_ETHEREUM=0xbE406F018894A5EBE5246F6f0dc9b2D596D6B5aC
AXELAR_GAS_SERVICE_POLYGON=0xbE406F018894A5EBE5246F6f0dc9b2D596D6B5aC
AXELAR_GAS_SERVICE_ARBITRUM=0xbE406F018894A5EBE5246F6f0dc9b2D596D6B5aC

# Private keys (testnet only)
PRIVATE_KEY=your_private_key_here
```

### Deployment

#### Deploy All Contracts
```bash
# Deploy on Ethereum (hub)
forge script script/DeployCrossChainLending.s.sol:DeployCrossChainLending --rpc-url $ETHEREUM_RPC --private-key $PRIVATE_KEY --broadcast

# Deploy on Polygon (spoke)
forge script script/DeployCrossChainLending.s.sol:DeployCrossChainLending --rpc-url $POLYGON_RPC --private-key $PRIVATE_KEY --broadcast

# Deploy on Arbitrum (spoke)
forge script script/DeployCrossChainLending.s.sol:DeployCrossChainLending --rpc-url $ARBITRUM_RPC --private-key $PRIVATE_KEY --broadcast
```

#### Deploy cTokens
```bash
# Deploy cTokens on hub chain
forge script script/DeployCrossChainLending.s.sol:DeployCrossChainLending --sig "deployCTokens()" --rpc-url $ETHEREUM_RPC --private-key $PRIVATE_KEY --broadcast
```

#### Whitelist cTokens
```bash
# Whitelist cTokens in PeridotForwarder
forge script script/DeployCrossChainLending.s.sol:DeployCrossChainLending --sig "whitelistCTokens()" --rpc-url $ETHEREUM_RPC --private-key $PRIVATE_KEY --broadcast
```

## 🧪 Testing

### Run Tests
```bash
# Run all tests
forge test

# Run specific test
forge test --match-test testSupplyFlow

# Run tests with verbosity
forge test -vvv
```

### Test Coverage
```bash
# Generate coverage report
forge coverage

# Generate detailed coverage
forge coverage --report lcov
```

## 🔄 Usage Flow

### Supply Flow
1. **User on spoke chain** calls `supplyToPeridot` with signature
2. **PeridotSpoke** encodes intent and sends via Axelar GMP
3. **PeridotHubHandler** receives message and forwards to PeridotForwarder
4. **PeridotForwarder** verifies signature and calls `mintFor` on cToken
5. **cTokens** are minted for user on hub chain

### Borrow Flow
1. **User on spoke chain** calls `borrowFromPeridot` with signature
2. **PeridotSpoke** encodes intent and sends via Axelar GMP
3. **PeridotHubHandler** receives message and forwards to PeridotForwarder
4. **PeridotForwarder** verifies signature and calls `borrowFor` on cToken
5. **Tokens** are borrowed and sent back to user on spoke chain via PeridotSpokeReceiver

## 📱 Frontend Integration

### React Hook
```javascript
import { useCrossChainLending } from './frontend/signature-flow.js'

function MyComponent() {
  const { createSupplySignature, createBorrowSignature, loading } = useCrossChainLending()
  
  const handleSupply = async (asset, amount) => {
    const { signature, deadline } = await createSupplySignature(asset, amount)
    // Send transaction with signature
  }
  
  return (
    <div>
      <SupplyComponent asset={asset} onSuccess={handleSuccess} />
      <BorrowComponent asset={asset} onSuccess={handleSuccess} />
    </div>
  )
}
```

### Signature Creation
```javascript
// Create supply signature
const { signature, deadline } = await createSupplySignature(
  '0xTokenAddress',
  ethers.utils.parseEther('1000')
)

// Create borrow signature
const { signature, deadline } = await createBorrowSignature(
  '0xTokenAddress',
  ethers.utils.parseEther('500')
)
```

## 🔐 Security Features

### Signature Verification
- **EIP-712** structured signatures
- **Domain separation** prevents cross-chain replay attacks
- **Nonce management** prevents replay attacks
- **Deadline enforcement** prevents stale signatures

### Access Control
- **Only PeridotForwarder** can call `mintFor` and `borrowFor`
- **Only PeridotHubHandler** can forward messages to PeridotForwarder
- **Owner-only** functions for contract administration

### Reentrancy Protection
- **ReentrancyGuard** on all external functions
- **Checks-effects-interactions** pattern throughout

## 📊 Monitoring

### Events to Monitor
```solidity
// Supply events
SupplyIntentSent(user, asset, amount, nonce, payloadHash)
SupplyExecuted(user, asset, cToken, amount, nonce)

// Borrow events
BorrowIntentSent(user, asset, amount, nonce, payloadHash)
BorrowExecuted(user, asset, cToken, amount, nonce)
TokensSentBack(user, asset, amount, destinationChain)
```

### Key Metrics
- **Cross-chain latency**: Time from spoke action to hub execution
- **Signature verification success rate**
- **Nonce usage patterns**
- **Gas costs** for cross-chain operations

## 🛠️ Troubleshooting

### Common Issues

#### "Invalid signature"
- Check EIP-712 domain parameters
- Verify chain ID matches deployment
- Ensure nonce is correct

#### "Signature expired"
- Increase deadline parameter
- Check system clock synchronization

#### "Only PeridotForwarder"
- Verify cToken has correct forwarder address
- Check PeridotForwarder has correct hub handler

#### Cross-chain message failures
- Check Axelar gateway connection
- Verify gas payment is sufficient
- Ensure contract addresses are correct

### Debug Commands
```bash
# Check contract addresses
forge inspect <contract> storage

# Verify signature creation
node scripts/verify-signature.js

# Check cross-chain message flow
node scripts/debug-axelar.js
```

## 📈 Performance Optimization

### Gas Optimization
- Use `uint256` instead of smaller integers
- Pack structs efficiently
- Minimize storage reads/writes
- Use events for off-chain data

### Frontend Optimization
- Batch signature requests
- Cache nonce values
- Implement retry logic for failed transactions
- Use optimistic UI updates

## 🔗 Axelar Integration

### Required Setup
1. **Fund Axelar gas receiver** on spoke chains
2. **Register contract addresses** with Axelar
3. **Test cross-chain flow** on testnet
4. **Monitor Axelar status** page

### Gas Estimation
```javascript
// Estimate gas for cross-chain message
const gasEstimate = await axelar.estimateGasFee(
  'ethereum',
  'polygon',
  'PeridotSpoke',
  payload
)
```

## 📞 Support

### Resources
- [Axelar Documentation](https://docs.axelar.dev/)
- [EIP-712 Specification](https://eips.ethereum.org/EIPS/eip-712)
- [Compound Protocol Documentation](https://compound.finance/docs)

### Community
- [Peridot Discord](https://discord.gg/peridot)
- [Axelar Discord](https://discord.gg/axelar)
- [GitHub Issues](https://github.com/peridot-finance/peridot-ccip/issues)

---
