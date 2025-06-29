// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PriceOracle.sol";
import "./PErc20.sol";

interface IFeeds {
    function latestAnswer() external view returns (uint256);

    function latestRoundData()
        external
        view
        returns (uint80, uint256, uint256, uint256, uint80);

    function decimals() external view returns (uint8);

    function latestRound() external view returns (uint256);

    function owner() external view returns (address);

    function description() external view returns (string memory);
}

contract FeedsAccess {
    IFeeds feeds;

    constructor(address _feedsAggregator) {
        feeds = IFeeds(_feedsAggregator);
    }

    function fetchLatestAnswer() external view returns (uint256) {
        return feeds.latestAnswer();
    }

    function fetchLatestRoundData()
        external
        view
        returns (uint80, uint256, uint256, uint256, uint80)
    {
        return feeds.latestRoundData();
    }

    function getDecimals() external view returns (uint8) {
        return feeds.decimals();
    }

    function getDescription() external view returns (string memory) {
        return feeds.description();
    }
}

/**
 * @title Peridot's Feeds Price Oracle
 * @notice Price Oracle that uses push-based feeds instead of pull-based Pyth
 * @author Peridot
 */
contract FeedsPriceOracle is PriceOracle {
    mapping(address => uint) prices;
    mapping(address => bool) public admin;
    mapping(address => address) public assetToFeedsAccess; // Maps asset addresses to FeedsAccess contract addresses
    mapping(address => uint) public feedsStaleThreshold; // Maximum age of price feed in seconds for each asset
    mapping(address => uint) public lastValidFeedsPriceMantissa; // Stores the last valid price mantissa from Feeds
    address private owner;
    uint public defaultStaleThreshold; // Default stale threshold for feeds

    event PricePosted(
        address asset,
        uint previousPriceMantissa,
        uint requestedPriceMantissa,
        uint newPriceMantissa
    );
    event FeedRegistered(address asset, address feedsAccess);
    event LastFeedsPriceUpdated(address indexed asset, uint priceMantissa);
    event StaleThresholdUpdated(address indexed asset, uint newThreshold);

    modifier onlyAdmin() {
        require(admin[msg.sender], "Only admin can call this function");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    constructor(uint _defaultStaleThreshold) {
        owner = msg.sender;
        admin[msg.sender] = true;
        defaultStaleThreshold = _defaultStaleThreshold;
    }

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

    function getUnderlyingPrice(
        PToken pToken
    ) external view override returns (uint) {
        address asset = _getUnderlyingAddress(pToken);
        address feedsAccessAddress = assetToFeedsAccess[asset];

        if (feedsAccessAddress != address(0)) {
            try this._getFeedsPrice(feedsAccessAddress, asset) returns (
                uint priceMantissa
            ) {
                if (priceMantissa > 0) {
                    return priceMantissa;
                }
            } catch {
                // If feeds call fails, try returning last known valid price
                uint lastValidPrice = lastValidFeedsPriceMantissa[asset];
                if (lastValidPrice != 0) {
                    return lastValidPrice;
                }
                // If that fails too, fall through to manual price
            }
        }

        // Fallback to manually set price
        uint manualPrice = prices[asset];
        if (manualPrice > 0) {
            return manualPrice;
        }

        // If no valid price is available from any source, revert
        revert("No valid price available");
    }

    /**
     * @notice Internal function to get price from feeds (separated for try/catch)
     * @param feedsAccessAddress The FeedsAccess contract address
     * @param asset The asset address for stale threshold lookup
     * @return The price mantissa scaled to 18 decimals
     */
    function _getFeedsPrice(
        address feedsAccessAddress,
        address asset
    ) external view returns (uint) {
        require(msg.sender == address(this), "Internal function only");

        FeedsAccess feedsAccess = FeedsAccess(feedsAccessAddress);

        // Get the latest round data which includes timestamp
        (
            uint80 roundId,
            uint256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feedsAccess.fetchLatestRoundData();

        // Check if the price is stale
        uint staleThreshold = feedsStaleThreshold[asset];
        if (staleThreshold == 0) {
            staleThreshold = defaultStaleThreshold;
        }

        require(
            block.timestamp - updatedAt <= staleThreshold,
            "Price feed is stale"
        );
        require(price > 0, "Invalid price from feed");

        // Get decimals from the feed
        uint8 feedDecimals = feedsAccess.getDecimals();

        // Convert price to 18 decimals
        uint priceMantissa = price;
        if (feedDecimals < 18) {
            priceMantissa = priceMantissa * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            priceMantissa = priceMantissa / (10 ** (feedDecimals - 18));
        }

        return priceMantissa;
    }

    /**
     * @notice Update the cached price for an asset from its feed
     * @param asset The asset to update the cached price for
     */
    function updateCachedPrice(address asset) external {
        address feedsAccessAddress = assetToFeedsAccess[asset];
        require(
            feedsAccessAddress != address(0),
            "No feed registered for asset"
        );

        try this._getFeedsPrice(feedsAccessAddress, asset) returns (
            uint priceMantissa
        ) {
            uint oldPrice = lastValidFeedsPriceMantissa[asset];
            lastValidFeedsPriceMantissa[asset] = priceMantissa;
            emit LastFeedsPriceUpdated(asset, priceMantissa);
        } catch {
            // If update fails, keep the old cached price
            revert("Failed to update cached price");
        }
    }

    /**
     * @notice Set manual price for an asset (fallback mechanism)
     * @param pToken The pToken to set the price for
     * @param underlyingPriceMantissa The price in 18 decimal format
     */
    function setUnderlyingPrice(
        PToken pToken,
        uint underlyingPriceMantissa
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

    /**
     * @notice Set manual price directly for an asset
     * @param asset The asset address
     * @param price The price in 18 decimal format
     */
    function setDirectPrice(address asset, uint price) public onlyAdmin {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    /**
     * @notice Register a feeds access contract for an asset
     * @param asset The asset address
     * @param feedsAccessAddress The FeedsAccess contract address (can be address(0) to unregister)
     */
    function registerFeed(
        address asset,
        address feedsAccessAddress
    ) public onlyAdmin {
        // Allow address(0) to unregister a feed
        assetToFeedsAccess[asset] = feedsAccessAddress;
        emit FeedRegistered(asset, feedsAccessAddress);
    }

    /**
     * @notice Set the stale threshold for a specific asset
     * @param asset The asset address
     * @param threshold The stale threshold in seconds
     */
    function setAssetStaleThreshold(
        address asset,
        uint threshold
    ) public onlyAdmin {
        feedsStaleThreshold[asset] = threshold;
        emit StaleThresholdUpdated(asset, threshold);
    }

    /**
     * @notice Set the default stale threshold for all assets
     * @param threshold The default stale threshold in seconds
     */
    function setDefaultStaleThreshold(uint threshold) public onlyOwner {
        defaultStaleThreshold = threshold;
    }

    /**
     * @notice Add a new admin
     * @param _newAdmin The address to add as admin
     */
    function setAdmin(address _newAdmin) public onlyOwner {
        admin[_newAdmin] = true;
    }

    /**
     * @notice Remove an admin
     * @param _admin The address to remove as admin
     */
    function removeAdmin(address _admin) public onlyOwner {
        admin[_admin] = false;
    }

    /**
     * @notice Transfer ownership
     * @param _newOwner The new owner address
     */
    function setOwner(address _newOwner) public onlyOwner {
        owner = _newOwner;
    }

    /**
     * @notice Get asset price (v1 oracle interface compatibility)
     * @param asset The asset address
     * @return The price in 18 decimal format
     */
    function assetPrices(address asset) external view returns (uint) {
        address feedsAccessAddress = assetToFeedsAccess[asset];

        if (feedsAccessAddress != address(0)) {
            try this._getFeedsPrice(feedsAccessAddress, asset) returns (
                uint priceMantissa
            ) {
                if (priceMantissa > 0) {
                    return priceMantissa;
                }
            } catch {
                // If feeds call fails, try returning last known valid price
                uint lastValidPrice = lastValidFeedsPriceMantissa[asset];
                if (lastValidPrice != 0) {
                    return lastValidPrice;
                }
                // If that fails too, fall through to manual price
            }
        }

        // Fallback to manually set price
        uint manualPrice = prices[asset];
        if (manualPrice > 0) {
            return manualPrice;
        }

        // If no valid price is available from any source, revert
        revert("No valid price available");
    }

    /**
     * @notice Deploy a new FeedsAccess contract for a given feed aggregator
     * @param feedAggregator The address of the feed aggregator
     * @return The address of the deployed FeedsAccess contract
     */
    function deployFeedsAccess(
        address feedAggregator
    ) external onlyAdmin returns (address) {
        require(
            feedAggregator != address(0),
            "Invalid feed aggregator address"
        );

        FeedsAccess feedsAccess = new FeedsAccess(feedAggregator);
        return address(feedsAccess);
    }

    /**
     * @notice Get the owner address
     * @return The owner address
     */
    function getOwner() external view returns (address) {
        return owner;
    }

    /**
     * @notice Compare two strings
     * @param a First string
     * @param b Second string
     * @return True if strings are equal
     */
    function compareStrings(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) ==
            keccak256(abi.encodePacked((b))));
    }
}
