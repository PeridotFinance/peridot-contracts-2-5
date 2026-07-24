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

    /// @notice When true the adapter is bypassed and funds stay on the pToken.
    bool public boostPaused;

    /// @notice Conservative ceiling for adapter assets included in market accounting.
    uint256 public accountedAdapterAssets;

    event BoostAdapterUpdated(address indexed oldAdapter, address indexed newAdapter, uint256 withdrawn);
    event LiquidityBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event BoostPausedUpdated(bool paused);
    event BoostFundsDeployed(uint256 amountDeployed);
    event BoostFundsPulled(uint256 amountPulled);
    event BoostAdapterWithdrawalFailed();
    event AdapterAssetsSynced(uint256 previousAssets, uint256 newAssets);

    /**
     * @notice Sets a new boost adapter. Withdraws all funds from the previous adapter before switching.
     * @param adapter The new adapter address (set to zero to disable boosting).
     */
    function setBoostAdapter(IBoostedYieldAdapter adapter) public {
        require(msg.sender == admin, "BoostedPErc20: only admin");

        address oldAdapter = address(boostAdapter);
        uint256 withdrawn;

        if (oldAdapter != address(0)) {
            _clearAdapterAllowance(oldAdapter);
            withdrawn = boostAdapter.withdrawAll(address(this));
            require(boostAdapter.totalUnderlying() == 0, "BoostedPErc20: old adapter not empty");
            accountedAdapterAssets = 0;
        }

        if (address(adapter) != address(0)) {
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
            if (pause && address(boostAdapter) != address(0)) {
                _clearAdapterAllowance(address(boostAdapter));
            }
            return;
        }
        boostPaused = pause;
        if (pause) {
            if (address(boostAdapter) != address(0)) {
                _clearAdapterAllowance(address(boostAdapter));
                try boostAdapter.withdrawAll(address(this)) returns (uint256 amount) {
                    _decreaseAccountedAssets(amount);
                    emit BoostFundsPulled(amount);
                } catch {
                    emit BoostAdapterWithdrawalFailed();
                }
            }
        } else {
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
        require(address(adapter) != address(0), "BoostedPErc20: adapter not set");
        boostPaused = true;
        _clearAdapterAllowance(address(adapter));
        try adapter.withdrawAll(recipient) returns (uint256 withdrawn) {
            _decreaseAccountedAssets(withdrawn);
            emit BoostFundsPulled(withdrawn);
        } catch {
            emit BoostAdapterWithdrawalFailed();
        }
        emit BoostPausedUpdated(true);
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

        uint256 localCash = super.getCashPrior();
        if (localCash >= amount) {
            return;
        }

        uint256 shortfall = amount - localCash;
        uint256 adapterBalanceBefore = adapter.totalUnderlying();
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

        uint256 localCash = super.getCashPrior();
        uint256 adapterBalance = _adapterBalance();
        uint256 totalAssets = localCash + adapterBalance;
        if (totalAssets == 0) {
            return;
        }

        uint256 targetBuffer = (totalAssets * liquidityBufferMantissa) / MANTISSA_ONE;

        if (localCash > targetBuffer) {
            uint256 toDeposit = localCash - targetBuffer;
            if (toDeposit > 0) {
                uint256 adapterBalanceBefore = adapter.totalUnderlying();
                _setAdapterAllowance(toDeposit);
                uint256 balanceBefore = _localCash();
                try adapter.deposit(toDeposit) returns (uint256 deployed) {
                    _clearAdapterAllowance(address(adapter));
                    uint256 balanceAfter = _localCash();
                    uint256 adapterBalanceAfter = adapter.totalUnderlying();
                    require(
                        balanceBefore >= balanceAfter && balanceBefore - balanceAfter == deployed
                            && deployed == toDeposit,
                        "BoostedPErc20: deposit balance mismatch"
                    );
                    require(adapterBalanceAfter >= adapterBalanceBefore, "BoostedPErc20: adapter deposit mismatch");
                    uint256 reportedIncrease = adapterBalanceAfter - adapterBalanceBefore;
                    accountedAdapterAssets += reportedIncrease < deployed ? reportedIncrease : deployed;
                    emit BoostFundsDeployed(deployed);
                } catch {
                    _clearAdapterAllowance(address(adapter));
                }
            }
        } else if (targetBuffer > localCash) {
            uint256 deficit = targetBuffer - localCash;
            if (deficit > 0) {
                uint256 adapterBalanceBefore = adapter.totalUnderlying();
                uint256 balanceBefore = _localCash();
                try adapter.withdraw(address(this), deficit) returns (uint256 pulled) {
                    uint256 balanceAfter = _localCash();
                    uint256 adapterBalanceAfter = adapter.totalUnderlying();
                    require(
                        balanceAfter >= balanceBefore && balanceAfter - balanceBefore == pulled,
                        "BoostedPErc20: withdrawal balance mismatch"
                    );
                    require(
                        adapterBalanceBefore >= adapterBalanceAfter
                            && adapterBalanceBefore - adapterBalanceAfter >= pulled,
                        "BoostedPErc20: adapter withdrawal mismatch"
                    );
                    _decreaseAccountedAssets(adapterBalanceBefore - adapterBalanceAfter);
                    emit BoostFundsPulled(pulled);
                } catch {}
            }
        }
    }

    function _localCash() internal view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    function _adapterBalance() internal view returns (uint256) {
        IBoostedYieldAdapter adapter = boostAdapter;
        if (address(adapter) == address(0)) {
            return 0;
        }
        if (boostPaused) {
            return accountedAdapterAssets;
        }
        uint256 reported = adapter.totalUnderlying();
        require(reported >= accountedAdapterAssets, "BoostedPErc20: adapter loss requires sync");
        return accountedAdapterAssets;
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
