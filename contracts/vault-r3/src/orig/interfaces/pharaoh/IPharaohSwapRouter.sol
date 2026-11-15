// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @notice Minimal exact-input interface for Pharaoh's Ramses V3 swap router.
interface IPharaohSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function deployer() external view returns (address);

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
