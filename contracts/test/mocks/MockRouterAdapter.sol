// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IMarginRouterAdapter} from "../../contracts/margin/IMarginRouterAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockRouterAdapter is IMarginRouterAdapter {
    using SafeERC20 for IERC20;

    function swap(
        address fromAccount,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        IERC20(tokenIn).safeTransferFrom(fromAccount, address(this), amountIn);
        require(amountIn >= minAmountOut, "mock: min out");
        IERC20(tokenOut).safeTransfer(fromAccount, amountIn);
        return amountIn;
    }
}
