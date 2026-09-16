// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {BorrowAccounting} from "./BorrowAccounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IBorrowAccountingMarket {
    function admin() external view returns (address);
    function borrowIndex() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function borrowBalanceStored(address borrower) external view returns (uint256);
}

/// @dev Immutable delegatecall helper deployed with each implementation. It uses the existing
///      market getters and ERC-7201 namespace; it is never an admin-selectable call target.
///      Only the namespace is written here. The caller writes returned aggregate/reserve totals.
contract BorrowAccountingModule {
    address private immutable SELF = address(this);
    error BorrowAccountingAlreadyEnabled();
    error BorrowAccountingSnapshotChanged();
    error BorrowAccountingInvalidBorrowerList();
    error BorrowAccountingAdjustmentExceeded();
    error BorrowAccountingIndexTooLarge();
    error BorrowAccountingDirectCall();

    event BorrowAccountingActivated(uint256 borrowers, uint256 previousTotal, uint256 newTotal);
    event BorrowRoundingReconciled(uint256 previousClaim, uint256 newClaim, uint256 newReserves);

    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert BorrowAccountingDirectCall();
        _;
    }

    function balance(uint256 shares, uint256 index) external pure returns (uint256) {
        return Math.mulDiv(shares, index, BorrowAccounting.SCALE);
    }

    function accrued(uint256 shares, uint256 index, uint256 previousBorrows, uint256 reserves, uint256 reserveFactor)
        external
        pure
        returns (uint256 borrows, uint256 updatedReserves)
    {
        _checkIndex(index);
        borrows = Math.mulDiv(shares, index, BorrowAccounting.SCALE);
        updatedReserves = reserves + Math.mulDiv(borrows - previousBorrows, reserveFactor, 1e18);
    }

    function activate(address[] calldata borrowers, uint256 expectedTotalBorrows, uint256 maxRoundingAdjustment)
        external
        onlyDelegateCall
        returns (uint256 updatedTotal, uint256 updatedReserves)
    {
        IBorrowAccountingMarket market = IBorrowAccountingMarket(address(this));
        require(msg.sender == market.admin(), "only admin may migrate borrows");
        BorrowAccounting.State storage debt = BorrowAccounting.state();
        if (debt.enabled) revert BorrowAccountingAlreadyEnabled();
        uint256 oldTotal = market.totalBorrows();
        if (oldTotal != expectedTotalBorrows) revert BorrowAccountingSnapshotChanged();
        uint256 index = market.borrowIndex();
        _checkIndex(index);
        address previous;
        for (uint256 i; i < borrowers.length; ++i) {
            address borrower = borrowers[i];
            if (borrower <= previous) revert BorrowAccountingInvalidBorrowerList();
            previous = borrower;
            uint256 balance = market.borrowBalanceStored(borrower);
            if (balance == 0) revert BorrowAccountingInvalidBorrowerList();
            uint256 shares = Math.mulDiv(balance, BorrowAccounting.SCALE, index, Math.Rounding.Ceil);
            debt.shares[borrower] = shares;
            debt.totalShares += shares;
        }
        updatedTotal = Math.mulDiv(debt.totalShares, index, BorrowAccounting.SCALE);
        uint256 adjustment = updatedTotal > oldTotal ? updatedTotal - oldTotal : oldTotal - updatedTotal;
        if (adjustment > maxRoundingAdjustment) revert BorrowAccountingAdjustmentExceeded();
        debt.enabled = true;
        updatedReserves = _reconcile(oldTotal, updatedTotal, market.totalReserves());
        emit BorrowAccountingActivated(borrowers.length, oldTotal, updatedTotal);
    }

    function setShares(address borrower, uint256 balance, uint256 previousClaim, uint256 repaidCash)
        external
        onlyDelegateCall
        returns (uint256 updatedTotal, uint256 updatedReserves)
    {
        IBorrowAccountingMarket market = IBorrowAccountingMarket(address(this));
        uint256 index = market.borrowIndex();
        _checkIndex(index);
        BorrowAccounting.State storage debt = BorrowAccounting.state();
        uint256 shares = Math.mulDiv(balance, BorrowAccounting.SCALE, index, Math.Rounding.Ceil);
        debt.totalShares = debt.totalShares - debt.shares[borrower] + shares;
        debt.shares[borrower] = shares;
        updatedTotal = Math.mulDiv(debt.totalShares, index, BorrowAccounting.SCALE);
        updatedReserves = _reconcile(previousClaim, updatedTotal + repaidCash, market.totalReserves());
    }

    function _checkIndex(uint256 index) private pure {
        if (index > BorrowAccounting.SCALE) revert BorrowAccountingIndexTooLarge();
    }

    /// @dev Reserves absorb discarded fractional claims first. Remaining losses reduce supplier
    ///      assets, never another borrower's debt. Upward adjustments accrue to reserves.
    function _reconcile(uint256 previousClaim, uint256 newClaim, uint256 reserves) private returns (uint256) {
        if (newClaim > previousClaim) reserves += newClaim - previousClaim;
        else if (previousClaim > newClaim) reserves -= Math.min(reserves, previousClaim - newClaim);
        if (previousClaim != newClaim) emit BorrowRoundingReconciled(previousClaim, newClaim, reserves);
        return reserves;
    }
}
