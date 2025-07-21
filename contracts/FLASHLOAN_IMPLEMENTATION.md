# Peridot Flash Loan Implementation

## Overview

This implementation adds ERC-3156 compliant flash loan functionality to your Peridot (Compound V2 fork) protocol. Flash loans allow users to borrow large amounts of assets without collateral, as long as they repay the loan plus fees within the same transaction.

## Features

- **ERC-3156 Compliant**: Implements the standard flash loan interface
- **Configurable Fees**: Admin can set flash loan fees (in basis points)
- **Liquidity Limits**: Admin can set maximum flash loan amounts as percentage of available cash
- **Pause Functionality**: Admin can pause/unpause flash loans
- **Multi-token Support**: Works with both ERC20 tokens (PErc20) and ETH (PEther)
- **Security Features**: Reentrancy protection, authorization checks, and proper callback validation

## Implementation Components

### 1. Modified Files

#### `PTokenInterfaces.sol`

- Added ERC-3156 interfaces (`IERC3156FlashLender`, `IERC3156FlashBorrower`)
- Added flash loan storage variables (`flashLoanFeeBps`, `maxFlashLoanRatio`, `flashLoansPaused`)
- Added flash loan events (`FlashLoan`, `NewFlashLoanFee`, etc.)
- Added flash loan function declarations

#### `PToken.sol`

- Implemented core flash loan functionality
- Added `maxFlashLoan()`, `flashFee()`, and `flashLoan()` functions
- Added admin functions for configuration
- Added `getUnderlyingAddress()` virtual function

#### `PErc20.sol`

- Implemented `getUnderlyingAddress()` to return the underlying ERC20 token address

#### `PEther.sol`

- Implemented `getUnderlyingAddress()` to return ETH sentinel address

#### `ErrorReporter.sol`

- Added flash loan error codes

### 2. New Files

#### `FlashLoanExample.sol`

- Complete example implementation of flash loan borrower
- Demonstrates various use cases (arbitrage, liquidation, collateral swap)
- Security best practices

## Configuration

### Initial Setup

After deploying your updated contracts, you need to configure flash loans:

```solidity
// Set flash loan fee to 0.05% (5 basis points)
pToken._setFlashLoanFee(5);

// Set maximum flash loan to 80% of available cash
pToken._setMaxFlashLoanRatio(8000);

// Enable flash loans (they start disabled)
pToken._setFlashLoansPaused(false);
```

### Admin Functions

```solidity
// Set flash loan fee (in basis points, max 100 = 1%)
function _setFlashLoanFee(uint newFeeBps) external returns (uint);

// Set max flash loan ratio (in basis points, max 10000 = 100%)
function _setMaxFlashLoanRatio(uint newMaxRatio) external returns (uint);

// Pause/unpause flash loans
function _setFlashLoansPaused(bool state) external returns (bool);
```

## Usage Examples

### Basic Flash Loan

```solidity
contract MyFlashLoanBorrower is IERC3156FlashBorrower {
    function executeFlashLoan(address pToken, address token, uint256 amount) external {
        bytes memory data = abi.encode("MY_ACTION", someData);
        IERC3156FlashLender(pToken).flashLoan(this, token, amount, data);
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        // Your logic here
        // ...

        // Approve repayment
        IERC20(token).approve(msg.sender, amount + fee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
```

### Using the Example Contract

```solidity
// Deploy the example contract
FlashLoanExample flashLoanExample = new FlashLoanExample();

// Authorize the PToken to call back
flashLoanExample.authorizeLender(address(pToken));

// Execute a simple transfer flash loan
bytes memory extraData = abi.encode(recipientAddress);
flashLoanExample.executeFlashLoan(
    address(pToken),
    tokenAddress,
    1000 * 1e18,
    keccak256("SIMPLE_TRANSFER"),
    extraData
);
```

## Use Cases

### 1. Arbitrage

```solidity
// Flash loan to exploit price differences between exchanges
bytes memory arbitrageData = abi.encode(targetExchange, minProfit);
flashLoanExample.executeFlashLoan(
    pTokenAddress,
    tokenAddress,
    amount,
    keccak256("ARBITRAGE"),
    arbitrageData
);
```

### 2. Liquidation

```solidity
// Flash loan to liquidate underwater positions
bytes memory liquidationData = abi.encode(borrower, collateralToken, repayAmount);
flashLoanExample.executeFlashLoan(
    pTokenAddress,
    tokenAddress,
    amount,
    keccak256("LIQUIDATION"),
    liquidationData
);
```

### 3. Collateral Swap

```solidity
// Flash loan to swap collateral types without partial liquidation
bytes memory swapData = abi.encode(newCollateralToken, swapRatio);
flashLoanExample.executeFlashLoan(
    pTokenAddress,
    tokenAddress,
    amount,
    keccak256("COLLATERAL_SWAP"),
    swapData
);
```

## Security Considerations

### 1. Reentrancy Protection

- All flash loan functions use the `nonReentrant` modifier
- Proper state updates before external calls

### 2. Authorization Checks

- Only authorized lenders can call the callback
- Proper initiator verification

### 3. Fee and Repayment Validation

- Fees are calculated consistently
- Repayment is verified by checking balance differences
- Fees are added to protocol reserves

### 4. Liquidity Limits

- Maximum flash loan amounts are enforced
- Available cash is checked before lending

## Integration with Peridottroller

You may want to add flash loan hooks to the Peridottroller for additional risk management:

```solidity
// In Peridottroller.sol
function flashLoanAllowed(
    address pToken,
    address borrower,
    uint amount
) external view returns (uint) {
    // Additional checks (e.g., borrower blacklist, global limits)
    return uint(Error.NO_ERROR);
}
```

## Testing

Create comprehensive tests covering:

1. **Basic Functionality**

   - Successful flash loans
   - Fee calculations
   - Repayment verification

2. **Edge Cases**

   - Insufficient liquidity
   - Invalid callbacks
   - Paused state

3. **Security Tests**

   - Reentrancy attempts
   - Unauthorized access
   - Invalid repayments

4. **Admin Functions**
   - Fee updates
   - Ratio changes
   - Pause/unpause

## Gas Optimization

- Flash loans are gas-intensive due to external calls
- Consider batching multiple operations in a single flash loan
- Optimize callback logic for common use cases

## Monitoring and Analytics

Track flash loan usage with events:

- `FlashLoan(receiver, token, amount, fee)`
- `NewFlashLoanFee(oldFee, newFee)`
- `FlashLoansPaused(paused)`

## Deployment Checklist

1. ✅ Deploy updated PToken contracts
2. ✅ Verify flash loan functions are accessible
3. ✅ Set initial flash loan parameters
4. ✅ Test with small amounts first
5. ✅ Monitor for any issues
6. ✅ Deploy example contracts for integration testing
7. ✅ Update documentation and interfaces

## Future Enhancements

- **Cross-chain Flash Loans**: Using Chainlink CCIP for cross-chain liquidity
- **Flash Loan Aggregator**: Routing to best available liquidity
- **Dynamic Fees**: Fee adjustment based on utilization
- **Flash Loan Pools**: Dedicated liquidity pools for flash loans

## Support

For questions or issues with the flash loan implementation:

1. Check the example contracts for usage patterns
2. Review the test cases for edge case handling
3. Ensure proper ERC-3156 compliance in your borrower contracts
