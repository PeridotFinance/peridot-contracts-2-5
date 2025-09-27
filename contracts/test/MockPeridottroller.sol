// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PToken} from "../contracts/PToken.sol";

contract MockPeridottroller is PeridottrollerInterface {
    // Safety defaults used by new guards
    bool public seededDefault = true;
    bool public circuitDefault = false;
    uint256 public minCTokenSupplyDefault = 0;
    uint256 public minCashDefault = 0;
    uint256 public maxExchangeRateChangeBpsDefault = 10_000; // effectively no cap in tests

    function enterMarkets(
        address[] calldata pTokens
    ) external override returns (uint256[] memory) {
        return new uint256[](pTokens.length);
    }

    function exitMarket(address pToken) external override returns (uint256) {
        return 0;
    }

    function mintAllowed(
        address pToken,
        address minter,
        uint256 mintAmount
    ) external override returns (uint256) {
        return 0;
    }

    function mintVerify(
        address pToken,
        address minter,
        uint256 mintAmount,
        uint256 mintTokens
    ) external override {}

    function redeemAllowed(
        address pToken,
        address redeemer,
        uint256 redeemTokens
    ) external override returns (uint256) {
        return 0;
    }

    function redeemVerify(
        address pToken,
        address redeemer,
        uint256 redeemAmount,
        uint256 redeemTokens
    ) external override {}

    function borrowAllowed(
        address pToken,
        address borrower,
        uint256 borrowAmount
    ) external override returns (uint256) {
        return 0;
    }

    function borrowVerify(
        address pToken,
        address borrower,
        uint256 borrowAmount
    ) external override {}

    function repayBorrowAllowed(
        address pToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external override returns (uint256) {
        return 0;
    }

    function repayBorrowVerify(
        address pToken,
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 borrowerIndex
    ) external override {}

    function liquidateBorrowAllowed(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external override returns (uint256) {
        return 0;
    }

    function liquidateBorrowVerify(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 seizeTokens
    ) external override {}

    function seizeAllowed(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external override returns (uint256) {
        return 0;
    }

    function seizeVerify(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external override {}

    function transferAllowed(
        address pToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external override returns (uint256) {
        return 0;
    }

    function transferVerify(
        address pToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external override {}

    function liquidateCalculateSeizeTokens(
        address pTokenBorrowed,
        address pTokenCollateral,
        uint256 repayAmount
    ) external view override returns (uint256, uint256) {
        return (0, 1e18);
    }

    function getAccountLiquidity(
        address account
    ) external view override returns (uint256, uint256, uint256) {
        return (0, 10000e18, 0); // $10,000 liquidity
    }

    function getAllMarkets() external view override returns (PToken[] memory) {
        return new PToken[](0);
    }

    // Helper setters for tests
    function __setSeededDefault(bool v) external {
        seededDefault = v;
    }

    function __setCircuitDefault(bool v) external {
        circuitDefault = v;
    }

    function __setMinCTokenSupply(uint256 v) external {
        minCTokenSupplyDefault = v;
    }

    function __setMinCash(uint256 v) external {
        minCashDefault = v;
    }

    function __setMaxRateBps(uint256 v) external {
        maxExchangeRateChangeBpsDefault = v;
    }

    // Expose storage-like getters so PToken guards pass in tests via PeridottrollerV8Storage-compatible names
    function marketSeeded(address) external view returns (bool) {
        return seededDefault;
    }

    function circuitBroken(address) external view returns (bool) {
        return circuitDefault;
    }

    function minCTokenSupply() external view returns (uint256) {
        return minCTokenSupplyDefault;
    }

    function minCash() external view returns (uint256) {
        return minCashDefault;
    }

    function maxExchangeRateChangeBps() external view returns (uint256) {
        return maxExchangeRateChangeBpsDefault;
    }
}
