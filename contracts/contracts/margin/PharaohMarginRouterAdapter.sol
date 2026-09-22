// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";

/// @notice Converts the two pinned Pharaoh vault shares and their base assets.
/// @dev Standalone building block, NOT authorization to enable these collateral markets.
/// pToken redemption and custody are responsibilities of the future margin executor.
/// Only the caller's approved funds can be used; no admin or rescue/withdrawal power.
/// The underlying router must separately authorize this adapter if it restricts operators.
contract PharaohMarginRouterAdapter is IMarginRouterAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable usdVault;
    address public immutable avaxVault;
    address public immutable usd;
    address public immutable wavax;
    IMarginRouterAdapter public immutable baseRouter;

    error InvalidConfiguration();
    error InvalidSwap();
    error UnsupportedToken();
    error VaultAssetChanged();
    error VaultCapacity();
    error UnexpectedBalance();
    error InsufficientOutput();

    constructor(address usdVault_, address avaxVault_, address usd_, address wavax_, address baseRouter_) {
        address[5] memory endpoints = [usdVault_, avaxVault_, usd_, wavax_, baseRouter_];
        for (uint256 i; i < endpoints.length; ++i) {
            if (endpoints[i].code.length == 0) revert InvalidConfiguration();
            for (uint256 j; j < i; ++j) {
                if (endpoints[i] == endpoints[j]) revert InvalidConfiguration();
            }
        }
        if (IERC4626(usdVault_).asset() != usd_ || IERC4626(avaxVault_).asset() != wavax_) {
            revert InvalidConfiguration();
        }
        usdVault = usdVault_;
        avaxVault = avaxVault_;
        usd = usd_;
        wavax = wavax_;
        baseRouter = IMarginRouterAdapter(baseRouter_);
    }

    function swap(
        address fromAccount,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external nonReentrant returns (uint256 amountOut) {
        if (fromAccount != msg.sender || tokenIn == tokenOut || amountIn == 0 || minAmountOut == 0) {
            revert InvalidSwap();
        }
        address assetIn = _asset(tokenIn);
        address assetOut = _asset(tokenOut);
        uint256 inputBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 assetInBefore = IERC20(assetIn).balanceOf(address(this));
        uint256 assetOutBefore = IERC20(assetOut).balanceOf(address(this));
        uint256 outputBefore = IERC20(tokenOut).balanceOf(fromAccount);
        uint256 outputCustodyBefore = IERC20(tokenOut).balanceOf(address(this));

        IERC20(tokenIn).safeTransferFrom(fromAccount, address(this), amountIn);
        if (IERC20(tokenIn).balanceOf(address(this)) != inputBefore + amountIn) revert UnexpectedBalance();
        uint256 baseAmount = amountIn;
        if (assetIn != tokenIn) {
            IERC4626 vault = IERC4626(tokenIn);
            if (vault.maxRedeem(address(this)) < amountIn) revert VaultCapacity();
            baseAmount = vault.redeem(amountIn, address(this), address(this));
            if (IERC20(assetIn).balanceOf(address(this)) != assetInBefore + baseAmount) revert UnexpectedBalance();
        }
        if (baseAmount == 0) revert InsufficientOutput();

        if (assetIn != assetOut) {
            uint256 baseMinimum = assetOut == tokenOut ? minAmountOut : IERC4626(tokenOut).previewMint(minAmountOut);
            if (baseMinimum == 0) revert InsufficientOutput();
            IERC20(assetIn).forceApprove(address(baseRouter), baseAmount);
            uint256 received = baseRouter.swap(address(this), assetIn, assetOut, baseAmount, baseMinimum, data);
            IERC20(assetIn).forceApprove(address(baseRouter), 0);
            if (IERC20(assetOut).balanceOf(address(this)) != assetOutBefore + received) revert UnexpectedBalance();
            baseAmount = received;
        }

        if (assetOut != tokenOut) {
            IERC4626 vault = IERC4626(tokenOut);
            if (vault.maxDeposit(fromAccount) < baseAmount) revert VaultCapacity();
            IERC20(assetOut).forceApprove(tokenOut, baseAmount);
            amountOut = vault.deposit(baseAmount, fromAccount);
            IERC20(assetOut).forceApprove(tokenOut, 0);
        } else {
            amountOut = baseAmount;
            IERC20(tokenOut).safeTransfer(fromAccount, amountOut);
        }

        if (amountOut < minAmountOut) revert InsufficientOutput();
        if (
            IERC20(tokenOut).balanceOf(fromAccount) != outputBefore + amountOut
                || IERC20(tokenIn).balanceOf(address(this)) != inputBefore
                || IERC20(assetIn).balanceOf(address(this)) != assetInBefore
                || IERC20(assetOut).balanceOf(address(this)) != assetOutBefore
                || IERC20(tokenOut).balanceOf(address(this)) != outputCustodyBefore
        ) revert UnexpectedBalance();
    }

    function _asset(address token) private view returns (address asset) {
        if (token == usd || token == wavax) return token;
        if (token == usdVault) asset = usd;
        else if (token == avaxVault) asset = wavax;
        else revert UnsupportedToken();
        if (IERC4626(token).asset() != asset) revert VaultAssetChanged();
    }
}
