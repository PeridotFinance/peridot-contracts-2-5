// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fork rehearsal only: etched over a Chainlink feed so a warped fork keeps a fresh answer. The answer is fixed
/// at etch time through storage slot 0; updatedAt is always the current block time.
contract FreshFeedMock {
    int256 public answer; // slot 0

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (uint80(1), answer, block.timestamp, block.timestamp, uint80(1));
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (uint80(1), answer, block.timestamp, block.timestamp, uint80(1));
    }
}
