// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./SimplePriceOracleTest.sol";

/**
 * @title SimplePriceOracle Test Runner
 * @notice Deploys and runs SimplePriceOracle tests
 */
contract RunSimplePriceOracleTest {
    SimplePriceOracleTest public testContract;

    event TestStarted();
    event TestCompleted();
    event TestInfo(
        address oracleAddress,
        address underlyingAddress,
        address pTokenAddress,
        address aggregatorAddress,
        uint256 staleThreshold
    );

    constructor() {
        emit TestStarted();

        // Deploy the test contract
        testContract = new SimplePriceOracleTest();

        // Get test info
        (
            address oracleAddress,
            address underlyingAddress,
            address pTokenAddress,
            address aggregatorAddress,
            uint256 staleThreshold
        ) = testContract.getTestInfo();

        emit TestInfo(oracleAddress, underlyingAddress, pTokenAddress, aggregatorAddress, staleThreshold);

        emit TestCompleted();
    }

    function runTests() external {
        testContract.runAllTests();
    }

    function runIndividualTest(string memory testName) external {
        if (keccak256(bytes(testName)) == keccak256("basic")) {
            testContract.testBasicPriceFunctionality();
        } else if (keccak256(bytes(testName)) == keccak256("admin")) {
            testContract.testAdminManagement();
        } else if (keccak256(bytes(testName)) == keccak256("chainlink")) {
            testContract.testChainlinkIntegration();
        } else if (keccak256(bytes(testName)) == keccak256("stale")) {
            testContract.testStalePriceHandling();
        } else if (keccak256(bytes(testName)) == keccak256("cache")) {
            testContract.testPriceCaching();
        } else if (keccak256(bytes(testName)) == keccak256("fallback")) {
            testContract.testManualPriceFallback();
        } else if (keccak256(bytes(testName)) == keccak256("failures")) {
            testContract.testAggregatorFailures();
        } else if (keccak256(bytes(testName)) == keccak256("invalid")) {
            testContract.testInvalidPriceHandling();
        } else if (keccak256(bytes(testName)) == keccak256("threshold")) {
            testContract.testStaleThresholdConfig();
        } else if (keccak256(bytes(testName)) == keccak256("owner")) {
            testContract.testOwnerTransfer();
        }
    }

    function getTestInfo()
        external
        view
        returns (
            address oracleAddress,
            address underlyingAddress,
            address pTokenAddress,
            address aggregatorAddress,
            uint256 staleThreshold
        )
    {
        return testContract.getTestInfo();
    }
}
