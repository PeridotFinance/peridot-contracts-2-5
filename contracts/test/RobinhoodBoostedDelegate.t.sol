// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {RobinhoodBoostedDelegate} from "../contracts/boosted/RobinhoodBoostedDelegate.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {TokenErrorReporter} from "../contracts/ErrorReporter.sol";
import {MockErc20} from "./MockErc20.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {MockRobinhoodBoostedVault} from "./mocks/MockRobinhoodBoostedVault.sol";

contract RobinhoodBoostedDelegateTest is Test {
    bytes32 internal constant PAIR_ID = keccak256("NVDA/USDG");
    uint256 internal constant INITIAL_EXCHANGE_RATE = 2e14;
    uint256 internal constant BUFFER = 2e17;

    address internal user = makeAddr("user");
    address internal operator = makeAddr("operator");

    MockErc20 internal usdg;
    MockPeridottroller internal comptroller;
    MockInterestRateModel internal interestModel;
    MockRobinhoodBoostedVault internal vault;
    PErc20Delegator internal delegator;
    RobinhoodBoostedDelegate internal boosted;

    function setUp() external {
        usdg = new MockErc20("Global Dollar", "USDG", 6);
        comptroller = new MockPeridottroller();
        interestModel = new MockInterestRateModel();
        vault = new MockRobinhoodBoostedVault(usdg, PAIR_ID);

        RobinhoodBoostedDelegate implementation = new RobinhoodBoostedDelegate();
        delegator = new PErc20Delegator(
            address(usdg),
            comptroller,
            interestModel,
            INITIAL_EXCHANGE_RATE,
            "Peridot Robinhood Boosted USDG",
            "pUSDG",
            8,
            payable(address(this)),
            address(implementation),
            bytes("")
        );
        boosted = RobinhoodBoostedDelegate(address(delegator));
        comptroller.setMarket(address(delegator), true, 0.75e18);

        vault.setSideAccount(address(delegator));
        _configureAndUnpause(vault);

        usdg.mint(user, 10_000e6);
        vm.prank(user);
        usdg.approve(address(delegator), type(uint256).max);
    }

    function testPTokenIsDirectVaultSideAccountAndMintDeploysBufferExcess() external {
        _mint(1_000e6);

        assertEq(vault.lastDepositor(), address(delegator));
        assertEq(vault.accounted(), 800e6);
        assertEq(usdg.balanceOf(address(delegator)), 200e6);
        assertEq(usdg.allowance(address(delegator), address(vault)), 0);
        assertEq(boosted.totalManagedAssets(), 1_000e6);
    }

    function testCashUsesLiquidButExchangeRateUsesFullAccountedClaim() external {
        _mint(1_000e6);
        vault.investAll();

        assertEq(PErc20(address(delegator)).getCash(), 200e6);
        assertEq(boosted.vaultAccountedAssets(), 800e6);
        assertEq(boosted.vaultLiquidAssets(), 0);
        assertEq(PErc20(address(delegator)).exchangeRateStored(), INITIAL_EXCHANGE_RATE);
    }

    function testCashExcludesVaultIdleThatIsUnreachableBehindOpenLiquidity() external {
        _mint(1_000e6);

        // 800 deployed, 200 local buffer. The vault still holds idle USDG in custody, but
        // with LP liquidity open and the oracle guard down that idle cannot be released.
        vault.setLiquidityOpen(true);
        vault.setOracleUnhealthy(true);

        uint256 custody = boosted.vaultLiquidAssets();
        assertGt(custody, 0, "vault holds idle in custody");
        assertEq(boosted.vaultWithdrawableAssets(), 0, "none of it is reachable");
        // Cash must not count custody the vault will refuse to release, or borrows and
        // redeems pass the controller check and then revert inside doTransferOut.
        assertEq(PErc20(address(delegator)).getCash(), 200e6);

        // Once the guard is healthy again the same idle becomes real cash.
        vault.setOracleUnhealthy(false);
        assertEq(boosted.vaultWithdrawableAssets(), custody);
        assertEq(PErc20(address(delegator)).getCash(), 200e6 + custody);
    }

    function testRedeemAppliesVaultLossBeforeBurnAndTransfer() external {
        _mint(1_000e6);
        vault.investAll();
        vault.setPendingLoss(200e6);

        uint256 redeemTokens = PErc20(address(delegator)).balanceOf(user) / 2;
        vm.prank(user);
        PErc20(address(delegator)).redeem(redeemTokens);

        assertEq(usdg.balanceOf(user), 9_400e6);
        assertEq(boosted.cumulativeVaultLoss(), 200e6);
        assertEq(PErc20(address(delegator)).balanceOf(user), redeemTokens);
        assertEq(boosted.totalManagedAssets(), 400e6);
    }

    function testRedeemUnderlyingBurnsMoreTokensAtPostLossRate() external {
        _mint(1_000e6);
        vault.investAll();
        vault.setPendingLoss(200e6);

        uint256 tokensBefore = PErc20(address(delegator)).balanceOf(user);
        vm.prank(user);
        PErc20(address(delegator)).redeemUnderlying(400e6);

        assertEq(usdg.balanceOf(user), 9_400e6);
        assertEq(PErc20(address(delegator)).balanceOf(user), tokensBefore / 2);
        assertEq(boosted.cumulativeVaultLoss(), 200e6);
    }

    function testBorrowPullsIdleVaultAssetsAndRecognizesLossAtomically() external {
        _mint(1_000e6);
        vault.setPendingLoss(200e6);

        vm.prank(user);
        PErc20(address(delegator)).borrow(400e6);

        assertEq(usdg.balanceOf(user), 9_400e6);
        assertEq(PErc20(address(delegator)).borrowBalanceStored(user), 400e6);
        assertEq(boosted.cumulativeVaultLoss(), 200e6);
        assertEq(vault.accounted(), 400e6);
        assertEq(PErc20(address(delegator)).exchangeRateStored(), 1.6e14);
    }

    function testIdleRedeemSurvivesVaultIncident() external {
        _mint(1_000e6);
        vault.investAll();
        vault.setWithdrawalReverts(true);

        uint256 tokensForOneHundred = (100e6 * 1e18) / INITIAL_EXCHANGE_RATE;
        vm.prank(user);
        PErc20(address(delegator)).redeem(tokensForOneHundred);

        assertEq(usdg.balanceOf(user), 9_100e6);
        assertEq(PErc20(address(delegator)).balanceOf(user), 4_500e9);
    }

    function testLiquidReadFailureFallsBackToLocalCash() external {
        _mint(1_000e6);
        vault.investAll();
        vault.setReadReverts(false, true);

        assertEq(PErc20(address(delegator)).getCash(), 200e6);
        assertEq(boosted.totalManagedAssets(), 1_000e6);
        assertEq(PErc20(address(delegator)).exchangeRateStored(), INITIAL_EXCHANGE_RATE);

        uint256 tokensForOneHundred = (100e6 * 1e18) / INITIAL_EXCHANGE_RATE;
        vm.prank(user);
        PErc20(address(delegator)).redeem(tokensForOneHundred);

        assertEq(usdg.balanceOf(user), 9_100e6);
        assertEq(usdg.balanceOf(address(delegator)), 100e6);
        assertEq(vault.accounted(), 800e6);
    }

    function testAccountedReadFailureIsConservativeAndBlocksCheapMint() external {
        _mint(1_000e6);
        vault.investAll();
        vault.setReadReverts(true, true);

        assertEq(PErc20(address(delegator)).getCash(), 200e6);
        assertEq(boosted.totalManagedAssets(), 200e6);
        assertEq(PErc20(address(delegator)).exchangeRateStored(), 4e13);

        uint256 supplyBefore = PErc20(address(delegator)).totalSupply();
        uint256 balanceBefore = usdg.balanceOf(user);
        vm.prank(user);
        vm.expectRevert(bytes("mock: accounted read blocked"));
        PErc20(address(delegator)).mint(10e6);
        assertEq(PErc20(address(delegator)).totalSupply(), supplyBefore);
        assertEq(usdg.balanceOf(user), balanceBefore);

        vm.prank(user);
        PErc20(address(delegator)).redeemUnderlying(100e6);

        assertEq(usdg.balanceOf(user), balanceBefore + 100e6);
        assertEq(usdg.balanceOf(address(delegator)), 100e6);
        assertEq(vault.accounted(), 800e6);
    }

    function testLpBackedRedeemFailsClosedDuringVaultIncidentWithoutDrift() external {
        _mint(1_000e6);
        vault.investAll();
        vault.setWithdrawalReverts(true);
        uint256 tokensBefore = PErc20(address(delegator)).balanceOf(user);

        vm.prank(user);
        vm.expectRevert(TokenErrorReporter.RedeemTransferOutNotPossible.selector);
        PErc20(address(delegator)).redeem(tokensBefore / 2);

        assertEq(PErc20(address(delegator)).balanceOf(user), tokensBefore);
        assertEq(boosted.totalManagedAssets(), 1_000e6);
    }

    function testAutomaticPostOperationRebalanceDoesNotDiscoverExtraLoss() external {
        _mint(1_000e6);
        vault.investAll();

        uint256 tokensForOneHundred = (100e6 * 1e18) / INITIAL_EXCHANGE_RATE;
        vm.prank(user);
        PErc20(address(delegator)).redeem(tokensForOneHundred);

        assertEq(usdg.balanceOf(address(delegator)), 100e6);
        assertEq(vault.accounted(), 800e6);

        vault.setPendingLoss(200e6);
        _mint(10e6);

        assertEq(boosted.cumulativeVaultLoss(), 0);
        assertEq(vault.accounted(), 800e6);
        assertEq(usdg.balanceOf(address(delegator)), 110e6);
    }

    function testVaultConfigurationRequiresDelegatorAsSideAccount() external {
        MockRobinhoodBoostedVault wrongVault = new MockRobinhoodBoostedVault(usdg, PAIR_ID);
        wrongVault.setSideAccount(address(0xBAD));
        bytes32 actionId = boosted.queueSetVaultConfig(address(wrongVault), PAIR_ID, BUFFER, operator);
        vm.warp(boosted.queuedActions(actionId));

        vm.expectRevert(RobinhoodBoostedDelegate.PTokenNotSideAccount.selector);
        boosted._setVaultConfig(address(wrongVault), PAIR_ID, BUFFER, operator);
    }

    function testOnlyOperatorCanSyncVaultLoss() external {
        _mint(1_000e6);
        vault.setPendingLoss(100e6);

        vm.prank(user);
        vm.expectRevert(RobinhoodBoostedDelegate.OnlyVaultOperator.selector);
        boosted.syncVault(100e6);

        vm.prank(operator);
        (uint256 returned, uint256 loss) = boosted.syncVault(100e6);
        assertEq(returned, 100e6);
        assertEq(loss, 100e6);
        assertEq(boosted.cumulativeVaultLoss(), 100e6);
    }

    function _configureAndUnpause(MockRobinhoodBoostedVault targetVault) internal {
        bytes32 configAction = boosted.queueSetVaultConfig(address(targetVault), PAIR_ID, BUFFER, operator);
        vm.warp(boosted.queuedActions(configAction));
        boosted._setVaultConfig(address(targetVault), PAIR_ID, BUFFER, operator);

        bytes32 pauseAction = boosted.queueSetVaultPaused(false);
        vm.warp(boosted.queuedActions(pauseAction));
        boosted._setVaultPaused(false);
    }

    function _mint(uint256 amount) internal {
        vm.prank(user);
        PErc20(address(delegator)).mint(amount);
    }
}
