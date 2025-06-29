# Peridot CCIP V2 Feature Guide

## 🆕 V2 vs V1 Comparison

### Core Enhancements

| Feature                    | V1                 | V2                                       |
| -------------------------- | ------------------ | ---------------------------------------- |
| **CCIP Version**           | CCIP 1.0           | CCIP 1.5.1 ✨                            |
| **Out-of-Order Execution** | ❌                 | ✅                                       |
| **Enhanced Token Support** | Basic ERC20        | BurnMintERC20 + Configurable Decimals ✨ |
| **Automation**             | Manual operations  | Chainlink Automation ✨                  |
| **Price Oracle**           | Pyth Network       | Chainlink Price Feeds ✨                 |
| **Emergency Controls**     | Basic              | Advanced Guardian System ✨              |
| **Batch Operations**       | Single tx only     | Multi-token batching ✨                  |
| **Cross-Chain Tokens**     | Same decimals only | Different decimals support ✨            |
| **Monitoring**             | Manual             | Automated health monitoring ✨           |

### New V2-Exclusive Features

#### 🚀 CCIP 1.5.1 Features

- **Out-of-Order Execution**: Messages can execute in parallel for better UX
- **Enhanced Token Pools**: Multiple active pools, seamless upgrades
- **Improved Security**: Better access controls and fail-safes

#### 🤖 Chainlink Automation

- **Automated Liquidations**: No manual intervention needed
- **Interest Rate Updates**: Continuous rate optimization
- **Oracle Price Refresh**: Automatic stale price detection and updates
- **Cross-Chain Synchronization**: Automated position syncing
- **Health Factor Monitoring**: 24/7 position risk assessment

#### 🔒 Enhanced Security

- **Emergency Guardians**: Multi-signature emergency controls
- **Circuit Breakers**: Automatic pause on unusual activity
- **Rate Limiting**: Configurable operation limits
- **Position Tracking**: Real-time cross-chain position monitoring

#### 💰 Advanced Token Management

- **Cross-Chain Standardization**: Unified token experience across chains
- **Configurable Decimals**: Support for different token decimals per chain
- **Enhanced Minting**: Daily limits, authorized minters, batch operations
- **Token Mapping**: Seamless cross-chain token relationships

## 🔄 Migration Guide

### For New Deployments

Simply use the V2 deployment scripts:

```bash
# Deploy complete V2 system
forge script script/DeployPeridotCCIPV2.s.sol --broadcast
```

### For Existing V1 Deployments

#### Step 1: Deploy V2 Contracts Alongside V1

```bash
# Deploy V2 contracts (won't affect V1)
forge script script/DeployPeridotCCIPV2.s.sol --broadcast

# Configure V2 with new features
forge script script/ConfigureV2Features.s.sol --broadcast
```

#### Step 2: Test V2 Functionality

```bash
# Test automation
forge script script/TestChainlinkAutomation.s.sol

# Test CCIP 1.5.1 features
forge script script/TestCCIPV2Features.s.sol

# Test enhanced tokens
forge script script/TestEnhancedTokens.s.sol
```

#### Step 3: Gradual Migration

1. **Phase 1**: Deploy V2 contracts
2. **Phase 2**: Migrate price oracle to Chainlink
3. **Phase 3**: Set up automation
4. **Phase 4**: Enable V2 features
5. **Phase 5**: Migrate user positions (optional)

## 📋 Configuration Checklist

### Essential V2 Setup

#### ✅ Chainlink Services Configuration

1. **CCIP 1.5.1**

   ```bash
   # Configure chains with out-of-order execution
   hub.configureChain(chainSelector, spokeAddress, true, true)

   # Set up enhanced token configs
   hub.configureToken(token, decimals, maxSupply, tokenPool, true, dailyLimit)
   ```

2. **Automation Setup**

   ```bash
   # Configure automation jobs
   automation.configureJob(JobType.LIQUIDATION, true, 5 minutes, 2000000, "")
   automation.configureJob(JobType.ORACLE_UPDATE, true, 30 minutes, 500000, "")

   # Register with Chainlink Automation
   # - Go to automation.chain.link
   # - Register new upkeep
   # - Fund with LINK tokens
   ```

3. **Price Feeds**

   ```bash
   # Configure Chainlink price feeds
   ORACLE_ADDRESS=0x... forge script script/ConfigureChainlinkFeeds.s.sol --broadcast

   # Test price feed functionality
   oracle.getChainlinkPrice(tokenAddress)
   ```

#### ✅ Enhanced Security Setup

1. **Emergency Guardians**

   ```bash
   # Add emergency guardians
   hub.addEmergencyGuardian(guardian1)
   hub.addEmergencyGuardian(guardian2)

   # Test emergency pause
   hub.emergencyPause() // Can be called by guardians
   ```

2. **Rate Limiting**

   ```bash
   # Configure daily mint limits
   token.setDailyMintLimit(10_000_000 * 1e6) // 10M USDC per day

   # Set up minter authorization
   token.authorizeMinter(hubAddress, 1_000_000 * 1e6) // 1M USDC limit
   ```

#### ✅ Cross-Chain Token Setup

1. **Token Mapping**

   ```bash
   # Map tokens across chains
   tokenV2.mapChainToken(arbitrumSelector, arbitrumTokenAddress)
   tokenV2.mapChainToken(baseSelector, baseTokenAddress)
   tokenV2.mapChainToken(polygonSelector, polygonTokenAddress)

   # Enable chain support
   tokenV2.setSupportedChain(arbitrumSelector, true)
   tokenV2.setSupportedChain(baseSelector, true)
   ```

2. **Enhanced Features**

   ```bash
   # Enable batch operations
   hub.setMaxOperationsPerBatch(10)

   # Configure out-of-order execution
   hub.setOutOfOrderExecution(true)
   ```

## 🎯 Best Practices

### Gas Optimization

- Use batch operations for multiple token transfers
- Enable out-of-order execution for better throughput
- Configure appropriate gas limits per operation type

### Security

- Use emergency guardians for critical operations
- Set up monitoring for unusual activity patterns
- Implement gradual rollout for new features

### Operations

- Monitor automation job performance
- Set up alerts for failed operations
- Regular health checks on cross-chain positions

### User Experience

- Provide clear fee estimation
- Show real-time operation status
- Enable automatic retries for failed operations

## 🔧 Troubleshooting

### Common Issues

#### CCIP Messages Failing

```bash
# Check chain configuration
hub.allowlistedChains(chainSelector)

# Verify gas limits
hub.defaultGasLimit() // Should be sufficient

# Check LINK balance for fees
linkToken.balanceOf(hubAddress)
```

#### Automation Not Triggering

```bash
# Check upkeep registration
automation.checkUpkeep("")

# Verify LINK funding
// Ensure automation upkeep has sufficient LINK

# Check job configuration
automation.getJobStatus(JobType.LIQUIDATION)
```

#### Price Feed Issues

```bash
# Check aggregator configuration
oracle.getAggregator(tokenAddress)

# Test price retrieval
oracle.getChainlinkPrice(tokenAddress)

# Verify staleness settings
oracle.isPriceStale(tokenAddress)
```

#### Token Operations Failing

```bash
# Check minter authorization
token.authorizedMinters(address)

# Verify daily limits
token.getDailyMintInfo()

# Check cross-chain support
token.isChainSupported(chainSelector)
```

## 📈 Performance Monitoring

### Key Metrics to Track

1. **CCIP Performance**

   - Message delivery time
   - Fee costs per operation
   - Success rate by chain

2. **Automation Efficiency**

   - Job execution frequency
   - Gas usage per job
   - Failed operation count

3. **Token Operations**

   - Cross-chain mint/burn volume
   - Daily limit utilization
   - Failed transaction rate

4. **Security Metrics**
   - Emergency pause triggers
   - Guardian action frequency
   - Health factor violations

### Monitoring Setup

```bash
# Set up event monitoring
# Monitor key events: MessageSent, JobExecuted, EmergencyPauseActivated
# Set up alerts for critical events

# Performance dashboards
# Track gas usage, transaction success rates, automation performance
# Monitor cross-chain position health factors
```

## 🚀 Future Enhancements

### Planned Features

- **Chainlink Functions Integration**: Advanced off-chain computations
- **VRF Integration**: Randomized liquidation ordering
- **Cross-Chain Governance**: Decentralized protocol governance
- **Advanced Analytics**: ML-powered risk assessment

### Community Contributions

- Submit feature requests via GitHub issues
- Contribute to testing on testnets
- Provide feedback on user experience improvements

---

**📞 Support**

- **Documentation**: [Chainlink CCIP Docs](https://docs.chain.link/ccip)
- **Community**: [Discord](https://discord.gg/chainlink)
- **GitHub**: [Peridot CCIP Issues](https://github.com/your-repo/issues)

**✨ Ready to get started with V2? Follow the deployment guide and join the next generation of cross-chain DeFi!**
