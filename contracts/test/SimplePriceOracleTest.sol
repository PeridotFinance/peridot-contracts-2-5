// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "../contracts/SimplePriceOracle.sol";
import "../contracts/PErc20Immutable.sol";
import "../contracts/MockErc20.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/JumpRateModel.sol";
import "../contracts/Unitroller.sol";

/**
 * @title Mock Chainlink Aggregator for Testing
 */
contract MockChainlinkAggregator {
    int256 public price;
    uint256 public updatedAt;
    uint8 public decimals;
    uint80 public roundId;
    bool public shouldRevert;

    constructor(int256 _price, uint8 _decimals) {
        price = _price;
        decimals = _decimals;
        updatedAt = block.timestamp;
        roundId = 1;
        shouldRevert = false;
    }

    function setPrice(int256 _price) external {
        price = _price;
        updatedAt = block.timestamp;
        roundId++;
    }

    function setUpdatedAt(uint256 _updatedAt) external {
        updatedAt = _updatedAt;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function latestRoundData()
        external
        view
        returns (uint80 _roundId, int256 _price, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
    {
        require(!shouldRevert, "Mock revert");
        return (roundId, price, block.timestamp, updatedAt, roundId);
    }
}

/**
 * @title Simple Price Oracle Test Suite
 * @notice Comprehensive tests for SimplePriceOracle functionality
 */
contract SimplePriceOracleTest {
    SimplePriceOracle public oracle;
    MockErc20 public underlying;
    PErc20Immutable public pToken;
    MockChainlinkAggregator public mockAggregator;

    address public owner;
    address public admin;
    address public user;

    // Test setup contracts
    Peridottroller public peridottroller;
    JumpRateModel public interestRateModel;
    Unitroller public unitroller;

    // Events for testing
    event TestResult(string testName, bool success);
    event PriceSet(address asset, uint256 price);

    constructor() {
        owner = msg.sender;
        admin = address(0x1);
        user = address(0x2);

        // Deploy oracle with 1 hour stale threshold
        oracle = new SimplePriceOracle(3600);

        // Deploy supporting contracts for pToken testing
        _deploySupportingContracts();

        // Deploy test token
        underlying = new MockErc20("Test Token", "TEST", 18);

        // Deploy pToken for testing
        pToken = new PErc20Immutable(
            address(underlying),
            PeridottrollerInterface(address(unitroller)),
            InterestRateModel(address(interestRateModel)),
            1e18, // Initial exchange rate
            "Test pToken",
            "pTEST",
            18,
            payable(address(this))
        );

        // Deploy mock Chainlink aggregator (price: $100, 8 decimals)
        mockAggregator = new MockChainlinkAggregator(100 * 1e8, 8);

        // Set up admin
        oracle.setAdmin(admin);
    }

    function _deploySupportingContracts() internal {
        // Deploy the real Peridottroller implementation
        peridottroller = new Peridottroller();

        // Deploy Unitroller (proxy)
        unitroller = new Unitroller();

        // Set the implementation
        unitroller._setPendingImplementation(address(peridottroller));
        peridottroller._become(unitroller);

        // Deploy interest rate model
        interestRateModel = new JumpRateModel(
            0.02e18, // baseRatePerYear (2%)
            0.1e18, // multiplierPerYear (10%)
            2.0e18, // jumpMultiplierPerYear (200%)
            0.8e18 // kink (80%)
        );

        // Configure the Peridottroller
        Peridottroller(address(unitroller))._setCloseFactor(0.5e18);
        Peridottroller(address(unitroller))._setLiquidationIncentive(1.08e18);
    }

    /**
     * @notice Test basic price setting and retrieval
     */
    function testBasicPriceFunctionality() public {
        uint256 testPrice = 1.5e18; // $1.50

        // Only admin should be able to set prices
        try oracle.setUnderlyingPrice(pToken, testPrice) {
            emit TestResult("Non-admin price setting (should fail)", false);
        } catch {
            emit TestResult("Non-admin price setting (should fail)", true);
        }

        // Test getting price initially
        uint256 retrievedPrice = oracle.getUnderlyingPrice(pToken);

        // Initially should be 0 since no price is set
        emit TestResult("Initial price is zero", retrievedPrice == 0);

        // Set price using direct asset address method (owner is also admin)
        oracle.setDirectPrice(address(underlying), testPrice);

        // Test getting price after setting
        uint256 retrievedPriceAfter = oracle.assetPrices(address(underlying));
        emit TestResult("Price set correctly", retrievedPriceAfter == testPrice);

        emit PriceSet(address(underlying), testPrice);
    }

    /**
     * @notice Test admin and owner management
     */
    function testAdminManagement() public {
        // Only owner should be able to add/remove admins
        bool isAdminBefore = oracle.admin(admin);
        emit TestResult("Admin was set correctly", isAdminBefore);

        // Test removing admin
        oracle.removeAdmin(admin);
        bool isAdminAfter = oracle.admin(admin);
        emit TestResult("Admin removed successfully", !isAdminAfter);

        // Re-add admin for other tests
        oracle.setAdmin(admin);
        bool isAdminReAdded = oracle.admin(admin);
        emit TestResult("Admin re-added successfully", isAdminReAdded);
    }

    /**
     * @notice Test Chainlink feed registration and functionality
     */
    function testChainlinkIntegration() public {
        address assetAddress = address(underlying);

        // Register Chainlink feed
        oracle.registerChainlinkFeed(assetAddress, address(mockAggregator));

        // Verify aggregator was registered
        address registeredAggregator = oracle.getAggregator(assetAddress);
        emit TestResult("Chainlink feed registered correctly", registeredAggregator == address(mockAggregator));

        // Test price retrieval from Chainlink
        uint256 chainlinkPrice = oracle.assetPrices(assetAddress);
        // Mock aggregator returns 100 * 1e8 (8 decimals), should be converted to 100 * 1e18
        uint256 expectedPrice = 100 * 1e18;
        emit TestResult("Chainlink price retrieved correctly", chainlinkPrice == expectedPrice);

        // Test latest round data
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            oracle.getLatestRoundData(assetAddress);

        emit TestResult("Round data retrieved", price == 100 * 1e8);
    }

    /**
     * @notice Test stale price detection and handling
     */
    function testStalePriceHandling() public {
        address assetAddress = address(underlying);

        // Register aggregator if not already done
        oracle.registerChainlinkFeed(assetAddress, address(mockAggregator));

        // Price should not be stale initially
        bool isStaleInitial = oracle.isPriceStale(assetAddress);
        emit TestResult("Price is fresh initially", !isStaleInitial);

        // Set updated time to be stale (more than 1 hour ago)
        uint256 staleTime = block.timestamp > 7200 ? block.timestamp - 7200 : 0;
        mockAggregator.setUpdatedAt(staleTime); // 2 hours ago

        // Price should now be stale
        bool isStaleAfter = oracle.isPriceStale(assetAddress);
        emit TestResult("Price is stale after time update", isStaleAfter);

        // Reset to fresh time
        mockAggregator.setUpdatedAt(block.timestamp);
        bool isFreshAgain = oracle.isPriceStale(assetAddress);
        emit TestResult("Price is fresh again", !isFreshAgain);
    }

    /**
     * @notice Test price caching functionality
     */
    function testPriceCaching() public {
        address assetAddress = address(underlying);

        // Register aggregator
        oracle.registerChainlinkFeed(assetAddress, address(mockAggregator));

        // Update cached prices
        address[] memory assets = new address[](1);
        assets[0] = assetAddress;
        oracle.updateChainlinkPrices(assets);

        // Verify cached price was set
        uint256 cachedPrice = oracle.lastValidChainlinkPrice(assetAddress);
        emit TestResult("Price cached correctly", cachedPrice == 100 * 1e18);

        // Make aggregator return stale data
        uint256 staleTime = block.timestamp > 7200 ? block.timestamp - 7200 : 0;
        mockAggregator.setUpdatedAt(staleTime); // 2 hours ago

        // Should still return cached price
        uint256 priceWhenStale = oracle.assetPrices(assetAddress);
        emit TestResult("Returns cached price when stale", priceWhenStale == 100 * 1e18);
    }

    /**
     * @notice Test fallback to manual prices
     */
    function testManualPriceFallback() public {
        // Create a new asset without Chainlink feed
        MockErc20 newToken = new MockErc20("New Token", "NEW", 18);

        uint256 manualPrice = 2.5e18; // $2.50

        // Set manual price
        oracle.setDirectPrice(address(newToken), manualPrice);

        // Should return manual price
        uint256 retrievedPrice = oracle.assetPrices(address(newToken));
        emit TestResult("Manual price fallback works", retrievedPrice == manualPrice);
    }

    /**
     * @notice Test aggregator failure scenarios
     */
    function testAggregatorFailures() public {
        address assetAddress = address(underlying);

        // Register aggregator
        oracle.registerChainlinkFeed(assetAddress, address(mockAggregator));

        // Set up a cached price first
        address[] memory assets = new address[](1);
        assets[0] = assetAddress;
        oracle.updateChainlinkPrices(assets);

        // Make aggregator revert
        mockAggregator.setShouldRevert(true);

        // Should return cached price when aggregator fails
        uint256 priceOnFailure = oracle.assetPrices(assetAddress);
        emit TestResult("Returns cached price on aggregator failure", priceOnFailure == 100 * 1e18);

        // Reset aggregator
        mockAggregator.setShouldRevert(false);

        // Should work normally again
        uint256 priceAfterReset = oracle.assetPrices(assetAddress);
        emit TestResult("Works normally after aggregator reset", priceAfterReset == 100 * 1e18);
    }

    /**
     * @notice Test zero/negative price handling
     */
    function testInvalidPriceHandling() public {
        address assetAddress = address(underlying);

        // Register aggregator
        oracle.registerChainlinkFeed(assetAddress, address(mockAggregator));

        // Set up cached price
        address[] memory assets = new address[](1);
        assets[0] = assetAddress;
        oracle.updateChainlinkPrices(assets);

        // Set negative price
        mockAggregator.setPrice(-100 * 1e8);

        // Should return cached price for negative price
        uint256 priceWithNegative = oracle.assetPrices(assetAddress);
        emit TestResult("Returns cached price for negative price", priceWithNegative == 100 * 1e18);

        // Set zero price
        mockAggregator.setPrice(0);

        // Should return cached price for zero price
        uint256 priceWithZero = oracle.assetPrices(assetAddress);
        emit TestResult("Returns cached price for zero price", priceWithZero == 100 * 1e18);
    }

    /**
     * @notice Test stale threshold configuration
     */
    function testStaleThresholdConfig() public {
        // Test setting new threshold
        uint256 newThreshold = 7200; // 2 hours
        oracle.setChainlinkStaleThreshold(newThreshold);

        uint256 currentThreshold = oracle.chainlinkPriceStaleThreshold();
        emit TestResult("Stale threshold updated correctly", currentThreshold == newThreshold);

        // Test with the new threshold
        address assetAddress = address(underlying);
        oracle.registerChainlinkFeed(assetAddress, address(mockAggregator));

        // Set time to be 1.5 hours ago (should not be stale with 2-hour threshold)
        uint256 recentTime = block.timestamp > 5400 ? block.timestamp - 5400 : 0;
        mockAggregator.setUpdatedAt(recentTime); // 1.5 hours

        bool isStale = oracle.isPriceStale(assetAddress);
        emit TestResult("Price not stale with new threshold", !isStale);
    }

    /**
     * @notice Test owner transfer functionality
     */
    function testOwnerTransfer() public {
        address newOwner = address(0x3);

        // Transfer ownership
        oracle.setOwner(newOwner);

        // Note: In a full test, we would verify that only newOwner can call owner functions
        // For this test, we'll just verify the function doesn't revert
        emit TestResult("Owner transfer completed", true);
    }

    /**
     * @notice Run all tests
     */
    function runAllTests() external {
        testBasicPriceFunctionality();
        testAdminManagement();
        testChainlinkIntegration();
        testStalePriceHandling();
        testPriceCaching();
        testManualPriceFallback();
        testAggregatorFailures();
        testInvalidPriceHandling();
        testStaleThresholdConfig();
        testOwnerTransfer();
    }

    /**
     * @notice Get test contract info
     */
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
        return (
            address(oracle),
            address(underlying),
            address(pToken),
            address(mockAggregator),
            oracle.chainlinkPriceStaleThreshold()
        );
    }
}
