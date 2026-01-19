// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPancakeV3Router {
    uint256 private mockOutput;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function setOutput(uint256 _output) external {
        mockOutput = _output;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external returns (uint256 amountOut) {
        // Transfer tokens in
        // Note: In real usage, this would be called after approval

        // Return mock output
        return mockOutput > 0 ? mockOutput : params.amountIn;
    }
}
