// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Chainlink AggregatorV3 stand-in (8 decimals). Switches: `revertLatest` (latestRoundData reverts), `revertAll` (EVERY call reverts, including decimals and unknown selectors),
///         settable answer / updatedAt, an incomplete round (answeredInRound < roundId).
contract MockChainlinkFeed {
    uint8 public feedDecimals = 8;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;
    bool public revertLatest;
    bool public revertAll;

    constructor(int256 answer_) {
        roundId = 1;
        answeredInRound = 1;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function decimals() external view returns (uint8) {
        require(!revertAll, "feed: dead");
        return feedDecimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!revertAll && !revertLatest, "feed: down");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    fallback() external {
        revert("feed: dead");
    }

    // ------------------------------------------------------------------ test knobs
    /// sets a new answer as a fresh complete round at block.timestamp
    function setAnswer(int256 a) external {
        answer = a;
        roundId += 1;
        answeredInRound = roundId;
        updatedAt = block.timestamp;
    }

    /// sets a new answer with an explicit updatedAt (stale feeds)
    function setAnswerAt(int256 a, uint256 ts) external {
        answer = a;
        roundId += 1;
        answeredInRound = roundId;
        updatedAt = ts;
    }

    /// keeps the answer but marks the round incomplete (answeredInRound < roundId)
    function setIncompleteRound() external {
        roundId += 1;
    }

    function setUpdatedAt(uint256 ts) external {
        updatedAt = ts;
    }

    function setDecimals(uint8 d) external {
        feedDecimals = d;
    }

    function setRevertLatest(bool b) external {
        revertLatest = b;
    }

    function setRevertAll(bool b) external {
        revertAll = b;
    }
}
