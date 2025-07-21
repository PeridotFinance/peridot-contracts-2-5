// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "../contracts/PErc20Immutable.sol";
import "../contracts/FlashLoanExample.sol";
import "../contracts/MockErc20.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/JumpRateModel.sol";
import "../contracts/Unitroller.sol";
import "../contracts/SimplePriceOracle.sol";

/**
 * @title Flash Loan Test Contract
 * @notice Test contract to verify flash loan functionality using real contracts
 */
contract FlashLoanTest {
    PErc20Immutable public pToken;
    MockErc20 public underlying;
    FlashLoanExample public flashLoanBorrower;

    address public admin;
    address public user1;
    address public user2;

    // Events for testing
    event TestResult(string testName, bool success);
    event FlashLoanExecuted(uint256 amount, uint256 fee);

    Peridottroller public peridottroller;
    JumpRateModel public interestRateModel;
    Unitroller public unitroller;
    SimplePriceOracle public priceOracle;

    constructor() {
        admin = msg.sender;
        user1 = address(0x1);
        user2 = address(0x2);

        // Deploy real contracts with proper configuration
        _deployContracts();

        // Deploy mock token
        underlying = new MockErc20("Test Token", "TEST", 18);

        // Deploy PToken using PErc20Immutable which properly handles admin initialization
        pToken = new PErc20Immutable(
            address(underlying),
            PeridottrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            1e18, // Initial exchange rate
            "Peridot Test Token",
            "pTEST",
            18,
            payable(address(this)) // This contract will be the admin
        );

        // Deploy flash loan borrower
        flashLoanBorrower = new FlashLoanExample();

        // Setup market and liquidity
        _setupMarketAndLiquidity();

        // Configure flash loans
        _setupFlashLoans();
    }

    function _deployContracts() internal {
        // Deploy the real Peridottroller implementation
        peridottroller = new Peridottroller();

        // Deploy Unitroller (proxy)
        unitroller = new Unitroller();

        // Set the implementation
        unitroller._setPendingImplementation(address(peridottroller));
        peridottroller._become(unitroller);

        // Deploy price oracle with 1 hour stale threshold
        priceOracle = new SimplePriceOracle(3600);

        // Deploy interest rate model with reasonable parameters
        // Base rate: 2% APY, Multiplier: 10% APY, Jump multiplier: 200% APY, Kink: 80%
        interestRateModel = new JumpRateModel(
            0.02e18, // baseRatePerYear (2%)
            0.10e18, // multiplierPerYear (10%)
            2.00e18, // jumpMultiplierPerYear (200%)
            0.80e18 // kink (80%)
        );

        // Configure the Peridottroller via Unitroller
        Peridottroller(address(unitroller))._setPriceOracle(priceOracle);
        Peridottroller(address(unitroller))._setCloseFactor(0.5e18); // 50%
        Peridottroller(address(unitroller))._setLiquidationIncentive(1.08e18); // 8%
    }

    function _setupMarketAndLiquidity() internal {
        // Support the market in Peridottroller
        Peridottroller(address(unitroller))._supportMarket(pToken);

        // Set collateral factor for the market (75%)
        Peridottroller(address(unitroller))._setCollateralFactor(
            pToken,
            0.75e18
        );

        // Set price for the underlying token ($1)
        priceOracle.setUnderlyingPrice(pToken, 1e18);

        // Mint tokens to this contract for initial liquidity
        underlying.mint(address(this), 1000000 * 1e18);

        // This contract supplies liquidity to the market
        underlying.approve(address(pToken), type(uint256).max);
        pToken.mint(100000 * 1e18);
    }

    function _setupFlashLoans() internal {
        // Set flash loan fee to 0.05% (5 basis points)
        pToken._setFlashLoanFee(5);

        // Set maximum flash loan to 50% of available cash
        pToken._setMaxFlashLoanRatio(5000);

        // Enable flash loans
        pToken._setFlashLoansPaused(false);

        // Authorize the flash loan borrower
        flashLoanBorrower.authorizeLender(address(pToken));
    }

    /**
     * @notice Test basic flash loan functionality
     */
    function testBasicFlashLoan() public {
        uint256 loanAmount = 1000 * 1e18;

        // Check maximum available
        uint256 maxLoan = pToken.maxFlashLoan(address(underlying));
        emit TestResult("Max flash loan available", maxLoan >= loanAmount);

        // Check fee calculation
        uint256 expectedFee = (loanAmount * 5) / 10000; // 0.05%
        uint256 actualFee = pToken.flashFee(address(underlying), loanAmount);
        emit TestResult("Fee calculation correct", expectedFee == actualFee);

        // Setup the borrower with funds to pay the fee
        underlying.mint(address(flashLoanBorrower), expectedFee + 100);

        // Execute flash loan
        bytes memory extraData = abi.encode(user1);

        try
            flashLoanBorrower.executeFlashLoan(
                address(pToken),
                address(underlying),
                loanAmount,
                keccak256("SIMPLE_TRANSFER"),
                extraData
            )
        {
            emit TestResult("Flash loan execution", true);
            emit FlashLoanExecuted(loanAmount, actualFee);
        } catch {
            emit TestResult("Flash loan execution", false);
        }
    }

    /**
     * @notice Test flash loan with insufficient fee
     */
    function testFlashLoanInsufficientFee() public {
        uint256 loanAmount = 1000 * 1e18;

        // Don't give the borrower enough funds to pay the fee
        // (It should already have some from previous test, but not enough for a new loan)

        bytes memory extraData = abi.encode(user2);

        try
            flashLoanBorrower.executeFlashLoan(
                address(pToken),
                address(underlying),
                loanAmount,
                keccak256("SIMPLE_TRANSFER"),
                extraData
            )
        {
            emit TestResult("Flash loan insufficient fee (should fail)", false);
        } catch {
            emit TestResult("Flash loan insufficient fee (should fail)", true);
        }
    }

    /**
     * @notice Test flash loan paused
     */
    function testFlashLoanPaused() public {
        // Pause flash loans
        pToken._setFlashLoansPaused(true);

        uint256 loanAmount = 1000 * 1e18;
        bytes memory extraData = abi.encode(user1);

        try
            flashLoanBorrower.executeFlashLoan(
                address(pToken),
                address(underlying),
                loanAmount,
                keccak256("SIMPLE_TRANSFER"),
                extraData
            )
        {
            emit TestResult("Flash loan when paused (should fail)", false);
        } catch {
            emit TestResult("Flash loan when paused (should fail)", true);
        }

        // Unpause for other tests
        pToken._setFlashLoansPaused(false);
    }

    /**
     * @notice Test exceeding maximum flash loan
     */
    function testExceedMaxFlashLoan() public {
        uint256 maxLoan = pToken.maxFlashLoan(address(underlying));
        uint256 excessiveLoan = maxLoan + 1;

        bytes memory extraData = abi.encode(user1);

        try
            flashLoanBorrower.executeFlashLoan(
                address(pToken),
                address(underlying),
                excessiveLoan,
                keccak256("SIMPLE_TRANSFER"),
                extraData
            )
        {
            emit TestResult("Excessive flash loan (should fail)", false);
        } catch {
            emit TestResult("Excessive flash loan (should fail)", true);
        }
    }

    /**
     * @notice Test admin functions
     */
    function testAdminFunctions() public {
        // Test setting flash loan fee
        uint256 newFee = 10; // 0.1%
        pToken._setFlashLoanFee(newFee);

        uint256 loanAmount = 1000 * 1e18;
        uint256 expectedFee = (loanAmount * newFee) / 10000;
        uint256 actualFee = pToken.flashFee(address(underlying), loanAmount);
        emit TestResult("Admin fee change", expectedFee == actualFee);

        // Test setting max flash loan ratio
        uint256 newRatio = 2500; // 25%
        pToken._setMaxFlashLoanRatio(newRatio);

        uint256 cash = pToken.getCash();
        uint256 expectedMaxLoan = (cash * newRatio) / 10000;
        uint256 actualMaxLoan = pToken.maxFlashLoan(address(underlying));
        emit TestResult("Admin ratio change", expectedMaxLoan == actualMaxLoan);

        // Reset for other tests
        pToken._setFlashLoanFee(5);
        pToken._setMaxFlashLoanRatio(5000);
    }

    /**
     * @notice Test flash loan with market operations
     */
    function testFlashLoanWithMarketOps() public {
        uint256 loanAmount = 5000 * 1e18;

        // Give borrower some tokens to play with
        underlying.mint(address(flashLoanBorrower), 10000 * 1e18);

        // Calculate expected fee
        uint256 expectedFee = pToken.flashFee(address(underlying), loanAmount);

        bytes memory extraData = abi.encode(address(pToken), loanAmount / 2);

        try
            flashLoanBorrower.executeFlashLoan(
                address(pToken),
                address(underlying),
                loanAmount,
                keccak256("ARBITRAGE"),
                extraData
            )
        {
            emit TestResult("Flash loan with market operations", true);
        } catch {
            emit TestResult("Flash loan with market operations", false);
        }
    }

    /**
     * @notice Test unsupported token
     */
    function testUnsupportedToken() public {
        // Create another token
        MockErc20 otherToken = new MockErc20("Other Token", "OTHER", 18);

        uint256 maxLoan = pToken.maxFlashLoan(address(otherToken));
        emit TestResult("Unsupported token max loan is 0", maxLoan == 0);

        try pToken.flashFee(address(otherToken), 1000) {
            emit TestResult("Unsupported token fee (should fail)", false);
        } catch {
            emit TestResult("Unsupported token fee (should fail)", true);
        }
    }

    /**
     * @notice Run all tests
     */
    function runAllTests() external {
        testBasicFlashLoan();
        testFlashLoanInsufficientFee();
        testFlashLoanPaused();
        testExceedMaxFlashLoan();
        testAdminFunctions();
        testFlashLoanWithMarketOps();
        testUnsupportedToken();
    }

    /**
     * @notice Get test parameters for inspection
     */
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
        return (
            address(pToken),
            address(underlying),
            address(flashLoanBorrower),
            pToken.maxFlashLoan(address(underlying)),
            pToken.flashFee(address(underlying), 1000 * 1e18)
        );
    }
}
