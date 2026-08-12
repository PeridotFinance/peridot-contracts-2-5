// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";

/**
 * @notice Permissionless, stateless execution module enforcing both user and oracle swap bounds.
 * @dev It can only spend the amount explicitly approved by its caller and returns output to that caller.
 */
contract IsolatedMarginSwapModule {
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;

    error SwapError(uint8 code);

    IIsolatedMarginConfig public immutable config;
    IsolatedMarginQuoter public immutable quoter;

    constructor(address config_, address quoter_) {
        if (config_.code.length == 0) revert SwapError(1);
        if (quoter_.code.length == 0) revert SwapError(2);
        config = IIsolatedMarginConfig(config_);
        quoter = IsolatedMarginQuoter(quoter_);
    }

    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16 maxSlippageBps,
        uint16 oracleDeviationBps,
        bytes calldata data
    ) external returns (uint256 amountOut) {
        if (amountIn == 0) revert SwapError(3);
        address adapter = config.routerAdapter();
        if (adapter.code.length == 0) revert SwapError(4);

        uint256 expectedOut = quoter.expectedOut(tokenIn, tokenOut, amountIn);
        uint256 protocolMinOut = Math.mulDiv(expectedOut, BPS - maxSlippageBps, BPS);
        if (minAmountOut != 0 && minAmountOut < protocolMinOut) revert SwapError(5);
        uint256 effectiveMinOut = minAmountOut > protocolMinOut ? minAmountOut : protocolMinOut;

        uint256 inputBefore = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(tokenIn).balanceOf(address(this)) - inputBefore != amountIn) revert SwapError(6);
        uint256 outputBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(adapter, amountIn);
        IMarginRouterAdapter(adapter).swap(address(this), tokenIn, tokenOut, amountIn, effectiveMinOut, data);
        IERC20(tokenIn).forceApprove(adapter, 0);

        if (IERC20(tokenIn).balanceOf(address(this)) != inputBefore) revert SwapError(6);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outputBefore;
        if (amountOut < effectiveMinOut) revert SwapError(7);
        if (
            quoter.underlyingValueUsd(tokenOut, amountOut)
                < Math.mulDiv(quoter.underlyingValueUsd(tokenIn, amountIn), BPS - oracleDeviationBps, BPS)
        ) revert SwapError(8);

        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}
