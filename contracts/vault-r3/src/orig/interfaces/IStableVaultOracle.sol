// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Independent price oracle for a two-token ERC-4626 strategy.
/// @dev Amounts use each token's native decimals.
interface IStableVaultOracle {
    function asset() external view returns (address);
    function pairedToken() external view returns (address);

    function quotePairToAsset(uint256 pairAmount) external view returns (uint256 assetAmount);
    function quoteAssetToPair(uint256 assetAmount) external view returns (uint256 pairAmount);
}
