// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {
    CollateralPreservingLifecycleTest,
    CollateralLifecycleInterestModel
} from "./CollateralPreservingLifecycle.t.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PErc20} from "../contracts/PErc20.sol";

/// @dev Fresh-stack recovery using actual lending/account/vault/fee logic, mock assets/venues.
contract CollateralPreservingRecoveryTest is CollateralPreservingLifecycleTest {
    function _approveRecovery(uint256 id) internal returns (address asset) {
        (,,,, address debt,) = executor.positions(id);
        asset = PErc20(debt).underlying();
        IERC20(asset).approve(address(executor), type(uint256).max);
    }

    function _outage() internal {
        config.pauseOpens();
        vm.warp(block.timestamp + 31 days);
        uVault.setLimits(true, true);
        aVault.setLimits(true, true);
        lender.setPaused(true);
        // Fail if recovery ever reaches price, swap, redemption or supply accrual paths.
        vm.mockCallRevert(address(oracle), bytes(""), bytes("oracle unavailable"));
        vm.mockCallRevert(address(router), bytes(""), bytes("DEX unavailable"));
        address[4] memory markets = [address(pUVault), address(pAVault), address(pUsd), address(pAvax)];
        for (uint256 i; i < markets.length; ++i) {
            vm.mockCallRevert(markets[i], abi.encodeWithSignature("redeem(uint256)"), bytes("cash unavailable"));
            vm.mockCallRevert(markets[i], abi.encodeWithSignature("exchangeRateCurrent()"), bytes("NAV unavailable"));
        }
    }

    function _recoverAndCheck(uint256 id, uint256 cap) internal returns (uint256 paid) {
        (, address account, address collateral, address position, address debt, uint256 locked) = executor.positions(id);
        address asset = PErc20(debt).underlying();
        uint256 wallet = IERC20(asset).balanceOf(address(this));
        uint256 original = IERC20(collateral).balanceOf(account);
        uint256 trade = IERC20(position).balanceOf(account);
        uint256 tradeWallet = IERC20(position).balanceOf(address(this));
        uint256 debtShares = IERC20(debt).balanceOf(account);
        uint256 debtWallet = IERC20(debt).balanceOf(address(this));
        uint256 free = marginVault.freeBalance(address(this), collateral);
        uint256 rewards = fees.pendingRewards(address(this), collateral);
        uint256 supply = IERC20(collateral).totalSupply();
        uint256 tradeSupply = IERC20(position).totalSupply();
        uint256 treasury = IERC20(collateral).balanceOf(TREASURY);
        uint256 insurance = IERC20(collateral).balanceOf(INSURANCE);
        uint256 feeBalance = IERC20(collateral).balanceOf(address(fees));
        executor.emergencyExitToPTokens(id, cap);
        paid = wallet - IERC20(asset).balanceOf(address(this));
        assertLe(paid, cap);
        assertEq(PErc20(debt).borrowBalanceStored(account), 0);
        assertEq(IERC20(position).balanceOf(address(this)), tradeWallet + trade);
        assertEq(IERC20(debt).balanceOf(address(this)), debtWallet + debtShares);
        assertEq(marginVault.freeBalance(address(this), collateral), free + rewards + original);
        assertEq(marginVault.lockedBalance(address(this), collateral), 0);
        assertEq(IERC20(collateral).totalSupply(), supply);
        assertEq(IERC20(position).totalSupply(), tradeSupply);
        assertEq(IERC20(collateral).balanceOf(TREASURY), treasury);
        assertEq(IERC20(collateral).balanceOf(INSURANCE), insurance);
        assertEq(IERC20(collateral).balanceOf(address(fees)), feeBalance - rewards, "no recovery fee");
        (uint256 eligible,,) = fees.userRewards(collateral, address(this));
        assertEq(eligible, free + rewards + original);
        (,,, Types.Status status,) = engine.accounts(account);
        assertEq(uint256(status), uint256(Types.Status.CLOSED));
        (,,,,, uint256 remaining) = executor.positions(id);
        assertEq(remaining, 0);
        assertGt(locked, 0);
        assertEq(IERC20(collateral).balanceOf(account), 0);
        assertEq(IERC20(position).balanceOf(account), 0);
        assertEq(IERC20(debt).balanceOf(account), 0);
        assertEq(IERC20(asset).allowance(account, debt), 0);
        assertEq(IERC20(collateral).allowance(account, address(marginVault)), 0);
        _executorClean();
    }

    function testRecoveryBothCollateralsBothSidesTwoThroughFiveXDuringOutage() public {
        _enableStack();
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                for (uint16 leverage = 200; leverage <= 500; leverage += 100) {
                    uint256 checkpoint = vm.snapshotState();
                    uint256 id = _openLife(c == 1, side == 1, leverage);
                    _approveRecovery(id);
                    _outage();
                    assertGt(_recoverAndCheck(id, type(uint256).max), 0);
                    (,, address collateral,,,) = executor.positions(id);
                    uint256 free = marginVault.freeBalance(address(this), collateral);
                    uint256 wallet = IERC20(collateral).balanceOf(address(this));
                    marginVault.withdraw(collateral, free);
                    assertEq(IERC20(collateral).balanceOf(address(this)), wallet + free);
                    assertTrue(vm.revertToStateAndDelete(checkpoint));
                    vm.clearMockedCalls();
                }
            }
        }
    }

    function testRecoveryRequiresPauseAndOwnerAndCannotRepeat() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        _approveRecovery(id);
        vm.expectRevert(Risk.InvalidState.selector);
        executor.emergencyExitToPTokens(id, type(uint256).max);
        config.pauseOpens();
        vm.prank(address(0xBAD));
        vm.expectRevert(Executor.Unauthorized.selector);
        executor.emergencyExitToPTokens(id, type(uint256).max);
        vm.expectRevert(Executor.Unauthorized.selector);
        executor.emergencyExitToPTokens(999, type(uint256).max);
        _recoverAndCheck(id, type(uint256).max);
        vm.expectRevert(Risk.InvalidState.selector);
        executor.emergencyExitToPTokens(id, 0);
    }

    function testRecoveryAccruesInterestAndEnforcesWalletCapBothSides() public {
        _enableStack();
        CollateralLifecycleInterestModel model = new CollateralLifecycleInterestModel();
        model.setRate(1e12);
        assertEq(pUsd._setInterestRateModel(model), 0);
        assertEq(pAvax._setInterestRateModel(model), 0);
        for (uint256 side; side < 2; ++side) {
            uint256 checkpoint = vm.snapshotState();
            uint256 id = _openLife(false, side == 1, 500);
            (, address account,,, address debt,) = executor.positions(id);
            uint256 principal = PErc20(debt).borrowBalanceStored(account);
            _approveRecovery(id);
            _outage();
            vm.roll(block.number + 10_000);
            vm.expectRevert(Executor.InvalidOperation.selector);
            executor.emergencyExitToPTokens(id, principal);
            assertEq(PErc20(debt).borrowBalanceStored(account), principal, "failed accrual rolled back");
            assertGt(_recoverAndCheck(id, type(uint256).max), principal);
            assertEq(PErc20(debt).totalBorrows(), 0);
            assertEq(PErc20(debt).totalBorrowShares(), 0);
            assertTrue(vm.revertToStateAndDelete(checkpoint));
            vm.clearMockedCalls();
        }
    }

    function testRecoveryPreviouslyRepaidNeedsNoWalletApproval() public {
        _enableStack();
        uint256 id = _openLife(true, true, 500);
        (, address account,,, address debt,) = executor.positions(id);
        IERC20(PErc20(debt).underlying()).approve(debt, type(uint256).max);
        assertEq(PErc20(debt).repayBorrowBehalf(account, type(uint256).max), 0);
        _outage();
        assertEq(_recoverAndCheck(id, 0), 0);
    }

    function testRecoveryInsufficientAllowanceAndFundsRevertAtomically() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,, address debt, uint256 locked) = executor.positions(id);
        uint256 owed = PErc20(debt).borrowBalanceStored(account);
        _outage();
        vm.expectRevert();
        executor.emergencyExitToPTokens(id, type(uint256).max);
        address asset = _approveRecovery(id);
        deal(asset, address(this), owed - 1);
        vm.expectRevert();
        executor.emergencyExitToPTokens(id, type(uint256).max);
        assertEq(PErc20(debt).borrowBalanceStored(account), owed);
        assertEq(IERC20(collateral).balanceOf(account), locked);
        assertEq(marginVault.lockedBalance(address(this), collateral), locked);
        (,,, Types.Status status,) = engine.accounts(account);
        assertEq(uint256(status), uint256(Types.Status.ACTIVE));
    }

    function testRecoveryAfterLossPartialCloseAndCollateralTopUp() public {
        _enableStack();
        uint256 id = _openLife(true, false, 500);
        _price(95e7);
        _closeLife(id, 5000);
        executor.addCollateral(id, quoter.feePToken(address(pAVault), 10e18));
        _approveRecovery(id);
        _outage();
        _recoverAndCheck(id, type(uint256).max);
    }

    function testRecoveryReturnsDonatedCollateralAndDebtPTokens() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,, address debt,) = executor.positions(id);
        IERC20(collateral).transfer(account, 123);
        IERC20(debt).transfer(account, 456);
        _approveRecovery(id);
        _outage();
        _recoverAndCheck(id, type(uint256).max);
    }

    function testRecoveryRiskHookRestrictedAndRawDebtCannotBeBypassed() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account,,, address debt,) = executor.positions(id);
        _approveRecovery(id);
        _outage();
        vm.expectRevert(Risk.Unauthorized.selector);
        engine.beginEmergencyClose(account);
        uint256 owed = PErc20(debt).borrowBalanceStored(account);
        // Simulate an account falsely reporting successful repayment without clearing debt.
        vm.mockCall(account, abi.encodeWithSignature("repayBorrow(uint256)", owed), abi.encode(owed));
        uint256 wallet = usd.balanceOf(address(this));
        vm.expectRevert(Risk.UnsafePosition.selector);
        executor.emergencyExitToPTokens(id, owed);
        assertEq(usd.balanceOf(address(this)), wallet);
        assertEq(PErc20(debt).borrowBalanceStored(account), owed);
    }

    function testRecoveryTransferPauseRollsBackWalletRepayment() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account, address collateral,, address debt, uint256 locked) = executor.positions(id);
        _approveRecovery(id);
        _outage();
        controller._setTransferPaused(true);
        uint256 wallet = usd.balanceOf(address(this));
        uint256 owed = PErc20(debt).borrowBalanceStored(account);
        vm.expectRevert(bytes("transfer is paused"));
        executor.emergencyExitToPTokens(id, type(uint256).max);
        assertEq(usd.balanceOf(address(this)), wallet);
        assertEq(PErc20(debt).borrowBalanceStored(account), owed);
        assertEq(marginVault.lockedBalance(address(this), collateral), locked);
        (,,, Types.Status status,) = engine.accounts(account);
        assertEq(uint256(status), uint256(Types.Status.ACTIVE));
    }

    function testRecoveryRejectsFailedAccrualOrUnmigratedDebtAccounting() public {
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        (, address account,,, address debt,) = executor.positions(id);
        _approveRecovery(id);
        config.pauseOpens();
        vm.mockCall(debt, abi.encodeWithSignature("accrueInterest()"), abi.encode(uint256(1)));
        vm.expectRevert(Risk.InvalidConfiguration.selector);
        executor.emergencyExitToPTokens(id, type(uint256).max);
        vm.clearMockedCalls();
        vm.mockCall(debt, abi.encodeWithSignature("borrowAccountingEnabled()"), abi.encode(false));
        vm.expectRevert(Risk.InvalidConfiguration.selector);
        executor.emergencyExitToPTokens(id, type(uint256).max);
        (,,, Types.Status status,) = engine.accounts(account);
        assertEq(uint256(status), uint256(Types.Status.ACTIVE));
    }

    function testRecoveryWaivesFeeButNormalCloseStillRequiresIt() public {
        config.queueFees(10, 10, 5000, 5000, 0);
        vm.warp(block.timestamp + 1 hours);
        config.setFees(10, 10, 5000, 5000, 0);
        _enableStack();
        uint256 id = _openLife(false, false, 500);
        Executor.CloseParams memory p = _closeParams(id, 10_000);
        p.maxFeeShares = 0;
        vm.expectRevert(Executor.FeeLimit.selector);
        executor.closePosition(p);
        _approveRecovery(id);
        _outage();
        _recoverAndCheck(id, type(uint256).max);
        assertEq(config.closeFeeBps(), 10);
    }

    function testRecoveryDoesNotReleaseAnotherPositionsCollateralOrDebt() public {
        _enableStack();
        uint256 first = _openLife(false, false, 500);
        uint256 second = _openLife(false, false, 500);
        (, address firstAccount,,,,) = executor.positions(first);
        (, address secondAccount, address collateral,, address debt, uint256 locked) = executor.positions(second);
        uint256 firstDebt = PErc20(debt).borrowBalanceStored(firstAccount);
        uint256 secondDebt = PErc20(debt).borrowBalanceStored(secondAccount);
        _approveRecovery(first);
        _outage();
        executor.emergencyExitToPTokens(first, firstDebt);
        assertEq(PErc20(debt).borrowBalanceStored(firstAccount), 0);
        assertEq(PErc20(debt).borrowBalanceStored(secondAccount), secondDebt);
        assertGt(PErc20(debt).totalBorrows(), 0);
        assertEq(IERC20(collateral).balanceOf(secondAccount), locked);
        assertEq(marginVault.lockedBalance(address(this), collateral), locked);
        (,,, Types.Status status,) = engine.accounts(secondAccount);
        assertEq(uint256(status), uint256(Types.Status.ACTIVE));
        _recoverAndCheck(second, secondDebt);
        assertEq(PErc20(debt).totalBorrows(), 0);
    }

    function testFuzzRecoveryPreservesSharesAndFullyRepays(
        bool avaxCollateral,
        bool short,
        uint16 leverageSeed,
        uint32 blocksSeed
    ) public {
        _enableStack();
        CollateralLifecycleInterestModel model = new CollateralLifecycleInterestModel();
        model.setRate(1e12);
        assertEq(pUsd._setInterestRateModel(model), 0);
        assertEq(pAvax._setInterestRateModel(model), 0);
        uint256 id = _openLife(avaxCollateral, short, uint16(bound(leverageSeed, 200, 500)));
        _approveRecovery(id);
        _outage();
        vm.roll(block.number + bound(blocksSeed, 1, 10_000));
        _recoverAndCheck(id, type(uint256).max);
    }
}
