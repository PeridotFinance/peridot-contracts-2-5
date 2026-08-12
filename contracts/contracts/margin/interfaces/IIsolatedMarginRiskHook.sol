// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IIsolatedMarginRiskHook {
    function isIsolatedMarginAccount(address account) external view returns (bool);

    function borrowAllowed(address account, address debtPToken, uint256 borrowAmount) external returns (bool);

    function redeemAllowed(address account, address collateralPToken, uint256 redeemTokens) external returns (bool);

    function transferAllowed(address account, address collateralPToken, uint256 transferTokens) external returns (bool);
}
