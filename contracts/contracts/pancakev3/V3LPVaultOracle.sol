// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../PriceOracle.sol";
import "../PErc20.sol";
import "../PToken.sol";
import "./interfaces/IV3LPVault4626.sol";
import "./interfaces/IChainlinkAggregator.sol";

/**
 * @title V3LPVaultOracle
 * @notice Prices ERC-4626 vault shares that wrap Pancake v3 liquidity.
 * @dev The current implementation relies on admin-supplied token prices (USD 1e18). TWAP integration
 *      and reward haircuts will be layered on in subsequent iterations.
 */
contract V3LPVaultOracle is PriceOracle, Ownable {
    struct VaultConfig {
        IV3LPVault4626 vault;
        address token0;
        address token1;
        uint8 token0Decimals;
        uint8 token1Decimals;
        uint256 fallbackPrice; // 1e18 scaled price used when share supply is zero or valuation unavailable.
    }

    // share token => config
    mapping(address => VaultConfig) public vaultConfigs;

    // asset => manual price in USD (1e18) (fallback when aggregator missing or stale)
    mapping(address => uint256) public assetPrices;

    // asset => chainlink aggregator
    mapping(address => IChainlinkAggregator) public assetFeeds;

    event VaultRegistered(
        address indexed shareToken, address indexed vault, address indexed token0, address token1, uint256 fallbackPrice
    );
    event AssetPriceUpdated(address indexed asset, uint256 price);
    event AssetFeedUpdated(address indexed asset, address indexed aggregator);
    event FallbackPriceUpdated(address indexed shareToken, uint256 price);

    constructor(address owner_) Ownable(owner_) {}

    function registerVault(IV3LPVault4626 vault, address token0, address token1, uint256 fallbackPrice)
        external
        onlyOwner
    {
        address shareToken = address(vault);
        require(shareToken != address(0), "share zero");
        require(token0 != address(0) && token1 != address(0), "token zero");

        vaultConfigs[shareToken] = VaultConfig({
            vault: vault,
            token0: token0,
            token1: token1,
            token0Decimals: IERC20Metadata(token0).decimals(),
            token1Decimals: IERC20Metadata(token1).decimals(),
            fallbackPrice: fallbackPrice
        });

        emit VaultRegistered(shareToken, address(vault), token0, token1, fallbackPrice);
    }

    function setAssetPrice(address asset, uint256 price) external onlyOwner {
        require(asset != address(0), "asset zero");
        assetPrices[asset] = price;
        emit AssetPriceUpdated(asset, price);
    }

    function setAssetFeed(address asset, address aggregator) external onlyOwner {
        require(asset != address(0), "asset zero");
        assetFeeds[asset] = IChainlinkAggregator(aggregator);
        emit AssetFeedUpdated(asset, aggregator);
    }

    function setFallbackPrice(address shareToken, uint256 price) external onlyOwner {
        VaultConfig storage cfg = vaultConfigs[shareToken];
        require(address(cfg.vault) != address(0), "vault missing");
        cfg.fallbackPrice = price;
        emit FallbackPriceUpdated(shareToken, price);
    }

    /**
     * @inheritdoc PriceOracle
     */
    function getUnderlyingPrice(PToken pToken) public view override returns (uint256) {
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

    function _computeSharePrice(VaultConfig memory cfg) internal view returns (uint256) {
        uint256 price0 = _getAssetPrice(cfg.token0);
        uint256 price1 = _getAssetPrice(cfg.token1);

        if (price0 == 0 || price1 == 0) {
            return 0;
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

        return (totalValue * 1e18) / supply;
    }

    function _getAssetPrice(address asset) internal view returns (uint256) {
        IChainlinkAggregator feed = assetFeeds[asset];
        if (address(feed) != address(0)) {
            try feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
                if (answer > 0 && updatedAt > 0) {
                    uint256 price = uint256(answer);
                    uint8 decimals = feed.decimals();
                    if (decimals < 18) {
                        price = price * (10 ** (18 - decimals));
                    } else if (decimals > 18) {
                        price = price / (10 ** (decimals - 18));
                    }
                    return price;
                }
            } catch {
                // fall through to manual price
            }
        }
        return assetPrices[asset];
    }
}
