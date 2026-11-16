// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAssetPriceSource} from "../RobinhoodMarginPriceOracle.sol";

/**
 * @title MarginPriceSourceRouter
 * @notice Lets the single-slot `RobinhoodMarginPriceOracle.assetSource` serve a second stock without touching the
 *         first stock's price path.
 * @dev - `secondaryAsset` (SPY) is priced only by `secondary`.
 *      - `sharedAsset` (USDG) is priced by `primary`; only when `primary` returns 0 (or reverts) is `secondary` asked.
 *        Every margin pair also needs its stock price, so the fallback never makes a stale pair priceable: an NVDA
 *        pair still needs NVDA from `primary`, a SPY pair still needs SPY from `secondary`.
 *      - Every other asset (NVDA) is priced only by `primary`, unchanged, value for value.
 *      A reverting source reads as 0, exactly as the margin oracle already treats a reverting `assetSource`.
 *      Immutable, no admin. Rollback is the oracle owner pointing `assetSource` back at `primary`.
 */
contract MarginPriceSourceRouter is IAssetPriceSource {
    IAssetPriceSource public immutable primary;
    IAssetPriceSource public immutable secondary;
    address public immutable secondaryAsset;
    address public immutable sharedAsset;

    error InvalidConfiguration();

    constructor(address primary_, address secondary_, address secondaryAsset_, address sharedAsset_) {
        if (primary_.code.length == 0 || secondary_.code.length == 0 || primary_ == secondary_) {
            revert InvalidConfiguration();
        }
        if (secondaryAsset_ == address(0) || sharedAsset_ == address(0) || secondaryAsset_ == sharedAsset_) {
            revert InvalidConfiguration();
        }
        primary = IAssetPriceSource(primary_);
        secondary = IAssetPriceSource(secondary_);
        secondaryAsset = secondaryAsset_;
        sharedAsset = sharedAsset_;
    }

    /// @inheritdoc IAssetPriceSource
    function assetPrices(address asset) external view returns (uint256) {
        if (asset == secondaryAsset) return _read(secondary, asset);
        uint256 price = _read(primary, asset);
        if (price != 0 || asset != sharedAsset) return price;
        return _read(secondary, asset);
    }

    function _read(IAssetPriceSource source, address asset) internal view returns (uint256) {
        try source.assetPrices(asset) returns (uint256 price) {
            return price;
        } catch {
            return 0;
        }
    }
}
