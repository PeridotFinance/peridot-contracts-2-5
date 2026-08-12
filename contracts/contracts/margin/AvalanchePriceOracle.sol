// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {PriceOracle} from "../PriceOracle.sol";
import {PToken} from "../PToken.sol";
import {PErc20} from "../PErc20.sol";
import {IMarginPriceOracle} from "./interfaces/IMarginPriceOracle.sol";

/**
 * @notice Fail-closed Chainlink oracle for Avalanche margin markets.
 * @dev Margin prices are always USD 1e18. Compound/Peridot prices are scaled to
 *      10^(36-underlyingDecimals), as required by the controller.
 */
contract AvalanchePriceOracle is PriceOracle, IMarginPriceOracle, Ownable {
    uint256 public constant MAX_EMERGENCY_PRICE_DURATION = 1 hours;

    struct FeedConfig {
        AggregatorV3Interface feed;
        uint32 maxAge;
        uint8 feedDecimals;
        bool enabled;
    }

    struct EmergencyPrice {
        uint192 priceUsd;
        uint64 expiresAt;
    }

    mapping(address asset => FeedConfig) public feeds;
    mapping(address asset => EmergencyPrice) public emergencyPrices;
    mapping(address pToken => address asset) public override marketAsset;
    mapping(address asset => uint8 decimals) public assetDecimals;

    event FeedConfigured(address indexed asset, address indexed feed, uint32 maxAge);
    event MarketRegistered(address indexed pToken, address indexed asset, uint8 assetDecimals);
    event EmergencyPriceConfigured(address indexed asset, uint256 priceUsd, uint64 expiresAt);

    constructor(address owner_) Ownable(owner_) {}

    function configureFeed(address asset, address feed, uint32 maxAge) external onlyOwner {
        require(asset != address(0) && feed.code.length > 0, "MarginOracle: invalid feed");
        require(maxAge > 0, "MarginOracle: zero max age");
        uint8 feedDecimals = AggregatorV3Interface(feed).decimals();
        require(feedDecimals <= 36, "MarginOracle: feed decimals");
        feeds[asset] =
            FeedConfig({feed: AggregatorV3Interface(feed), maxAge: maxAge, feedDecimals: feedDecimals, enabled: true});
        emit FeedConfigured(asset, feed, maxAge);
    }

    function disableFeed(address asset) external onlyOwner {
        delete feeds[asset];
        emit FeedConfigured(asset, address(0), 0);
    }

    function registerMarket(address pToken, address asset) external onlyOwner {
        require(pToken.code.length > 0 && asset.code.length > 0, "MarginOracle: invalid market");
        require(PErc20(pToken).underlying() == asset, "MarginOracle: wrong underlying");
        uint8 decimals = IERC20Metadata(asset).decimals();
        require(decimals <= 36, "MarginOracle: asset decimals");
        marketAsset[pToken] = asset;
        assetDecimals[asset] = decimals;
        emit MarketRegistered(pToken, asset, decimals);
    }

    function setEmergencyPrice(address asset, uint192 priceUsd, uint64 expiresAt) external onlyOwner {
        require(priceUsd > 0, "MarginOracle: zero price");
        require(expiresAt > block.timestamp, "MarginOracle: expired");
        require(uint256(expiresAt) <= block.timestamp + MAX_EMERGENCY_PRICE_DURATION, "MarginOracle: duration too long");
        emergencyPrices[asset] = EmergencyPrice({priceUsd: priceUsd, expiresAt: expiresAt});
        emit EmergencyPriceConfigured(asset, priceUsd, expiresAt);
    }

    function clearEmergencyPrice(address asset) external onlyOwner {
        delete emergencyPrices[asset];
        emit EmergencyPriceConfigured(asset, 0, 0);
    }

    function getPrice(address asset) public view override returns (uint256) {
        FeedConfig memory config = feeds[asset];
        if (config.enabled) {
            try config.feed.latestRoundData() returns (
                uint80 roundId, int256 answer, uint256, uint256 updatedAt, uint80 answeredInRound
            ) {
                if (
                    roundId != 0 && answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp
                        && answeredInRound >= roundId && block.timestamp - updatedAt <= config.maxAge
                ) {
                    return _scaleToWad(uint256(answer), config.feedDecimals);
                }
            } catch {}
        }

        EmergencyPrice memory emergencyPrice = emergencyPrices[asset];
        if (emergencyPrice.priceUsd != 0 && block.timestamp <= emergencyPrice.expiresAt) {
            return emergencyPrice.priceUsd;
        }
        return 0;
    }

    function getUnderlyingPrice(PToken pToken) public view override returns (uint256) {
        address asset = marketAsset[address(pToken)];
        if (asset == address(0)) return 0;

        uint256 priceUsd = getPrice(asset);
        if (priceUsd == 0) return 0;

        uint8 decimals = assetDecimals[asset];
        if (decimals < 18) return priceUsd * (10 ** uint256(18 - decimals));
        if (decimals > 18) return priceUsd / (10 ** uint256(decimals - 18));
        return priceUsd;
    }

    function _scaleToWad(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals < 18) return value * (10 ** uint256(18 - decimals));
        if (decimals > 18) return value / (10 ** uint256(decimals - 18));
        return value;
    }
}
