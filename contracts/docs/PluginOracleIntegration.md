# Plugin Oracle Integration with Peridot Protocol

## Overview

This guide shows how to integrate Plugin oracles with your existing Peridottroller and PErc20 contracts. The integration is seamless since both contracts already implement the standard `PriceOracle` interface.

## Architecture

```
Peridottroller.sol
    ↓ calls oracle.getUnderlyingPrice(pToken)
PluginDirectOracle.sol
    ↓ uses assetToFeedsAccess mapping
FeedsAccess.sol (per asset)
    ↓ calls feeds.latestRoundData()
Plugin Aggregator Contract (0x7D27...B497)
```

## Step-by-Step Integration

### Step 1: Get Plugin Aggregator Addresses

Visit [Plugin Feeds](https://feeds.goplugin.co) and get the aggregator addresses for your assets:

**Example for XDC Apothem:**

- XDC/USDT: `0x7D27B497B4C8d0E1c6e3c0B4E8F9A2C3D4E5F6A7`
- PLI/USDT: `0x8E38C508C9F0F2D4F0A1B2C3D4E5F6A7B8C9D0E1`

### Step 2: Deploy Plugin Oracle

```bash
# Set environment variables
export PRIVATE_KEY="your_private_key"
export RPC_URL="your_rpc_url"

# Deploy the oracle
forge script script/IntegratePluginOracle.s.sol --rpc-url $RPC_URL --broadcast
```

### Step 3: Update Asset and Aggregator Addresses

Edit `script/IntegratePluginOracle.s.sol` and update:

```solidity
// Replace with real Plugin aggregator addresses from their docs
address constant XDC_USD_AGGREGATOR = 0x7D27B497B4C8d0E1c6e3c0B4E8F9A2C3D4E5F6A7;
address constant PLI_USD_AGGREGATOR = 0x8E38C508C9F0F2D4F0A1B2C3D4E5F6A7B8C9D0E1;

// Replace with your actual token addresses
address constant XDC_TOKEN = 0xYourXDCTokenAddress;
address constant PLI_TOKEN = 0xYourPLITokenAddress;
```

### Step 4: Connect Oracle to Peridottroller

```bash
# Set the oracle address in Peridottroller
export PERIDOTTROLLER_ADDRESS="your_peridottroller_address"
export PLUGIN_ORACLE_ADDRESS="deployed_oracle_address"

forge script script/UpdatePeridottrollerOracle.s.sol --rpc-url $RPC_URL --broadcast
```

## How It Works

### 1. Price Fetching Flow

When Peridottroller needs a price:

```solidity
// In Peridottroller.sol (line 508)
if (oracle.getUnderlyingPrice(PToken(pToken)) == 0) {
    return uint(Error.PRICE_ERROR);
}
```

### 2. Oracle Resolution

The Plugin oracle resolves the price:

```solidity
// In PluginDirectOracle.sol
function getUnderlyingPrice(PToken pToken) external view override returns (uint) {
    address asset = _getUnderlyingAddress(pToken); // Gets underlying from PErc20
    address feedsAccessAddress = assetToFeedsAccess[asset]; // Gets registered feed

    // Fetches price from Plugin aggregator via FeedsAccess
    uint priceMantissa = this._getFeedsPrice(feedsAccessAddress, asset);
    return priceMantissa; // Returns 18-decimal price
}
```

### 3. Asset Address Resolution

For PErc20 tokens, the oracle gets the underlying asset:

```solidity
// In PluginDirectOracle.sol
function _getUnderlyingAddress(PToken pToken) private view returns (address) {
    if (compareStrings(pToken.symbol(), "pETH")) {
        return 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // ETH placeholder
    } else {
        return address(PErc20(address(pToken)).underlying()); // ERC20 token address
    }
}
```

## Testing Integration

### Test Oracle Prices

```bash
# Test all market prices
forge script script/UpdatePeridottrollerOracle.s.sol:UpdatePeridottrollerOracle \
  --sig "testOraclePrices(address)" $PERIDOTTROLLER_ADDRESS \
  --rpc-url $RPC_URL
```

### Manual Testing

```solidity
// Get price for a specific pToken
uint price = peridottroller.oracle().getUnderlyingPrice(pTokenAddress);
console.log("Price:", price); // Should return price in 18 decimals
```

## Key Integration Points

### 1. Peridottroller Integration

The Peridottroller uses the oracle in several places:

- **Borrowing**: Checks asset prices before allowing borrows
- **Liquidation**: Calculates liquidation amounts using prices
- **Collateral**: Values collateral using oracle prices

```solidity
// Example from Peridottroller.sol
vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
if (vars.oraclePriceMantissa == 0) {
    return (Error.PRICE_ERROR, 0, 0);
}
```

### 2. PErc20 Integration

PErc20 contracts provide the underlying asset address:

```solidity
// In PErc20.sol
address public underlying; // The ERC20 token address

// Oracle uses this to map pToken -> underlying -> price feed
```

### 3. Price Format

All prices are returned in 18-decimal format:

```solidity
// Example: $2000.50 USD = 2000500000000000000000 (18 decimals)
uint price = oracle.getUnderlyingPrice(pToken);
```

## Configuration Options

### 1. Stale Price Thresholds

Set different thresholds per asset:

```solidity
oracle.setAssetStaleThreshold(XDC_TOKEN, 1800); // 30 minutes
oracle.setAssetStaleThreshold(PLI_TOKEN, 3600); // 1 hour
```

### 2. Manual Price Fallbacks

Set manual prices as fallbacks:

```solidity
oracle.setUnderlyingPrice(pToken, 2000 * 1e18); // $2000 USD
```

### 3. Admin Management

Add/remove admins:

```solidity
oracle.setAdmin(newAdminAddress);
oracle.removeAdmin(oldAdminAddress);
```

## Error Handling

The oracle handles various error scenarios:

1. **Stale Prices**: Reverts if price is too old
2. **Invalid Feeds**: Falls back to manual prices
3. **No Price Available**: Reverts with clear error message

## Migration from Existing Oracle

If you're migrating from another oracle:

1. Deploy new Plugin oracle
2. Set up all required feeds
3. Test prices for all markets
4. Update Peridottroller to use new oracle
5. Verify all functionality works

## Production Checklist

- [ ] All aggregator addresses verified from Plugin docs
- [ ] All asset addresses correct
- [ ] Stale thresholds set appropriately
- [ ] Manual fallback prices set if needed
- [ ] Oracle ownership transferred to multisig
- [ ] All markets tested for price fetching
- [ ] Peridottroller successfully updated

## Troubleshooting

### Common Issues

1. **"No valid price available"**: Feed not registered for asset
2. **"Price feed is stale"**: Aggregator not updating, check threshold
3. **"Only admin can call"**: Wrong account calling admin functions

### Debug Commands

```bash
# Check if feed is registered
cast call $ORACLE_ADDRESS "assetToFeedsAccess(address)" $ASSET_ADDRESS

# Check price directly
cast call $ORACLE_ADDRESS "getUnderlyingPrice(address)" $PTOKEN_ADDRESS

# Check stale threshold
cast call $ORACLE_ADDRESS "feedsStaleThreshold(address)" $ASSET_ADDRESS
```

## Support

For issues with:

- **Plugin Feeds**: Check [Plugin Documentation](https://docs.goplugin.co)
- **Oracle Integration**: Review this guide and test scripts
- **Peridot Protocol**: Check existing Peridottroller functionality
