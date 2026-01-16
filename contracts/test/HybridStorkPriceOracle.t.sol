// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "../contracts/HybridStorkPriceOracle.sol";
import "../contracts/PToken.sol";
import "./MockErc20.sol";
import "@storknetwork/stork-evm-sdk/StorkStructs.sol";

contract MockAggregator is AggregatorV3Interface {
    int256 private _answer;
    uint8 private _decimals;
    uint80 private _roundId;
    uint256 private _updatedAt;
    bool private _shouldRevert;

    constructor(int256 initialAnswer, uint8 decimals_) {
        _answer = initialAnswer;
        _decimals = decimals_;
        _roundId = 1;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 newAnswer) external {
        _answer = newAnswer;
        _roundId++;
        _updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 newUpdatedAt) external {
        _updatedAt = newUpdatedAt;
    }

    function setShouldRevert(bool shouldRevert) external {
        _shouldRevert = shouldRevert;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "Mock Aggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function latestRoundData()
        public
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!_shouldRevert, "MockAggregator: revert");
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }

    function getRoundData(uint80)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return latestRoundData();
    }
}

contract MockPToken {
    address public immutable underlying;
    string public symbol_;

    constructor(address underlying_, string memory symbolName) {
        underlying = underlying_;
        symbol_ = symbolName;
    }

    function symbol() external view returns (string memory) {
        return symbol_;
    }
}

contract MockStorkContract {
    mapping(bytes32 => StorkStructs.TemporalNumericValue) internal values;
    bool public shouldRevert;

    function setValue(bytes32 id, int192 quantizedValue, uint64 timestampSec) external {
        values[id] = StorkStructs.TemporalNumericValue({
            timestampNs: timestampSec * 1_000_000_000, quantizedValue: quantizedValue
        });
    }

    function setShouldRevert(bool value) external {
        shouldRevert = value;
    }

    function getTemporalNumericValueUnsafeV1(bytes32 id)
        external
        view
        returns (StorkStructs.TemporalNumericValue memory value)
    {
        require(!shouldRevert, "MockStork: revert");
        value = values[id];
        require(value.timestampNs != 0, "MockStork: no value");
    }
}

contract HybridStorkPriceOracleTest is Test {
    HybridStorkPriceOracle internal oracle;
    MockErc20 internal underlying;
    MockPToken internal pToken;
    MockAggregator internal chainlinkFeed;
    MockStorkContract internal storkContract;
    bytes32 internal constant STORK_ID = keccak256("TEST_STORK_FEED");

    address internal asset;

    function setUp() public {
        vm.warp(10_000);
        underlying = new MockErc20("Test Token", "TEST", 18);
        pToken = new MockPToken(address(underlying), "pTEST");
        chainlinkFeed = new MockAggregator(int256(105e8), 8);
        storkContract = new MockStorkContract();
        oracle = new HybridStorkPriceOracle(3600, address(storkContract), 3600);
        asset = address(underlying);
    }

    function testReturnsChainlinkPriceByDefault() public {
        oracle.registerChainlinkFeed(asset, address(chainlinkFeed));

        uint256 price = oracle.getUnderlyingPrice(PToken(address(pToken)));
        assertEq(price, 105e18, "should return scaled Chainlink price");
    }

    function testReturnsStorkPriceWhenPreferred() public {
        oracle.registerChainlinkFeed(asset, address(chainlinkFeed));
        oracle.registerStorkFeed(asset, STORK_ID);
        storkContract.setValue(STORK_ID, int192(104e18), uint64(block.timestamp));
        oracle.setFeedPreference(asset, true);

        uint256 price = oracle.getUnderlyingPrice(PToken(address(pToken)));
        assertEq(price, 104e18, "should return scaled Stork price");
    }

    function testFallsBackFromPreferredToSecondaryFeed() public {
        oracle.registerChainlinkFeed(asset, address(chainlinkFeed));
        oracle.registerStorkFeed(asset, STORK_ID);
        storkContract.setValue(STORK_ID, int192(104e18), uint64(block.timestamp));
        oracle.setFeedPreference(asset, true);

        // make stork stale
        storkContract.setValue(STORK_ID, int192(104e18), uint64(block.timestamp - 4000));

        uint256 price = oracle.getUnderlyingPrice(PToken(address(pToken)));
        assertEq(price, 105e18, "should fall back to Chainlink price when Stork stale");
    }

    function testUsesCachedPriceWhenFeedReverts() public {
        oracle.registerStorkFeed(asset, STORK_ID);
        storkContract.setValue(STORK_ID, int192(104e18), uint64(block.timestamp));
        oracle.setFeedPreference(asset, true);

        // prime cache
        address[] memory assets = new address[](1);
        assets[0] = asset;
        oracle.updateStorkCache(assets);
        storkContract.setShouldRevert(true);

        uint256 price = oracle.getUnderlyingPrice(PToken(address(pToken)));
        assertEq(price, 104e18, "should use cached Stork price when feed reverts");
    }

    function testFallsBackToManualPrice() public {
        oracle.registerChainlinkFeed(asset, address(chainlinkFeed));
        chainlinkFeed.setUpdatedAt(block.timestamp - 4000); // stale feed

        oracle.setManualPrice(asset, 99e18);

        uint256 price = oracle.getUnderlyingPrice(PToken(address(pToken)));
        assertEq(price, 99e18, "should return manual price when no feeds available");
    }
}
