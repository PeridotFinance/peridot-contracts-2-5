# Peridot Protocol

A next-generation cross-chain lending, borrowing, and investment protocol enabling seamless DeFi across multiple blockchains.

## Overview

Peridot Protocol is revolutionizing decentralized lending by eliminating barriers between blockchains. Built on proven Compound V2 architecture, it extends core lending mechanics with cross-chain capabilities and sophisticated investment products.

### Key Features

- 🔁 **Cross-Chain Lending & Borrowing** — Powered by Wormhole NTT and LayerZero OFT for secure cross-chain token transfers
- 💎 **Dual Investment Products** — Options-like strategies on yield-bearing assets with call/put positions
- 📈 **Margin Trading** — Leveraged trading with smart margin accounts and PancakeSwap V3 integration
- 💧 **Unified Liquidity** — Concentrated liquidity on the hub chain for better capital efficiency
- 🏦 **Boosted Yield Vaults** — LP vault strategies (PancakeSwap V3, Magma, Morpho) with auto-compounding
- 🪙 **xPeridot Staking** — Vault + staking with tiered rewards and governance participation

## Technology Stack

- **Smart Contracts**: Solidity ^0.8.20
- **Development Framework**: Foundry
- **Cross-Chain Infrastructure**: 
  - Wormhole Native Token Transfers (NTT)
  - LayerZero V2 OFT Adapters
  - ICP Chain Fusion (experimental)
- **Price Oracles**: Chainlink, DIA, Stork (Hybrid oracle support)
- **DEX Integrations**: PancakeSwap V3

## Supported Networks

### Mainnet
| Network | Comptroller (Proxy) | $P Token |
|---------|---------------------|----------|
| BNB Chain | `0x6fC0c15531CB5901ac72aB3CFCd9dF6E99552e14` | `0x96650BebC549456F253974c11Fc6cBE28172A2d2` |
| Monad | `0x6D208789f0a978aF789A3C8Ba515749598940716` | `0x96650BebC549456F253974c11Fc6cBE28172A2d2` |

### Testnet
| Network | Comptroller (Proxy) | $P Token |
|---------|---------------------|----------|
| BNB Testnet | `0xe8F09917d56Cc5B634f4DE091A2c82189dc41b54` | `0x5A5063a749fCF050CE58Cae6bB76A29bb37BA4Ed` |
| Monad Testnet | — | `0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0` |
| Base Sepolia | — | `0x7E9aa6aa7fa64c41ba6fbC15A08efa84685F5c54` |
| Somnia Testnet | — | `0xB911C192ed1d6428A12F2Cf8F636B00c34e68a2a` |
| Solana Devnet | — | `ENiCZ2pc3uhD8zewSYxRaBnATdF8G8d9UfiVHquY3gW9` |

See [contracts/addresses.MD](contracts/addresses.MD) for full deployment addresses including markets, oracles, and adapters.

## Repository Layout

```
├── contracts/               # Solidity smart contracts (Foundry)
│   ├── contracts/
│   │   ├── PToken.sol, PErc20.sol, PEther.sol    # Core lending tokens
│   │   ├── Peridottroller.sol                     # Risk management & governance
│   │   ├── DualInvestment/                        # Dual investment system
│   │   ├── margin/                                # Margin trading contracts
│   │   ├── boosted/                               # Boosted yield vaults (Pancake, Magma, Morpho)
│   │   ├── layerzero/                             # LayerZero OFT adapters
│   │   ├── xperidot/                              # xPeridot vault & staking
│   │   └── pancakev3/                             # PancakeSwap V3 LP vaults
│   ├── script/              # Deployment & operations scripts
│   └── test/                # Foundry tests
├── ntt/                     # Wormhole Native Token Transfers (EVM, Solana, Sui)
├── icp-chain-fusion/        # ICP Chain Fusion integration (experimental)
├── script/                  # Off-chain utilities (liquidation bot, price updater)
└── src/                     # TypeScript bot services
```

## Core Protocol Components

### Lending Markets
- **PTokens** (pUSDC, pETH, pWBTC, etc.) — Interest-bearing tokens representing supplied assets
- **Interest Rate Models** — Dynamic rates based on utilization (JumpRateModelV2, JumpRateModelBoosted)
- **Peridottroller** — Compound-style risk management, collateral factors, and liquidation logic

### Cross-Chain Architecture
- **Hub Chain** (BNB/Monad): Central lending pools, accounting, and liquidation logic
- **Spoke Chains**: User interfaces on supported chains with cross-chain token transfers
- **$P Token Bridges**: LayerZero OFT adapters for seamless $P transfers across chains

### Advanced Products
- **Dual Investment Manager** — Enter call/put positions with collateral or borrowed funds
- **Margin Manager** — Smart margin accounts with up to 10x leverage on supported pairs
- **Boosted Vaults** — Auto-compounding LP strategies integrated with lending markets

## Build, Test, and Deploy

```bash
# Navigate to contracts directory
cd contracts

# Install dependencies
forge install

# Compile contracts
forge build

# Run tests
forge test

# Run tests with verbosity
forge test -vvv

# Deploy Comptroller
forge script script/DeployPeridottroller.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# Deploy pToken market
forge script script/DeployPErc20Fixed.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# Verify contract (BscScan)
forge verify-contract --chain bsc <address> <path:Contract> --etherscan-api-key $BNB_KEY
```

### Environment Variables

Create a `.env` file with:

```bash
PRIVATE_KEY=<your-deployer-key>
BNB_MAINNET_RPC_URL=<bnb-mainnet-rpc>
BNB_TESTNET_RPC_URL=<bnb-testnet-rpc>
MONAD_RPC_URL=<monad-rpc>
BNB_KEY=<bscscan-api-key>
```

## Documentation

- [GitBook Documentation](https://peridot-finance.gitbook.io/peridot-protocol)
- [Technical Architecture](contracts/PERIDOT_TECHNICAL_ARCHITECTURE.md)
- [Contract Addresses](contracts/addresses.MD)

## Security

- Built on battle-tested Compound V2 architecture
- Reentrancy guards and checks-effects-interactions pattern
- Rate limiting on cross-chain transfers
- Multi-oracle price feeds with staleness protection
- Upgradeable proxy pattern with admin controls
- Never commit secrets; use `.env`

## License

See individual package licenses. Core contracts follow Compound's BSD-3-Clause license.
