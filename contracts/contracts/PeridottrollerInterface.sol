// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PToken.sol";

abstract contract PeridottrollerInterface {
    /// @notice Indicator that this is a Peridottroller contract (for inspection)
    bool public constant isPeridottroller = true;

    /**
     * Assets You Are In **
     */
    function enterMarkets(address[] calldata pTokens) external virtual returns (uint256[] memory);

    function exitMarket(address pToken) external virtual returns (uint256);

    /**
     * Policy Hooks **
     */
    function mintAllowed(address pToken, address minter, uint256 mintAmount) external virtual returns (uint256);

    function mintVerify(address pToken, address minter, uint256 mintAmount, uint256 mintTokens) external virtual;

    function redeemAllowed(address pToken, address redeemer, uint256 redeemTokens) external virtual returns (uint256);

    function redeemVerify(address pToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens)
        external
        virtual;

    function borrowAllowed(address pToken, address borrower, uint256 borrowAmount) external virtual returns (uint256);

    function borrowVerify(address pToken, address borrower, uint256 borrowAmount) external virtual;

    function repayBorrowAllowed(address pToken, address payer, address borrower, uint256 repayAmount)
        external
        virtual
        returns (uint256);

    function repayBorrowVerify(
        address pToken,
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 borrowerIndex
    ) external virtual;

    function liquidateBorrowAllowed(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external virtual returns (uint256);

    function liquidateBorrowVerify(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 seizeTokens
    ) external virtual;

    function seizeAllowed(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external virtual returns (uint256);

    function seizeVerify(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external virtual;

    function transferAllowed(address pToken, address src, address dst, uint256 transferTokens)
        external
        virtual
        returns (uint256);

    function transferVerify(address pToken, address src, address dst, uint256 transferTokens) external virtual;

    /**
     * Liquidity/Liquidation Calculations **
     */
    function liquidateCalculateSeizeTokens(address pTokenBorrowed, address pTokenCollateral, uint256 repayAmount)
        external
        view
        virtual
        returns (uint256, uint256);

    function getAccountLiquidity(address account) external view virtual returns (uint256, uint256, uint256);

    function getAllMarkets() external view virtual returns (PToken[] memory);
}
