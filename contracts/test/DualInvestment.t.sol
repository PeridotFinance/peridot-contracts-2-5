// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Dual Investment contracts
import "../contracts/DualInvestment/DualInvestmentManager.sol";
import "../contracts/DualInvestment/ERC1155DualPosition.sol";
import "../contracts/DualInvestment/VaultExecutor.sol";
import "../contracts/DualInvestment/SettlementEngine.sol";

// Core protocol contracts
import "../contracts/SimplePriceOracle.sol";
import "../contracts/PErc20.sol";
import "../contracts/Peridottroller.sol";
import "../contracts/InterestRateModel.sol";
import "../contracts/JumpRateModelV2.sol";

// Mock contracts
import "../contracts/MockErc20.sol";
import "./MockPeridottroller.sol";
import "./MockInterestRateModel.sol";
import "./MockPErc20.sol";

contract DualInvestmentTest is Test {
    // Core contracts
    DualInvestmentManager public manager;
    ERC1155DualPosition public positionToken;
    VaultExecutor public vaultExecutor;
    SettlementEngine public settlementEngine;
    SimplePriceOracle public oracle;
    MockPeridottroller public peridottroller;

    // Mock tokens and cTokens
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

        // Deploy core dual investment contracts
        positionToken = new ERC1155DualPosition();
        vaultExecutor = new VaultExecutor(protocolAccount);
        settlementEngine = new SettlementEngine(address(positionToken), address(vaultExecutor), address(oracle));
        // Create dummy addresses for Phase 2 components for backward compatibility
        address dummyBorrowRouter = makeAddr("dummyBorrowRouter");
        address dummyRiskGuard = makeAddr("dummyRiskGuard");

        manager = new DualInvestmentManager(
            address(positionToken),
            address(vaultExecutor),
            address(settlementEngine),
            dummyBorrowRouter,
            dummyRiskGuard,
            address(peridottroller)
        );

        // Set up authorizations
        positionToken.setAuthorizedMinter(address(manager), true);
        positionToken.setAuthorizedMinter(address(settlementEngine), true);
        vaultExecutor.setAuthorizedManager(address(manager), true);
        vaultExecutor.setAuthorizedManager(address(settlementEngine), true);

        // Deploy mock pTokens (simplified for testing)
        // Note: In a real deployment, these would be proper PErc20 contracts
        // For testing, we'll use a simplified approach

        // Set up oracle prices
        oracle.setDirectPrice(address(weth), ETH_PRICE);
        oracle.setDirectPrice(address(usdc), USDC_PRICE);

        // Mint initial tokens to users
        usdc.mint(user1, INITIAL_USDC_BALANCE);
        usdc.mint(user2, INITIAL_USDC_BALANCE);
        weth.mint(user1, INITIAL_ETH_BALANCE);
        weth.mint(user2, INITIAL_ETH_BALANCE);

        // Give users some ETH for gas
        vm.deal(user1, 100e18);
        vm.deal(user2, 100e18);
    }

    function testPositionTokenCreation() public {
        // Test generating token IDs
        uint256 tokenId = positionToken.generateTokenId(
            address(weth),
            uint64(ETH_PRICE), // Strike at current price
            uint64(block.timestamp + 1 days), // 1 day expiry
            0, // CALL direction
            1 // Market ID
        );

        assertGt(tokenId, 0, "Token ID should be non-zero");

        // Test that same parameters generate same token ID
        uint256 tokenId2 =
            positionToken.generateTokenId(address(weth), uint64(ETH_PRICE), uint64(block.timestamp + 1 days), 0, 1);

        assertEq(tokenId, tokenId2, "Same parameters should generate same token ID");
    }

    function testVaultExecutorBasics() public {
        // Test authorization
        assertFalse(vaultExecutor.authorizedManagers(user1), "User1 should not be authorized initially");

        vaultExecutor.setAuthorizedManager(user1, true);
        assertTrue(vaultExecutor.authorizedManagers(user1), "User1 should be authorized after setting");

        vaultExecutor.setAuthorizedManager(user1, false);
        assertFalse(vaultExecutor.authorizedManagers(user1), "User1 should not be authorized after removing");
    }

    function testOraclePriceRetrieval() public {
        // Test direct price setting and retrieval
        uint256 newEthPrice = 2500e18;
        oracle.setDirectPrice(address(weth), newEthPrice);

        uint256 retrievedPrice = oracle.assetPrices(address(weth));
        assertEq(retrievedPrice, newEthPrice, "Oracle should return set price");
    }

    function testManagerCTokenSupport() public {
        // Initially no cTokens should be supported
        assertFalse(manager.supportedCTokens(address(pUSDC)), "pUSDC should not be supported initially");

        // Add support for a cToken
        manager.setSupportedCToken(address(pUSDC), true);
        assertTrue(manager.supportedCTokens(address(pUSDC)), "pUSDC should be supported after setting");

        // Remove support
        manager.setSupportedCToken(address(pUSDC), false);
        assertFalse(manager.supportedCTokens(address(pUSDC)), "pUSDC should not be supported after removing");
    }

    function testRiskParameterUpdates() public {
        // Test risk parameter updates
        uint256 newMaxSize = 500000e18;
        uint256 newMinSize = 10e18;
        uint256 newMaxExpiry = 60 days;
        uint256 newMinExpiry = 30 minutes;

        manager.setRiskParameters(newMaxSize, newMinSize, newMaxExpiry, newMinExpiry);

        assertEq(manager.maxPositionSize(), newMaxSize, "Max position size should be updated");
        assertEq(manager.minPositionSize(), newMinSize, "Min position size should be updated");
        assertEq(manager.maxExpiry(), newMaxExpiry, "Max expiry should be updated");
        assertEq(manager.minExpiry(), newMinExpiry, "Min expiry should be updated");
    }

    function testSettlementWindowUpdate() public {
        uint256 newWindow = 2 hours;
        settlementEngine.setSettlementWindow(newWindow);

        assertEq(settlementEngine.settlementWindow(), newWindow, "Settlement window should be updated");
    }

    function testPositionTokenEvents() public {
        // Set up authorization
        positionToken.setAuthorizedMinter(address(this), true);

        // Create a test position
        ERC1155DualPosition.Position memory position = ERC1155DualPosition.Position({
            user: user1,
            cTokenIn: address(pETH),
            cTokenOut: address(pUSDC),
            notional: 1000e18,
            expiry: uint64(block.timestamp + 1 days),
            strike: uint64(ETH_PRICE),
            direction: 0, // CALL
            settled: false
        });

        uint256 tokenId =
            positionToken.generateTokenId(address(weth), position.strike, position.expiry, position.direction, 1);

        // Test position creation event
        vm.expectEmit(true, true, false, true);
        emit ERC1155DualPosition.PositionCreated(
            tokenId,
            position.user,
            position.cTokenIn,
            position.cTokenOut,
            position.notional,
            position.expiry,
            position.strike,
            position.direction
        );

        positionToken.mintPosition(user1, tokenId, 1000e18, position);

        // Verify position data
        ERC1155DualPosition.Position memory storedPosition = positionToken.getPosition(tokenId);
        assertEq(storedPosition.user, position.user, "User should match");
        assertEq(storedPosition.notional, position.notional, "Notional should match");
        assertEq(storedPosition.strike, position.strike, "Strike should match");
        assertEq(storedPosition.direction, position.direction, "Direction should match");

        // Verify token balance
        uint256 balance = positionToken.balanceOf(user1, tokenId);
        assertEq(balance, 1000e18, "User should have correct token balance");
    }

    function testSettlementInfoQueries() public {
        // Test settlement info for non-existent position
        uint256 fakeTokenId = 999;
        (bool settled, uint256 settlementPrice, bool canSettle) = settlementEngine.getSettlementInfo(fakeTokenId);

        assertFalse(settled, "Non-existent position should not be settled");
        assertEq(settlementPrice, 0, "Non-existent position should have zero settlement price");
        assertFalse(canSettle, "Non-existent position should not be settleable");
    }

    function testCanSettlePosition() public {
        uint256 fakeTokenId = 999;
        (bool canSettle, string memory reason) = settlementEngine.canSettlePosition(fakeTokenId);

        assertFalse(canSettle, "Non-existent position should not be settleable");
        // Note: We can't easily test string equality in Solidity, but we can verify it's not empty
        assertTrue(bytes(reason).length > 0, "Should provide reason for non-settleable position");
    }

    // Test helper functions
    function _createTestPosition(address user, uint256 amount, uint64 strike, uint64 expiry, uint8 direction)
        internal
        returns (uint256 tokenId)
    {
        ERC1155DualPosition.Position memory position = ERC1155DualPosition.Position({
            user: user,
            cTokenIn: address(pETH),
            cTokenOut: address(pUSDC),
            notional: uint128(amount),
            expiry: expiry,
            strike: strike,
            direction: direction,
            settled: false
        });

        tokenId = positionToken.generateTokenId(address(weth), strike, expiry, direction, 1);

        // Authorize this contract to mint
        positionToken.setAuthorizedMinter(address(this), true);
        positionToken.mintPosition(user, tokenId, amount, position);

        return tokenId;
    }

    function testBasicPositionLifecycle() public {
        // Create a test position
        uint256 amount = 1000e18;
        uint64 strike = uint64(ETH_PRICE);
        uint64 expiry = uint64(block.timestamp + 1 days);

        uint256 tokenId = _createTestPosition(user1, amount, strike, expiry, 0);

        // Verify position exists
        ERC1155DualPosition.Position memory position = positionToken.getPosition(tokenId);
        assertEq(position.user, user1, "Position user should match");
        assertFalse(position.settled, "Position should not be settled initially");

        // Verify user has tokens
        uint256 balance = positionToken.balanceOf(user1, tokenId);
        assertEq(balance, amount, "User should have correct balance");

        // Check if position is expired (should not be)
        assertFalse(positionToken.isExpired(tokenId), "Position should not be expired yet");
        assertFalse(positionToken.isSettled(tokenId), "Position should not be settled yet");
    }

    // Test edge cases and error conditions
    function testFailUnauthorizedMint() public {
        ERC1155DualPosition.Position memory position = ERC1155DualPosition.Position({
            user: user1,
            cTokenIn: address(pETH),
            cTokenOut: address(pUSDC),
            notional: 1000e18,
            expiry: uint64(block.timestamp + 1 days),
            strike: uint64(ETH_PRICE),
            direction: 0,
            settled: false
        });

        uint256 tokenId = 1;

        // This should fail because we're not authorized
        vm.prank(user1);
        positionToken.mintPosition(user1, tokenId, 1000e18, position);
    }

    function testFailInvalidDirection() public {
        ERC1155DualPosition.Position memory position = ERC1155DualPosition.Position({
            user: user1,
            cTokenIn: address(pETH),
            cTokenOut: address(pUSDC),
            notional: 1000e18,
            expiry: uint64(block.timestamp + 1 days),
            strike: uint64(ETH_PRICE),
            direction: 5, // Invalid direction
            settled: false
        });

        positionToken.setAuthorizedMinter(address(this), true);
        uint256 tokenId = 1;

        // This should fail due to invalid direction
        positionToken.mintPosition(user1, tokenId, 1000e18, position);
    }
}
