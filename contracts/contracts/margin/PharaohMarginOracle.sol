// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PErc20} from "../PErc20.sol";
import {PharaohVaultShareOracle} from "../PharaohVaultShareOracle.sol";
import {IMarginPriceOracle} from "./interfaces/IMarginPriceOracle.sol";

/// @notice Read-only composition of base-asset and Pharaoh share USD prices.
/// @dev Pins two pToken/vault pairs at construction. Does not relabel vault shares
/// as base assets, enable collateral, prove liquidity, or alter the controller oracle.
/// Source-oracle administration remains subject to the release's governance review.
contract PharaohMarginOracle is IMarginPriceOracle {
    IMarginPriceOracle public immutable baseOracle;
    PharaohVaultShareOracle public immutable shareOracle;
    address public immutable usdMarket;
    address public immutable avaxMarket;
    address public immutable usdVault;
    address public immutable avaxVault;

    error InvalidConfiguration();

    constructor(
        IMarginPriceOracle baseOracle_,
        PharaohVaultShareOracle shareOracle_,
        address usdMarket_,
        address usdVault_,
        address avaxMarket_,
        address avaxVault_
    ) {
        if (
            address(baseOracle_).code.length == 0 || address(shareOracle_).code.length == 0
                || usdMarket_.code.length == 0 || avaxMarket_.code.length == 0 || usdVault_.code.length == 0
                || avaxVault_.code.length == 0 || usdMarket_ == avaxMarket_ || usdVault_ == avaxVault_
                || PErc20(usdMarket_).underlying() != usdVault_ || PErc20(avaxMarket_).underlying() != avaxVault_
                || shareOracle_.getShareUsdPrice(usdVault_) == 0 || shareOracle_.getShareUsdPrice(avaxVault_) == 0
        ) revert InvalidConfiguration();
        baseOracle = baseOracle_;
        shareOracle = shareOracle_;
        usdMarket = usdMarket_;
        avaxMarket = avaxMarket_;
        usdVault = usdVault_;
        avaxVault = avaxVault_;
    }

    function marketAsset(address market) external view returns (address) {
        if (market == usdMarket || market == avaxMarket) {
            address expected = market == usdMarket ? usdVault : avaxVault;
            try PErc20(market).underlying() returns (address actual) {
                return actual == expected ? expected : address(0);
            } catch {
                return address(0);
            }
        }
        try baseOracle.marketAsset(market) returns (address asset) {
            return asset;
        } catch {
            return address(0);
        }
    }

    function getPrice(address asset) external view returns (uint256) {
        if (asset == usdVault || asset == avaxVault) {
            // A failed share quote must not fall back to a plain-asset or emergency price.
            try shareOracle.getShareUsdPrice(asset) returns (uint256 price) {
                return price;
            } catch {
                return 0;
            }
        }
        try baseOracle.getPrice(asset) returns (uint256 price) {
            return price;
        } catch {
            return 0;
        }
    }
}
