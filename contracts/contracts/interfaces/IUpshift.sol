// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUpshift {
    function balanceOf(address account) external view returns (uint256);

    function convertToAssets(uint256 shares) external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);

    function deposit(uint256 assets, address receiver) external returns (uint256);

    function instantRedeem(uint256 shares, address receiver, address owner) external returns (uint256);

    function instantRedemptionFee() external view returns (uint256);
}
