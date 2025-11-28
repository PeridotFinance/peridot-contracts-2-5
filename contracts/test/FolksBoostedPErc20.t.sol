// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/boosted/FolksBoostedPErc20.sol";
import "./MockErc20.sol";
import "./MockInterestRateModel.sol";
import "./MockPeridottroller.sol";
import "./mocks/MockERC4626Vault.sol";

contract FolksBoostedPErc20Test is Test {
    MockErc20 internal underlying;
    MockERC4626Vault internal vault;
    MockPeridottroller internal comptroller;
    MockInterestRateModel internal irm;
    FolksBoostedPErc20 internal pToken;

    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);

    uint256 internal constant INITIAL_EXCHANGE_RATE = 1e18;
    uint256 internal constant BUFFER = 1e17; // 10%

    function setUp() public {
        underlying = new MockErc20("Mock USD", "mUSD", 18);
        vault = new MockERC4626Vault(IERC20Metadata(address(underlying)));
        comptroller = new MockPeridottroller();
        irm = new MockInterestRateModel();

        pToken = new FolksBoostedPErc20(
            address(underlying),
            comptroller,
            irm,
            INITIAL_EXCHANGE_RATE,
            "Peridot Folks mUSD",
            "pfmUSD",
            18,
            payable(address(this)),
            IERC4626(address(vault)),
            BUFFER
        );

        comptroller.setMarket(address(pToken), true, 0.75e18);

        underlying.mint(alice, 1_000e18);
        underlying.mint(bob, 1_000e18);
    }

    function testMintDepositsIntoVaultRespectingBuffer() public {
        vm.startPrank(alice);
        underlying.approve(address(pToken), 100e18);
        pToken.mint(100e18);
        vm.stopPrank();

        uint256 vaultAssets = vault.totalAssets();
        uint256 localCash = underlying.balanceOf(address(pToken));

        // 10% buffer local, 90% in vault
        assertApproxEqAbs(vaultAssets, 90e18, 1);
        assertApproxEqAbs(localCash, 10e18, 1);
        assertEq(pToken.balanceOf(alice), 100e18);
    }

    function testBorrowPullsFromVaultAndMaintainsBuffer() public {
        vm.startPrank(alice);
        underlying.approve(address(pToken), 100e18);
        pToken.mint(100e18);
        vm.stopPrank();

        vm.startPrank(bob);
        underlying.approve(address(pToken), 50e18);
        pToken.borrow(50e18);
        vm.stopPrank();

        uint256 vaultAssets = vault.totalAssets();
        uint256 localCash = underlying.balanceOf(address(pToken));

        // After borrowing 50, total managed ~50; buffer ~5
        assertApproxEqAbs(vaultAssets + localCash, 50e18, 1);
        assertApproxEqAbs(localCash, 5e18, 1);
        assertEq(underlying.balanceOf(bob), 1_050e18);
    }

    function testRedeemWithdrawsFromVault() public {
        vm.startPrank(alice);
        underlying.approve(address(pToken), 80e18);
        pToken.mint(80e18);
        pToken.redeem(40e18);
        vm.stopPrank();

        uint256 vaultAssets = vault.totalAssets();
        uint256 localCash = underlying.balanceOf(address(pToken));

        // Remaining managed ~40, buffer ~4
        assertApproxEqAbs(vaultAssets + localCash, 40e18, 1);
        assertApproxEqAbs(localCash, 4e18, 1);
    }
}
