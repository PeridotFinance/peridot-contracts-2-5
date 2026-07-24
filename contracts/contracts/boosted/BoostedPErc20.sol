// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20.sol";
import "../interfaces/IBoostedYieldAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Peridot's Boosted PErc20
 * @notice Extends PErc20 by deploying idle liquidity into an external yield adapter that supports instant withdrawals.
 */
contract BoostedPErc20 is PErc20 {
    using SafeERC20 for IERC20;

    uint256 internal constant MANTISSA_ONE = 1e18;

    /// @notice Adapter that manages external yield for this market.
    IBoostedYieldAdapter public boostAdapter;

    /// @notice Fraction (scaled by 1e18) of total assets to keep as idle liquidity on the pToken.
    uint256 public liquidityBufferMantissa = 1e17; // 10%

    /// @notice When true the adapter is bypassed and its assets are excluded from market accounting.
    bool public boostPaused;

    /// @notice Conservative ceiling for adapter assets included in market accounting.
    uint256 public accountedAdapterAssets;

    /// @notice Adapter detached after a failed exit and still eligible for recovery.
    address internal detachedBoostAdapter;

    /// @dev Pins a validated adapter accounting snapshot across a mint operation.
    bool internal mintAdapterAssetsValidated;

    event BoostAdapterUpdated(address indexed oldAdapter, address indexed newAdapter, uint256 withdrawn);
    event LiquidityBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event BoostPausedUpdated(bool paused);
    event BoostFundsDeployed(uint256 amountDeployed);
    event BoostFundsPulled(uint256 amountPulled);
    event BoostAdapterWithdrawalFailed();
    event AdapterAssetsSynced(uint256 previousAssets, uint256 newAssets);
    event BoostAdapterDetached(address indexed adapter);

    /**
     * @notice Supplies assets only when all strategy value used for mint pricing has been proven.
     * @dev Existing holders must not be diluted by minting against a conservative zero-value
     *      fallback while an adapter report is unavailable or a detached adapter is unresolved.
     */
    function mint(uint256 mintAmount) external override returns (uint256) {
        require(detachedBoostAdapter == address(0), "BoostedPErc20: detached adapter unresolved");

        IBoostedYieldAdapter adapter = boostAdapter;
        if (boostPaused || address(adapter) == address(0)) {
            require(accountedAdapterAssets == 0, "BoostedPErc20: adapter assets unresolved");
        } else {
            mintAdapterAssetsValidated = true;
        }

        mintInternal(mintAmount);
        mintAdapterAssetsValidated = false;
        return NO_ERROR;
    }

    /**
     * @notice Sets a new boost adapter. Withdraws all funds from the previous adapter before switching.
     * @param adapter The new adapter address (set to zero to disable boosting).
     */
    function setBoostAdapter(IBoostedYieldAdapter adapter) public nonReentrant {
        require(msg.sender == admin, "BoostedPErc20: only admin");

        address oldAdapter = address(boostAdapter);
        uint256 withdrawn;

        if (oldAdapter != address(0)) {
            boostAdapter = IBoostedYieldAdapter(address(0));
            boostPaused = true;
            accountedAdapterAssets = 0;
            _clearAdapterAllowance(oldAdapter);
            try this.executeBoostAdapterExit(oldAdapter, address(this)) returns (uint256 amount) {
                withdrawn = amount;
            } catch {
                _markAdapterDetached(oldAdapter);
                emit BoostAdapterWithdrawalFailed();
            }
        }

        if (address(adapter) != address(0)) {
            require(address(adapter) != detachedBoostAdapter, "BoostedPErc20: adapter detached");
            require(adapter.underlying() == underlying, "BoostedPErc20: adapter underlying mismatch");
            require(adapter.owner() == address(this), "BoostedPErc20: adapter owner mismatch");
            require(adapter.totalUnderlying() == 0, "BoostedPErc20: adapter not empty");
            boostAdapter = adapter;
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
    function setLiquidityBufferMantissa(uint256 newMantissa) public nonReentrant {
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
    function setBoostPaused(bool pause) public nonReentrant {
        require(msg.sender == admin, "BoostedPErc20: only admin");

        IBoostedYieldAdapter adapter = boostAdapter;
        if (pause) {
            bool changed = !boostPaused;
            boostPaused = true;
            if (address(adapter) != address(0)) {
                _clearAdapterAllowance(address(adapter));
                try this.executeBoostAdapterExit(address(adapter), address(this)) returns (uint256 amount) {
                    accountedAdapterAssets = 0;
                    emit BoostFundsPulled(amount);
                } catch {
                    emit BoostAdapterWithdrawalFailed();
                }
            }
            if (changed) {
                emit BoostPausedUpdated(true);
            }
            return;
        }

        require(address(adapter) != address(0), "BoostedPErc20: adapter not set");
        uint256 reported = adapter.totalUnderlying();
        require(reported >= accountedAdapterAssets, "BoostedPErc20: adapter loss requires sync");
        boostPaused = false;
        emit BoostPausedUpdated(false);
        _rebalanceBuffer();
    }

    /**
     * @notice Emergency hook to pull all funds from the adapter to a recipient.
     * @param recipient Address that receives the withdrawn underlying.
     */
    function emergencyWithdrawAdapter(address recipient) external nonReentrant {
        require(msg.sender == admin, "BoostedPErc20: only admin");
        require(recipient != address(0), "BoostedPErc20: recipient zero");
        IBoostedYieldAdapter adapter = boostAdapter;
        require(address(adapter) != address(0), "BoostedPErc20: adapter not set");
        bool changed = !boostPaused;
        boostPaused = true;
        _clearAdapterAllowance(address(adapter));
        try this.executeBoostAdapterExit(address(adapter), recipient) returns (uint256 withdrawn) {
            accountedAdapterAssets = 0;
            emit BoostFundsPulled(withdrawn);
        } catch {
            emit BoostAdapterWithdrawalFailed();
        }
        if (changed) {
            emit BoostPausedUpdated(true);
        }
    }

    /**
     * @notice Recovers or explicitly writes off an adapter detached after a failed exit.
     * @dev Recovered funds return to the market before any optional redeployment.
     * @param adapter The detached adapter address.
     * @param writeOff True to accept a total loss without retrying withdrawal.
     */
    function resolveDetachedBoostAdapter(address adapter, bool writeOff) external nonReentrant {
        require(msg.sender == admin, "BoostedPErc20: only admin");
        require(adapter == detachedBoostAdapter, "BoostedPErc20: adapter not detached");

        if (writeOff) {
            _clearDetachedAdapter();
            emit BoostAdapterUpdated(adapter, address(boostAdapter), 0);
            return;
        }

        try this.executeBoostAdapterExit(adapter, address(this)) returns (uint256 withdrawn) {
            _clearDetachedAdapter();
            emit BoostAdapterUpdated(adapter, address(boostAdapter), withdrawn);
            emit BoostFundsPulled(withdrawn);
            _rebalanceBuffer();
        } catch {
            emit BoostAdapterWithdrawalFailed();
        }
    }

    /**
     * @notice Reconciles the conservative adapter ceiling to an explicitly reviewed value.
     * @dev Yield is not admitted into collateral accounting until the admin supplies the
     *      reviewed amount. A larger live report is left uncredited, so forced transfers
     *      cannot block loss reconciliation or inflate market accounting.
     */
    function syncAdapterAssets(uint256 expectedAssets) external {
        require(msg.sender == admin, "BoostedPErc20: only admin");
        IBoostedYieldAdapter adapter = boostAdapter;
        require(address(adapter) != address(0), "BoostedPErc20: adapter not set");
        uint256 reported = adapter.totalUnderlying();
        require(reported >= expectedAssets, "BoostedPErc20: adapter balance below expected");
        uint256 previous = accountedAdapterAssets;
        accountedAdapterAssets = expectedAssets;
        emit AdapterAssetsSynced(previous, expectedAssets);
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
    function doTransferIn(address from, uint256 amount) internal override returns (uint256) {
        uint256 actual = super.doTransferIn(from, amount);
        _rebalanceBuffer();
        return actual;
    }

    /**
     * @dev Before transferring tokens out make sure enough liquidity is on-hand, pulling from the adapter as needed.
     */
    function doTransferOut(address payable to, uint256 amount) internal override {
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

        (bool valid, uint256 adapterBalanceBefore) = _tryValidatedAdapterBalance(adapter);
        uint256 localCash = super.getCashPrior();
        if (!valid) {
            require(localCash >= amount, "BoostedPErc20: liquidity shortfall");
            return;
        }
        if (localCash >= amount) {
            return;
        }

        uint256 shortfall = amount - localCash;
        uint256 balanceBefore = _localCash();
        uint256 pulled = adapter.withdraw(address(this), shortfall);
        uint256 balanceAfter = _localCash();
        uint256 adapterBalanceAfter = adapter.totalUnderlying();
        require(
            balanceAfter >= balanceBefore && balanceAfter - balanceBefore == pulled,
            "BoostedPErc20: withdrawal balance mismatch"
        );
        require(
            adapterBalanceBefore >= adapterBalanceAfter && adapterBalanceBefore - adapterBalanceAfter >= pulled,
            "BoostedPErc20: adapter withdrawal mismatch"
        );
        _decreaseAccountedAssets(adapterBalanceBefore - adapterBalanceAfter);
        emit BoostFundsPulled(pulled);

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
        if (super.getCashPrior() + accountedAdapterAssets == 0) {
            return;
        }

        try this.executeBoostRebalance() {}
        catch {
            _tripBoostCircuitBreaker(adapter);
        }
    }

    /**
     * @dev Executes an atomic rebalance in a self-call so optional strategy failures can be caught
     *      without retaining partial token, allowance, or accounting changes.
     */
    function executeBoostRebalance() external {
        require(msg.sender == address(this), "BoostedPErc20: only self");

        IBoostedYieldAdapter adapter = boostAdapter;
        require(!boostPaused && address(adapter) != address(0), "BoostedPErc20: adapter inactive");

        uint256 adapterBalanceBefore = adapter.totalUnderlying();
        require(adapterBalanceBefore >= accountedAdapterAssets, "BoostedPErc20: adapter loss requires sync");
        uint256 localCash = super.getCashPrior();
        uint256 totalAssets = localCash + accountedAdapterAssets;
        uint256 targetBuffer = (totalAssets * liquidityBufferMantissa) / MANTISSA_ONE;

        if (localCash > targetBuffer) {
            uint256 toDeposit = localCash - targetBuffer;
            if (toDeposit > 0) {
                _setAdapterAllowance(toDeposit);
                uint256 balanceBefore = _localCash();
                uint256 deployed = adapter.deposit(toDeposit);
                _clearAdapterAllowance(address(adapter));
                uint256 balanceAfter = _localCash();
                uint256 adapterBalanceAfter = adapter.totalUnderlying();
                require(
                    balanceBefore >= balanceAfter && balanceBefore - balanceAfter == deployed && deployed == toDeposit,
                    "BoostedPErc20: deposit balance mismatch"
                );
                require(adapterBalanceAfter >= adapterBalanceBefore, "BoostedPErc20: adapter deposit mismatch");
                uint256 reportedIncrease = adapterBalanceAfter - adapterBalanceBefore;
                accountedAdapterAssets += reportedIncrease < deployed ? reportedIncrease : deployed;
                emit BoostFundsDeployed(deployed);
            }
        } else if (targetBuffer > localCash) {
            uint256 deficit = targetBuffer - localCash;
            if (deficit > 0) {
                uint256 balanceBefore = _localCash();
                uint256 pulled = adapter.withdraw(address(this), deficit);
                uint256 balanceAfter = _localCash();
                uint256 adapterBalanceAfter = adapter.totalUnderlying();
                require(
                    balanceAfter >= balanceBefore && balanceAfter - balanceBefore == pulled,
                    "BoostedPErc20: withdrawal balance mismatch"
                );
                require(
                    adapterBalanceBefore >= adapterBalanceAfter && adapterBalanceBefore - adapterBalanceAfter >= pulled,
                    "BoostedPErc20: adapter withdrawal mismatch"
                );
                _decreaseAccountedAssets(adapterBalanceBefore - adapterBalanceAfter);
                emit BoostFundsPulled(pulled);
            }
        }
    }

    /**
     * @dev Strictly exits an adapter and verifies the recipient's exact balance increase.
     *      This function is self-call-only so callers can atomically catch adapter failures.
     */
    function executeBoostAdapterExit(address adapter, address recipient) external returns (uint256 withdrawn) {
        require(msg.sender == address(this), "BoostedPErc20: only self");
        require(adapter != address(0) && recipient != address(0), "BoostedPErc20: invalid exit");

        IERC20 token = IERC20(underlying);
        uint256 balanceBefore = token.balanceOf(recipient);
        IBoostedYieldAdapter target = IBoostedYieldAdapter(adapter);
        withdrawn = target.withdrawAll(recipient);
        uint256 balanceAfter = token.balanceOf(recipient);
        require(
            balanceAfter >= balanceBefore && balanceAfter - balanceBefore == withdrawn,
            "BoostedPErc20: withdrawal balance mismatch"
        );
        require(target.totalUnderlying() == 0, "BoostedPErc20: old adapter not empty");
    }

    function _localCash() internal view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function _adapterBalance() internal view returns (uint256) {
        IBoostedYieldAdapter adapter = boostAdapter;
        if (address(adapter) == address(0) || boostPaused) {
            return 0;
        }
        if (mintAdapterAssetsValidated) {
            uint256 reported = adapter.totalUnderlying();
            require(reported >= accountedAdapterAssets, "BoostedPErc20: adapter loss requires sync");
            return accountedAdapterAssets;
        }
        (bool valid,) = _tryValidatedAdapterBalance(adapter);
        return valid ? accountedAdapterAssets : 0;
    }

    function _tryValidatedAdapterBalance(IBoostedYieldAdapter adapter)
        internal
        view
        returns (bool valid, uint256 reported)
    {
        try adapter.totalUnderlying() returns (uint256 assets) {
            return (assets >= accountedAdapterAssets, assets);
        } catch {
            return (false, 0);
        }
    }

    function _tripBoostCircuitBreaker(IBoostedYieldAdapter adapter) internal {
        if (boostPaused) {
            return;
        }
        boostPaused = true;
        _clearAdapterAllowance(address(adapter));
        emit BoostPausedUpdated(true);
    }

    function _markAdapterDetached(address adapter) internal {
        if (detachedBoostAdapter == adapter) {
            return;
        }
        require(detachedBoostAdapter == address(0), "BoostedPErc20: detached adapter unresolved");
        detachedBoostAdapter = adapter;
        emit BoostAdapterDetached(adapter);
    }

    function _clearDetachedAdapter() internal {
        detachedBoostAdapter = address(0);
    }

    function _setAdapterAllowance(uint256 amount) internal {
        IBoostedYieldAdapter adapter = boostAdapter;
        if (address(adapter) == address(0)) {
            return;
        }
        IERC20(underlying).forceApprove(address(adapter), amount);
    }

    function _clearAdapterAllowance(address adapter) internal {
        if (adapter == address(0)) {
            return;
        }
        IERC20 token = IERC20(underlying);
        token.forceApprove(adapter, 0);
        require(token.allowance(address(this), adapter) == 0, "BoostedPErc20: allowance not revoked");
    }

    function _decreaseAccountedAssets(uint256 amount) internal {
        accountedAdapterAssets = amount >= accountedAdapterAssets ? 0 : accountedAdapterAssets - amount;
    }
}
