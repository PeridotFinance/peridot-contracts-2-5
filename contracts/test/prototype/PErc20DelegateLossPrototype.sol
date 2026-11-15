// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {PErc20Delegate} from "../../contracts/PErc20Delegate.sol";
import {PToken} from "../../contracts/PToken.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {Peridottroller} from "../../contracts/Peridottroller.sol";
import {BorrowAccounting} from "../../contracts/BorrowAccounting.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Admin-only entry point of the prototype, used by the tests through the delegator's fallback.
interface ILossPrototype {
    function writeOffBadDebt(address account, uint256 amount) external returns (uint256 removed, uint256 fromReserves);
}

/**
 * @title PErc20DelegateLossPrototype (TEST-ONLY PROTOTYPE, NOT PRODUCTION CODE, NOT AUDITED)
 * @notice Prototype of an explicit RESERVE-FIRST bad-debt recognition for a plain `PErc20Delegate` market. It exists only under
 *         `contracts/test/prototype/` to measure the design in `docs/deployment-handoffs/avalanche-cash-only-loss-handling.md`.
 *         NOTHING in `contracts/contracts/` calls it, imports it or inherits from it, and no deployment script references it.
 *
 * Semantics of `writeOffBadDebt(account, amount)` (market admin only; in production the admin would be a timelock):
 *   1. accrue interest first (so the debt written off is the current debt and the exchange rate is current);
 *   2. SHARES borrow accounting only (the mode every new market starts in): the account's borrow shares and `totalShares` are
 *      reduced in the `BorrowAccounting` ERC-7201 namespace and `totalBorrows` is recomputed from the remaining shares. A market
 *      still on legacy per-account snapshots reverts (not prototyped). The stock `BorrowAccountingModule` has no forgiveness
 *      path (its `setShares` is reachable only from repay), which is why this needs new code;
 *   3. PRECONDITION (if `ENFORCE_PRECONDITION`): the account is in shortfall AND the value of every pToken balance it holds in every
 *      listed market is at most `MAX_RESIDUAL_COLLATERAL_VALUE` (oracle value, 1e18 = USD 1). I.e. liquidation has already taken
 *      what it can; nothing worth recovering is left;
 *   4. CAPS (immutables, 0 = none): `CAP_PER_CALL` per call; `PERIOD_CAP` per `PERIOD_SECONDS` (period state lives in an ERC-7201
 *      namespaced slot, so no field is appended to `PTokenStorage`);
 *   5. the debt is removed from the account and from `totalBorrows`;
 *   6. RESERVE-FIRST: the loss is absorbed first by `totalReserves` (`fromReserves = min(removed, totalReserves)`); only the
 *      remainder changes the exchange rate `(cash + totalBorrows - totalReserves) / totalSupply`, i.e. it is recognised by all
 *      suppliers pro rata at once, with no run advantage from that block on;
 *   7. an event states the split.
 * The controls are IMMUTABLES on purpose: loosening them needs a new implementation (a timelocked `_setImplementation`), not a
 * single admin call. Instantiating with `enforcePrecondition = false` and no cap models an UNRESTRICTED admin (theft vector tests).
 */
contract PErc20DelegateLossPrototype is PErc20Delegate {
    bool public immutable ENFORCE_PRECONDITION;
    uint256 public immutable CAP_PER_CALL;
    uint256 public immutable PERIOD_CAP;
    uint256 public immutable PERIOD_SECONDS;
    uint256 public immutable MAX_RESIDUAL_COLLATERAL_VALUE;

    /// @dev ERC-7201 namespaced slot: keccak256(abi.encode(uint256(keccak256("peridot.storage.LossPrototype")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LOSS_SLOT =
        keccak256(abi.encode(uint256(keccak256("peridot.storage.LossPrototype")) - 1)) & ~bytes32(uint256(0xff));

    struct LossState {
        uint256 periodStart;
        uint256 writtenInPeriod;
    }

    event BadDebtWrittenOff(
        address indexed account,
        uint256 amount,
        uint256 absorbedByReserves,
        uint256 recognisedBySuppliers,
        uint256 exchangeRateBefore,
        uint256 exchangeRateAfter,
        uint256 totalBorrowsAfter,
        uint256 totalReservesAfter
    );

    constructor(
        bool enforcePrecondition,
        uint256 capPerCall,
        uint256 periodCap,
        uint256 periodSeconds,
        uint256 maxResidualCollateralValue
    ) {
        ENFORCE_PRECONDITION = enforcePrecondition;
        CAP_PER_CALL = capPerCall;
        PERIOD_CAP = periodCap;
        PERIOD_SECONDS = periodSeconds;
        MAX_RESIDUAL_COLLATERAL_VALUE = maxResidualCollateralValue;
    }

    function writeOffBadDebt(address account, uint256 amount)
        external
        nonReentrant
        returns (uint256 removed, uint256 fromReserves)
    {
        require(msg.sender == admin, "only the admin may write off bad debt");
        // New markets are created with shares accounting (`PToken.initialize`). Legacy per-account snapshots are not handled.
        BorrowAccounting.State storage d = BorrowAccounting.state();
        require(d.enabled, "write-off requires shares accounting");

        accrueInterest();
        require(accrualBlockNumber == getBlockNumber(), "not fresh");

        uint256 owed = borrowBalanceStoredInternal(account);
        require(amount > 0 && owed > 0, "nothing to write off");
        require(amount <= owed, "amount exceeds the recorded debt");

        // shares to drop (ceil so the recorded debt never exceeds what was asked; a full write-off drops every share)
        uint256 sh = d.shares[account];
        uint256 dropShares =
            amount == owed ? sh : Math.min(sh, Math.mulDiv(amount, BorrowAccounting.SCALE, borrowIndex, Math.Rounding.Ceil));
        uint256 newTotalBorrows = Math.mulDiv(d.totalShares - dropShares, borrowIndex, BorrowAccounting.SCALE);
        removed = totalBorrows - newTotalBorrows; // what leaves the aggregate asset side (includes share rounding)
        require(removed > 0, "nothing removed");

        if (ENFORCE_PRECONDITION) _requireNothingToRecover(account);
        if (CAP_PER_CALL != 0) require(removed <= CAP_PER_CALL, "per-call cap");
        if (PERIOD_CAP != 0) _spendPeriodAllowance(removed);

        uint256 rateBefore = exchangeRateStoredInternal();

        // RESERVE-FIRST: reserves absorb the loss before any supplier does
        fromReserves = removed > totalReserves ? totalReserves : removed;
        totalReserves = totalReserves - fromReserves;
        totalBorrows = newTotalBorrows;
        d.shares[account] = sh - dropShares;
        d.totalShares -= dropShares;
        // keep the legacy snapshot consistent: `_requireMigratedBorrower` treats zero shares with a non-zero snapshot as a missing borrower
        accountBorrows[account].principal = Math.mulDiv(sh - dropShares, borrowIndex, BorrowAccounting.SCALE);
        accountBorrows[account].interestIndex = borrowIndex;

        uint256 rateAfter = exchangeRateStoredInternal();
        emit BadDebtWrittenOff(
            account, removed, fromReserves, removed - fromReserves, rateBefore, rateAfter, totalBorrows, totalReserves
        );
    }

    function _spendPeriodAllowance(uint256 removed) private {
        LossState storage s = _lossState();
        if (block.timestamp >= s.periodStart + PERIOD_SECONDS) {
            s.periodStart = block.timestamp;
            s.writtenInPeriod = 0;
        }
        require(s.writtenInPeriod + removed <= PERIOD_CAP, "per-period cap");
        s.writtenInPeriod += removed;
    }

    function lossPeriodState() external view returns (uint256 periodStart, uint256 writtenInPeriod) {
        LossState storage s = _lossState();
        return (s.periodStart, s.writtenInPeriod);
    }

    function _lossState() private pure returns (LossState storage s) {
        bytes32 slot = LOSS_SLOT;
        assembly ("memory-safe") {
            s.slot := slot
        }
    }

    function _requireNothingToRecover(address account) private view {
        Peridottroller c = Peridottroller(address(peridottroller));
        (uint256 err,, uint256 shortfall) = c.getAccountLiquidity(account);
        require(err == 0 && shortfall > 0, "account is not in shortfall");
        PToken[] memory ms = c.getAllMarkets();
        PriceOracle o = c.oracle();
        uint256 value;
        for (uint256 i; i < ms.length; ++i) {
            (uint256 e, uint256 bal,, uint256 rate) = ms[i].getAccountSnapshot(account);
            require(e == 0, "snapshot error");
            if (bal == 0) continue;
            uint256 price = o.getUnderlyingPrice(ms[i]);
            require(price > 0, "no price");
            value += (bal * rate / 1e18) * price / 1e18;
        }
        require(value <= MAX_RESIDUAL_COLLATERAL_VALUE, "collateral remains: liquidate first");
    }
}
