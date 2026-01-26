// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20.sol";
import "../EIP20Interface.sol";
import "../interfaces/IBoostedYieldAdapter.sol";

/**
 * @title Peridot's Boosted PErc20
 * @notice Extends PErc20 by deploying idle liquidity into an external yield adapter that supports instant withdrawals.
 */
contract BoostedPErc20 is PErc20 {
    uint256 internal constant MANTISSA_ONE = 1e18;

    /// @notice Adapter that manages external yield for this market.
    IBoostedYieldAdapter public boostAdapter;

    /// @notice Fraction (scaled by 1e18) of total assets to keep as idle liquidity on the pToken.
    uint256 public liquidityBufferMantissa = 1e17; // 10%

    /// @notice When true the adapter is bypassed and funds stay on the pToken.
    bool public boostPaused;

    event BoostAdapterUpdated(
        address indexed oldAdapter,
        address indexed newAdapter,
        uint256 withdrawn
    );
    event LiquidityBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event BoostPausedUpdated(bool paused);
    event BoostFundsDeployed(uint256 amountDeployed);
    event BoostFundsPulled(uint256 amountPulled);

    /**
     * @notice Sets a new boost adapter. Withdraws all funds from the previous adapter before switching.
     * @param adapter The new adapter address (set to zero to disable boosting).
     */
    function setBoostAdapter(IBoostedYieldAdapter adapter) public {
        require(msg.sender == admin, "BoostedPErc20: only admin");

        address oldAdapter = address(boostAdapter);
        uint256 withdrawn;

        if (oldAdapter != address(0)) {
            withdrawn = boostAdapter.withdrawAll(address(this));
            _clearAdapterAllowance(oldAdapter);
        }

        if (address(adapter) != address(0)) {
            require(
                adapter.underlying() == underlying,
                "BoostedPErc20: adapter underlying mismatch"
            );
            boostAdapter = adapter;
            _ensureAdapterAllowance();
            boostPaused = false;
            _rebalanceBuffer();
        } else {
            boostAdapter = IBoostedYieldAdapter(address(0));
            boostPaused = true;
        }

        emit BoostAdapterUpdated(oldAdapter, address(adapter), withdrawn);
    }

    /**
     * @notice Updates the buffer ratio that remains on the pToken.
     * @param newMantissa Ratio scaled by 1e18. Must be between 0 and 1e18.
     */
    function setLiquidityBufferMantissa(uint256 newMantissa) public {
        require(msg.sender == admin, "BoostedPErc20: only admin");
        require(newMantissa <= MANTISSA_ONE, "BoostedPErc20: invalid buffer");
        uint256 previous = liquidityBufferMantissa;
        liquidityBufferMantissa = newMantissa;
        emit LiquidityBufferUpdated(previous, newMantissa);
        _rebalanceBuffer();
    }

    /**
     * @notice Pauses or resumes the adapter. Pausing withdraws all funds back to the pToken
     *         and revokes the adapter's allowance to prevent fund extraction while paused.
     */
    function setBoostPaused(bool pause) public {
        require(msg.sender == admin, "BoostedPErc20: only admin");
        if (pause == boostPaused) {
            return;
        }
        boostPaused = pause;
        if (pause) {
            if (address(boostAdapter) != address(0)) {
                uint256 amount = boostAdapter.withdrawAll(address(this));
                emit BoostFundsPulled(amount);
                // Revoke allowance to prevent compromised adapter from pulling funds while paused
                _clearAdapterAllowance(address(boostAdapter));
            }
        } else {
            _ensureAdapterAllowance();
            _rebalanceBuffer();
        }
        emit BoostPausedUpdated(pause);
    }

    /**
     * @notice Emergency hook to pull all funds from the adapter to a recipient.
     * @param recipient Address that receives the withdrawn underlying.
     */
    function emergencyWithdrawAdapter(address recipient) external {
        require(msg.sender == admin, "BoostedPErc20: only admin");
        require(recipient != address(0), "BoostedPErc20: recipient zero");
        IBoostedYieldAdapter adapter = boostAdapter;
        require(
            address(adapter) != address(0),
            "BoostedPErc20: adapter not set"
        );
        uint256 withdrawn = adapter.withdrawAll(recipient);
        emit BoostFundsPulled(withdrawn);
    }

    /**
     * @notice Returns total idle cash plus assets deployed in the adapter.
     */
    function totalManagedAssets() external view returns (uint256) {
        return _localCash() + _adapterBalance();
    }

    /**
     * @dev Adds adapter balances to local cash when the core protocol asks for cash prior.
     */
    function getCashPrior() internal view override returns (uint256) {
        return super.getCashPrior() + _adapterBalance();
    }

    /**
     * @dev After the protocol pulls tokens in, forward the excess above the buffer into the adapter.
     */
    function doTransferIn(
        address from,
        uint256 amount
    ) internal override returns (uint256) {
        uint256 actual = super.doTransferIn(from, amount);
        _rebalanceBuffer();
        return actual;
    }

    /**
     * @dev Before transferring tokens out make sure enough liquidity is on-hand, pulling from the adapter as needed.
     */
    function doTransferOut(
        address payable to,
        uint256 amount
    ) internal override {
        _ensureLiquidity(amount);
        super.doTransferOut(to, amount);
        _rebalanceBuffer();
    }

    /**
     * @dev Ensures the pToken holds at least `amount` of underlying before an outgoing transfer.
     */
    function _ensureLiquidity(uint256 amount) internal {
        if (boostPaused) {
            return;
        }
        IBoostedYieldAdapter adapter = boostAdapter;
        if (address(adapter) == address(0)) {
            return;
        }

        uint256 localCash = super.getCashPrior();
        if (localCash >= amount) {
            return;
        }

        uint256 shortfall = amount - localCash;
        try adapter.withdraw(address(this), shortfall) returns (uint256 pulled) {
            emit BoostFundsPulled(pulled);
        } catch {}

        uint256 newCash = super.getCashPrior();
        require(newCash >= amount, "BoostedPErc20: liquidity shortfall");
    }

    /**
     * @dev Brings local liquidity back to its configured buffer by depositing or withdrawing from the adapter.
     */
    function _rebalanceBuffer() internal {
        if (boostPaused) {
            return;
        }
        IBoostedYieldAdapter adapter = boostAdapter;
        if (address(adapter) == address(0)) {
            return;
        }

        uint256 localCash = super.getCashPrior();
        (bool balanceOk, uint256 adapterBalance) = _adapterBalanceSafe();
        if (!balanceOk) {
            return;
        }
        uint256 totalAssets = localCash + adapterBalance;
        if (totalAssets == 0) {
            return;
        }

        uint256 targetBuffer = (totalAssets * liquidityBufferMantissa) /
            MANTISSA_ONE;

        if (localCash > targetBuffer) {
            uint256 toDeposit = localCash - targetBuffer;
            if (toDeposit > 0) {
                _ensureAdapterAllowance();
                try adapter.deposit(toDeposit) returns (uint256 deployed) {
                    emit BoostFundsDeployed(deployed);
                } catch {}
            }
        } else if (targetBuffer > localCash) {
            uint256 deficit = targetBuffer - localCash;
            if (deficit > 0) {
                try adapter.withdraw(address(this), deficit) returns (uint256 pulled) {
                    emit BoostFundsPulled(pulled);
                } catch {}
            }
        }
    }

    function _localCash() internal view returns (uint256) {
        return EIP20Interface(underlying).balanceOf(address(this));
    }

    function _adapterBalance() internal view returns (uint256) {
        (bool ok, uint256 balance) = _adapterBalanceSafe();
        return ok ? balance : 0;
    }

    function _adapterBalanceSafe() internal view returns (bool ok, uint256 balance) {
        if (boostPaused) {
            return (true, 0);
        }
        IBoostedYieldAdapter adapter = boostAdapter;
        if (address(adapter) == address(0)) {
            return (true, 0);
        }
        try adapter.totalUnderlying() returns (uint256 reported) {
            return (true, reported);
        } catch {
            return (false, 0);
        }
    }

    function _ensureAdapterAllowance() internal {
        IBoostedYieldAdapter adapter = boostAdapter;
        if (address(adapter) == address(0)) {
            return;
        }
        EIP20Interface token = EIP20Interface(underlying);
        uint256 allowance = token.allowance(address(this), address(adapter));
        if (allowance < type(uint256).max / 2) {
            token.approve(address(adapter), 0);
            token.approve(address(adapter), type(uint256).max);
        }
    }

    function _clearAdapterAllowance(address adapter) internal {
        if (adapter == address(0)) {
            return;
        }
        EIP20Interface(underlying).approve(adapter, 0);
    }
}
