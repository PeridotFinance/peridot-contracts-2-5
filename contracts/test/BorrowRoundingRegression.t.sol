// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockErc20} from "./MockErc20.sol";
import {BorrowAccounting} from "../contracts/BorrowAccounting.sol";

/// @dev Test-only deterministic rate; production mint/borrow/accrue/repay/redeem code is unchanged.
contract RoundingFixedRate is InterestRateModel {
    uint256 public constant RATE = 637_000_003;

    function getBorrowRate(uint256, uint256, uint256) external pure override returns (uint256) {
        return RATE;
    }

    function getSupplyRate(uint256, uint256, uint256, uint256) external pure override returns (uint256) {
        return 0;
    }
}

/// @notice Characterizes the retained legacy path, NOT a fix or a universal solvency bound.
contract BorrowRoundingRegressionTest is Test {
    MockErc20 token;
    PErc20Delegator market;
    address constant BORROWER = address(0xB0B);
    uint256 constant WAD = 1e18;
    uint256 constant RATE = 637_000_003;

    function setUp() public {
        _deploy(18);
    }

    function _deploy(uint8 decimals) private {
        token = new MockErc20("Rounding test", "ROUND", decimals);
        market = new PErc20Delegator(
            address(token),
            new MockPeridottroller(),
            new RoundingFixedRate(),
            2 * 10 ** (uint256(decimals) + 8),
            "Rounding pToken",
            "pROUND",
            8,
            payable(address(this)),
            address(new PErc20Delegate()),
            ""
        );
        // Test ONLY: select the pre-migration path. No borrow balances or indices are injected.
        vm.store(address(market), BorrowAccounting.SLOT, bytes32(0));
        token.mint(address(this), 10_000 * 10 ** uint256(decimals));
        token.approve(address(market), type(uint256).max);
        assertEq(market.mint(token.balanceOf(address(this))), 0);
        // Create a fractional index naturally, without storage edits or account debt injection.
        vm.roll(vm.getBlockNumber() + 17);
        assertEq(market.accrueInterest(), 0);
    }

    function testSingleFullRepaymentLeavesEightUnitsButNoAccountDebt() public {
        _cycle(10e18, 2);
        assertEq(market.totalBorrows(), 8);
        assertEq(market.borrowBalanceStored(BORROWER), 0);
    }

    function testRepeatedEighteenDecimalCyclesAccumulateResidue() public {
        for (uint256 i; i < 64; ++i) {
            _cycle(10e18 + i * 1e15, 2 + i % 7);
        }
        assertGt(market.totalBorrows(), 8);
        assertLt(market.totalBorrows(), 1000); // Observed scenario bound, not a protocol cap.
        console2.log("64 eighteen-decimal cycles residual raw", market.totalBorrows());
        assertEq(market.exchangeRateStored(), (market.getCash() + market.totalBorrows()) * WAD / market.totalSupply());
        assertGt(market.exchangeRateStored(), market.getCash() * WAD / market.totalSupply());
    }

    function testRepeatedSixDecimalCyclesClearAccountDebt() public {
        _deploy(6);
        for (uint256 i; i < 64; ++i) {
            _cycle(100e6 + i, 2 + i % 7);
        }
        console2.log("64 six-decimal cycles residual raw", market.totalBorrows());
        assertLe(market.totalBorrows(), 64);
    }

    function testSameBlockNewBorrowerDoesNotInheritOldResidue() public {
        _cycle(10e18, 2);
        uint256 residue = market.totalBorrows();
        address newcomer = address(0xCAFE);
        vm.startPrank(newcomer);
        assertEq(market.borrow(1e18), 0);
        assertEq(market.borrowBalanceStored(newcomer), 1e18);
        token.approve(address(market), type(uint256).max);
        assertEq(market.repayBorrow(type(uint256).max), 0);
        vm.stopPrank();
        assertEq(market.borrowBalanceStored(newcomer), 0);
        assertEq(market.totalBorrows(), residue);
    }

    function testClosingOneBorrowerMustNotEraseOtherBorrowersDebt() public {
        address other = address(0xCAFE);
        vm.prank(BORROWER);
        assertEq(market.borrow(10e18), 0);
        vm.prank(other);
        assertEq(market.borrow(20e18), 0);
        vm.roll(vm.getBlockNumber() + 100);
        assertEq(market.accrueInterest(), 0);
        uint256 firstDebt = market.borrowBalanceStored(BORROWER);
        uint256 otherDebt = market.borrowBalanceStored(other);
        uint256 aggregate = market.totalBorrows();
        token.mint(BORROWER, firstDebt - 10e18);
        vm.startPrank(BORROWER);
        token.approve(address(market), type(uint256).max);
        assertEq(market.repayBorrow(type(uint256).max), 0);
        vm.stopPrank();
        assertEq(market.borrowBalanceStored(BORROWER), 0);
        assertEq(market.borrowBalanceStored(other), otherDebt);
        assertEq(market.totalBorrows(), aggregate - firstDebt);
        assertGe(market.totalBorrows(), otherDebt);
    }

    function testFrequentSixDecimalAccrualCanBlockFullRepayment() public {
        _deploy(6);
        uint256 principal = 100e6;
        vm.prank(BORROWER);
        assertEq(market.borrow(principal), 0);
        // Aggregate interest floors to zero EACH block, but the index still advances.
        // Cheatcode return cannot be rematerialized as NUMBER across vm.roll by the optimizer.
        uint256 firstBlock = vm.getBlockNumber();
        for (uint256 i; i < 32; ++i) {
            vm.roll(firstBlock + i + 1);
            assertEq(market.accrueInterest(), 0);
        }
        uint256 debt = market.borrowBalanceStored(BORROWER);
        assertEq(market.totalBorrows(), principal);
        assertEq(debt, principal + 2);
        token.mint(BORROWER, debt - principal);
        vm.startPrank(BORROWER);
        token.approve(address(market), type(uint256).max);
        // Characterizes the existing aggregate subtraction underflow, NOT acceptable final behavior.
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        market.repayBorrow(type(uint256).max);
        vm.stopPrank();
        assertEq(market.borrowBalanceStored(BORROWER), debt);
        assertEq(token.balanceOf(BORROWER), debt); // Transfer-in rolled back with the repayment.
    }

    function testResidualCanAccrueWithoutAnyBorrower() public {
        _cycle(10e18, 2);
        uint256 before = market.totalBorrows();
        uint256 elapsed = 1_000_000_000; // Synthetic long horizon, not a calendar-time forecast.
        vm.roll(vm.getBlockNumber() + elapsed);
        assertEq(market.accrueInterest(), 0);
        assertEq(market.totalBorrows(), before + before * RATE * elapsed / WAD);
        assertGt(market.totalBorrows(), before);
        assertEq(market.borrowBalanceStored(BORROWER), 0);
    }

    function testUnbackedResidueCanBlockLastSupplierFullRedemption() public {
        _cycle(10e18, 2);
        uint256 shares = market.balanceOf(address(this));
        uint256 claim = shares * market.exchangeRateStored() / WAD;
        assertGt(claim, market.getCash());
        assertLe(claim - market.getCash(), market.totalBorrows());
        vm.expectRevert(bytes4(keccak256("RedeemTransferOutNotPossible()")));
        market.redeem(shares);
        assertEq(market.balanceOf(address(this)), shares);
        // Returning pTokens in kind still works: this is underlying redemption, not custody loss.
        assertTrue(market.transfer(address(0xCAFE), shares));
        assertEq(market.balanceOf(address(0xCAFE)), shares);
    }

    function testFuzzSingleBorrowerResidualMatchesIndependentRounding(uint96 principal, uint32 elapsed) public {
        principal = uint96(bound(principal, 1, 1000e18));
        elapsed = uint32(bound(elapsed, 1, 100_000));
        _cycle(principal, elapsed);
    }

    function _cycle(uint256 principal, uint256 elapsed) private {
        uint256 priorResidual = market.totalBorrows();
        uint256 index = market.borrowIndex();
        uint256 cash = market.getCash();
        vm.prank(BORROWER);
        assertEq(market.borrow(principal), 0);
        vm.roll(vm.getBlockNumber() + elapsed);
        uint256 factor = RATE * elapsed;
        uint256 nextIndex = index + factor * index / WAD;
        uint256 accountDebt = principal * nextIndex / index;
        uint256 aggregateDebt = priorResidual + principal + factor * (priorResidual + principal) / WAD;
        assertEq(market.accrueInterest(), 0);
        assertEq(market.borrowIndex(), nextIndex);
        assertEq(market.borrowBalanceStored(BORROWER), accountDebt);
        assertEq(market.totalBorrows(), aggregateDebt);
        token.mint(BORROWER, accountDebt - principal);
        vm.startPrank(BORROWER);
        token.approve(address(market), type(uint256).max);
        assertEq(market.repayBorrow(type(uint256).max), 0);
        vm.stopPrank();
        assertEq(token.balanceOf(BORROWER), 0);
        assertEq(market.borrowBalanceStored(BORROWER), 0);
        assertEq(market.getCash(), cash + accountDebt - principal);
        assertEq(market.totalBorrows(), aggregateDebt - accountDebt);
        assertGe(market.totalBorrows(), priorResidual);
        // Includes growth of pre-existing residue; applies only to this one-borrower/one-accrual fixture.
        assertLe(market.totalBorrows() - priorResidual, factor * priorResidual / WAD + principal / index + 2);
    }
}
