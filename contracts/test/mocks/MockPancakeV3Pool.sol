// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockPancakeV3Pool {
    uint160 public sqrtPriceX96;
    int24 public tick;
    int24 public spacing;

    constructor(uint160 _sqrtPriceX96, int24 _tick, int24 _tickSpacing) {
        sqrtPriceX96 = _sqrtPriceX96;
        tick = _tick;
        spacing = _tickSpacing;
    }

    function setSqrtPrice(uint160 _sqrtPriceX96, int24 _tick) external {
        sqrtPriceX96 = _sqrtPriceX96;
        tick = _tick;
    }

    function slot0() external view returns (uint160 sqrtPrice, int24 currentTick, uint16, uint16, uint16, uint8, bool) {
        sqrtPrice = sqrtPriceX96;
        currentTick = tick;
        return (sqrtPrice, currentTick, 0, 0, 0, 0, true);
    }

    function tickSpacing() external view returns (int24) {
        return spacing;
    }
}
