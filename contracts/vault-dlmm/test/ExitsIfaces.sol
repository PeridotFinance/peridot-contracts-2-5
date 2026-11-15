// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IChainlinkFeedMin {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}
