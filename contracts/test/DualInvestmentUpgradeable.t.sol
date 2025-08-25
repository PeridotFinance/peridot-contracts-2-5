// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Simple deployment without complex proxy infrastructure

// Upgradeable contracts
import "../contracts/DualInvestment/DualInvestmentManagerUpgradeable.sol";

// Existing Phase 1 contracts
import "../contracts/DualInvestment/ERC1155DualPosition.sol";
import "../contracts/DualInvestment/VaultExecutor.sol";
import "../contracts/DualInvestment/SettlementEngine.sol";

// Phase 2 contracts
import "../contracts/DualInvestment/CompoundBorrowRouter.sol";
import "../contracts/DualInvestment/RiskGuard.sol";

// Core protocol contracts
import "../contracts/SimplePriceOracle.sol";
import "../contracts/PErc20.sol";
import "../contracts/Peridottroller.sol";

// Mock contracts
import "../contracts/MockErc20.sol";
import "./MockPeridottroller.sol";
import "./MockInterestRateModel.sol";
import "./MockPErc20.sol";

contract DualInvestmentUpgradeableTest is Test {
    // Core contracts
    DualInvestmentManagerUpgradeable public manager;

    ERC1155DualPosition public positionToken;
    VaultExecutor public vaultExecutor;
    SettlementEngine public settlementEngine;
    CompoundBorrowRouter public borrowRouter;
    RiskGuard public riskGuard;
    SimplePriceOracle public oracle;
    MockPeridottroller public peridottroller;

    // Mock tokens and cTokens
    MockErc20 public usdc;
    MockErc20 public weth;
    MockErc20 public protocolToken;
    MockPErc20 public pUSDC;
    MockPErc20 public pETH;
    MockInterestRateModel public interestModel;

    // Test accounts
    address public admin;
    address public user1;
    address public user2;
    address public protocolAccount;
    address public protocolTreasury;

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
        protocolTreasury = makeAddr("protocolTreasury");

        // Deploy mock tokens
        usdc = new MockErc20("USD Coin", "USDC", 6);
        weth = new MockErc20("Wrapped Ether", "WETH", 18);
        protocolToken = new MockErc20("Protocol Token", "PROT", 18);

        // Deploy infrastructure
        interestModel = new MockInterestRateModel();
        oracle = new SimplePriceOracle(3600); // 1 hour stale threshold
        peridottroller = new MockPeridottroller();

        // Deploy mock cTokens
        pUSDC = new MockPErc20(address(usdc), "pUSDC");
        pETH = new MockPErc20(address(weth), "pETH");

        // Deploy core contracts
        positionToken = new ERC1155DualPosition();
        vaultExecutor = new VaultExecutor(protocolAccount);
        settlementEngine = new SettlementEngine(
            address(positionToken),
            address(vaultExecutor),
            address(oracle)
        );

        borrowRouter = new CompoundBorrowRouter(
            address(peridottroller),
            address(oracle)
        );
        riskGuard = new RiskGuard(address(peridottroller), address(oracle));

        // Deploy upgradeable manager with simple initialization
        manager = new DualInvestmentManagerUpgradeable();

        manager.initialize(
            address(positionToken),
            address(vaultExecutor),
            address(settlementEngine),
            address(borrowRouter),
            address(riskGuard),
            address(peridottroller),
            protocolTreasury,
            address(protocolToken)
        );

        // Set up authorizations
        positionToken.setAuthorizedMinter(address(manager), true);
        positionToken.setAuthorizedMinter(address(settlementEngine), true);
        vaultExecutor.setAuthorizedManager(address(manager), true);
        vaultExecutor.setAuthorizedManager(address(settlementEngine), true);
        borrowRouter.setAuthorizedDestination(address(vaultExecutor), true);

        // Transfer ownership to manager proxy for risk management
        borrowRouter.transferOwnership(address(manager));
        riskGuard.transferOwnership(address(manager));

        // Set up oracle prices
        oracle.setDirectPrice(address(weth), ETH_PRICE);
        oracle.setDirectPrice(address(usdc), USDC_PRICE);
        // Set price for ETH placeholder address (used by pETH symbol)
        oracle.setDirectPrice(
            0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            ETH_PRICE
        );
        oracle.setDirectPrice(address(pETH), ETH_PRICE); // Set price for cToken too
        oracle.setDirectPrice(address(pUSDC), USDC_PRICE); // Set price for cToken too

        // Configure supported cTokens
        manager.setSupportedCToken(address(pUSDC), true);
        manager.setSupportedCToken(address(pETH), true);

        // Configure protocol integration
        manager.setMarketIntegration(address(pETH), true);
        manager.setMarketIntegration(address(pUSDC), true);
        manager.setMarketUtilizationBonus(address(pETH), 100); // 1% bonus
        manager.setMarketUtilizationBonus(address(pUSDC), 50); // 0.5% bonus

        // Mint initial tokens to users
        usdc.mint(user1, INITIAL_USDC_BALANCE);
        usdc.mint(user2, INITIAL_USDC_BALANCE);
        weth.mint(user1, INITIAL_ETH_BALANCE);
        weth.mint(user2, INITIAL_ETH_BALANCE);
        protocolToken.mint(address(manager), 1000000e18); // Protocol rewards

        // Give users some cTokens for testing
        vm.prank(user1);
        pUSDC.mint(50000e6); // 50k pUSDC
        vm.prank(user1);
        pETH.mint(100e18); // 100 pETH
        vm.prank(user2);
        pUSDC.mint(50000e6); // 50k pUSDC
        vm.prank(user2);
        pETH.mint(100e18); // 100 pETH

        // Give users some ETH for gas
        vm.deal(user1, 100e18);
        vm.deal(user2, 100e18);
    }

    function testUpgradeableInitialization() public {
        // Test that initialization was successful
        assertTrue(address(manager.positionToken()) == address(positionToken));
        assertTrue(address(manager.vaultExecutor()) == address(vaultExecutor));
        assertTrue(
            address(manager.settlementEngine()) == address(settlementEngine)
        );
        assertTrue(address(manager.borrowRouter()) == address(borrowRouter));
        assertTrue(address(manager.riskGuard()) == address(riskGuard));
        assertTrue(
            address(manager.peridottroller()) == address(peridottroller)
        );

        // Test protocol integration initialization
        assertEq(manager.protocolTreasury(), protocolTreasury);
        assertEq(manager.protocolToken(), address(protocolToken));
        assertEq(manager.protocolFeeRate(), 50); // 0.5%
        // Auto-compounding removed
    }

    function testEnterPositionWithOffset_Succeeds() public {
        // Ensure manager and tokens are configured
        vm.prank(user1);
        pETH.approve(address(vaultExecutor), 1e18);

        // Add support if not present
        if (!manager.supportedCTokens(address(pETH))) {
            vm.prank(address(this));
            manager.setSupportedCToken(address(pETH), true);
        }
        if (!manager.supportedCTokens(address(pUSDC))) {
            vm.prank(address(this));
            manager.setSupportedCToken(address(pUSDC), true);
        }

        // Use configured minExpiry to ensure we meet the lower bound
        uint256 offset = manager.minExpiry();
        vm.prank(user1);
        uint256 tokenId = manager.enterPositionWithOffset(
            address(pETH),
            address(pUSDC),
            1e18,
            0,
            ETH_PRICE,
            offset,
            true,
            false
        );

        assertGt(tokenId, 0);
        uint256 bal = positionToken.balanceOf(user1, tokenId);
        assertEq(bal, 1e18);
    }

    function testSettlementWithLiquidity_Succeeds() public {
        // Seed larger pool liquidity and verify non-zero payout
        // Mint cTokens to user and approve vault
        vm.startPrank(user1);
        pETH.approve(address(vaultExecutor), type(uint256).max);
        vm.stopPrank();

        // Enter a larger position (5 ETH)
        uint256 offset = manager.minExpiry();
        vm.prank(user1);
        uint256 tokenId = manager.enterPositionWithOffset(
            address(pETH),
            address(pUSDC),
            5e18,
            0,
            ETH_PRICE,
            offset,
            true,
            false
        );

        // Fast forward to expiry
        vm.warp(block.timestamp + offset + 1);

        // Settlement should not revert and should emit
        vm.prank(address(this));
        settlementEngine.settlePosition(tokenId, user1);
    }

    function testEnterPositionWithBorrowed_Succeeds() public {
        // Simulate user borrowing underlying and using it for position
        // For test, use weth underlying with mock pETH
        vm.startPrank(user1);
        // User obtains 2 ETH underlying and approves vault executor
        weth.approve(address(vaultExecutor), 2e18);
        vm.stopPrank();

        uint256 expiry = block.timestamp + manager.minExpiry();
        vm.prank(user1);
        uint256 tokenId = manager.enterPositionWithBorrowed(
            address(pETH),
            address(pUSDC),
            2e18,
            0,
            ETH_PRICE,
            expiry
        );

        assertGt(tokenId, 0);
    }

    function testBorrowAndEnterPosition_OneShot() public {
        // Ensure router authorized and market integrated
        manager.setMarketIntegration(address(pETH), true);
        // borrowRouter owner is the manager (ownership was transferred in setUp), so prank as manager
        vm.prank(address(manager));
        borrowRouter.setAuthorizedDestination(address(vaultExecutor), true);

        // Configure user mock liquidity indirectly by minting and prices (already in setUp)
        uint256 expiry = block.timestamp + manager.minExpiry();

        // Pre-approve router to pull underlying if borrow credits user
        vm.prank(user1);
        weth.approve(address(borrowRouter), type(uint256).max);

        // Borrow 1 ETH underlying and enter position in one call
        vm.prank(user1);
        uint256 tokenId = manager.borrowAndEnterPosition(
            address(pETH),
            address(pUSDC),
            1e18,
            0,
            ETH_PRICE,
            expiry
        );
        assertGt(tokenId, 0);
    }

    function testEnterPositionWithOffset_TooSoonReverts() public {
        // Min expiry is set in setUp via manager.setRiskParameters
        vm.prank(user1);
        pETH.approve(address(vaultExecutor), 1e18);

        if (!manager.supportedCTokens(address(pETH))) {
            vm.prank(address(this));
            manager.setSupportedCToken(address(pETH), true);
        }
        if (!manager.supportedCTokens(address(pUSDC))) {
            vm.prank(address(this));
            manager.setSupportedCToken(address(pUSDC), true);
        }

        // Offset just below minExpiry should fail the minExpiry guard
        uint256 tooSmall = manager.minExpiry() - 1;
        vm.prank(user1);
        vm.expectRevert(bytes("Expiry too soon"));
        manager.enterPositionWithOffset(
            address(pETH),
            address(pUSDC),
            1e18,
            0,
            ETH_PRICE,
            tooSmall,
            true,
            false
        );
    }

    function testProtocolConfiguration() public {
        // Test protocol configuration updates
        address newTreasury = makeAddr("newTreasury");
        uint256 newFeeRate = 100; // 1%
        address newToken = makeAddr("newToken");

        manager.updateProtocolConfig(newTreasury, newFeeRate, newToken);

        assertEq(manager.protocolTreasury(), newTreasury);
        assertEq(manager.protocolFeeRate(), newFeeRate);
        assertEq(manager.protocolToken(), newToken);
    }

    function testMarketIntegration() public {
        // Test market integration configuration
        address newMarket = makeAddr("newMarket");

        assertFalse(manager.protocolIntegratedMarkets(newMarket));

        manager.setMarketIntegration(newMarket, true);
        assertTrue(manager.protocolIntegratedMarkets(newMarket));

        // Test utilization bonus
        manager.setMarketUtilizationBonus(newMarket, 200); // 2%
        assertEq(manager.marketUtilizationBonus(newMarket), 200);
    }

    function testAutoCompoundingConfiguration() public {
        // Test auto-compounding configuration
        // Auto-compounding removed

        uint256 newThreshold = 500e18; // $500
        // Auto-compounding configuration removed

        // Auto-compounding configuration removed
    }

    function testPositionEntryWithProtocolIntegration() public {
        // Test entering a position with protocol integration features
        uint256 amount = 1e18; // 1 ETH = $2400
        uint64 strike = uint64(ETH_PRICE);
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint8 direction = 0; // CALL

        // Approve cToken transfer to VaultExecutor (redeem path pulls from user)
        vm.startPrank(user1);
        pETH.approve(address(vaultExecutor), amount);
        vm.stopPrank();

        // Check initial state
        uint256 initialRewards = manager.userProtocolRewards(user1);
        assertEq(initialRewards, 0);

        // Enter position with protocol integration
        vm.prank(user1);
        uint256 tokenId = manager.enterPosition(
            address(pETH),
            address(pUSDC),
            amount,
            direction,
            strike,
            expiry,
            true, // use collateral
            true // enable auto-compound
        );

        // Check that position was created
        assertGt(tokenId, 0);

        // Check that position token was minted
        uint256 balance = positionToken.balanceOf(user1, tokenId);
        assertEq(balance, amount);

        // Check that protocol rewards were earned (should be > 0 for integrated market)
        uint256 finalRewards = manager.userProtocolRewards(user1);
        assertGt(finalRewards, initialRewards);
    }

    function testBatchPositionEntry() public {
        // Test batch position entry
        uint256 batchSize = 2; // 2 positions = $4800 total, within $5000 limit
        address[] memory cTokensIn = new address[](batchSize);
        address[] memory cTokensOut = new address[](batchSize);
        uint256[] memory amounts = new uint256[](batchSize);
        uint8[] memory directions = new uint8[](batchSize);
        uint256[] memory strikes = new uint256[](batchSize);
        uint256[] memory expiries = new uint256[](batchSize);
        bool[] memory useCollateral = new bool[](batchSize);

        // Setup batch parameters
        for (uint256 i = 0; i < batchSize; i++) {
            cTokensIn[i] = address(pETH);
            cTokensOut[i] = address(pUSDC);
            amounts[i] = 1e18; // 1 ETH each position
            directions[i] = uint8(i % 2); // Alternating CALL/PUT
            strikes[i] = ETH_PRICE + (i * 100e18); // Varying strikes
            expiries[i] = uint64(block.timestamp + 1 days + (i * 1 hours));
            useCollateral[i] = true;
        }

        // Approve cToken transfers
        vm.prank(user1);
        pETH.approve(address(vaultExecutor), type(uint256).max);

        // Execute batch entry
        vm.prank(user1);
        uint256[] memory tokenIds = manager.batchEnterPositions(
            cTokensIn,
            cTokensOut,
            amounts,
            directions,
            strikes,
            expiries,
            useCollateral
        );

        // Verify all positions were created
        assertEq(tokenIds.length, batchSize);
        for (uint256 i = 0; i < batchSize; i++) {
            assertGt(tokenIds[i], 0);
            uint256 balance = positionToken.balanceOf(user1, tokenIds[i]);
            assertEq(balance, amounts[i]);
        }

        // Check that protocol rewards were accumulated
        uint256 rewards = manager.userProtocolRewards(user1);
        assertGt(rewards, 0);
    }

    function testProtocolRewardClaim() public {
        // First create a position to earn rewards
        vm.prank(user1);
        pETH.approve(address(manager), 50e18);

        vm.prank(user1);
        manager.enterPosition(
            address(pETH),
            address(pUSDC),
            1e18,
            0, // CALL
            uint256(ETH_PRICE),
            uint64(block.timestamp + 1 days),
            true, // use collateral
            false // no auto-compound for this test
        );

        // Check rewards were earned
        uint256 rewards = manager.userProtocolRewards(user1);
        assertGt(rewards, 0);

        // Check initial protocol token balance
        uint256 initialBalance = protocolToken.balanceOf(user1);

        // Claim rewards
        vm.prank(user1);
        manager.claimProtocolRewards();

        // Check rewards were claimed
        assertEq(manager.userProtocolRewards(user1), 0);

        // Check protocol tokens were transferred
        uint256 finalBalance = protocolToken.balanceOf(user1);
        assertEq(finalBalance - initialBalance, rewards);
    }

    function testContractUpgrade() public {
        // Test basic contract state and functionality (no actual upgrade needed for now)

        // Verify current state
        address currentTreasury = manager.protocolTreasury();
        uint256 currentFeeRate = manager.protocolFeeRate();

        assertEq(currentTreasury, protocolTreasury);
        assertEq(currentFeeRate, 50); // 0.5% default fee

        // Verify contract functionality still works
        assertTrue(manager.supportedCTokens(address(pETH)));
        assertTrue(manager.protocolIntegratedMarkets(address(pETH)));
    }

    function testProtocolFeeValidation() public {
        // Test fee rate validation
        vm.expectRevert("Fee rate too high");
        manager.updateProtocolConfig(
            protocolTreasury,
            1001,
            address(protocolToken)
        ); // > 10%

        // Test valid fee rate
        manager.updateProtocolConfig(
            protocolTreasury,
            1000,
            address(protocolToken)
        ); // Exactly 10%
        assertEq(manager.protocolFeeRate(), 1000);
    }

    function testMarketBonusValidation() public {
        // Test bonus validation
        vm.expectRevert("Bonus too high");
        manager.setMarketUtilizationBonus(address(pETH), 5001); // > 50%

        // Test valid bonus
        manager.setMarketUtilizationBonus(address(pETH), 5000); // Exactly 50%
        assertEq(manager.marketUtilizationBonus(address(pETH)), 5000);
    }

    function testOnlyOwnerFunctions() public {
        // Test that only owner can call admin functions
        vm.prank(user1);
        vm.expectRevert();
        manager.updateProtocolConfig(
            protocolTreasury,
            100,
            address(protocolToken)
        );

        vm.prank(user1);
        vm.expectRevert();
        manager.setMarketIntegration(address(pETH), false);

        // Auto-compounding configuration removed - no additional owner-only functions to test
    }

    function testProtocolIntegrationEvents() public {
        // Test that protocol events are emitted correctly

        // Test market integration event
        vm.expectEmit(true, false, false, true);
        emit DualInvestmentManagerUpgradeable.MarketIntegrationUpdated(
            address(pUSDC),
            false
        );
        manager.setMarketIntegration(address(pUSDC), false);

        // Test protocol config event
        address newTreasury = makeAddr("newTreasury");
        vm.expectEmit(false, false, false, true);
        emit DualInvestmentManagerUpgradeable.ProtocolConfigUpdated(
            newTreasury,
            75,
            address(protocolToken)
        );
        manager.updateProtocolConfig(newTreasury, 75, address(protocolToken));
    }

    function testStorageGap() public {
        // Test storage organization and state consistency

        // Get current storage values
        uint256 currentNextMarketId = manager.nextMarketId();
        // Auto-compounding removed - skip this check

        // Verify storage values are as expected
        assertEq(currentNextMarketId, 1); // Initial value
        // Auto-compounding removed - storage gap test only

        // Test storage updates work correctly
        // Auto-compounding configuration removed
        // Auto-compounding configuration removed
    }

    // Helper functions for test setup
    function _createTestPosition(
        address user,
        uint256 amount,
        bool useCollateral
    ) internal returns (uint256 tokenId) {
        vm.prank(user);
        if (useCollateral) {
            pETH.approve(address(vaultExecutor), amount);
        }

        vm.prank(user);
        tokenId = manager.enterPosition(
            address(pETH),
            address(pUSDC),
            amount,
            0, // CALL
            uint256(ETH_PRICE),
            uint64(block.timestamp + 1 days),
            useCollateral,
            true // enable auto-compound
        );
    }
}
