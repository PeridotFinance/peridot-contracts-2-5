# Peridot Protocol Liquidation Bot

This directory contains three liquidation bot scripts designed to automatically detect and execute liquidations on the Peridot Protocol (Compound fork) deployed on Monad Testnet.

## Scripts Overview

### 1. LiquidationBot.s.sol

**Basic liquidation bot with core functionality:**

- Scans for undercollateralized positions
- Calculates liquidation opportunities with profit estimates
- Executes liquidations automatically
- Simple account tracking using hardcoded test addresses

**Usage:**

```bash
forge script script/LiquidationBot.s.sol --rpc-url monad_testnet --broadcast --private-key YOUR_PRIVATE_KEY
```

### 2. AdvancedLiquidationBot.s.sol

**Enhanced liquidation bot with advanced features:**

- Sophisticated market state tracking
- Event-based account discovery (framework included)
- Advanced profit calculations with gas cost estimates
- Better error handling and liquidation validation
- Sorting by profitability

**Usage:**

```bash
forge script script/AdvancedLiquidationBot.s.sol --rpc-url monad_testnet --broadcast --private-key YOUR_PRIVATE_KEY
```

### 3. LiquidationMonitor.s.sol

**Production-ready monitoring system:**

- Continuous monitoring capabilities
- Performance statistics tracking
- Emergency stop functionality
- Success rate monitoring
- Gas usage tracking
- Quick scan optimization for high-frequency checks

**Usage:**

```bash
forge script script/LiquidationMonitor.s.sol --rpc-url monad_testnet --broadcast --private-key YOUR_PRIVATE_KEY
```

## Key Features

### Liquidation Logic

- **Health Factor Monitoring**: Detects accounts with health factor < 1.0
- **Close Factor Compliance**: Respects protocol's maximum liquidation percentage (typically 50%)
- **Profit Optimization**: Calculates and prioritizes most profitable liquidations
- **Collateral Validation**: Ensures sufficient collateral available for seizure

### Safety Features

- **Minimum Profit Thresholds**: Only executes profitable liquidations
- **Gas Cost Estimation**: Subtracts estimated gas costs from profit calculations
- **Price Validation**: Checks oracle prices before execution
- **Slippage Protection**: Validates liquidations are still profitable before execution

### Protocol Configuration

- **Unitroller**: `0xa41D586530BC7BC872095950aE03a780d5114445`
- **Oracle**: `0xeAEdaF63CbC1d00cB6C14B5c4DE161d68b7C63A0`
- **PERIDOT Token**: `0x28fE679719e740D15FC60325416bB43eAc50cD15`
- **pUSDC**: `0xA72b43Bd60E5a9a13B99d0bDbEd36a9041269246`
- **pUSDT**: `0xa568bD70068A940910d04117c36Ab1A0225FD140`

## Configuration Parameters

### Liquidation Settings

```solidity
uint256 MIN_LIQUIDATION_AMOUNT = 1e6;      // $1.00 minimum liquidation
uint256 MAX_LIQUIDATION_AMOUNT = 10000e6;  // $10,000 maximum liquidation
uint256 MIN_PROFIT_USD = 1e6;              // $1.00 minimum profit
uint256 LIQUIDATION_INCENTIVE = 1.08e18;   // 8% liquidation bonus
```

### Monitoring Settings

```solidity
uint256 CHECK_INTERVAL = 60;               // 60 seconds between checks
uint256 MAX_SLIPPAGE = 0.05e18;           // 5% maximum slippage
uint256 HEALTH_FACTOR_THRESHOLD = 1.03e18; // Liquidate when HF < 1.03
```

## Account Discovery

### Current Implementation

The scripts use hardcoded test addresses for demonstration. In production, you would implement event-based account tracking:

```solidity
// Event signatures for account tracking
bytes32 constant MINT_EVENT = keccak256("Mint(address,uint256,uint256)");
bytes32 constant BORROW_EVENT = keccak256("Borrow(address,uint256,uint256,uint256)");
bytes32 constant REDEEM_EVENT = keccak256("Redeem(address,uint256,uint256)");
bytes32 constant REPAY_BORROW_EVENT = keccak256("RepayBorrow(address,address,uint256,uint256,uint256)");
```

### Production Implementation

For production use, implement:

1. **Event Log Parsing**: Parse past events to discover active accounts
2. **Real-time Monitoring**: Subscribe to new events for account updates
3. **Database Integration**: Store and update account states efficiently
4. **API Integration**: Use The Graph or similar indexing service

## Profit Calculation

### Basic Formula

```
Profit = (Collateral Seized Value * Liquidation Incentive) - Repay Amount - Gas Costs
```

### Detailed Calculation

1. **Maximum Repay Amount**: `borrowBalance * closeFactorMantissa`
2. **Seizure Amount**: `(repayAmount * borrowPrice * liquidationIncentive) / collateralPrice`
3. **Profit Estimate**: `seizeValueUSD - repayValueUSD - gasCosts`

## Error Handling

### Common Error Codes

- `0`: Success
- `1`: Unauthorized
- `2`: Bad Input
- `3`: Market Closed
- `4`: Insufficient Liquidity
- `9`: Calculation Error

### Validation Checks

- Account still liquidatable
- Sufficient collateral available
- Oracle prices valid
- Profit still above minimum threshold

## Gas Optimization

### Strategies Implemented

1. **Quick Scans**: Fast initial checks before detailed calculations
2. **Batch Processing**: Process multiple liquidations in single transaction
3. **Priority Sorting**: Execute highest-profit liquidations first
4. **Early Termination**: Skip unprofitable opportunities quickly

## Monitoring and Analytics

### Statistics Tracked

- Total liquidations executed
- Success/failure rates
- Total profit generated
- Gas consumption
- Average profit per liquidation

### Performance Metrics

```bash
=== LIQUIDATION MONITOR SUMMARY ===
Total liquidations executed: 42
Successful liquidations: 38
Failed liquidations: 4
Total profit generated: $156.78
Success rate: 90%
====================================
```

## Production Deployment

### Requirements

1. **Funded Account**: Ensure liquidator account has sufficient tokens
2. **Oracle Access**: Verify oracle is providing accurate prices
3. **Network Monitoring**: Monitor network congestion and gas prices
4. **Emergency Procedures**: Implement kill switches and emergency stops

### Recommended Setup

1. **Multi-sig Control**: Use multi-sig for emergency functions
2. **Monitoring Alerts**: Set up alerts for failed liquidations
3. **Profit Tracking**: Monitor profitability and adjust parameters
4. **Regular Updates**: Update account lists and market parameters

## Security Considerations

### Risks

- **MEV Competition**: Other bots may front-run liquidations
- **Oracle Manipulation**: Price feed attacks could affect calculations
- **Smart Contract Risk**: Protocol upgrades or bugs
- **Slippage**: Market conditions changing between detection and execution

### Mitigations

- **Private Mempools**: Use Flashbots or similar for MEV protection
- **Multiple Oracles**: Cross-reference price feeds
- **Circuit Breakers**: Implement maximum loss limits
- **Regular Audits**: Review and update bot logic regularly

## Troubleshooting

### Common Issues

1. **No Liquidation Opportunities**: Check market conditions and account activity
2. **Failed Transactions**: Verify gas settings and account balances
3. **Low Profitability**: Adjust minimum profit thresholds
4. **Oracle Errors**: Check oracle connectivity and price feeds

### Debug Commands

```bash
# Check account liquidity
cast call $UNITROLLER "getAccountLiquidity(address)" $ACCOUNT --rpc-url monad_testnet

# Check market prices
cast call $ORACLE "getUnderlyingPrice(address)" $PTOKEN --rpc-url monad_testnet

# Check close factor
cast call $UNITROLLER "closeFactorMantissa()" --rpc-url monad_testnet
```

## Support

For issues or questions regarding the liquidation bot:

1. Check protocol documentation
2. Review Compound v2 liquidation mechanics
3. Test on smaller amounts first
4. Monitor gas prices and network conditions

Remember to test thoroughly on testnet before running on mainnet with real funds.
