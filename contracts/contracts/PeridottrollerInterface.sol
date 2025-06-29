// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

abstract contract PeridottrollerInterface {
    /// @notice Indicator that this is a Peridottroller contract (for inspection)
    bool public constant isPeridottroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(
        address[] calldata pTokens
    ) external virtual returns (uint[] memory);

    function exitMarket(address pToken) external virtual returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(
        address pToken,
        address minter,
        uint mintAmount
    ) external virtual returns (uint);

    function mintVerify(
        address pToken,
        address minter,
        uint mintAmount,
        uint mintTokens
    ) external virtual;

    function redeemAllowed(
        address pToken,
        address redeemer,
        uint redeemTokens
    ) external virtual returns (uint);

    function redeemVerify(
        address pToken,
        address redeemer,
        uint redeemAmount,
        uint redeemTokens
    ) external virtual;

    function borrowAllowed(
        address pToken,
        address borrower,
        uint borrowAmount
    ) external virtual returns (uint);

    function borrowVerify(
        address pToken,
        address borrower,
        uint borrowAmount
    ) external virtual;

    function repayBorrowAllowed(
        address pToken,
        address payer,
        address borrower,
        uint repayAmount
    ) external virtual returns (uint);

    function repayBorrowVerify(
        address pToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex
    ) external virtual;

    function liquidateBorrowAllowed(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external virtual returns (uint);

    function liquidateBorrowVerify(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens
    ) external virtual;

    function seizeAllowed(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external virtual returns (uint);

    function seizeVerify(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external virtual;

    function transferAllowed(
        address pToken,
        address src,
        address dst,
        uint transferTokens
    ) external virtual returns (uint);

    function transferVerify(
        address pToken,
        address src,
        address dst,
        uint transferTokens
    ) external virtual;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address pTokenBorrowed,
        address pTokenCollateral,
        uint repayAmount
    ) external view virtual returns (uint, uint);

    function getAccountLiquidity(
        address account
    ) external view virtual returns (uint, uint, uint);
}
