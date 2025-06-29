// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceOracle} from "../../PriceOracle.sol";
import {PToken} from "../../PToken.sol";

/**
 * @title ChainlinkPriceOracle
 * @dev A price oracle that fetches prices from Chainlink Data Feeds.
 * This oracle implements the PriceOracle interface used by the Peridot protocol.
 */
contract ChainlinkPriceOracle is PriceOracle {
    event PriceFeedSet(address indexed pToken, address indexed priceFeed);
    event PriceFeedRemoved(address indexed pToken);
    event FallbackOracleSet(address indexed fallbackOracle);

    // Mapping from pToken to Chainlink price feed
    mapping(address => AggregatorV3Interface) public priceFeeds;

    // Fallback oracle for tokens without Chainlink feeds
    PriceOracle public fallbackOracle;

    // Admin address
    address public admin;

    // Maximum staleness for price data (in seconds)
    uint256 public constant MAX_STALENESS = 3600; // 1 hour

    // Price scaling factor (Chainlink typically uses 8 decimals, we need 18)
    uint256 public constant PRICE_SCALE = 10 ** 10;

    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }

    /**
     * @dev Constructor sets the admin address.
     * @param _admin The admin address.
     */
    constructor(address _admin) {
        admin = _admin;
    }

    /**
     * @dev Set a price feed for a pToken.
     * @param _pToken The pToken address.
     * @param _priceFeed The Chainlink price feed address.
     */
    function setPriceFeed(
        address _pToken,
        address _priceFeed
    ) external onlyAdmin {
        require(_pToken != address(0), "Invalid pToken address");
        require(_priceFeed != address(0), "Invalid price feed address");

        priceFeeds[_pToken] = AggregatorV3Interface(_priceFeed);
        emit PriceFeedSet(_pToken, _priceFeed);
    }

    /**
     * @dev Remove a price feed for a pToken.
     * @param _pToken The pToken address.
     */
    function removePriceFeed(address _pToken) external onlyAdmin {
        require(_pToken != address(0), "Invalid pToken address");

        delete priceFeeds[_pToken];
        emit PriceFeedRemoved(_pToken);
    }

    /**
     * @dev Set the fallback oracle.
     * @param _fallbackOracle The fallback oracle address.
     */
    function setFallbackOracle(address _fallbackOracle) external onlyAdmin {
        fallbackOracle = PriceOracle(_fallbackOracle);
        emit FallbackOracleSet(_fallbackOracle);
    }

    /**
     * @dev Get the underlying price of a pToken asset.
     * @param pToken The pToken to get the underlying price of.
     * @return The underlying asset price mantissa (scaled by 1e18).
     *         Zero means the price is unavailable.
     */
    function getUnderlyingPrice(
        PToken pToken
    ) external view override returns (uint) {
        address pTokenAddress = address(pToken);
        AggregatorV3Interface priceFeed = priceFeeds[pTokenAddress];

        // If we have a Chainlink price feed for this token, use it
        if (address(priceFeed) != address(0)) {
            return _getChainlinkPrice(priceFeed);
        }

        // Otherwise, use the fallback oracle if available
        if (address(fallbackOracle) != address(0)) {
            return fallbackOracle.getUnderlyingPrice(pToken);
        }

        // No price available
        return 0;
    }

    /**
     * @dev Get price from a Chainlink price feed.
     * @param priceFeed The Chainlink price feed.
     * @return The price scaled to 18 decimals.
     */
    function _getChainlinkPrice(
        AggregatorV3Interface priceFeed
    ) internal view returns (uint) {
        try priceFeed.latestRoundData() returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            // Check if price is positive
            if (price <= 0) {
                return 0;
            }

            // Check if price is not stale
            if (block.timestamp - updatedAt > MAX_STALENESS) {
                return 0;
            }

            // Check if round is complete
            if (updatedAt == 0 || roundId == 0 || answeredInRound < roundId) {
                return 0;
            }

            // Scale price to 18 decimals (Chainlink typically uses 8 decimals)
            uint8 decimals = priceFeed.decimals();
            uint256 scaleFactor = 10 ** (18 - decimals);

            return uint256(price) * scaleFactor;
        } catch {
            // Return 0 if there's any error fetching the price
            return 0;
        }
    }

    /**
     * @dev Get price feed information for a pToken.
     * @param pToken The pToken address.
     * @return priceFeed The price feed address.
     * @return decimals The price feed decimals.
     * @return description The price feed description.
     */
    function getPriceFeedInfo(
        address pToken
    )
        external
        view
        returns (address priceFeed, uint8 decimals, string memory description)
    {
        AggregatorV3Interface feed = priceFeeds[pToken];
        if (address(feed) == address(0)) {
            return (address(0), 0, "");
        }

        try feed.decimals() returns (uint8 _decimals) {
            decimals = _decimals;
        } catch {
            decimals = 0;
        }

        try feed.description() returns (string memory _description) {
            description = _description;
        } catch {
            description = "";
        }

        return (address(feed), decimals, description);
    }

    /**
     * @dev Check if a price feed is available for a pToken.
     * @param pToken The pToken address.
     * @return True if a price feed is available.
     */
    function hasPriceFeed(address pToken) external view returns (bool) {
        return address(priceFeeds[pToken]) != address(0);
    }

    /**
     * @dev Transfer admin rights to a new address.
     * @param newAdmin The new admin address.
     */
    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "Invalid admin address");
        admin = newAdmin;
    }
}
