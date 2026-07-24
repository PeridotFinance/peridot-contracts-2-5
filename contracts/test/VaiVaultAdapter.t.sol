// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BoostedPErc20} from "../contracts/boosted/BoostedPErc20.sol";
import {BoostedPErc20Immutable} from "../contracts/boosted/BoostedPErc20Immutable.sol";
import {VaiVaultAdapter} from "../contracts/boosted/adapters/VaiVaultAdapter.sol";
import {IBoostedYieldAdapter} from "../contracts/interfaces/IBoostedYieldAdapter.sol";
import {MockErc20} from "./MockErc20.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {MockVaiVault} from "./mocks/MockVaiVault.sol";

contract VaiVaultAdapterTest is Test {
    uint256 constant INITIAL_EXCHANGE_RATE = 2e16; // 0.02
    uint256 constant LIQUIDITY_BUFFER = 2e17; // 20%

    address internal constant ADMIN = address(0xABC);
    address internal constant ALICE = address(0xA11CE);

    MockErc20 internal underlying;
    MockPeridottroller internal comptroller;
    MockInterestRateModel internal interestModel;
    MockVaiVault internal vault;
    BoostedPErc20 internal boosted;
    VaiVaultAdapter internal adapter;

    function setUp() public {
        underlying = new MockErc20("VAI", "VAI", 18);
        comptroller = new MockPeridottroller();
        interestModel = new MockInterestRateModel();
        vault = new MockVaiVault(address(underlying));

        vm.startPrank(ADMIN);
        boosted = BoostedPErc20(
            address(
                new BoostedPErc20Immutable(
                    address(underlying),
                    comptroller,
                    interestModel,
                    INITIAL_EXCHANGE_RATE,
                    "Boosted VAI",
                    "bpVAI",
                    18,
                    payable(ADMIN),
                    IBoostedYieldAdapter(address(0)),
                    LIQUIDITY_BUFFER
                )
            )
        );
        vm.stopPrank();

        adapter = new VaiVaultAdapter(address(boosted), address(underlying), address(vault));

        vm.prank(ADMIN);
        boosted.setBoostAdapter(adapter);
    }

    function testMintRoutesFundsIntoVault() public {
        uint256 mintAmount = 1_000e18;
        underlying.mint(ALICE, mintAmount);

        vm.startPrank(ALICE);
        underlying.approve(address(boosted), mintAmount);
        boosted.mint(mintAmount);
        vm.stopPrank();

        // 20% buffer should remain on the pToken, rest is staked
        (uint256 staked,) = vault.userInfo(address(adapter));
        uint256 onHand = underlying.balanceOf(address(boosted));

        uint256 expectedBuffer = (mintAmount * LIQUIDITY_BUFFER) / 1e18;
        assertApproxEqAbs(onHand, expectedBuffer, 1, "buffer mismatch");
        assertApproxEqAbs(staked, mintAmount - expectedBuffer, 1, "staked mismatch");
    }

    function testRedeemPullsStakeBack() public {
        uint256 mintAmount = 1_000e18;
        underlying.mint(ALICE, mintAmount);
        vm.startPrank(ALICE);
        underlying.approve(address(boosted), mintAmount);
        boosted.mint(mintAmount);
        vm.stopPrank();

        uint256 redeemAmount = 400e18;
        vm.startPrank(ALICE);
        boosted.redeemUnderlying(redeemAmount);
        vm.stopPrank();

        (uint256 staked,) = vault.userInfo(address(adapter));
        uint256 onHand = underlying.balanceOf(address(boosted));

        uint256 remainingAssets = mintAmount - redeemAmount;
        uint256 expectedBuffer = (remainingAssets * LIQUIDITY_BUFFER) / 1e18;
        assertApproxEqAbs(onHand, expectedBuffer, 1, "buffer restored");
        assertApproxEqAbs(staked, remainingAssets - expectedBuffer, 1, "vault balance");

        assertEq(underlying.balanceOf(ALICE), redeemAmount, "alice redeemed underlying");
    }

    function testPauseDrainsVault() public {
        uint256 mintAmount = 500e18;
        underlying.mint(ALICE, mintAmount);
        vm.startPrank(ALICE);
        underlying.approve(address(boosted), mintAmount);
        boosted.mint(mintAmount);
        vm.stopPrank();

        vm.prank(ADMIN);
        boosted.setBoostPaused(true);

        (uint256 staked,) = vault.userInfo(address(adapter));
        assertEq(staked, 0, "vault should be empty after pause");
        assertEq(underlying.balanceOf(address(boosted)), mintAmount, "funds returned to market");
    }

    function testMintKeepsFundsLocalWhileVaultPaused() public {
        vault.setVaultPaused(true);

        uint256 mintAmount = 100e18;
        underlying.mint(ALICE, mintAmount);

        vm.startPrank(ALICE);
        underlying.approve(address(boosted), mintAmount);
        uint256 result = boosted.mint(mintAmount);
        vm.stopPrank();

        (uint256 staked,) = vault.userInfo(address(adapter));
        assertEq(result, 0, "mint should succeed");
        assertEq(staked, 0, "paused vault should remain empty");
        assertEq(underlying.balanceOf(address(boosted)), mintAmount, "funds should remain on the market");
        assertEq(underlying.allowance(address(boosted), address(adapter)), 0, "adapter allowance should remain zero");
    }
}
