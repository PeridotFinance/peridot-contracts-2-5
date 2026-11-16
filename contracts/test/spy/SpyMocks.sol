// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockSpyFeed {
    uint80 public round = 10;
    int256 public answer = 74853877750; // $748.5387775, 8 decimals
    uint256 public updatedAt;
    uint80 public answeredIn = 10;
    uint8 public decimals = 8;
    bool public broken;

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRounds(uint80 round_, uint80 answeredIn_) external {
        round = round_;
        answeredIn = answeredIn_;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "FEED_BROKEN");
        return (round, answer, updatedAt, updatedAt, answeredIn);
    }
}

contract MockStockToken {
    bool public paused;
    bool public oraclePaused;
    bool public broken;
    uint8 public decimals = 18;
    address public underlying; // lets the same mock stand in as a market in adapter tests

    function setFlags(bool p, bool o) external {
        paused = p;
        oraclePaused = o;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function setDecimals(uint8 d) external {
        decimals = d;
    }

    function setUnderlying(address u) external {
        underlying = u;
    }
}

/// @dev A stock token whose flag getters revert.
contract RevertingFlagsToken {
    function paused() external pure returns (bool) {
        revert("NO_FLAGS");
    }

    function oraclePaused() external pure returns (bool) {
        revert("NO_FLAGS");
    }
}

contract MockPriceSource {
    mapping(address => uint256) public price;
    mapping(address => bool) public reverts;

    function set(address asset, uint256 p) external {
        price[asset] = p;
    }

    function setReverts(address asset, bool r) external {
        reverts[asset] = r;
    }

    function assetPrices(address asset) external view returns (uint256) {
        require(!reverts[asset], "SOURCE_REVERT");
        return price[asset];
    }
}

contract MockMarket {
    address public underlying;

    constructor(address u) {
        underlying = u;
    }
}

contract MockDecimalsToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}
