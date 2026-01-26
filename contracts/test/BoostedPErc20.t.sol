// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {BoostedPErc20} from "../contracts/boosted/BoostedPErc20.sol";
import {BoostedPErc20Immutable} from "../contracts/boosted/BoostedPErc20Immutable.sol";
import {IBoostedYieldAdapter} from "../contracts/interfaces/IBoostedYieldAdapter.sol";
import {MockErc20} from "./MockErc20.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {MockInstantYieldAdapter} from "./MockInstantYieldAdapter.sol";
import {FailingYieldAdapter} from "./FailingYieldAdapter.sol";

contract BoostedPErc20Test is Test {
    uint256 constant INITIAL_EXCHANGE_RATE = 2e16; // 0.02 scaled by 1e18
    uint256 constant LIQUIDITY_BUFFER = 2e17; // 20%

    address internal admin = address(this);
    address internal alice = address(0xA11CE);

    MockErc20 internal underlying;
    MockPeridottroller internal comptroller;
    MockInterestRateModel internal interestModel;
    BoostedPErc20 internal boosted;
    MockInstantYieldAdapter internal adapter;
    FailingYieldAdapter internal failingAdapter;

    function setUp() public {
        underlying = new MockErc20("Mock Token", "MOCK", 18);
        comptroller = new MockPeridottroller();
        interestModel = new MockInterestRateModel();

        boosted = BoostedPErc20(
            address(
                new BoostedPErc20Immutable(
                    address(underlying),
                    comptroller,
                    interestModel,
                    INITIAL_EXCHANGE_RATE,
                    "Boosted Mock",
                    "bpMOCK",
                    18,
                    payable(admin),
                    IBoostedYieldAdapter(address(0)),
                    LIQUIDITY_BUFFER
                )
            )
        );

        adapter = new MockInstantYieldAdapter(address(underlying), address(boosted));
        boosted.setBoostAdapter(adapter);
    }

    function testMintDeploysExcessToAdapter() public {
        uint256 mintAmount = 1_000e18;

        underlying.mint(alice, mintAmount);

        vm.startPrank(alice);
        underlying.approve(address(boosted), mintAmount);
        uint256 res = boosted.mint(mintAmount);
        vm.stopPrank();

        assertEq(res, 0, "mint result");

        uint256 adapterBal = adapter.totalUnderlying();
        uint256 onHand = underlying.balanceOf(address(boosted));
        uint256 total = adapterBal + onHand;
        assertEq(total, mintAmount, "total managed assets");

        uint256 expectedBuffer = (mintAmount * LIQUIDITY_BUFFER) / 1e18;
        assertApproxEqAbs(onHand, expectedBuffer, 1, "buffer on hand");
        assertApproxEqAbs(boosted.totalManagedAssets(), mintAmount, 1, "total managed assets view");
    }

    function testRedeemPullsFromAdapterToSatisfyLiquidity() public {
        uint256 mintAmount = 1_000e18;
        uint256 redeemAmount = 400e18;

        underlying.mint(alice, mintAmount);
        vm.startPrank(alice);
        underlying.approve(address(boosted), mintAmount);
        boosted.mint(mintAmount);
        vm.stopPrank();

        uint256 adapterBalBefore = adapter.totalUnderlying();
        assertGt(adapterBalBefore, redeemAmount, "adapter funded");

        vm.startPrank(alice);
        uint256 redeemRes = boosted.redeemUnderlying(redeemAmount);
        vm.stopPrank();
        assertEq(redeemRes, 0, "redeem result");

        uint256 aliceBalance = underlying.balanceOf(alice);
        assertEq(aliceBalance, redeemAmount, "alice receives redeemed underlying");

        uint256 adapterBalAfter = adapter.totalUnderlying();
        assertLt(adapterBalAfter, adapterBalBefore, "adapter drained");

        uint256 onHand = underlying.balanceOf(address(boosted));
        uint256 total = adapterBalAfter + onHand;
        assertEq(total, mintAmount - redeemAmount, "assets accounted");

        uint256 expectedBuffer = (total * LIQUIDITY_BUFFER) / 1e18;
        assertApproxEqAbs(onHand, expectedBuffer, 1, "buffer restored after redeem");
    }

    function testPauseWithdrawsAllBackToToken() public {
        uint256 mintAmount = 500e18;

        underlying.mint(alice, mintAmount);
        vm.startPrank(alice);
        underlying.approve(address(boosted), mintAmount);
        boosted.mint(mintAmount);
        vm.stopPrank();

        uint256 adapterBalBefore = adapter.totalUnderlying();
        assertGt(adapterBalBefore, 0, "adapter populated");

        boosted.setBoostPaused(true);
        assertEq(adapter.totalUnderlying(), 0, "adapter empty after pause");
        uint256 onHand = underlying.balanceOf(address(boosted));
        assertEq(onHand, mintAmount, "all funds returned");
    }

    function testAdapterTotalUnderlyingFailureKeepsFundsLocal() public {
        failingAdapter = new FailingYieldAdapter(address(underlying), address(boosted));
        boosted.setBoostAdapter(failingAdapter);
        vm.prank(address(boosted));
        failingAdapter.setFailFlags(true, false, false, false);

        uint256 mintAmount = 1_000e18;
        underlying.mint(alice, mintAmount);

        vm.startPrank(alice);
        underlying.approve(address(boosted), mintAmount);
        uint256 res = boosted.mint(mintAmount);
        vm.stopPrank();

        assertEq(res, 0, "mint result");
        assertEq(underlying.balanceOf(address(boosted)), mintAmount, "funds stay local");
    }

    function testAdapterDepositFailureDoesNotRevertMint() public {
        failingAdapter = new FailingYieldAdapter(address(underlying), address(boosted));
        boosted.setBoostAdapter(failingAdapter);
        vm.prank(address(boosted));
        failingAdapter.setFailFlags(false, true, false, false);

        uint256 mintAmount = 1_000e18;
        underlying.mint(alice, mintAmount);

        vm.startPrank(alice);
        underlying.approve(address(boosted), mintAmount);
        uint256 res = boosted.mint(mintAmount);
        vm.stopPrank();

        assertEq(res, 0, "mint result");
        assertEq(underlying.balanceOf(address(boosted)), mintAmount, "deposit failure keeps cash local");
    }

    function testAdapterWithdrawFailureDoesNotRevertRebalance() public {
        failingAdapter = new FailingYieldAdapter(address(underlying), address(boosted));
        boosted.setBoostAdapter(failingAdapter);

        uint256 mintAmount = 1_000e18;
        underlying.mint(alice, mintAmount);

        vm.startPrank(alice);
        underlying.approve(address(boosted), mintAmount);
        boosted.mint(mintAmount);
        vm.stopPrank();

        vm.prank(address(boosted));
        failingAdapter.setFailFlags(false, false, true, false);
        boosted.setLiquidityBufferMantissa(9e17);
        assertTrue(true, "rebalance handled withdraw failure");
    }
}
