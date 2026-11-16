// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Chainlink AggregatorV3 stand-in for the LOCAL FORK REHEARSAL ONLY (tools/rehearsal). It has NO storage: answer, timestamp and round are IMMUTABLES, so its
///         runtime code can be `anvil_setCode`d over the real feed's address without touching (or being corrupted by) the real feed's storage, and the real code can
///         be put back afterwards. Nothing here is ever deployed on a real chain.
contract FixedFeed {
    int256 public immutable ANSWER;
    uint256 public immutable UPDATED_AT;
    bool public immutable REVERTS;

    constructor(int256 answer_, uint256 updatedAt_, bool reverts_) {
        ANSWER = answer_;
        UPDATED_AT = updatedAt_;
        REVERTS = reverts_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!REVERTS, "feed: down");
        return (1000, ANSWER, UPDATED_AT, UPDATED_AT, 1000);
    }
}
