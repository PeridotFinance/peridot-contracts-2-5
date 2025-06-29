# Plugin Oracle Integration - Two Approaches

## Overview

There are two ways to integrate Plugin oracles into your Peridot protocol:

1. **Registry Pattern** (`FeedsPriceOracle.sol`) - More flexible, enterprise-grade
2. **Direct Pattern** (`PluginDirectOracle.sol`) - Follows Plugin documentation exactly

## Approach 1: Registry Pattern (Recommended)

### Architecture

- One oracle contract manages multiple assets
- Feeds are registered after deployment
- More sophisticated fallback mechanisms
- Better for production environments

### Usage Example

```solidity
// 1. Deploy the oracle
FeedsPriceOracle oracle = new FeedsPriceOracle(3600); // 1 hour stale threshold

// 2. For XDC/USDT, deploy FeedsAccess with Plugin aggregator
FeedsAccess xdcFeedsAccess = new FeedsAccess(0x7D27...B497); // Plugin aggregator address

// 3. Register the feed
oracle.registerFeed(XDC_TOKEN_ADDRESS, address(xdcFeedsAccess));

// 4. Oracle automatically uses the feed
uint price = oracle.getUnderlyingPrice(pXDC);
```

### Advantages

- ✅ Centralized management
- ✅ Advanced fallback system (feed → cached → manual)
- ✅ Per-asset stale thresholds
- ✅ Price caching for reliability
- ✅ Easy to add/remove feeds
- ✅ Better error handling

## Approach 2: Direct Pattern (Plugin Documentation)

### Architecture

- Follows Plugin documentation exactly
- Each asset deployment includes aggregator address
- Simpler, more direct approach
- Matches Plugin examples precisely

### Usage Example

```solidity
// 1. Deploy the oracle
PluginDirectOracle oracle = new PluginDirectOracle(3600);

// 2. Deploy and register feed in one step (Plugin pattern)
address feedsAccess = oracle.deployAndRegisterFeed(
    XDC_TOKEN_ADDRESS,
    0x7D27...B497  // Plugin aggregator address from documentation
);

// 3. Oracle uses the feed
uint price = oracle.getUnderlyingPrice(pXDC);
```

### Advantages

- ✅ Matches Plugin documentation exactly
- ✅ Simpler deployment process
- ✅ Direct aggregator address usage
- ✅ Easier to understand for Plugin users

## Plugin Documentation Reference

Based on [Plugin Apothem Documentation](https://docs.goplugin.co/plugin-data-feeds-platform/end-data-consumers-apothem):

### XDC/USDT Example

- **Aggregator Address**: `0x7D27...B497`
- **Network**: XDC Apothem
- **Decimals**: Varies by feed

### Integration Steps (Direct Pattern)

1. Copy the `IFeeds` interface and `FeedsAccess` contract
2. Deploy `FeedsAccess` with the aggregator address from Plugin docs
3. Call `fetchLatestAnswer()` to get current price

## Deployment Instructions

### For Registry Pattern (FeedsPriceOracle)

```bash
# Deploy oracle
forge script script/DeployFeedsPriceOracle.s.sol --rpc-url $RPC_URL --broadcast

# Register feeds (after deployment)
cast send $ORACLE_ADDRESS "deployAndRegisterFeed(address,address)" $ASSET_ADDRESS $AGGREGATOR_ADDRESS
```

### For Direct Pattern (PluginDirectOracle)

```bash
# Deploy oracle
forge script script/DeployPluginDirectOracle.s.sol --rpc-url $RPC_URL --broadcast

# Deploy and register feed in one transaction
cast send $ORACLE_ADDRESS "deployAndRegisterFeed(address,address)" $ASSET_ADDRESS $AGGREGATOR_ADDRESS
```

## Key Differences

| Feature              | Registry Pattern                | Direct Pattern           |
| -------------------- | ------------------------------- | ------------------------ |
| Deployment           | Oracle first, then feeds        | Oracle first, then feeds |
| Feed Registration    | Separate step                   | Combined with deployment |
| Fallback System      | 3-tier (feed → cached → manual) | 2-tier (feed → manual)   |
| Price Caching        | ✅ Yes                          | ❌ No                    |
| Per-Asset Thresholds | ✅ Yes                          | ✅ Yes                   |
| Plugin Compatibility | ✅ Compatible                   | ✅ Exact match           |
| Complexity           | Higher                          | Lower                    |
| Production Ready     | ✅ Yes                          | ✅ Yes                   |

## Recommendation

- **Use Registry Pattern** for production deployments where you need maximum reliability and flexibility
- **Use Direct Pattern** if you want to follow Plugin documentation exactly or prefer simpler architecture

Both patterns are fully compatible with Plugin feeds and your existing Peridottroller.sol contract.

## Plugin Aggregator Addresses

From Plugin documentation, you'll need to get the specific aggregator addresses for each price pair:

- Visit [Plugin Feeds](https://feeds.goplugin.co)
- Select your network (Mainnet/Apothem)
- Find your price pair (e.g., XDC/USDT)
- Copy the aggregator address (highlighted in pink in their docs)
- Use this address when deploying FeedsAccess contracts

Example for XDC/USDT on Apothem: `0x7D27...B497`
