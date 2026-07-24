// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TokenErrorReporter} from "../contracts/ErrorReporter.sol";
import {BoostedPErc20} from "../contracts/boosted/BoostedPErc20.sol";
import {BoostedPErc20Immutable} from "../contracts/boosted/BoostedPErc20Immutable.sol";
import {IBoostedYieldAdapter} from "../contracts/interfaces/IBoostedYieldAdapter.sol";
import {MockErc20} from "./MockErc20.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {MockInstantYieldAdapter} from "./MockInstantYieldAdapter.sol";
import {FailingYieldAdapter} from "./FailingYieldAdapter.sol";

contract MockNoReturnErc20 {
    string public constant name = "No Return Token";
    string public constant symbol = "NRT";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address recipient, uint256 amount) external {
        _transfer(msg.sender, recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount) external {
        uint256 currentAllowance = allowance[sender][msg.sender];
        require(currentAllowance >= amount, "ALLOWANCE");
        allowance[sender][msg.sender] = currentAllowance - amount;
        _transfer(sender, recipient, amount);
    }

    function mint(address recipient, uint256 amount) external {
        totalSupply += amount;
        balanceOf[recipient] += amount;
    }

    function _transfer(address sender, address recipient, uint256 amount) internal {
        require(recipient != address(0), "RECIPIENT");
        require(balanceOf[sender] >= amount, "BALANCE");
        balanceOf[sender] -= amount;
        balanceOf[recipient] += amount;
    }
}

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
        assertEq(underlying.allowance(address(boosted), address(adapter)), 0, "adapter allowance");
    }

    function testExactAdapterAllowanceSupportsNoReturnToken() public {
        MockNoReturnErc20 noReturnToken = new MockNoReturnErc20();
        BoostedPErc20 noReturnMarket = BoostedPErc20(
            address(
                new BoostedPErc20Immutable(
                    address(noReturnToken),
                    comptroller,
                    interestModel,
                    INITIAL_EXCHANGE_RATE,
                    "Boosted No Return",
                    "bpNRT",
                    18,
                    payable(admin),
                    IBoostedYieldAdapter(address(0)),
                    LIQUIDITY_BUFFER
                )
            )
        );
        MockInstantYieldAdapter noReturnAdapter =
            new MockInstantYieldAdapter(address(noReturnToken), address(noReturnMarket));
        noReturnMarket.setBoostAdapter(noReturnAdapter);

        noReturnToken.mint(alice, 1_000e18);
        vm.startPrank(alice);
        noReturnToken.approve(address(noReturnMarket), 1_000e18);
        uint256 result = noReturnMarket.mint(1_000e18);
        vm.stopPrank();

        assertEq(result, 0);
        assertEq(noReturnToken.balanceOf(address(noReturnMarket)), 200e18);
        assertEq(noReturnAdapter.totalUnderlying(), 800e18);
        assertEq(noReturnToken.allowance(address(noReturnMarket), address(noReturnAdapter)), 0);
    }

    function testAdapterOnboardingRequiresPTokenOwnership() public {
        MockInstantYieldAdapter wrongOwner = new MockInstantYieldAdapter(address(underlying), address(this));

        vm.expectRevert(bytes("BoostedPErc20: adapter owner mismatch"));
        boosted.setBoostAdapter(wrongOwner);

        assertEq(address(boosted.boostAdapter()), address(adapter));
    }

    function testImmutableConstructorEmitsAdminHandoff() public {
        address designatedAdmin = address(0xBEEF);
        vm.recordLogs();
        BoostedPErc20Immutable market = new BoostedPErc20Immutable(
            address(underlying),
            comptroller,
            interestModel,
            INITIAL_EXCHANGE_RATE,
            "Boosted Event Test",
            "bpEVENT",
            18,
            payable(designatedAdmin),
            IBoostedYieldAdapter(address(0)),
            LIQUIDITY_BUFFER
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 eventSignature = keccak256("NewAdmin(address,address)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(market) && logs[i].topics[0] == eventSignature) {
                (address oldAdmin, address newAdmin) = abi.decode(logs[i].data, (address, address));
                found = oldAdmin == address(this) && newAdmin == designatedAdmin;
                break;
            }
        }
        assertTrue(found, "admin handoff event");
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

    function testAdapterTotalUnderlyingFailureBlocksCheapMint() public {
        failingAdapter = new FailingYieldAdapter(address(underlying), address(boosted));
        boosted.setBoostAdapter(failingAdapter);
        uint256 mintAmount = 1_000e18;
        underlying.mint(alice, mintAmount);
        vm.startPrank(alice);
        underlying.approve(address(boosted), mintAmount);
        boosted.mint(mintAmount / 2);
        vm.stopPrank();

        uint256 supplyBefore = boosted.totalSupply();
        uint256 balanceBefore = underlying.balanceOf(alice);
        vm.prank(address(boosted));
        failingAdapter.setFailFlags(true, false, false, false);

        vm.prank(alice);
        vm.expectRevert(bytes("adapter: totalUnderlying fail"));
        boosted.mint(mintAmount / 2);

        assertEq(boosted.totalSupply(), supplyBefore, "supply unchanged");
        assertEq(underlying.balanceOf(alice), balanceBefore, "underlying unchanged");
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
        assertEq(underlying.allowance(address(boosted), address(failingAdapter)), 0, "allowance revoked");
    }

    function testPauseSurvivesAdapterFailureAndPricesIdleExitConservatively() public {
        failingAdapter = new FailingYieldAdapter(address(underlying), address(boosted));
        boosted.setBoostAdapter(failingAdapter);

        uint256 mintAmount = 1_000e18;
        underlying.mint(alice, mintAmount);

        vm.startPrank(alice);
        underlying.approve(address(boosted), mintAmount);
        boosted.mint(mintAmount);
        vm.stopPrank();

        vm.prank(address(boosted));
        failingAdapter.setFailFlags(true, false, true, true);
        boosted.setBoostPaused(true);

        assertTrue(boosted.boostPaused(), "boost paused");
        assertEq(boosted.totalManagedAssets(), 200e18, "unproven adapter assets excluded");
        assertEq(boosted.exchangeRateStored(), 4e15, "idle assets set conservative rate");
        assertEq(underlying.allowance(address(boosted), address(failingAdapter)), 0, "allowance revoked");
        uint256 pTokenBalanceBeforeIdleExit = boosted.balanceOf(alice);
        vm.prank(alice);
        boosted.redeemUnderlying(100e18);
        assertEq(underlying.balanceOf(alice), 100e18, "idle exit succeeds");
        assertEq(
            pTokenBalanceBeforeIdleExit - boosted.balanceOf(alice), 25_000e18, "idle exit bears unresolved adapter risk"
        );

        uint256 pTokenBalanceBefore = boosted.balanceOf(alice);
        vm.prank(alice);
        vm.expectRevert(TokenErrorReporter.RedeemTransferOutNotPossible.selector);
        boosted.redeemUnderlying(200e18);
        assertEq(boosted.balanceOf(alice), pTokenBalanceBefore, "adapter-backed exit has no drift");
    }

    function testEmergencyWithdrawalFailureStillPausesAndRevokes() public {
        failingAdapter = new FailingYieldAdapter(address(underlying), address(boosted));
        boosted.setBoostAdapter(failingAdapter);

        underlying.mint(alice, 1_000e18);
        vm.startPrank(alice);
        underlying.approve(address(boosted), 1_000e18);
        boosted.mint(1_000e18);
        vm.stopPrank();
        vm.prank(address(boosted));
        failingAdapter.setFailFlags(false, false, false, true);

        boosted.emergencyWithdrawAdapter(address(this));

        assertTrue(boosted.boostPaused(), "boost paused");
        assertEq(underlying.allowance(address(boosted), address(failingAdapter)), 0, "allowance revoked");
    }

    function testSpoofedAdapterIncreaseCannotInflateMarketAssets() public {
        underlying.mint(alice, 1_000e18);
        vm.startPrank(alice);
        underlying.approve(address(boosted), 1_000e18);
        boosted.mint(1_000e18);
        vm.stopPrank();

        uint256 managedBefore = boosted.totalManagedAssets();
        adapter.setReportBonus(10_000e18);

        assertEq(boosted.totalManagedAssets(), managedBefore, "report capped by accounting");
        assertEq(boosted.exchangeRateStored(), INITIAL_EXCHANGE_RATE, "rate not inflated");
    }

    function testAdapterLossFailsClosedUntilAdminReconciles() public {
        underlying.mint(alice, 1_000e18);
        vm.startPrank(alice);
        underlying.approve(address(boosted), 1_000e18);
        boosted.mint(1_000e18);
        vm.stopPrank();
        underlying.burn(address(adapter), 100e18);

        vm.expectRevert(bytes("BoostedPErc20: adapter loss requires sync"));
        boosted.totalManagedAssets();

        boosted.syncAdapterAssets(700e18);
        assertEq(boosted.totalManagedAssets(), 900e18, "loss reconciled");
    }

    function testForcedDustCannotBlockReviewedLossSync() public {
        underlying.mint(alice, 1_000e18);
        vm.startPrank(alice);
        underlying.approve(address(boosted), 1_000e18);
        boosted.mint(1_000e18);
        vm.stopPrank();
        underlying.burn(address(adapter), 100e18);
        underlying.mint(address(adapter), 1);

        vm.expectRevert(bytes("BoostedPErc20: adapter balance below expected"));
        boosted.syncAdapterAssets(700e18 + 2);

        boosted.syncAdapterAssets(700e18);
        assertEq(boosted.accountedAdapterAssets(), 700e18, "only reviewed assets credited");
        assertEq(boosted.totalManagedAssets(), 900e18, "forced dust remains uncredited");
        assertEq(adapter.totalUnderlying(), 700e18 + 1, "dust remains recoverable");
    }

    function testAdminSyncExplicitlyCreditsRealizedYield() public {
        underlying.mint(alice, 1_000e18);
        vm.startPrank(alice);
        underlying.approve(address(boosted), 1_000e18);
        boosted.mint(1_000e18);
        vm.stopPrank();
        underlying.mint(address(adapter), 100e18);

        assertEq(boosted.totalManagedAssets(), 1_000e18, "yield capped before sync");
        boosted.syncAdapterAssets(900e18);
        assertEq(boosted.totalManagedAssets(), 1_100e18, "reviewed yield credited");
    }
}
