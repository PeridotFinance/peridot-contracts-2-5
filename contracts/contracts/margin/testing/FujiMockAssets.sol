// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @notice Unbacked, owner-minted TEST assets. Never USDC or redeemable wrapped AVAX.
contract FujiMockToken is ERC20, Ownable {
    uint8 private immutable tokenDecimals;
    uint256 public immutable supplyCap;
    bool public constant IS_FUJI_MOCK = true;

    constructor(address owner_, bool isUsd)
        ERC20(isUsd ? "MOCK USD - Fuji testing only" : "MOCK AVAX - Fuji testing only", isUsd ? "mockUSD" : "mockAVAX")
        Ownable(owner_)
    {
        require(block.chainid == 43_113, "FujiMock: Fuji only");
        tokenDecimals = isUsd ? 6 : 18;
        supplyCap = 1_000_000_000 * 10 ** uint256(tokenDecimals);
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        require(amount <= supplyCap - totalSupply(), "FujiMock: supply cap");
        _mint(to, amount);
    }
}

/// @notice Owner-controlled Chainlink-interface fixture, NOT a Chainlink data feed.
/// @dev Updating an answer refreshes its timestamp. Not updating it tests stale-price rejection.
contract FujiMockPriceFeed is Ownable, AggregatorV3Interface {
    uint8 public constant override decimals = 8;
    uint256 public constant override version = 1;
    bool public constant IS_FUJI_MOCK = true;
    string public override description;
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;

    event MockAnswerUpdated(uint80 indexed roundId, int256 answer, uint256 updatedAt);

    constructor(address owner_, bool isUsd) Ownable(owner_) {
        require(block.chainid == 43_113, "FujiMock: Fuji only");
        description = isUsd ? "MOCK USD / USD" : "MOCK AVAX / USD";
        _setAnswer(isUsd ? int256(1e8) : int256(10e8));
    }

    function setAnswer(int256 answer_) external onlyOwner {
        _setAnswer(answer_);
    }

    function _setAnswer(int256 answer_) private {
        require(answer_ > 0 && answer_ <= 1_000_000e8, "FujiMock: price bounds");
        roundId++;
        answer = answer_;
        updatedAt = block.timestamp;
        emit MockAnswerUpdated(roundId, answer_, updatedAt);
    }

    function latestRoundData() public view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function getRoundData(uint80 requested) external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(requested == roundId, "FujiMock: historical round unavailable");
        return latestRoundData();
    }
}
