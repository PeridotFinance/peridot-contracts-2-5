// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/PancakeBoostedPErc20.sol";
import "./MockErc20.sol";
import "./MockInterestRateModel.sol";
import "./MockPeridottroller.sol";
import "./mocks/MockERC4626Vault.sol";

contract PancakeBoostedPErc20Test is Test {
    MockErc20 internal baseToken;
    MockERC4626Vault internal vault;
    MockPeridottroller internal comptroller;
    MockInterestRateModel internal irm;
    PancakeBoostedPErc20 internal pToken;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);

    uint256 internal constant INITIAL_EXCHANGE_RATE = 1e18;
    uint256 internal constant MIN_SEED = 1000; // Minimum vault shares at dead address

    function setUp() public {
        // Base token that the vault wraps
        baseToken = new MockErc20("Base Token", "BASE", 18);

        // ERC4626 vault - this will be our pToken's underlying
        vault = new MockERC4626Vault(IERC20Metadata(address(baseToken)));

        comptroller = new MockPeridottroller();
        irm = new MockInterestRateModel();

        // Seed the vault with dead address shares for inflation protection
        baseToken.mint(address(this), MIN_SEED);
        baseToken.approve(address(vault), MIN_SEED);
        vault.deposit(MIN_SEED, DEAD);

        // Create pToken with vault shares as underlying
        pToken = new PancakeBoostedPErc20(
            address(vault), // underlying = vault share token
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Peridot Pancake LP",
            "pPancakeLP",
            18,
            payable(address(this)),
            MIN_SEED // require seed at dead address
        );

        comptroller.setMarket(address(pToken), true, 0.75e18);

        // Give alice and bob some base tokens and vault shares
        baseToken.mint(alice, 1_000e18);
        baseToken.mint(bob, 1_000e18);

        // Alice and Bob deposit into vault to get shares
        vm.startPrank(alice);
        baseToken.approve(address(vault), type(uint256).max);
        vault.deposit(500e18, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        baseToken.approve(address(vault), type(uint256).max);
        vault.deposit(500e18, bob);
        vm.stopPrank();
    }

    function testConstructorValidatesVault() public {
        vm.expectRevert("PancakeBoosted: vault zero");
        new PancakeBoostedPErc20(
            address(0), comptroller, irm, INITIAL_EXCHANGE_RATE, "Test", "TST", 18, payable(address(this)), 0
        );
    }

    function testConstructorValidatesSeed() public {
        // Create a new vault without seed
        MockERC4626Vault unseededVault = new MockERC4626Vault(IERC20Metadata(address(baseToken)));

        vm.expectRevert("PancakeBoosted: vault seed missing");
        new PancakeBoostedPErc20(
            address(unseededVault),
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Test",
            "TST",
            18,
            payable(address(this)),
            MIN_SEED // requires seed but vault has none
        );
    }

    function testMintWithVaultShares() public {
        uint256 sharesToSupply = 100e18;

        vm.startPrank(alice);
        vault.approve(address(pToken), sharesToSupply);
        uint256 err = pToken.mint(sharesToSupply);
        vm.stopPrank();

        assertEq(err, 0, "mint should succeed");
        assertEq(pToken.balanceOf(alice), sharesToSupply, "pToken balance");
        assertEq(vault.balanceOf(address(pToken)), sharesToSupply, "vault shares held by pToken");
    }

    function testRedeemReturnsVaultShares() public {
        uint256 sharesToSupply = 100e18;

        vm.startPrank(alice);
        vault.approve(address(pToken), sharesToSupply);
        pToken.mint(sharesToSupply);

        uint256 vaultBalanceBefore = vault.balanceOf(alice);
        pToken.redeem(50e18);
        uint256 vaultBalanceAfter = vault.balanceOf(alice);
        vm.stopPrank();

        assertEq(vaultBalanceAfter - vaultBalanceBefore, 50e18, "vault shares returned");
        assertEq(pToken.balanceOf(alice), 50e18, "remaining pTokens");
    }

    function testBorrowVaultShares() public {
        // Alice supplies
        vm.startPrank(alice);
        vault.approve(address(pToken), 200e18);
        pToken.mint(200e18);
        vm.stopPrank();

        // Bob borrows (needs collateral in real scenario, but mock comptroller allows it)
        vm.startPrank(bob);
        uint256 vaultBalanceBefore = vault.balanceOf(bob);
        pToken.borrow(50e18);
        uint256 vaultBalanceAfter = vault.balanceOf(bob);
        vm.stopPrank();

        assertEq(vaultBalanceAfter - vaultBalanceBefore, 50e18, "borrowed vault shares");
    }

    function testRepayBorrow() public {
        // Alice supplies
        vm.startPrank(alice);
        vault.approve(address(pToken), 200e18);
        pToken.mint(200e18);
        vm.stopPrank();

        // Bob borrows
        vm.startPrank(bob);
        pToken.borrow(50e18);

        // Bob repays
        vault.approve(address(pToken), 50e18);
        pToken.repayBorrow(50e18);
        vm.stopPrank();

        assertEq(pToken.borrowBalanceCurrent(bob), 0, "borrow repaid");
    }

    function testVaultViewHelpers() public {
        vm.startPrank(alice);
        vault.approve(address(pToken), 100e18);
        pToken.mint(100e18);
        vm.stopPrank();

        // Test view helpers
        assertEq(pToken.vaultSharesHeld(), 100e18, "shares held");
        assertGt(pToken.vaultTotalAssets(), 0, "total assets");
        assertGt(pToken.vaultTotalSupply(), 0, "total supply");

        // Test conversion helpers
        uint256 assets = pToken.convertVaultSharesToAssets(100e18);
        assertEq(assets, 100e18, "1:1 conversion in mock vault");

        uint256 shares = pToken.convertAssetsToVaultShares(100e18);
        assertEq(shares, 100e18, "1:1 conversion in mock vault");
    }

    function testMultipleUsersSupplyAndRedeem() public {
        // Alice supplies
        vm.startPrank(alice);
        vault.approve(address(pToken), 100e18);
        pToken.mint(100e18);
        vm.stopPrank();

        // Bob supplies
        vm.startPrank(bob);
        vault.approve(address(pToken), 150e18);
        pToken.mint(150e18);
        vm.stopPrank();

        assertEq(pToken.totalSupply(), 250e18, "total pToken supply");
        assertEq(vault.balanceOf(address(pToken)), 250e18, "total vault shares held");

        // Both redeem partially
        vm.prank(alice);
        pToken.redeem(50e18);

        vm.prank(bob);
        pToken.redeem(75e18);

        assertEq(pToken.totalSupply(), 125e18, "remaining pToken supply");
        assertEq(vault.balanceOf(address(pToken)), 125e18, "remaining vault shares");
    }
}
