// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PriceOracle.sol";
import "./PErc20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SimplePriceOracle is PriceOracle {
    mapping(address => uint) prices;
    mapping(address => bool) public admin;
    mapping(address => AggregatorV3Interface) public assetToAggregator; // Maps asset addresses to Chainlink aggregators
    mapping(address => uint) public lastValidChainlinkPrice; // Stores the last valid price from Chainlink
    address private owner;
    uint public chainlinkPriceStaleThreshold; // Maximum age of price feed in seconds (default 3600 = 1 hour)

    event PricePosted(
        address asset,
        uint previousPriceMantissa,
        uint requestedPriceMantissa,
        uint newPriceMantissa
    );
    event ChainlinkFeedRegistered(address asset, address aggregator);
    event LastChainlinkPriceUpdated(address indexed asset, uint priceMantissa);

    modifier onlyAdmin() {
        require(admin[msg.sender], "Only admin can call this function");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    constructor(uint _staleThreshold) {
        owner = msg.sender;
        admin[msg.sender] = true;
        chainlinkPriceStaleThreshold = _staleThreshold; // Default: 3600 seconds (1 hour)
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
    ) public view override returns (uint) {
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
                // Check if the price timestamp is within the allowed threshold
                if (
                    block.timestamp - updatedAt <=
                    chainlinkPriceStaleThreshold &&
                    price > 0
                ) {
                    // Price is fresh and valid, convert to 18 decimals
                    uint8 decimals = aggregator.decimals();
                    uint256 priceMantissa = uint256(price);

                    if (decimals < 18) {
                        priceMantissa = priceMantissa * (10 ** (18 - decimals));
                    } else if (decimals > 18) {
                        priceMantissa = priceMantissa / (10 ** (decimals - 18));
                    }

                    return priceMantissa;
                } else {
                    // Price is stale or invalid, return last known valid price if available
                    uint lastValidPrice = lastValidChainlinkPrice[asset];
                    if (lastValidPrice != 0) {
                        return lastValidPrice;
                    }
                    // If no last valid price, fall through to manual price
                }
            } catch {
                // If latestRoundData fails, try returning last known valid price
                uint lastValidPrice = lastValidChainlinkPrice[asset];
                if (lastValidPrice != 0) {
                    return lastValidPrice;
                }
                // If that fails too, fall through to manual price
            }
        }

        // Fallback to manually set price
        return prices[asset];
    }

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

    function setDirectPrice(address asset, uint price) public onlyAdmin {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    // Register a Chainlink price feed for an asset
    function registerChainlinkFeed(
        address asset,
        address aggregator
    ) public onlyAdmin {
        require(aggregator != address(0), "Invalid aggregator address");
        assetToAggregator[asset] = AggregatorV3Interface(aggregator);
        emit ChainlinkFeedRegistered(asset, aggregator);
    }

    // Update cached prices from Chainlink Oracle (can be called by anyone to update cache)
    function updateChainlinkPrices(address[] calldata assets) public {
        for (uint i = 0; i < assets.length; i++) {
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
                    if (
                        block.timestamp - updatedAt <=
                        chainlinkPriceStaleThreshold &&
                        price > 0
                    ) {
                        // Price is fresh and valid, update cache
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
                } catch {
                    // Ignore failed updates
                }
            }
        }
    }

    // Set the maximum age for Chainlink price feeds
    function setChainlinkStaleThreshold(uint _newThreshold) public onlyOwner {
        chainlinkPriceStaleThreshold = _newThreshold;
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

    // Remove a Chainlink price feed for an asset
    function removeChainlinkFeed(address asset) public onlyAdmin {
        require(address(assetToAggregator[asset]) != address(0), "No feed exists for this asset");
        delete assetToAggregator[asset];
        delete lastValidChainlinkPrice[asset];
        emit ChainlinkFeedRegistered(asset, address(0)); // Emit with zero address to indicate removal
    }

    // Withdraw LINK tokens from the contract (in case any are sent to this contract)
    function withdrawLINK(address linkToken, address to, uint256 amount) public onlyOwner {
        require(to != address(0), "Cannot withdraw to zero address");
        require(amount > 0, "Amount must be greater than zero");
        
        // Use the ERC20 interface to transfer LINK tokens
        IERC20 link = IERC20(linkToken);
        uint256 balance = link.balanceOf(address(this));
        require(balance >= amount, "Insufficient LINK balance");
        
        bool success = link.transfer(to, amount);
        require(success, "LINK transfer failed");
    }

    // Get LINK balance of this contract (utility function)
    function getLINKBalance(address linkToken) public view returns (uint256) {
        IERC20 link = IERC20(linkToken);
        return link.balanceOf(address(this));
    }

    // v1 price oracle interface for use as backing of proxy
    function assetPrices(address asset) external view returns (uint) {
        AggregatorV3Interface aggregator = assetToAggregator[asset];

        if (address(aggregator) != address(0)) {
            try aggregator.latestRoundData() returns (
                uint80 /* roundId */,
                int256 price,
                uint256 /* startedAt */,
                uint256 updatedAt,
                uint80 /* answeredInRound */
            ) {
                // Check if the price timestamp is within the allowed threshold
                if (
                    block.timestamp - updatedAt <=
                    chainlinkPriceStaleThreshold &&
                    price > 0
                ) {
                    // Price is fresh and valid, convert to 18 decimals
                    uint8 decimals = aggregator.decimals();
                    uint256 priceMantissa = uint256(price);

                    if (decimals < 18) {
                        priceMantissa = priceMantissa * (10 ** (18 - decimals));
                    } else if (decimals > 18) {
                        priceMantissa = priceMantissa / (10 ** (decimals - 18));
                    }

                    return priceMantissa;
                } else {
                    // Price is stale or invalid, return last known valid price if available
                    uint lastValidPrice = lastValidChainlinkPrice[asset];
                    if (lastValidPrice != 0) {
                        return lastValidPrice;
                    }
                    // If no last valid price, fall through to manual price
                }
            } catch {
                // If latestRoundData fails, try returning last known valid price
                uint lastValidPrice = lastValidChainlinkPrice[asset];
                if (lastValidPrice != 0) {
                    return lastValidPrice;
                }
                // If that fails too, fall through to manual price
            }
        }

        // Fallback to manually set price
        return prices[asset];
    }

    // Get the Chainlink aggregator for an asset
    function getAggregator(address asset) external view returns (address) {
        return address(assetToAggregator[asset]);
    }

    // Get the latest round data for an asset directly
    function getLatestRoundData(
        address asset
    )
        external
        view
        returns (
            uint80 roundId,
            int256 price,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        AggregatorV3Interface aggregator = assetToAggregator[asset];
        require(address(aggregator) != address(0), "No aggregator for asset");
        return aggregator.latestRoundData();
    }

    // Check if a price feed is stale
    function isPriceStale(address asset) external view returns (bool) {
        AggregatorV3Interface aggregator = assetToAggregator[asset];
        if (address(aggregator) == address(0)) {
            return true; // No feed = stale
        }

        try aggregator.latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            return (block.timestamp - updatedAt >
                chainlinkPriceStaleThreshold ||
                price <= 0);
        } catch {
            return true; // Failed call = stale
        }
    }

    function compareStrings(
        string memory a,
        string memory b
    ) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) ==
            keccak256(abi.encodePacked((b))));
    }
}
