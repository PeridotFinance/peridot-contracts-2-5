// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PriceOracle.sol";
import "./PErc20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title StockSimplePriceOracle
 * @notice Drop-in replacement for SimplePriceOracle with per-asset stock flag that uses
 *         a separate staleness threshold for stock-marked assets.
 */
contract StockSimplePriceOracle is PriceOracle {
    // Manual prices and roles
    mapping(address => uint256) prices;
    mapping(address => bool) public admin;

    // Chainlink mapping and cache
    mapping(address => AggregatorV3Interface) public assetToAggregator;
    mapping(address => uint256) public lastValidChainlinkPrice;

    // Ownership / thresholds
    address private owner;
    uint256 public chainlinkPriceStaleThreshold; // default (non-stock) threshold in seconds
    uint256 public stockChainlinkPriceStaleThreshold; // stock-specific threshold in seconds

    // Asset stock classification
    mapping(address => bool) public isStockAsset; // underlying asset => isStock

    // Events (mirrors SimplePriceOracle for compatibility)
    event PricePosted(
        address asset,
        uint256 previousPriceMantissa,
        uint256 requestedPriceMantissa,
        uint256 newPriceMantissa
    );
    event ChainlinkFeedRegistered(address asset, address aggregator);
    event LastChainlinkPriceUpdated(
        address indexed asset,
        uint256 priceMantissa
    );
    event StockAssetSet(address indexed asset, bool isStock);

    modifier onlyAdmin() {
        require(admin[msg.sender], "Only admin");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(uint256 _defaultStaleThreshold, uint256 _stockStaleThreshold) {
        owner = msg.sender;
        admin[msg.sender] = true;
        chainlinkPriceStaleThreshold = _defaultStaleThreshold;
        stockChainlinkPriceStaleThreshold = _stockStaleThreshold;
    }

    // --- Internal helpers ---

    function _getUnderlyingAddress(
        PToken pToken
    ) private view returns (address) {
        address asset;
        if (compareStrings(pToken.symbol(), "pETH")) {
            asset = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
        } else {
            asset = address(PErc20(address(pToken)).underlying());
        }
        return asset;
    }

    function _thresholdFor(address asset) internal view returns (uint256) {
        return
            isStockAsset[asset]
                ? stockChainlinkPriceStaleThreshold
                : chainlinkPriceStaleThreshold;
    }

    // --- Oracle view ---

    function getUnderlyingPrice(
        PToken pToken
    ) public view override returns (uint256) {
        address asset = _getUnderlyingAddress(pToken);
        AggregatorV3Interface aggregator = assetToAggregator[asset];

        if (address(aggregator) != address(0)) {
            try aggregator.latestRoundData() returns (
                uint80 /* roundId */,
                int256 price,
                uint256 /* startedAt */,
                uint256 updatedAt,
                uint80 /* answeredInRound */
            ) {
                uint256 threshold = _thresholdFor(asset);
                if (block.timestamp - updatedAt <= threshold && price > 0) {
                    uint8 decimals = aggregator.decimals();
                    uint256 priceMantissa = uint256(price);
                    if (decimals < 18) {
                        priceMantissa = priceMantissa * (10 ** (18 - decimals));
                    } else if (decimals > 18) {
                        priceMantissa = priceMantissa / (10 ** (decimals - 18));
                    }
                    return priceMantissa;
                } else {
                    uint256 lastValid = lastValidChainlinkPrice[asset];
                    if (lastValid != 0) {
                        return lastValid;
                    }
                }
            } catch {
                uint256 lastValid = lastValidChainlinkPrice[asset];
                if (lastValid != 0) {
                    return lastValid;
                }
            }
        }

        // Fallback to manual price
        return prices[asset];
    }

    // v1 compatibility (used by proxies sometimes)
    function assetPrices(address asset) external view returns (uint256) {
        AggregatorV3Interface aggregator = assetToAggregator[asset];
        if (address(aggregator) != address(0)) {
            try aggregator.latestRoundData() returns (
                uint80 /* roundId */,
                int256 price,
                uint256 /* startedAt */,
                uint256 updatedAt,
                uint80 /* answeredInRound */
            ) {
                uint256 threshold = _thresholdFor(asset);
                if (block.timestamp - updatedAt <= threshold && price > 0) {
                    uint8 decimals = aggregator.decimals();
                    uint256 priceMantissa = uint256(price);
                    if (decimals < 18) {
                        priceMantissa = priceMantissa * (10 ** (18 - decimals));
                    } else if (decimals > 18) {
                        priceMantissa = priceMantissa / (10 ** (decimals - 18));
                    }
                    return priceMantissa;
                } else {
                    uint256 lastValid = lastValidChainlinkPrice[asset];
                    if (lastValid != 0) {
                        return lastValid;
                    }
                }
            } catch {
                uint256 lastValid = lastValidChainlinkPrice[asset];
                if (lastValid != 0) {
                    return lastValid;
                }
            }
        }
        return prices[asset];
    }

    function isPriceStale(address asset) external view returns (bool) {
        AggregatorV3Interface aggregator = assetToAggregator[asset];
        if (address(aggregator) == address(0)) {
            return true;
        }
        try aggregator.latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            uint256 threshold = _thresholdFor(asset);
            return (block.timestamp - updatedAt > threshold || price <= 0);
        } catch {
            return true;
        }
    }

    // --- Admin setters ---

    function setUnderlyingPrice(
        PToken pToken,
        uint256 underlyingPriceMantissa
    ) public onlyAdmin {
        address asset = _getUnderlyingAddress(pToken);
        emit PricePosted(
            asset,
            prices[asset],
            underlyingPriceMantissa,
            underlyingPriceMantissa
        );
        prices[asset] = underlyingPriceMantissa;
    }

    function setDirectPrice(address asset, uint256 price) public onlyAdmin {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    function registerChainlinkFeed(
        address asset,
        address aggregator
    ) public onlyAdmin {
        require(aggregator != address(0), "Invalid aggregator");
        assetToAggregator[asset] = AggregatorV3Interface(aggregator);
        emit ChainlinkFeedRegistered(asset, aggregator);
    }

    function removeChainlinkFeed(address asset) public onlyAdmin {
        require(address(assetToAggregator[asset]) != address(0), "No feed");
        delete assetToAggregator[asset];
        delete lastValidChainlinkPrice[asset];
        emit ChainlinkFeedRegistered(asset, address(0));
    }

    // Cache updater (anyone can call; writes only when fresh)
    function updateChainlinkPrices(address[] calldata assets) public {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            AggregatorV3Interface aggregator = assetToAggregator[asset];
            if (address(aggregator) != address(0)) {
                try aggregator.latestRoundData() returns (
                    uint80 /* roundId */,
                    int256 price,
                    uint256 /* startedAt */,
                    uint256 updatedAt,
                    uint80 /* answeredInRound */
                ) {
                    uint256 threshold = _thresholdFor(asset);
                    if (block.timestamp - updatedAt <= threshold && price > 0) {
                        uint8 decimals = aggregator.decimals();
                        uint256 priceMantissa = uint256(price);
                        if (decimals < 18) {
                            priceMantissa =
                                priceMantissa *
                                (10 ** (18 - decimals));
                        } else if (decimals > 18) {
                            priceMantissa =
                                priceMantissa /
                                (10 ** (decimals - 18));
                        }
                        lastValidChainlinkPrice[asset] = priceMantissa;
                        emit LastChainlinkPriceUpdated(asset, priceMantissa);
                    }
                } catch {}
            }
        }
    }

    // Roles & thresholds
    function setChainlinkStaleThreshold(
        uint256 _newThreshold
    ) public onlyOwner {
        chainlinkPriceStaleThreshold = _newThreshold;
    }

    function setStockChainlinkStaleThreshold(
        uint256 _newThreshold
    ) public onlyOwner {
        stockChainlinkPriceStaleThreshold = _newThreshold;
    }

    function setStockAsset(address asset, bool stock) public onlyAdmin {
        isStockAsset[asset] = stock;
        emit StockAssetSet(asset, stock);
    }

    function setAdmin(address _newAdmin) public onlyOwner {
        admin[_newAdmin] = true;
    }

    function removeAdmin(address _admin) public onlyOwner {
        admin[_admin] = false;
    }

    function setOwner(address _newOwner) public onlyOwner {
        owner = _newOwner;
    }

    // Utility
    function compareStrings(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) ==
            keccak256(abi.encodePacked((b))));
    }
}
