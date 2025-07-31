// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PToken} from "../contracts/PToken.sol";

contract MockPeridottroller is PeridottrollerInterface {
    function enterMarkets(address[] calldata pTokens) external override returns (uint[] memory) {
        return new uint[](pTokens.length);
    }

    function exitMarket(address pToken) external override returns (uint) {
        return 0;
    }

    function mintAllowed(address pToken, address minter, uint mintAmount) external override returns (uint) {
        return 0;
    }

    function mintVerify(address pToken, address minter, uint mintAmount, uint mintTokens) external override {}

    function redeemAllowed(address pToken, address redeemer, uint redeemTokens) external override returns (uint) {
        return 0;
    }

    function redeemVerify(address pToken, address redeemer, uint redeemAmount, uint redeemTokens) external override {}

    function borrowAllowed(address pToken, address borrower, uint borrowAmount) external override returns (uint) {
        return 0;
    }

    function borrowVerify(address pToken, address borrower, uint borrowAmount) external override {}

    function repayBorrowAllowed(address pToken, address payer, address borrower, uint repayAmount) external override returns (uint) {
        return 0;
    }

    function repayBorrowVerify(address pToken, address payer, address borrower, uint repayAmount, uint borrowerIndex) external override {}

    function liquidateBorrowAllowed(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external override returns (uint) {
        return 0;
    }

    function liquidateBorrowVerify(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens
    ) external override {}

    function seizeAllowed(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override returns (uint) {
        return 0;
    }

    function seizeVerify(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override {}

    function transferAllowed(address pToken, address src, address dst, uint transferTokens) external override returns (uint) {
        return 0;
    }

    function transferVerify(address pToken, address src, address dst, uint transferTokens) external override {}

    function liquidateCalculateSeizeTokens(
        address pTokenBorrowed,
        address pTokenCollateral,
        uint repayAmount
    ) external view override returns (uint, uint) {
        return (0, 1e18);
    }

    function getAccountLiquidity(
        address account
    ) external view override returns (uint, uint, uint) {
        return (0, 1000e18, 0);
    }

    function getAllMarkets() external view override returns (PToken[] memory) {
        return new PToken[](0);
    }
}
