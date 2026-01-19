// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../PriceOracle.sol";
import "../PErc20.sol";
import "../PToken.sol";
import "./interfaces/IV3LPVault4626.sol";
import "./interfaces/IChainlinkAggregator.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "./libraries/FullMath.sol";
import "./libraries/FixedPoint96.sol";
import "./libraries/TickMath.sol";

/**
 * @title V3LPVaultOracle
 * @notice Prices ERC-4626 vault shares that wrap Pancake v3 liquidity.
 * @dev GOVERNANCE: Owner can set all prices and feeds. In production, owner should be a multisig/timelock.
 *
 *      TWAP CALCULATION: Pool prices are normalized to match USD feed conventions (both in human-decimals).
 */
contract V3LPVaultOracle is PriceOracle, Ownable {
    struct VaultConfig {
        IV3LPVault4626 vault;
        address token0;
        address token1;
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint256 fallbackPrice; // 1e18 scaled price used when share supply is zero or valuation unavailable.
        address pool;
        uint256 maxDeviationBps;
        uint32 twapWindow;
    }

    // share token => config
    mapping(address => VaultConfig) public vaultConfigs;

    // asset => manual price in USD (1e18) (fallback when aggregator missing or stale)
    mapping(address => uint256) public assetPrices;

    // asset => chainlink aggregator
    mapping(address => IChainlinkAggregator) public assetFeeds;

    // asset => max staleness in seconds (default 86400 = 24h)
    mapping(address => uint256) public feedMaxStaleness;

    // vault => use pool-derived prices (for stablecoin pairs without external feeds)
    mapping(address => bool) public usePoolDerivedPrices;

    // Reference price for pool-derived pricing (1e18 = $1)
    uint256 public constant STABLECOIN_PRICE = 1e18;

    // Default staleness: 24 hours
    uint256 public constant DEFAULT_MAX_STALENESS = 86400;

    event VaultRegistered(
        address indexed shareToken,
        address indexed vault,
        address indexed token0,
        address token1,
        uint256 fallbackPrice
    );
    event AssetPriceUpdated(address indexed asset, uint256 price);
    event AssetFeedUpdated(address indexed asset, address indexed aggregator);
    event FallbackPriceUpdated(address indexed shareToken, uint256 price);

    constructor(address owner_) Ownable(owner_) {}

    function registerVault(
        IV3LPVault4626 vault,
        address token0,
        address token1,
        uint256 fallbackPrice
    ) external onlyOwner {
        address shareToken = address(vault);
        require(shareToken != address(0), "share zero");
        require(token0 != address(0) && token1 != address(0), "token zero");

        VaultConfig storage cfg = vaultConfigs[shareToken];
        cfg.vault = vault;
        cfg.token0 = token0;
        cfg.token1 = token1;
        cfg.token0Decimals = IERC20Metadata(token0).decimals();
        cfg.token1Decimals = IERC20Metadata(token1).decimals();
        cfg.fallbackPrice = fallbackPrice;
        cfg.pool = vault.pool();
        if (cfg.maxDeviationBps == 0) cfg.maxDeviationBps = 500;
        if (cfg.twapWindow == 0) cfg.twapWindow = 300;

        emit VaultRegistered(
            shareToken,
            address(vault),
            token0,
            token1,
            fallbackPrice
        );
    }

    function setShareDeviationBps(
        address shareToken,
        uint256 bps
    ) external onlyOwner {
        require(bps <= 10_000, "bps");
        VaultConfig storage cfg = vaultConfigs[shareToken];
        require(address(cfg.vault) != address(0), "vault missing");
        cfg.maxDeviationBps = bps;
    }

    function setTwapWindow(
        address shareToken,
        uint32 window
    ) external onlyOwner {
        VaultConfig storage cfg = vaultConfigs[shareToken];
        require(address(cfg.vault) != address(0), "vault missing");
        cfg.twapWindow = window;
    }

    function setAssetPrice(address asset, uint256 price) external onlyOwner {
        require(asset != address(0), "asset zero");
        assetPrices[asset] = price;
        emit AssetPriceUpdated(asset, price);
    }

    /**
     * @notice Set Chainlink price feed for an asset
     * @dev Sets default staleness of 24h. Use setFeedStaleness() to customize.
     */
    function setAssetFeed(
        address asset,
        address aggregator
    ) external onlyOwner {
        require(asset != address(0), "asset zero");
        assetFeeds[asset] = IChainlinkAggregator(aggregator);
        if (feedMaxStaleness[asset] == 0) {
            feedMaxStaleness[asset] = DEFAULT_MAX_STALENESS;
        }
        emit AssetFeedUpdated(asset, aggregator);
    }

    /**
     * @notice Set maximum staleness for a Chainlink feed
     * @param asset The asset address
     * @param maxStaleness Maximum seconds since last update
     */
    function setFeedStaleness(
        address asset,
        uint256 maxStaleness
    ) external onlyOwner {
        require(
            maxStaleness > 0 && maxStaleness <= 7 days,
            "invalid staleness"
        );
        feedMaxStaleness[asset] = maxStaleness;
    }

    function setFallbackPrice(
        address shareToken,
        uint256 price
    ) external onlyOwner {
        VaultConfig storage cfg = vaultConfigs[shareToken];
        require(address(cfg.vault) != address(0), "vault missing");
        cfg.fallbackPrice = price;
        emit FallbackPriceUpdated(shareToken, price);
    }

    /**
     * @notice Enable pool-derived pricing for stablecoin pairs without external price feeds.
     * @dev When enabled, assumes both tokens are ~$1 stablecoins and uses pool TWAP for relative pricing.
     *      token1 is treated as the reference ($1), token0 price is derived from pool.
     */
    function setUsePoolDerivedPrices(
        address shareToken,
        bool enabled
    ) external onlyOwner {
        VaultConfig storage cfg = vaultConfigs[shareToken];
        require(address(cfg.vault) != address(0), "vault missing");
        usePoolDerivedPrices[shareToken] = enabled;
    }

    /// @notice Convenience helper to fetch price by share token address (for external oracles).
    function getPrice(address shareToken) external view returns (uint256) {
        VaultConfig memory cfg = vaultConfigs[shareToken];
        if (address(cfg.vault) == address(0)) return 0;
        uint256 price = _computeSharePrice(cfg);
        if (price == 0) return cfg.fallbackPrice;
        return price;
    }

    /**
     * @inheritdoc PriceOracle
     */
    function getUnderlyingPrice(
        PToken pToken
    ) public view override returns (uint256) {
        address underlying = PErc20(address(pToken)).underlying();
        VaultConfig memory cfg = vaultConfigs[underlying];
        if (address(cfg.vault) == address(0)) {
            return 0;
        }

        uint256 price = _computeSharePrice(cfg);
        if (price == 0) {
            return cfg.fallbackPrice;
        }
        return price;
    }

    function _computeSharePrice(
        VaultConfig memory cfg
    ) internal view returns (uint256) {
        uint256 price0;
        uint256 price1;

        // Check if pool-derived pricing is enabled for this vault
        if (usePoolDerivedPrices[address(cfg.vault)]) {
            // For stablecoin pairs: assume token1 = $1, derive token0 from pool TWAP
            price1 = STABLECOIN_PRICE; // token1 (e.g., USDC) = $1
            uint256 poolRatio = _getTwapRatio(cfg); // token1/token0 ratio from pool (normalized)
            // poolRatio is token1/token0, so price0 = price1 / poolRatio
            price0 = poolRatio > 0
                ? FullMath.mulDiv(STABLECOIN_PRICE, 1e18, poolRatio)
                : STABLECOIN_PRICE;
        } else {
            price0 = _getAssetPrice(cfg.token0);
            price1 = _getAssetPrice(cfg.token1);

            if (price0 == 0 || price1 == 0) {
                return 0;
            }
        }

        uint256 amount0 = cfg.vault.totalManagedToken0();
        uint256 amount1 = cfg.vault.totalManagedToken1();
        uint256 supply = cfg.vault.totalSupply();

        if (supply == 0) {
            return 0;
        }

        uint256 value0 = (amount0 * price0) / (10 ** cfg.token0Decimals);
        uint256 value1 = (amount1 * price1) / (10 ** cfg.token1Decimals);

        uint256 totalValue = value0 + value1;
        if (totalValue == 0) {
            return 0;
        }

        uint256 sharePrice = (totalValue * 1e18) / supply;

        // Only validate deviation if not using pool-derived prices (no external reference)
        if (!usePoolDerivedPrices[address(cfg.vault)]) {
            _validateDeviation(cfg, price0, price1);
        }
        return sharePrice;
    }

    function _validateDeviation(
        VaultConfig memory cfg,
        uint256 price0,
        uint256 price1
    ) internal view {
        if (cfg.maxDeviationBps == 0) {
            return;
        }

        uint256 aggRatio = price0 == 0
            ? 0
            : FullMath.mulDiv(price1, 1e18, price0);

        if (aggRatio == 0) {
            return;
        }

        uint256 poolRatio = _getTwapRatio(cfg);
        uint256 diff = aggRatio > poolRatio
            ? aggRatio - poolRatio
            : poolRatio - aggRatio;
        uint256 bps = (diff * 10_000) / aggRatio;
        require(bps <= cfg.maxDeviationBps, "price deviation");
    }

    /**
     * @notice Get TWAP price ratio token1/token0 normalized for human decimals.
     * @dev UniswapV3/PancakeV3 sqrtPriceX96 encodes sqrt(token1/token0) in raw token units.
     *      We compute token1/token0 in human decimals (same as USD feeds) by:
     *      1. Computing priceX192 = (token1/token0 in raw units) * 2^192
     *      2. Normalizing: ratio = priceX192 * 10^(decimals0 - decimals1) / 2^192
     *      This makes the ratio consistent with price1/price0 from USD feeds.
     */
    function _getTwapRatio(
        VaultConfig memory cfg
    ) internal view returns (uint256) {
        uint256 priceX192;

        if (cfg.twapWindow == 0) {
            (uint160 currentSqrtPrice, , , , , , ) = IPancakeV3Pool(cfg.pool)
                .slot0();
            priceX192 = uint256(currentSqrtPrice) * uint256(currentSqrtPrice);
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = cfg.twapWindow;
            secondsAgos[1] = 0;
            (int56[] memory tickCumulatives, ) = IPancakeV3Pool(cfg.pool)
                .observe(secondsAgos);
            int56 delta = tickCumulatives[1] - tickCumulatives[0];
            int24 meanTick = int24(delta / int56(uint56(cfg.twapWindow)));
            if (delta < 0 && (delta % int56(uint56(cfg.twapWindow)) != 0)) {
                meanTick--;
            }

            uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(meanTick);
            priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        }

        // Correct: priceX192 encodes (token1/token0 in raw units) * 2^192
        // Compute ratio = token1/token0 normalized to same decimal basis as USD feeds
        uint256 ratio = FullMath.mulDiv(priceX192, 1e18, FixedPoint96.Q192);

        // Apply decimal normalization: adjust for token decimal differences
        // If token0 has more decimals, ratio should be multiplied up
        // If token1 has more decimals, ratio should be divided down
        if (cfg.token0Decimals > cfg.token1Decimals) {
            uint256 decimalAdjust = 10 **
                (cfg.token0Decimals - cfg.token1Decimals);
            ratio = ratio * decimalAdjust;
        } else if (cfg.token1Decimals > cfg.token0Decimals) {
            uint256 decimalAdjust = 10 **
                (cfg.token1Decimals - cfg.token0Decimals);
            ratio = ratio / decimalAdjust;
        }

        return ratio;
    }

    function _getAssetPrice(address asset) internal view returns (uint256) {
        IChainlinkAggregator feed = assetFeeds[asset];
        if (address(feed) != address(0)) {
            try feed.latestRoundData() returns (
                uint80 roundId,
                int256 answer,
                uint256,
                uint256 updatedAt,
                uint80 answeredInRound
            ) {
                // Validate price data
                require(answer > 0, "negative price");
                require(updatedAt > 0, "round not complete");
                require(answeredInRound >= roundId, "stale answer");

                // Check staleness
                uint256 maxStaleness = feedMaxStaleness[asset];
                if (maxStaleness == 0) maxStaleness = DEFAULT_MAX_STALENESS;
                require(
                    block.timestamp - updatedAt <= maxStaleness,
                    "price stale"
                );

                uint256 price = uint256(answer);

                // Safe decimals() call within try/catch
                try feed.decimals() returns (uint8 decimals) {
                    if (decimals < 18) {
                        price = price * (10 ** (18 - decimals));
                    } else if (decimals > 18) {
                        price = price / (10 ** (decimals - 18));
                    }
                } catch {
                    // Assume 8 decimals (Chainlink default) if decimals() fails
                    price = price * 1e10;
                }

                return price;
            } catch {
                // fall through to manual price
            }
        }
        return assetPrices[asset];
    }
}
