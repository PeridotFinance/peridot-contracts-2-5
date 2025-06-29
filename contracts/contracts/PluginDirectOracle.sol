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
    IFeeds public feeds;

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
 * @title Plugin Direct Oracle (Following Plugin Documentation Pattern)
 * @notice Oracle that follows the exact pattern from Plugin documentation
 * @author Peridot
 */
contract PluginDirectOracle is PriceOracle {
    mapping(address => address) public assetToFeedsAccess; // Maps asset to FeedsAccess contract
    mapping(address => uint) public feedsStaleThreshold; // Stale threshold per asset
    mapping(address => uint) prices; // Manual price fallback
    mapping(address => bool) public admin;

    address private owner;
    uint public defaultStaleThreshold;

    event PricePosted(
        address asset,
        uint previousPriceMantissa,
        uint requestedPriceMantissa,
        uint newPriceMantissa
    );
    event FeedRegistered(address asset, address feedsAccess);

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
                // Fall through to manual price
            }
        }

        // Fallback to manually set price
        uint manualPrice = prices[asset];
        if (manualPrice > 0) {
            return manualPrice;
        }

        revert("No valid price available");
    }

    function _getFeedsPrice(
        address feedsAccessAddress,
        address asset
    ) external view returns (uint) {
        require(msg.sender == address(this), "Internal function only");

        FeedsAccess feedsAccess = FeedsAccess(feedsAccessAddress);

        // Get latest round data
        (
            uint80 roundId,
            uint256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = feedsAccess.fetchLatestRoundData();

        // Check staleness
        uint staleThreshold = feedsStaleThreshold[asset];
        if (staleThreshold == 0) {
            staleThreshold = defaultStaleThreshold;
        }

        require(
            block.timestamp - updatedAt <= staleThreshold,
            "Price feed is stale"
        );
        require(price > 0, "Invalid price from feed");

        // Get decimals and convert to 18 decimals
        uint8 feedDecimals = feedsAccess.getDecimals();

        uint priceMantissa = price;
        if (feedDecimals < 18) {
            priceMantissa = priceMantissa * (10 ** (18 - feedDecimals));
        } else if (feedDecimals > 18) {
            priceMantissa = priceMantissa / (10 ** (feedDecimals - 18));
        }

        return priceMantissa;
    }

    /**
     * @notice Deploy FeedsAccess and register it for an asset (Plugin pattern)
     * @param asset The asset address
     * @param aggregatorAddress The Plugin aggregator address from their documentation
     */
    function deployAndRegisterFeed(
        address asset,
        address aggregatorAddress
    ) external onlyAdmin returns (address) {
        require(aggregatorAddress != address(0), "Invalid aggregator address");

        // Deploy FeedsAccess with the aggregator address (Plugin pattern)
        FeedsAccess feedsAccess = new FeedsAccess(aggregatorAddress);

        // Register it
        assetToFeedsAccess[asset] = address(feedsAccess);
        emit FeedRegistered(asset, address(feedsAccess));

        return address(feedsAccess);
    }

    /**
     * @notice Register an existing FeedsAccess contract for an asset
     * @param asset The asset address
     * @param feedsAccessAddress The FeedsAccess contract address
     */
    function registerFeed(
        address asset,
        address feedsAccessAddress
    ) external onlyAdmin {
        assetToFeedsAccess[asset] = feedsAccessAddress;
        emit FeedRegistered(asset, feedsAccessAddress);
    }

    /**
     * @notice Set manual price fallback
     */
    function setUnderlyingPrice(
        PToken pToken,
        uint underlyingPriceMantissa
    ) external onlyAdmin {
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
     * @notice Set stale threshold for an asset
     */
    function setAssetStaleThreshold(
        address asset,
        uint threshold
    ) external onlyAdmin {
        feedsStaleThreshold[asset] = threshold;
    }

    /**
     * @notice Admin management
     */
    function setAdmin(address _newAdmin) external onlyOwner {
        admin[_newAdmin] = true;
    }

    function removeAdmin(address _admin) external onlyOwner {
        admin[_admin] = false;
    }

    function setOwner(address _newOwner) external onlyOwner {
        owner = _newOwner;
    }

    function getOwner() external view returns (address) {
        return owner;
    }

    function compareStrings(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) ==
            keccak256(abi.encodePacked((b))));
    }
}
