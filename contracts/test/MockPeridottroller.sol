// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PToken} from "../contracts/PToken.sol";

contract MockPeridottroller is PeridottrollerInterface {
    struct MarketData {
        bool isListed;
        uint256 collateralFactorMantissa;
        bool isPeridoted;
    }

    mapping(address => MarketData) internal marketData;
    address[] internal marketList;
    mapping(address => bool) internal marketInList;

    mapping(address => uint256) internal accountLiquidityValue;
    mapping(address => uint256) internal accountShortfallValue;
    mapping(address => bool) internal liquiditySet;
    mapping(address => bool) internal shortfallSet;

    function setMarket(address cToken, bool isListed, uint256 collateralFactorMantissa) external {
        marketData[cToken] =
            MarketData({isListed: isListed, collateralFactorMantissa: collateralFactorMantissa, isPeridoted: false});

        if (isListed && !marketInList[cToken]) {
            marketList.push(cToken);
            marketInList[cToken] = true;
        }
    }

    function setAccountLiquidity(address account, uint256 liquidity, uint256 shortfall) external {
        accountLiquidityValue[account] = liquidity;
        accountShortfallValue[account] = shortfall;
        liquiditySet[account] = true;
        shortfallSet[account] = true;
    }

    function markets(address cToken) external view returns (bool, uint256, bool) {
        MarketData memory data = marketData[cToken];
        return (data.isListed, data.collateralFactorMantissa, data.isPeridoted);
    }

    function enterMarkets(address[] calldata pTokens) external override returns (uint256[] memory) {
        return new uint256[](pTokens.length);
    }

    function exitMarket(address pToken) external override returns (uint256) {
        return 0;
    }

    function mintAllowed(address pToken, address minter, uint256 mintAmount) external override returns (uint256) {
        return 0;
    }

    function mintVerify(address pToken, address minter, uint256 mintAmount, uint256 mintTokens) external override {}

    function redeemAllowed(address pToken, address redeemer, uint256 redeemTokens) external override returns (uint256) {
        return 0;
    }

    function redeemVerify(address pToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens)
        external
        override
    {}

    function borrowAllowed(address pToken, address borrower, uint256 borrowAmount) external override returns (uint256) {
        return 0;
    }

    function borrowVerify(address pToken, address borrower, uint256 borrowAmount) external override {}

    function repayBorrowAllowed(address pToken, address payer, address borrower, uint256 repayAmount)
        external
        override
        returns (uint256)
    {
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

    function transferAllowed(address pToken, address src, address dst, uint256 transferTokens)
        external
        override
        returns (uint256)
    {
        return 0;
    }

    function transferVerify(address pToken, address src, address dst, uint256 transferTokens) external override {}

    function liquidateCalculateSeizeTokens(address pTokenBorrowed, address pTokenCollateral, uint256 repayAmount)
        external
        view
        override
        returns (uint256, uint256)
    {
        return (0, 1e18);
    }

    function getAccountLiquidity(address account) external view override returns (uint256, uint256, uint256) {
        uint256 liquidity = accountLiquidityValue[account];
        uint256 shortfall = accountShortfallValue[account];
        if (!liquiditySet[account] && !shortfallSet[account]) {
            liquidity = 10000e18;
        }
        return (0, liquidity, shortfall);
    }

    function getAllMarkets() external view override returns (PToken[] memory) {
        uint256 len = marketList.length;
        PToken[] memory marketsArray = new PToken[](len);
        for (uint256 i = 0; i < len; i++) {
            marketsArray[i] = PToken(marketList[i]);
        }
        return marketsArray;
    }
}
