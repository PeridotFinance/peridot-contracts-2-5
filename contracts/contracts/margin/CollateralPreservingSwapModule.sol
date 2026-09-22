// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";
import {IsolatedMarginQuoter} from "./IsolatedMarginQuoter.sol";
import {IIsolatedMarginConfig} from "./interfaces/IIsolatedMarginConfig.sol";

/// @notice Caller-funded swaps for the NEW collateral-preserving execution path.
/// @dev Both percentage bounds are enforced in output-token base units, rounding
/// the oracle output down first and then the percentage floor. Those two operations
/// permit less than TWO output base units of quantization, in addition to the
/// oracle's USD-WAD precision, not an extra percentage of slippage. Output must remain
/// positive. The legacy module's unrounded USD comparison is deliberately unchanged.
contract CollateralPreservingSwapModule is ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant executionVersion = keccak256("collateral-preserving-swap-v1");
    IIsolatedMarginConfig public immutable config;
    IsolatedMarginQuoter public immutable quoter;

    error InvalidSwap();
    error InvalidConfiguration();
    error InsufficientOutput();
    error UnexpectedBalance();

    constructor(address config_, address quoter_) {
        if (config_.code.length == 0 || quoter_.code.length == 0) revert InvalidConfiguration();
        config = IIsolatedMarginConfig(config_);
        quoter = IsolatedMarginQuoter(quoter_);
        if (address(quoter.config()) != config_) revert InvalidConfiguration();
    }

    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16 maxSlippageBps,
        uint16 oracleDeviationBps,
        bytes calldata data
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0 || tokenIn == tokenOut || maxSlippageBps >= 10_000 || oracleDeviationBps >= 10_000) {
            revert InvalidSwap();
        }
        address adapter = config.routerAdapter();
        if (adapter.code.length == 0) revert InvalidConfiguration();
        uint256 expected = quoter.expectedOut(tokenIn, tokenOut, amountIn);
        uint256 bound = Math.min(maxSlippageBps, oracleDeviationBps);
        uint256 minimum = Math.max(1, Math.mulDiv(expected, 10_000 - bound, 10_000));
        minimum = Math.max(minimum, minAmountOut);
        uint256 inputBefore = IERC20(tokenIn).balanceOf(address(this));
        uint256 outputBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        if (IERC20(tokenIn).balanceOf(address(this)) != inputBefore + amountIn) revert UnexpectedBalance();
        IERC20(tokenIn).forceApprove(adapter, amountIn);
        uint256 reported = IMarginRouterAdapter(adapter).swap(address(this), tokenIn, tokenOut, amountIn, minimum, data);
        IERC20(tokenIn).forceApprove(adapter, 0);
        amountOut = IERC20(tokenOut).balanceOf(address(this)) - outputBefore;
        if (amountOut < minimum) revert InsufficientOutput();
        if (reported != amountOut || IERC20(tokenIn).balanceOf(address(this)) != inputBefore) {
            revert UnexpectedBalance();
        }
        uint256 callerBefore = IERC20(tokenOut).balanceOf(msg.sender);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        if (
            IERC20(tokenOut).balanceOf(address(this)) != outputBefore
                || IERC20(tokenOut).balanceOf(msg.sender) != callerBefore + amountOut
        ) revert UnexpectedBalance();
    }
}
