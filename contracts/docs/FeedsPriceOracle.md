# FeedsPriceOracle Documentation

## Overview

The `FeedsPriceOracle` is a push-based price oracle that replaces the pull-based Pyth oracle in the Peridot protocol. It uses the `FeedsAccess` contract to interact with external price feed aggregators that implement the `IFeeds` interface.

## Key Differences from Pyth Oracle

### Pull vs Push Architecture

- **Pyth Oracle (Old)**: Pull-based system where prices need to be actively updated by submitting price update data
- **FeedsPriceOracle (New)**: Push-based system where external aggregators automatically update prices

### Price Updates

- **Pyth**: Required calling `updatePythPrices()` with price update data and paying fees
- **Feeds**: Prices are automatically updated by external aggregators, no manual updates needed

### Stale Price Handling

- **Pyth**: Used `pythPriceStaleThreshold` globally
- **Feeds**: Supports both global `defaultStaleThreshold` and per-asset `feedsStaleThreshold`

## Architecture

```
FeedsPriceOracle
├── FeedsAccess (per asset)
│   └── IFeeds (external aggregator)
├── Price Caching System
├── Manual Price Fallback
└── Admin Controls
```

## Core Components

### 1. IFeeds Interface

External price feed aggregators must implement:

```solidity
interface IFeeds {
    function latestAnswer() external view returns (uint256);
    function latestRoundData() external view returns (uint80, uint256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
    function latestRound() external view returns (uint256);
    function owner() external view returns (address);
    function description() external view returns (string memory);
}
```

### 2. FeedsAccess Contract

Wrapper contract that provides a clean interface to external feed aggregators:

```solidity
contract FeedsAccess {
    function fetchLatestAnswer() external view returns (uint256);
    function fetchLatestRoundData() external view returns (uint80, uint256, uint256, uint256, uint80);
    function getDecimals() external view returns (uint8);
    function getDescription() external view returns (string memory);
}
```

### 3. FeedsPriceOracle Contract

Main oracle contract that:

- Manages multiple FeedsAccess contracts
- Handles price scaling to 18 decimals
- Provides stale price protection
- Offers manual price fallbacks
- Maintains price caching for reliability

## Deployment

### 1. Deploy the Oracle

```bash
forge script script/DeployFeedsPriceOracle.s.sol --rpc-url <RPC_URL> --private-key <PRIVATE_KEY> --broadcast
```

### 2. Set Up Feed Aggregators

For each asset, you need to:

1. Deploy or identify the external feed aggregator
2. Deploy a FeedsAccess contract (or use the oracle's `deployFeedsAccess` function)
3. Register the feed with the oracle

```solidity
// Deploy FeedsAccess for ETH/USD feed
address ethFeedAggregator = 0x...; // External aggregator address
address ethFeedsAccess = oracle.deployFeedsAccess(ethFeedAggregator);

// Register the feed for ETH
address ethAsset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
oracle.registerFeed(ethAsset, ethFeedsAccess);
```

## Usage

### Getting Prices

```solidity
// Get price for a pToken (same interface as Pyth oracle)
uint256 price = oracle.getUnderlyingPrice(pToken);

// Get price directly for an asset
uint256 price = oracle.assetPrices(assetAddress);
```

### Admin Functions

#### Register New Feeds

```solidity
oracle.registerFeed(assetAddress, feedsAccessAddress);
```

#### Set Stale Thresholds

```solidity
// Set default threshold for all assets
oracle.setDefaultStaleThreshold(3600); // 1 hour

// Set custom threshold for specific asset
oracle.setAssetStaleThreshold(assetAddress, 1800); // 30 minutes
```

#### Manual Price Overrides

```solidity
// Set manual price for pToken
oracle.setUnderlyingPrice(pToken, priceInWei);

// Set manual price directly for asset
oracle.setDirectPrice(assetAddress, priceInWei);
```

#### Update Cached Prices

```solidity
// Update cached price for an asset (useful for stale price fallback)
oracle.updateCachedPrice(assetAddress);
```

## Price Resolution Logic

The oracle follows this priority order when getting prices:

1. **Fresh Feed Price**: If feed is available and not stale
2. **Cached Feed Price**: If feed fails but cached price exists
3. **Manual Price**: Fallback to manually set price

```solidity
function getUnderlyingPrice(PToken pToken) external view returns (uint) {
    address asset = _getUnderlyingAddress(pToken);
    address feedsAccessAddress = assetToFeedsAccess[asset];

    if (feedsAccessAddress != address(0)) {
        try this._getFeedsPrice(feedsAccessAddress, asset) returns (uint priceMantissa) {
            if (priceMantissa > 0) {
                return priceMantissa; // Fresh feed price
            }
        } catch {
            uint lastValidPrice = lastValidFeedsPriceMantissa[asset];
            if (lastValidPrice != 0) {
                return lastValidPrice; // Cached feed price
            }
        }
    }

    return prices[asset]; // Manual price fallback
}
```

## Migration from Pyth Oracle

### 1. Deploy New Oracle

```bash
forge script script/DeployFeedsPriceOracle.s.sol --broadcast
```

### 2. Set Up Feeds

For each asset currently using Pyth:

```solidity
// Deploy FeedsAccess contracts
address feedsAccess = oracle.deployFeedsAccess(externalAggregatorAddress);
oracle.registerFeed(assetAddress, feedsAccess);
```

### 3. Update Peridottroller

```solidity
// In Peridottroller, update the oracle reference
peridottroller._setPriceOracle(newFeedsPriceOracle);
```

### 4. Set Manual Prices (Temporary)

During transition, set manual prices as backup:

```solidity
oracle.setDirectPrice(assetAddress, currentPriceInWei);
```

### 5. Test and Verify

- Verify all assets return correct prices
- Test stale price handling
- Confirm manual fallbacks work

## Security Considerations

### 1. Feed Reliability

- Ensure external aggregators are reliable and well-maintained
- Set appropriate stale thresholds for each asset
- Monitor feed uptime and accuracy

### 2. Price Validation

- The oracle validates that prices are positive
- Stale price protection prevents using outdated data
- Manual price fallbacks provide emergency override capability

### 3. Access Control

- Owner can manage admins and global settings
- Admins can register feeds and set prices
- Regular users can only read prices

### 4. Decimal Handling

- Automatic scaling to 18 decimals
- Supports feeds with different decimal places
- Prevents overflow/underflow in conversions

## Events

```solidity
event PricePosted(address asset, uint previousPriceMantissa, uint requestedPriceMantissa, uint newPriceMantissa);
event FeedRegistered(address asset, address feedsAccess);
event LastFeedsPriceUpdated(address indexed asset, uint priceMantissa);
event StaleThresholdUpdated(address indexed asset, uint newThreshold);
```

## Testing

Run the comprehensive test suite:

```bash
forge test --match-contract FeedsPriceOracleTest -vvv
```

The tests cover:

- Price retrieval for different assets
- Decimal conversion accuracy
- Stale price handling
- Manual price fallbacks
- Admin functionality
- Error conditions

## Troubleshooting

### Common Issues

1. **Price Returns 0**

   - Check if feed is registered: `oracle.assetToFeedsAccess(asset)`
   - Verify external aggregator is working
   - Check if manual price is set as fallback

2. **Stale Price Errors**

   - Verify external aggregator is updating prices
   - Check stale threshold settings
   - Update cached price manually if needed

3. **Decimal Conversion Issues**
   - Verify external aggregator returns correct decimals
   - Check if price scaling is working correctly
   - Test with known price values

### Monitoring

Monitor these metrics:

- Feed update frequency
- Price deviation from other sources
- Stale price occurrences
- Manual price usage frequency

## Conclusion

The FeedsPriceOracle provides a more robust and flexible price feed system compared to the Pyth oracle. Its push-based architecture eliminates the need for manual price updates while maintaining strong reliability through caching and manual fallbacks.
