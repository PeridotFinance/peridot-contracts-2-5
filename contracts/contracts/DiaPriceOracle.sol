// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PriceOracle.sol";
import "./PErc20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title DiaPriceOracle
/// @notice Price oracle compatible with DIA adapter contracts on Somnia (AggregatorV3-style)
/// @dev Prefers DIA adapter feeds; falls back to last cached valid price, then to manual price.
contract DiaPriceOracle is PriceOracle {
    address internal constant NATIVE_TOKEN =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    // Manual price storage as ultimate fallback
    mapping(address => uint256) private prices;

    // Access control
    mapping(address => bool) public admin;
    address private owner;

    // Maps asset addresses to DIA adapter contracts implementing AggregatorV3Interface
    mapping(address => AggregatorV3Interface) public assetToDIAAdapter;

    // Stores the last valid (non-stale, >0) price seen from the oracle for each asset
    mapping(address => uint256) public lastValidOraclePrice;

    // Maximum age of oracle price feed in seconds (e.g., 3600 = 1 hour)
    uint256 public priceStaleThreshold;

    event PricePosted(
        address asset,
        uint256 previousPriceMantissa,
        uint256 requestedPriceMantissa,
        uint256 newPriceMantissa
    );
    event DIAAdapterRegistered(address asset, address adapter);
    event LastOraclePriceUpdated(address indexed asset, uint256 priceMantissa);

    modifier onlyAdmin() {
        require(admin[msg.sender], "Only admin can call this function");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    constructor(uint256 _staleThreshold) {
        owner = msg.sender;
        admin[msg.sender] = true;
        priceStaleThreshold = _staleThreshold;
    }

    function _getUnderlyingAddress(
        PErc20 pToken
    ) private view returns (address) {
        address asset;
        if (compareStrings(pToken.symbol(), "pETH")) {
            return NATIVE_TOKEN;
        }

        try PErc20(address(pToken)).underlying() returns (
            address underlyingAsset
        ) {
            asset = underlyingAsset;
        } catch {
            asset = NATIVE_TOKEN;
        }

        if (asset == address(0)) {
            asset = NATIVE_TOKEN;
        }

        return asset;
    }

    /// @notice Returns the price of the underlying asset in mantissa (18 decimals)
    function getUnderlyingPrice(
        PToken pToken
    ) public view override returns (uint256) {
        address asset = _getUnderlyingAddress(PErc20(address(pToken)));
        AggregatorV3Interface adapter = assetToDIAAdapter[asset];

        if (address(adapter) != address(0)) {
            try adapter.latestRoundData() returns (
                uint80 /* roundId */,
                int256 price,
                uint256 /* startedAt */,
                uint256 updatedAt,
                uint80 /* answeredInRound */
            ) {
                if (
                    block.timestamp - updatedAt <= priceStaleThreshold &&
                    price > 0
                ) {
                    uint8 decimals = adapter.decimals();
                    uint256 priceMantissa = uint256(price);

                    if (decimals < 18) {
                        priceMantissa = priceMantissa * (10 ** (18 - decimals));
                    } else if (decimals > 18) {
                        priceMantissa = priceMantissa / (10 ** (decimals - 18));
                    }

                    return priceMantissa;
                } else {
                    uint256 lastValidPrice = lastValidOraclePrice[asset];
                    if (lastValidPrice != 0) {
                        return lastValidPrice;
                    }
                }
            } catch {
                uint256 lastValidPrice = lastValidOraclePrice[asset];
                if (lastValidPrice != 0) {
                    return lastValidPrice;
                }
            }
        }

        return prices[asset];
    }

    /// @notice Admin: set the underlying price directly on the manual storage
    function setUnderlyingPrice(
        PToken pToken,
        uint256 underlyingPriceMantissa
    ) public onlyAdmin {
        address asset = _getUnderlyingAddress(PErc20(address(pToken)));
        emit PricePosted(
            asset,
            prices[asset],
            underlyingPriceMantissa,
            underlyingPriceMantissa
        );
        prices[asset] = underlyingPriceMantissa;
    }

    /// @notice Admin: set a direct manual price for an asset (fallback)
    function setDirectPrice(address asset, uint256 price) public onlyAdmin {
        emit PricePosted(asset, prices[asset], price, price);
        prices[asset] = price;
    }

    /// @notice Admin: register a DIA adapter implementing AggregatorV3Interface for an asset
    function registerDIAAdapter(
        address asset,
        address adapter
    ) public onlyAdmin {
        require(adapter != address(0), "Invalid adapter address");
        assetToDIAAdapter[asset] = AggregatorV3Interface(adapter);
        emit DIAAdapterRegistered(asset, adapter);
    }

    /// @notice Anyone: pull fresh prices from DIA adapters and cache last valid price
    function updateDIAAdapterPrices(address[] calldata assets) public {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            AggregatorV3Interface adapter = assetToDIAAdapter[asset];

            if (address(adapter) != address(0)) {
                try adapter.latestRoundData() returns (
                    uint80 /* roundId */,
                    int256 price,
                    uint256 /* startedAt */,
                    uint256 updatedAt,
                    uint80 /* answeredInRound */
                ) {
                    if (
                        block.timestamp - updatedAt <= priceStaleThreshold &&
                        price > 0
                    ) {
                        uint8 decimals = adapter.decimals();
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

                        lastValidOraclePrice[asset] = priceMantissa;
                        emit LastOraclePriceUpdated(asset, priceMantissa);
                    }
                } catch {
                    // ignore failures
                }
            }
        }
    }

    /// @notice Owner: set the maximum allowed price age
    function setPriceStaleThreshold(uint256 _newThreshold) public onlyOwner {
        priceStaleThreshold = _newThreshold;
    }

    /// @notice Owner: add a new admin address
    function setAdmin(address _newAdmin) public onlyOwner {
        admin[_newAdmin] = true;
    }

    /// @notice Owner: revoke admin permissions
    function removeAdmin(address _admin) public onlyOwner {
        admin[_admin] = false;
    }

    /// @notice Owner: transfer ownership
    function setOwner(address _newOwner) public onlyOwner {
        owner = _newOwner;
    }

    /// @notice Admin: remove a DIA adapter and clear cached price
    function removeDIAAdapter(address asset) public onlyAdmin {
        require(
            address(assetToDIAAdapter[asset]) != address(0),
            "No adapter for asset"
        );
        delete assetToDIAAdapter[asset];
        delete lastValidOraclePrice[asset];
        emit DIAAdapterRegistered(asset, address(0));
    }

    /// @notice v1 price oracle interface for use as backing of proxy
    function assetPrices(address asset) external view returns (uint256) {
        AggregatorV3Interface adapter = assetToDIAAdapter[asset];

        if (address(adapter) != address(0)) {
            try adapter.latestRoundData() returns (
                uint80 /* roundId */,
                int256 price,
                uint256 /* startedAt */,
                uint256 updatedAt,
                uint80 /* answeredInRound */
            ) {
                if (
                    block.timestamp - updatedAt <= priceStaleThreshold &&
                    price > 0
                ) {
                    uint8 decimals = adapter.decimals();
                    uint256 priceMantissa = uint256(price);

                    if (decimals < 18) {
                        priceMantissa = priceMantissa * (10 ** (18 - decimals));
                    } else if (decimals > 18) {
                        priceMantissa = priceMantissa / (10 ** (decimals - 18));
                    }

                    return priceMantissa;
                } else {
                    uint256 lastValidPrice = lastValidOraclePrice[asset];
                    if (lastValidPrice != 0) {
                        return lastValidPrice;
                    }
                }
            } catch {
                uint256 lastValidPrice = lastValidOraclePrice[asset];
                if (lastValidPrice != 0) {
                    return lastValidPrice;
                }
            }
        }

        return prices[asset];
    }

    /// @notice Get the DIA adapter address for an asset
    function getAdapter(address asset) external view returns (address) {
        return address(assetToDIAAdapter[asset]);
    }

    /// @notice Expose latest round data directly from the DIA adapter
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
        AggregatorV3Interface adapter = assetToDIAAdapter[asset];
        require(address(adapter) != address(0), "No adapter for asset");
        return adapter.latestRoundData();
    }

    /// @notice Check if the DIA adapter price for an asset is stale
    function isPriceStale(address asset) external view returns (bool) {
        AggregatorV3Interface adapter = assetToDIAAdapter[asset];
        if (address(adapter) == address(0)) {
            return true;
        }

        try adapter.latestRoundData() returns (
            uint80,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            return (block.timestamp - updatedAt > priceStaleThreshold ||
                price <= 0);
        } catch {
            return true;
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
