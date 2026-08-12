// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMarginPriceOracle {
    /// @notice Returns an asset price in USD with 18 decimals, or zero when unavailable.
    function getPrice(address asset) external view returns (uint256);

    /// @notice Returns the underlying asset registered for a pToken.
    function marketAsset(address pToken) external view returns (address);
}
