// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20Delegate.sol";
import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IMagma {
    // Deposits (synchronous)
    function depositWMON(
        uint256 assets,
        address receiver,
        uint256 referralId
    ) external returns (uint256 shares);

    function depositMON(
        address receiver,
        uint256 referralId
    ) external payable returns (uint256 shares);

    // Redemptions (asynchronous - two step)
    function requestRedeem(
        uint256 shares,
        address controller,
        address owner
    ) external returns (uint256 requestId);

    function redeemMON(
        uint256 requestId,
        address controller,
        address receiver
    ) external returns (uint256 assets);

    function redeem(
        uint256 requestId,
        address controller,
        address receiver
    ) external returns (uint256 assets);

    // ERC-4626 View functions
    function balanceOf(address account) external view returns (uint256 shares);

    function convertToAssets(
        uint256 shares
    ) external view returns (uint256 assets);

    function convertToShares(
        uint256 assets
    ) external view returns (uint256 shares);

    function totalAssets() external view returns (uint256);

    // Request tracking
    function ownerRequestId(
        address owner
    ) external view returns (uint256 requestId);
}

/**
 * @title MagmaBoostedDelegate
 * @notice Compound-style delegate for a Magma-boosted market.
 * @dev Underlying is WMON. Idle WMON is deposited into Magma to earn gMON (Monad LST) yield.
 *      Due to Magma's asynchronous redemption design (Monad unbonding period), this implementation
 *      maintains a buffer of WMON for immediate withdrawals. If buffer is insufficient,
 *      withdrawals may fail until admin rebalances or async redemptions complete.
 *
 *      IMPORTANT - Liquidity Accounting:
 *      - `getCashPrior()` returns ONLY immediately available WMON (local cash)
 *      - Vault assets (gMON) are NOT counted as cash due to async redemption requirement
 *      - This means interest rates and borrow limits reflect true available liquidity
 *      - The `totalManagedAssets()` view function shows the full picture including vault
 *
 *      WITHDRAWAL RISK:
 *      - If local buffer is depleted, withdrawals will fail
 *      - Admin must proactively request redemptions to maintain buffer
 *      - Users should be aware of potential delays during high withdrawal demand
 *
 *      GOVERNANCE:
 *      - Admin functions should be controlled by multisig/timelock in production
 *      - Consider using a DAO or governance contract as admin
 */
contract MagmaBoostedDelegate is PErc20Delegate {
    using SafeERC20 for IERC20;

    uint256 internal constant MANTISSA_ONE = 1e18;
    uint256 internal constant MIN_BUFFER_MANTISSA = 1e17; // 10% minimum buffer

    /// @notice Magma contract (gMON LST).
    IMagma public magmaVault;

    /// @notice Fraction of total managed assets to keep as liquid WMON buffer (scaled by 1e18).
    /// @dev Higher buffer = more immediate withdrawal capacity, but less capital efficiency.
    ///      Minimum 10% buffer enforced to ensure basic withdrawal availability.
    uint256 public vaultBufferMantissa;

    /// @notice When true, deposits are paused and funds should be withdrawn from Magma.
    bool public vaultPaused;

    /// @notice Pending redemption request ID from Magma (0 if none).
    uint256 public pendingRedemptionId;

    /// @notice Amount of shares in pending redemption (for accounting).
    uint256 public pendingRedemptionShares;

    /// @notice Referral ID for Magma points (default: 0).
    uint256 public referralId;

    event VaultBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event VaultPausedUpdated(bool paused);
    event VaultDeposited(uint256 assets, uint256 shares);
    event RedemptionRequested(uint256 requestId, uint256 shares);
    event RedemptionCompleted(uint256 requestId, uint256 assets);
    event ReferralIdUpdated(uint256 newReferralId);
    event BufferLow(uint256 localCash, uint256 requiredBuffer);

    /**
     * @notice Called when becoming the implementation for a delegator.
     */
    function _becomeImplementation(bytes memory data) public override {
        require(msg.sender == admin, "only admin");
        if (data.length > 0) {
            (address vault_, uint256 buffer_) = abi.decode(
                data,
                (address, uint256)
            );
            if (vault_ != address(0)) {
                _validateBuffer(buffer_);
                magmaVault = IMagma(vault_);
                vaultBufferMantissa = buffer_;
            }
        }
    }

    /**
     * @notice Admin function to set the Magma vault.
     */
    function _setMagmaVault(address vault_, uint256 buffer_) external {
        require(msg.sender == admin, "only admin");
        require(vault_ != address(0), "zero vault");
        _validateBuffer(buffer_);
        magmaVault = IMagma(vault_);
        vaultBufferMantissa = buffer_;
        emit VaultBufferUpdated(0, buffer_);
    }

    /**
     * @notice Initialize delegate storage.
     */
    function initialize(
        address underlying_,
        PeridottrollerInterface peridottroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IMagma magmaVault_,
        uint256 vaultBufferMantissa_
    ) public {
        require(accrualBlockNumber == 0 && borrowIndex == 0, "already init");
        _validateBuffer(vaultBufferMantissa_);

        admin = payable(msg.sender);
        magmaVault = magmaVault_;
        vaultBufferMantissa = vaultBufferMantissa_;

        super.initialize(
            underlying_,
            peridottroller_,
            interestRateModel_,
            initialExchangeRateMantissa_,
            name_,
            symbol_,
            decimals_
        );
    }

    // Admin setters
    // NOTE: In production, admin should be a multisig or timelock contract
    function _setVaultBuffer(uint256 newMantissa) external {
        require(msg.sender == admin, "only admin");
        require(newMantissa >= MIN_BUFFER_MANTISSA, "buffer too low");
        require(newMantissa <= MANTISSA_ONE, "invalid buffer");
        uint256 prev = vaultBufferMantissa;
        vaultBufferMantissa = newMantissa;
        emit VaultBufferUpdated(prev, newMantissa);
        _rebalanceVault();
    }

    function _setVaultPaused(bool pause) external {
        require(msg.sender == admin, "only admin");
        if (pause == vaultPaused) return;
        vaultPaused = pause;
        emit VaultPausedUpdated(pause);
        // Note: When paused, we can't immediately pull from Magma due to async redemptions
        // Admin must manually request redemptions via _requestRedemption
    }

    function _setReferralId(uint256 newReferralId) external {
        require(msg.sender == admin, "only admin");
        referralId = newReferralId;
        emit ReferralIdUpdated(newReferralId);
    }

    /**
     * @notice Admin function to request redemption from Magma (step 1 of async withdrawal).
     * @dev Should be called proactively when buffer is running low.
     * @param shares Amount of gMON shares to redeem.
     */
    function _requestRedemption(uint256 shares) external {
        require(msg.sender == admin, "only admin");
        require(pendingRedemptionId == 0, "redemption pending");
        require(shares > 0, "zero shares");

        uint256 requestId = magmaVault.requestRedeem(
            shares,
            address(this),
            address(this)
        );
        pendingRedemptionId = requestId;
        pendingRedemptionShares = shares;
        emit RedemptionRequested(requestId, shares);
    }

    /**
     * @notice Admin function to complete redemption from Magma (step 2 of async withdrawal).
     * @dev Can only be called after WITHDRAWAL_DELAY epochs have passed.
     */
    function _completeRedemption() external {
        require(msg.sender == admin, "only admin");
        uint256 requestId = pendingRedemptionId;
        require(requestId != 0, "no pending redemption");

        // Complete redemption - this returns WMON to this contract
        uint256 assets = magmaVault.redeem(
            requestId,
            address(this),
            address(this)
        );
        pendingRedemptionId = 0;
        pendingRedemptionShares = 0;

        emit RedemptionCompleted(requestId, assets);
        _rebalanceVault();
    }

    /**
     * @notice Anyone can call this to auto-request redemption when buffer is critically low.
     * @dev Provides a permissionless mechanism to prevent withdrawal blocking.
     *      Requests redemption of enough shares to restore buffer to target level.
     */
    function requestRedemptionIfNeeded() external {
        require(msg.sender == admin, "only admin");
        require(pendingRedemptionId == 0, "redemption pending");

        uint256 localCash = super.getCashPrior();
        uint256 vaultAssets = _vaultAssets();
        uint256 total = localCash + vaultAssets;
        if (total == 0) return;

        uint256 targetBuffer = (total * vaultBufferMantissa) / MANTISSA_ONE;

        // Only allow if buffer is below 50% of target
        if (localCash >= targetBuffer / 2) return;

        // Calculate how much we need to redeem to restore buffer
        uint256 deficit = targetBuffer - localCash;
        if (deficit > vaultAssets) {
            deficit = vaultAssets;
        }
        if (deficit == 0) return;

        // Convert to shares
        uint256 sharesToRedeem = magmaVault.convertToShares(deficit);
        if (sharesToRedeem == 0) return;

        uint256 requestId = magmaVault.requestRedeem(
            sharesToRedeem,
            address(this),
            address(this)
        );
        pendingRedemptionId = requestId;
        pendingRedemptionShares = sharesToRedeem;
        emit RedemptionRequested(requestId, sharesToRedeem);
        emit BufferLow(localCash, targetBuffer);
    }

    // Overridden cash/view hooks
    /**
     * @notice Returns total cash including vault assets for exchange rate calculation.
     * @dev WARNING: This includes vault assets that are NOT immediately withdrawable.
     *      Magma redemptions are asynchronous and may take multiple days.
     *      Users should check `getAvailableLiquidity()` before large withdrawals.
     *      The protocol maintains a buffer for normal operations, but during high
     *      withdrawal demand, withdrawals may fail until admin completes redemptions.
     */
    function getCashPrior() internal view override returns (uint256) {
        // Include vault assets for accurate exchange rate and yield reflection
        // But document that not all of this is immediately withdrawable
        return super.getCashPrior() + _vaultAssets();
    }

    /**
     * @notice Returns total managed assets including vault assets.
     */
    function totalManagedAssets() external view returns (uint256) {
        return super.getCashPrior() + _vaultAssets();
    }

    /**
     * @notice Returns ONLY immediately available liquidity (local WMON buffer).
     * @dev Use this to check if a withdrawal of a given size will succeed.
     *      If withdrawal amount > available liquidity, the transaction will revert.
     */
    function getAvailableLiquidity() external view returns (uint256) {
        return super.getCashPrior();
    }

    /**
     * @notice Returns the amount of assets locked in pending redemption.
     */
    function pendingRedemptionAssets() external view returns (uint256) {
        if (pendingRedemptionShares == 0) return 0;
        return magmaVault.convertToAssets(pendingRedemptionShares);
    }

    function doTransferIn(
        address from,
        uint256 amount
    ) internal override returns (uint256) {
        uint256 actual = super.doTransferIn(from, amount);
        _rebalanceVault();
        return actual;
    }

    function doTransferOut(
        address payable to,
        uint256 amount
    ) internal override {
        _ensureLocalLiquidity(amount);
        super.doTransferOut(to, amount);
        _rebalanceVault();
    }

    // Vault helpers
    function _rebalanceVault() internal {
        if (vaultPaused) return;

        uint256 localCash = super.getCashPrior();
        uint256 vaultAssets = _vaultAssets();
        uint256 total = localCash + vaultAssets;
        if (total == 0) return;

        uint256 target = (total * vaultBufferMantissa) / MANTISSA_ONE;

        if (localCash > target) {
            uint256 toDeposit = localCash - target;
            _depositToVault(toDeposit);
        }
        // Note: We cannot pull from vault immediately due to async redemptions
        // Admin must manually request and complete redemptions if buffer is low
    }

    function _ensureLocalLiquidity(uint256 amount) internal {
        uint256 localCash = super.getCashPrior();
        if (localCash < amount) {
            // Emit event to alert that buffer is low
            uint256 vaultAssets = _vaultAssets();
            uint256 total = localCash + vaultAssets;
            uint256 targetBuffer = total > 0
                ? (total * vaultBufferMantissa) / MANTISSA_ONE
                : 0;
            emit BufferLow(localCash, targetBuffer);
            revert("insufficient buffer - admin must complete redemption");
        }
    }

    function _depositToVault(uint256 amount) internal {
        if (amount == 0 || vaultPaused) return;

        IERC20(underlying).forceApprove(address(magmaVault), amount);
        uint256 shares = magmaVault.depositWMON(
            amount,
            address(this),
            referralId
        );
        emit VaultDeposited(amount, shares);
    }

    function _vaultAssets() internal view returns (uint256) {
        uint256 shares = magmaVault.balanceOf(address(this));
        // Exclude pending redemption shares as they're no longer in our control
        if (pendingRedemptionShares > 0 && shares >= pendingRedemptionShares) {
            shares = shares - pendingRedemptionShares;
        }
        if (shares == 0) return 0;
        return magmaVault.convertToAssets(shares);
    }

    function _validateBuffer(uint256 buffer) internal pure {
        require(buffer >= MIN_BUFFER_MANTISSA, "buffer too low");
        require(buffer <= MANTISSA_ONE, "invalid buffer");
    }

    /**
     * @notice View function to check if a pending redemption can be completed.
     */
    function canCompleteRedemption() external view returns (bool) {
        uint256 requestId = pendingRedemptionId;
        if (requestId == 0) return false;
        // Note: Magma doesn't expose a "isClaimable" function
        // Admin should track epochs and call _completeRedemption after WITHDRAWAL_DELAY
        return true;
    }

    /**
     * @notice View function to check current buffer health.
     * @return localCash Current WMON balance
     * @return targetBuffer Target buffer based on total assets
     * @return bufferHealthy True if local cash >= target buffer
     * @return redemptionNeeded True if permissionless redemption request is possible
     */
    function getBufferStatus()
        external
        view
        returns (
            uint256 localCash,
            uint256 targetBuffer,
            bool bufferHealthy,
            bool redemptionNeeded
        )
    {
        localCash = super.getCashPrior();
        uint256 vaultAssets = _vaultAssets();
        uint256 total = localCash + vaultAssets;

        if (total == 0) {
            return (0, 0, true, false);
        }

        targetBuffer = (total * vaultBufferMantissa) / MANTISSA_ONE;
        bufferHealthy = localCash >= targetBuffer;
        // Redemption can be requested if buffer is below 50% of target and no pending redemption
        redemptionNeeded =
            (localCash < targetBuffer / 2) &&
            (pendingRedemptionId == 0) &&
            (vaultAssets > 0);
    }
}
