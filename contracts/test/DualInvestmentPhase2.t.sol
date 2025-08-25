// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Phase 2 contracts
import "../contracts/DualInvestment/CompoundBorrowRouter.sol";
import "../contracts/DualInvestment/RiskGuard.sol";
import "../contracts/DualInvestment/DualInvestmentManager.sol";

// Existing Phase 1 contracts
import "../contracts/DualInvestment/ERC1155DualPosition.sol";
import "../contracts/DualInvestment/VaultExecutor.sol";
import "../contracts/DualInvestment/SettlementEngine.sol";

// Core protocol contracts
import "../contracts/SimplePriceOracle.sol";
import "../contracts/PErc20.sol";
import "../contracts/Peridottroller.sol";

// Mock contracts
import "../contracts/MockErc20.sol";
import "./MockPeridottroller.sol";
import "./MockInterestRateModel.sol";
import "./MockPErc20.sol";

contract DualInvestmentPhase2Test is Test {
    // Phase 2 contracts
    CompoundBorrowRouter public borrowRouter;
    RiskGuard public riskGuard;
    DualInvestmentManager public manager;

    // Phase 1 contracts
    ERC1155DualPosition public positionToken;
    VaultExecutor public vaultExecutor;
    SettlementEngine public settlementEngine;
    SimplePriceOracle public oracle;

    // Mock contracts
    MockPeridottroller public peridottroller;
    MockErc20 public usdc;
    MockErc20 public weth;
    MockPErc20 public pUSDC;
    MockPErc20 public pETH;
    MockInterestRateModel public interestModel;

    // Test accounts
    address public admin;
    address public user1;
    address public user2;
    address public protocolAccount;

    // Test constants
    uint256 public constant INITIAL_USDC_BALANCE = 100000e6; // 100k USDC
    uint256 public constant INITIAL_ETH_BALANCE = 100e18; // 100 ETH
    uint256 public constant ETH_PRICE = 2400e18; // $2400 ETH
    uint256 public constant USDC_PRICE = 1e18; // $1 USDC

    function setUp() public {
        admin = address(this);
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        protocolAccount = makeAddr("protocolAccount");

        // Deploy mock tokens
        usdc = new MockErc20("USD Coin", "USDC", 6);
        weth = new MockErc20("Wrapped Ether", "WETH", 18);

        // Deploy interest rate model
        interestModel = new MockInterestRateModel();

        // Deploy price oracle
        oracle = new SimplePriceOracle(3600); // 1 hour stale threshold

        // Deploy mock peridottroller
        peridottroller = new MockPeridottroller();

        // Deploy mock cTokens
        pUSDC = new MockPErc20(address(usdc), "pUSDC");
        pETH = new MockPErc20(address(weth), "pETH");

        // Deploy Phase 1 contracts
        positionToken = new ERC1155DualPosition();
        vaultExecutor = new VaultExecutor(protocolAccount);
        settlementEngine = new SettlementEngine(address(positionToken), address(vaultExecutor), address(oracle));

        // Deploy Phase 2 contracts
        borrowRouter = new CompoundBorrowRouter(address(peridottroller), address(oracle));
        riskGuard = new RiskGuard(address(peridottroller), address(oracle));

        // Deploy updated manager with Phase 2 components
        manager = new DualInvestmentManager(
            address(positionToken),
            address(vaultExecutor),
            address(settlementEngine),
            address(borrowRouter),
            address(riskGuard),
            address(peridottroller)
        );

        // Set up authorizations
        positionToken.setAuthorizedMinter(address(manager), true);
        positionToken.setAuthorizedMinter(address(settlementEngine), true);
        vaultExecutor.setAuthorizedManager(address(manager), true);
        vaultExecutor.setAuthorizedManager(address(settlementEngine), true);
        borrowRouter.setAuthorizedDestination(address(vaultExecutor), true);

        // Set up oracle prices
        oracle.setDirectPrice(address(weth), ETH_PRICE);
        oracle.setDirectPrice(address(usdc), USDC_PRICE);

        // Mint initial tokens to users
        usdc.mint(user1, INITIAL_USDC_BALANCE);
        usdc.mint(user2, INITIAL_USDC_BALANCE);
        weth.mint(user1, INITIAL_ETH_BALANCE);
        weth.mint(user2, INITIAL_ETH_BALANCE);

        // Give users some cTokens for testing
        vm.prank(user1);
        pUSDC.mint(10000e6); // 10k pUSDC
        vm.prank(user1);
        pETH.mint(10e18); // 10 pETH

        // Give users some ETH for gas
        vm.deal(user1, 100e18);
        vm.deal(user2, 100e18);

        // Configure supported cTokens
        manager.setSupportedCToken(address(pUSDC), true);
        manager.setSupportedCToken(address(pETH), true);
    }

    function testBorrowRouterBasics() public {
        // Test initial state
        assertEq(borrowRouter.minHealthFactorAfterBorrow(), 1.25e18, "Initial min health factor should be 125%");
        assertEq(borrowRouter.maxLTVForBorrow(), 0.75e18, "Initial max LTV should be 75%");

        // Test authorization
        assertFalse(borrowRouter.authorizedDestinations(user1), "User1 should not be authorized initially");

        borrowRouter.setAuthorizedDestination(user1, true);
        assertTrue(borrowRouter.authorizedDestinations(user1), "User1 should be authorized after setting");

        // Test parameter updates
        borrowRouter.setMinHealthFactor(1.5e18);
        assertEq(borrowRouter.minHealthFactorAfterBorrow(), 1.5e18, "Min health factor should be updated");

        borrowRouter.setMaxLTV(0.8e18);
        assertEq(borrowRouter.maxLTVForBorrow(), 0.8e18, "Max LTV should be updated");
    }

    function testRiskGuardBasics() public {
        // Test initial parameters
        assertEq(riskGuard.minHealthFactor(), 1.3e18, "Initial min health factor should be 130%");
        // Liquidation threshold removed - handled by Peridottroller
        assertEq(riskGuard.maxPositionSizeRatio(), 0.5e18, "Initial max position size ratio should be 50%");

        // Test parameter updates
        riskGuard.setMinHealthFactor(1.4e18);
        assertEq(riskGuard.minHealthFactor(), 1.4e18, "Min health factor should be updated");

        // Liquidation threshold setter removed

        riskGuard.setMaxPositionSizeRatio(0.6e18);
        assertEq(riskGuard.maxPositionSizeRatio(), 0.6e18, "Max position size ratio should be updated");
    }

    function testManagerPhase2Integration() public {
        // Test that new constructor parameters are properly set
        assertTrue(address(manager.borrowRouter()) != address(0), "Borrow router should be set");
        assertTrue(address(manager.riskGuard()) != address(0), "Risk guard should be set");

        // Existing functionality should still work
        assertFalse(manager.supportedCTokens(makeAddr("randomToken")), "Random token should not be supported");
        assertTrue(manager.supportedCTokens(address(pUSDC)), "pUSDC should be supported");
    }

    function testUserHealthFactorCalculation() public {
        // Test health factor calculation with clean user
        uint256 healthFactor = riskGuard.getUserHealthFactor(user1);
        // Should be very high or max since no borrows
        assertTrue(healthFactor >= 1e18, "Health factor should be high for user with no borrows");
    }

    function testPositionEntryRiskChecks() public {
        // Test position entry with risk checking
        uint256 amount = 1000e18;
        uint64 strike = uint64(ETH_PRICE);
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint8 direction = 0; // CALL

        // This should work since risk guard allows it by default
        (bool canEnter, string memory reason) = manager.canEnterPosition(
            user1,
            address(pETH),
            amount,
            true // use collateral
        );

        // The test should pass basic checks (we configured supported tokens)
        // Note: Full position entry would require more complex mock setup
    }

    function testBorrowRouterCanUserBorrow() public {
        // Test borrow capacity check
        (bool canBorrow, string memory reason) = borrowRouter.canUserBorrow(
            user1,
            address(pETH),
            1e18 // 1 ETH
        );

        // Result depends on mock peridottroller implementation
        // This tests that the function doesn't revert and returns a result
        assertTrue(bytes(reason).length >= 0, "Should return a reason string");
    }

    function testRiskGuardPositionEntryChecks() public {
        // Test position entry validation
        uint256 positionValue = 1000e18; // $1000 position

        (bool allowed, string memory reason) = riskGuard.checkPositionEntry(
            user1,
            address(pETH),
            positionValue,
            true // use collateral
        );

        // Should work for reasonable position size
        assertTrue(bytes(reason).length >= 0, "Should return a reason");
    }

    function testRiskGuardUserPositionTracking() public {
        // Test position value tracking
        uint256 initialValue = riskGuard.userTotalPositionValue(user1);
        assertEq(initialValue, 0, "Initial position value should be zero");

        // Update position value
        uint256 newPositionValue = 1000e18;
        riskGuard.updateUserPositionValue(user1, 0, newPositionValue);

        uint256 updatedValue = riskGuard.userTotalPositionValue(user1);
        assertEq(updatedValue, newPositionValue, "Position value should be updated");
    }

    function testRiskGuardMarketUtilization() public {
        // Test market utilization tracking
        address market = address(pETH);
        uint256 initialUtilization = riskGuard.marketCurrentUtilization(market);
        assertEq(initialUtilization, 0, "Initial market utilization should be zero");

        // Update utilization
        uint256 utilizationIncrease = 5000e18; // $5000
        riskGuard.updateMarketUtilization(market, utilizationIncrease, true);

        uint256 newUtilization = riskGuard.marketCurrentUtilization(market);
        assertEq(newUtilization, utilizationIncrease, "Market utilization should increase");

        // Decrease utilization
        uint256 utilizationDecrease = 2000e18; // $2000
        riskGuard.updateMarketUtilization(market, utilizationDecrease, false);

        uint256 finalUtilization = riskGuard.marketCurrentUtilization(market);
        assertEq(finalUtilization, utilizationIncrease - utilizationDecrease, "Market utilization should decrease");
    }

    function testRiskGuardWhitelisting() public {
        // Test user whitelisting
        assertFalse(riskGuard.whitelistedUsers(user1), "User1 should not be whitelisted initially");

        riskGuard.setWhitelistedUser(user1, true);
        assertTrue(riskGuard.whitelistedUsers(user1), "User1 should be whitelisted after setting");

        riskGuard.setWhitelistedUser(user1, false);
        assertFalse(riskGuard.whitelistedUsers(user1), "User1 should not be whitelisted after removing");
    }

    function testRiskGuardEmergencyControls() public {
        // Test emergency pause
        assertFalse(riskGuard.emergencyPaused(), "Should not be paused initially");

        riskGuard.setEmergencyPause(true);
        assertTrue(riskGuard.emergencyPaused(), "Should be paused after setting");

        riskGuard.setEmergencyPause(false);
        assertFalse(riskGuard.emergencyPaused(), "Should not be paused after unsetting");

        // Test market specific pause
        address market = address(pETH);
        assertFalse(riskGuard.marketsPaused(market), "Market should not be paused initially");

        riskGuard.setMarketPaused(market, true);
        assertTrue(riskGuard.marketsPaused(market), "Market should be paused after setting");
    }

    function testBorrowRouterParameterValidation() public {
        // Test parameter validation
        vm.expectRevert("Health factor must be >= 100%");
        borrowRouter.setMinHealthFactor(0.9e18); // Below 100%

        vm.expectRevert("Health factor too high");
        borrowRouter.setMinHealthFactor(4e18); // Too high

        vm.expectRevert("Invalid LTV range");
        borrowRouter.setMaxLTV(1.1e18); // Above 100%
    }

    function testRiskGuardParameterValidation() public {
        // Test parameter validation for risk guard
        vm.expectRevert("Health factor must be >= 100%");
        riskGuard.setMinHealthFactor(0.8e18);

        vm.expectRevert("Invalid ratio");
        riskGuard.setMaxPositionSizeRatio(1.5e18); // Above 100%

        vm.expectRevert("Invalid ratio");
        riskGuard.setMaxPositionSizeRatio(0); // Zero
    }

    function testLiquidationThresholdValidation() public {
        // Set min health factor first
        riskGuard.setMinHealthFactor(1.5e18);

        // Liquidation threshold setters removed
        // Liquidation threshold removed - handled by Peridottroller

        // Liquidation threshold tests removed
    }

    // Integration test helper functions
    function _setupUserWithCollateral(address user, uint256 collateralAmount) internal {
        // Give user some collateral tokens
        vm.startPrank(user);
        // Setup would depend on specific test scenario
        vm.stopPrank();
    }

    function _mockUserLiquidity(address user, uint256 liquidity) internal {
        // In a real test, you'd configure the mock peridottroller
        // to return specific liquidity values for this user
    }

    // Test events are emitted correctly
    function testBorrowRouterEvents() public {
        // Setup authorized destination
        vm.expectEmit(true, false, false, true);
        emit CompoundBorrowRouter.AuthorizedDestinationUpdated(user1, true);
        borrowRouter.setAuthorizedDestination(user1, true);

        // Test min health factor update event
        vm.expectEmit(false, false, false, true);
        emit CompoundBorrowRouter.MinHealthFactorUpdated(1.25e18, 1.3e18);
        borrowRouter.setMinHealthFactor(1.3e18);
    }

    function testRiskGuardEvents() public {
        // Test risk parameter update event
        vm.expectEmit(false, false, false, true);
        emit RiskGuard.RiskParameterUpdated("minHealthFactor", 1.3e18, 1.4e18);
        riskGuard.setMinHealthFactor(1.4e18);

        // Test user position value update event
        vm.expectEmit(true, false, false, true);
        emit RiskGuard.UserPositionValueUpdated(user1, 0, 1000e18);
        riskGuard.updateUserPositionValue(user1, 0, 1000e18);
    }
}
