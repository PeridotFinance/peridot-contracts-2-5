// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./FlashLoanTest.sol";

/**
 * @title Flash Loan Test Runner
 * @notice Deploys and runs flash loan tests
 */
contract RunFlashLoanTest {
    FlashLoanTest public testContract;

    event TestStarted();
    event TestCompleted();
    event TestInfo(
        address pTokenAddress,
        address underlyingAddress,
        address borrowerAddress,
        uint256 maxFlashLoan,
        uint256 flashLoanFee
    );

    constructor() {
        emit TestStarted();

        // Deploy the test contract
        testContract = new FlashLoanTest();

        // Get test info
        (
            address pTokenAddress,
            address underlyingAddress,
            address borrowerAddress,
            uint256 maxFlashLoan,
            uint256 flashLoanFee
        ) = testContract.getTestInfo();

        emit TestInfo(
            pTokenAddress,
            underlyingAddress,
            borrowerAddress,
            maxFlashLoan,
            flashLoanFee
        );

        emit TestCompleted();
    }

    function runTests() external {
        testContract.runAllTests();
    }

    function runIndividualTest(string memory testName) external {
        if (keccak256(bytes(testName)) == keccak256("basic")) {
            testContract.testBasicFlashLoan();
        } else if (keccak256(bytes(testName)) == keccak256("insufficient")) {
            testContract.testFlashLoanInsufficientFee();
        } else if (keccak256(bytes(testName)) == keccak256("paused")) {
            testContract.testFlashLoanPaused();
        } else if (keccak256(bytes(testName)) == keccak256("exceed")) {
            testContract.testExceedMaxFlashLoan();
        } else if (keccak256(bytes(testName)) == keccak256("admin")) {
            testContract.testAdminFunctions();
        } else if (keccak256(bytes(testName)) == keccak256("unsupported")) {
            testContract.testUnsupportedToken();
        }
    }

    function getTestInfo()
        external
        view
        returns (
            address pTokenAddress,
            address underlyingAddress,
            address borrowerAddress,
            uint256 maxFlashLoan,
            uint256 flashLoanFee
        )
    {
        return testContract.getTestInfo();
    }
}
