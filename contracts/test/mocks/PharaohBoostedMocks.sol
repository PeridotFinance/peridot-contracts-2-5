// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {PToken} from "../../contracts/PToken.sol";

contract PharaohTestAsset is ERC20 {
    uint8 private immutable _tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address recipient, uint256 amount) external {
        _mint(recipient, amount);
    }
}

contract PharaohTestVault is ERC4626 {
    bool public conversionReverts;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC20(name_, symbol_) ERC4626(asset_) {}

    function setConversionReverts(bool state) external {
        conversionReverts = state;
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        require(!conversionReverts, "vault price unavailable");
        return super.convertToAssets(shares);
    }
}

contract PharaohTestBaseOracle is PriceOracle {
    mapping(address market => uint256 price) public prices;

    function setPrice(address market, uint256 price) external {
        prices[market] = price;
    }

    function getUnderlyingPrice(PToken pToken) external view override returns (uint256) {
        return prices[address(pToken)];
    }
}

contract PharaohTestMarket {
    address public immutable underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }
}

contract PharaohTestFeed is AggregatorV3Interface {
    uint8 public immutable override decimals;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    bool public readReverts;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setRound(int256 answer_, uint256 updatedAt_, uint80 roundId_, uint80 answeredInRound_) external {
        answer = answer_;
        updatedAt = updatedAt_;
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function setReadReverts(bool state) external {
        readReverts = state;
    }

    function description() external pure override returns (string memory) {
        return "test feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 requestedRoundId)
        external
        view
        override
        returns (uint80, int256, uint256, uint256, uint80)
    {
        requestedRoundId;
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        require(!readReverts, "feed unavailable");
        return (roundId, answer, updatedAt, updatedAt, answeredInRound);
    }
}
