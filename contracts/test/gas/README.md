# Gas Stress Tests

This directory contains comprehensive gas stress tests for the Peridot protocol to ensure that no operations hit gas limits under heavy load conditions.

## ✅ Working Test Files

### 1. SimpleBoostedGasStress.t.sol

Tests for Morpho boosted markets with extensive user load simulation.

**Scenarios Tested:**

- `testGas_ManyUsersMint`: 100 users minting sequentially
- `testGas_ManyUsersRedeem`: 100 users redeeming after minting
- `testGas_SequentialMintsByOneUser`: Single user performing 50 sequential mints
- `testGas_ExchangeRateCalculation`: Exchange rate calculation with 50 users
- `testGas_AccrueInterest`: Interest accrual with 100 users after 365 days

**Measured Gas Usage:**

- First mint: ~215k gas
- 99th mint: ~88k gas (gas decreases due to storage warm-up)
- Redeem: ~48k gas (constant)
- Accrue interest: ~1.7k gas (O(1) - stays constant with user count!)
- Exchange rate: ~9.7k gas

### 2. MarginGasStress.t.sol

Tests for leveraged margin trading system.

**Scenarios Tested:**

- `testGas_ManyUsersCreateAccounts`: 50 users creating margin accounts
- `testGas_DepositAcrossAllMarkets`: Depositing to all 5 markets sequentially
- `testGas_BorrowFromMultipleMarkets`: Borrowing from 3 different markets
- `testGas_GetAccountMetricsWithManyMarkets`: Risk calculation with 5 markets
- `testGas_WithdrawWithManyMarkets`: Withdrawal with 5 active markets
- `testGas_TradeWithMultipleMarkets`: Swap operation with 3 active markets
- `testGas_LeveragedPositionWithManyMarkets`: Opening leveraged position
- `testGas_RepayWithManyBorrows`: Repaying with 4 active borrows
- `testGas_ManyUsersWithManyMarkets`: 20 users each with 3 markets

**Gas Limits:**

- Account Creation: < 300k gas
- 5th Market Deposit: < 600k gas
- 3rd Borrow: < 700k gas
- Metrics (5 markets): < 500k gas
- Withdraw (5 markets): < 700k gas
- Trade: < 800k gas
- Open Leveraged Position: < 1M gas
- Repay: < 600k gas

### 3. DualInvestmentGasStress.t.sol

Tests for dual investment structured products.

**Scenarios Tested:**

- `testGas_ManyUsersCreateProducts`: 100 users creating products
- `testGas_ManyUsersDepositBullish`: 100 users depositing to bullish product
- `testGas_ManyUsersDepositBearish`: 50 users depositing to bearish product
- `testGas_ManyUsersWithdrawAfterSettlement`: 100 users withdrawing after settlement
- `testGas_SettleWithManyDepositors`: Settlement with 100 depositors
- `testGas_MultipleProductsMultipleUsers`: 5 products, 20 users each
- `testGas_EmergencyWithdrawWithManyUsers`: Emergency withdrawal stress test
- `testGas_SequentialDepositsWithdrawals`: 10 products, sequential operations
- `testGas_BullishProductReachingCap`: Deposits approaching cap limit

**Gas Limits:**

- Create Product: < 500k gas
- Deposit: < 300k gas
- Withdraw: < 250k gas
- Settlement: < 300k gas (O(1) regardless of depositor count)
- Emergency Withdraw: < 200k gas

### 4. MorphoMagmaBoostedGasStress.t.sol

Tests for Morpho and Magma protocol integrations with their specific features.

**Morpho Tests:**

- `testGas_MorphoManyUsersMintRedeem`: 50 mints, 20 redeems
- `testGas_MorphoVaultRebalance`: Rebalance with 100 users
- `testGas_MorphoHarvestWithManyUsers`: Harvest with 100 users
- `testGas_MorphoBufferStressTest`: Low buffer (5%) stress test with 30 withdrawals

**Magma Tests:**

- `testGas_MagmaManyUsersMintRedeem`: 50 mints, 10 redeems
- `testGas_MagmaAsyncRedemptionFlow`: Full async redemption cycle
- `testGas_MagmaBufferManagement`: Buffer adjustment operations
- `testGas_MagmaPermissionlessRedemptionRequest`: Permissionless redemption trigger
- `testGas_MagmaVaultPause`: Pause/unpause operations

**Combined:**

- `testGas_ParallelOperationsBothProtocols`: 30 users operating on both protocols simultaneously

**Gas Limits:**

- Morpho Redeem: < 700k gas
- Morpho Rebalance: < 300k gas
- Morpho Harvest: < 500k gas
- Magma Redeem: < 700k gas
- Magma Request Redemption: < 300k gas
- Magma Complete Redemption: < 400k gas
- Magma Permissionless Request: < 350k gas

## Running the Tests

### Run All Gas Tests

```bash
forge test --match-path "test/gas/*.t.sol" --gas-report
```

### Run Specific Test Suite

```bash
# Boosted markets
forge test --match-path "test/gas/BoostedMarketsGasStress.t.sol" -vv

# Margin trading
forge test --match-path "test/gas/MarginGasStress.t.sol" -vv

# Dual investment
forge test --match-path "test/gas/DualInvestmentGasStress.t.sol" -vv

# Morpho & Magma
forge test --match-path "test/gas/MorphoMagmaBoostedGasStress.t.sol" -vv
```

### Run with Detailed Gas Reporting

```bash
forge test --match-path "test/gas/*.t.sol" --gas-report -vvv
```

### Run Specific Test Function

```bash
forge test --match-test "testGas_ManyUsersMintBoosted" -vv
```

## Test Methodology

### User Simulation

- Tests create 50-100 user addresses
- Each user gets initial token balances (1M USDC, 1000 WETH, etc.)
- Operations are performed sequentially to measure gas at different points

### Gas Measurement Points

1. **First User**: Baseline gas cost
2. **Mid-Point** (25th or 50th user): Check for linear growth
3. **Last User** (99th or 100th user): Maximum expected gas

### Edge Cases Covered

1. **High User Count**: 50-100 concurrent users
2. **Multiple Markets**: Up to 5 markets per user
3. **Large Time Periods**: Interest accrual over 365 days
4. **Buffer Stress**: Low buffer settings (5-10%)
5. **Extreme Deposits**: 500k+ USDC single deposits
6. **Sequential Operations**: 50+ operations by single user
7. **Parallel Protocols**: Operating on multiple protocols simultaneously

### Assertions

- Each test includes `assertLt()` checks to ensure gas stays under specified limits
- Gas increase from first to last user should be minimal (< 100k gas)
- O(1) operations (rebalance, harvest, accrue interest) should stay constant
- O(n) operations (metrics calculation) should scale linearly with n

## Gas Optimization Notes

### O(1) Operations

These operations should have constant gas regardless of user count:

- `rebalance()` - Only updates buffer ratios
- `accrueInterest()` - Time-based calculation
- `harvest()` - Claim and reinvest rewards
- `settle()` - Product settlement calculation

### O(n) Operations

These operations scale with the number of markets/positions:

- `getAccountMetrics()` - Iterates through user's markets
- `_getUserMarkets()` - Copies market array
- Deposit/Withdraw when entering new markets

### Optimization Strategies

1. **Bounded Loops**: MAX_MARKETS_PER_ACCOUNT prevents unbounded iteration
2. **Storage Patterns**: Use storage references, avoid memory copies
3. **Early Returns**: Exit loops early when possible
4. **Lazy Updates**: Only update state when necessary
5. **Batch Operations**: Group state changes together

## Interpreting Results

### Acceptable Gas Ranges

| Operation           | Good   | Acceptable | Concerning |
| ------------------- | ------ | ---------- | ---------- |
| Mint/Deposit        | < 300k | < 500k     | > 500k     |
| Redeem/Withdraw     | < 400k | < 700k     | > 700k     |
| Borrow              | < 400k | < 700k     | > 700k     |
| Trade               | < 600k | < 800k     | > 800k     |
| Leverage Position   | < 800k | < 1M       | > 1M       |
| Rebalance/Harvest   | < 200k | < 400k     | > 400k     |
| Metrics Calculation | < 300k | < 500k     | > 500k     |

### Warning Signs

- **Linear Growth**: Gas increasing significantly with each user
- **Quadratic Growth**: Gas increasing exponentially
- **Sudden Spikes**: Large jumps in gas at certain thresholds
- **Near Block Limit**: Any operation > 10M gas (risky)

## Continuous Monitoring

### Pre-Deployment Checklist

- [ ] All gas stress tests pass
- [ ] No operation exceeds 1M gas under normal conditions
- [ ] O(1) operations stay constant with user growth
- [ ] Buffer management doesn't cause excessive gas spikes
- [ ] Multi-market operations scale linearly

### Post-Deployment Monitoring

- Monitor actual gas usage on mainnet
- Compare actual vs. test results
- Watch for gas spikes during high activity
- Adjust MAX_MARKETS_PER_ACCOUNT if needed
- Consider gas optimizations for frequently-called functions

## Future Enhancements

### Additional Test Scenarios

1. Fork tests against actual mainnet state
2. Cross-chain operation gas tests
3. Flash loan integration gas tests
4. Liquidation gas under various conditions
5. Oracle update gas costs
6. Governance operations gas

### Profiling Tools

- Use `forge test --gas-report` for detailed breakdown
- Analyze opcodes with `--debug` flag
- Use `forge snapshot` for gas comparisons
- Profile with `flamegraph` for bottleneck identification

## Contact

For questions about gas optimization or test failures, please contact the Peridot development team.
