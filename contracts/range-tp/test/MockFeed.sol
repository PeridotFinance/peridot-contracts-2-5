// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Test-only Chainlink aggregator stand-in for the ANVIL keeper fork test: its runtime code is placed at the real feed addresses by the
/// TypeScript harness (anvil_setCode) and its two storage words are written with anvil_setStorageAt (slot 0 = answer, slot 1 = updatedAt).
contract MockFeed {
    int256 public answer; // slot 0
    uint256 public updatedAt; // slot 1

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1000, answer, updatedAt, updatedAt, 1000);
    }
}
