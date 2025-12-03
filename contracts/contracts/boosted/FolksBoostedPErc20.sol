// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20.sol";
import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Folks-boosted pToken
 * @notice Routes idle liquidity into a Folks Finance ERC4626 vault.
 * @dev Similar to MorphoBoosted: buffer + pause controls, vault asset checked on init.
 */
contract FolksBoostedPErc20 is PErc20 {
    using SafeERC20 for IERC20;

    uint256 internal constant MANTISSA_ONE = 1e18;

    /// @notice Folks vault (ERC4626-compatible).
    IERC4626 public immutable folksVault;

    /// @notice Fraction of total managed assets to keep as idle cash (scaled by 1e18).
    uint256 public vaultBufferMantissa;

    /// @notice When true, deposits to vault are paused and funds are pulled back on toggle.
    bool public vaultPaused;

    event VaultBufferUpdated(uint256 previousMantissa, uint256 newMantissa);
    event VaultPausedUpdated(bool paused);
    event VaultDeposited(uint256 assets, uint256 shares);
    event VaultWithdrawn(uint256 assets, uint256 shares);

    constructor(
        address underlying_,
        PeridottrollerInterface peridottroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_,
        IERC4626 vault_,
        uint256 vaultBufferMantissa_
    ) {
        require(address(vault_) != address(0), "FolksBoosted: vault zero");
        require(vault_.asset() == underlying_, "FolksBoosted: asset mismatch");

        // Temporary admin for initialization
        admin = payable(msg.sender);
        folksVault = vault_;

        initialize(
            underlying_, peridottroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_
        );

        _setVaultBufferInternal(vaultBufferMantissa_);

        // Transfer admin rights to designated admin
        admin = admin_;
    }

    function setVaultBufferMantissa(uint256 newMantissa) external {
        require(msg.sender == admin, "FolksBoosted: only admin");
        _setVaultBufferInternal(newMantissa);
        _rebalanceVault();
    }

    function setVaultPaused(bool pause) external {
        require(msg.sender == admin, "FolksBoosted: only admin");
        if (pause == vaultPaused) return;
        vaultPaused = pause;
        if (pause) {
            _withdrawFromVault(_vaultAssets());
        } else {
            _rebalanceVault();
        }
        emit VaultPausedUpdated(pause);
    }

    function totalVaultAssets() external view returns (uint256) {
        return _vaultAssets();
    }

    function totalManagedAssets() external view returns (uint256) {
        return super.getCashPrior() + _vaultAssets();
    }

    /**
     * @dev Include withdrawable vault liquidity in cash.
     */
    function getCashPrior() internal view override returns (uint256) {
        return super.getCashPrior() + _vaultWithdrawable();
    }

    function doTransferIn(address from, uint256 amount) internal override returns (uint256) {
        uint256 actual = super.doTransferIn(from, amount);
        _rebalanceVault();
        return actual;
    }

    function doTransferOut(address payable to, uint256 amount) internal override {
        _ensureLocalLiquidity(amount);
        super.doTransferOut(to, amount);
        _rebalanceVault();
    }

    function _setVaultBufferInternal(uint256 newMantissa) internal {
        require(newMantissa <= MANTISSA_ONE, "FolksBoosted: invalid buffer");
        uint256 previous = vaultBufferMantissa;
        vaultBufferMantissa = newMantissa;
        emit VaultBufferUpdated(previous, newMantissa);
    }

    function _rebalanceVault() internal {
        if (vaultPaused) return;

        uint256 localCash = super.getCashPrior();
        uint256 vaultAssets = _vaultAssets();
        uint256 total = localCash + vaultAssets;
        if (total == 0) return;

        uint256 targetBuffer = (total * vaultBufferMantissa) / MANTISSA_ONE;

        if (localCash > targetBuffer) {
            uint256 toDeposit = localCash - targetBuffer;
            _depositToVault(toDeposit);
        } else if (targetBuffer > localCash) {
            uint256 deficit = targetBuffer - localCash;
            if (deficit > vaultAssets) deficit = vaultAssets;
            _withdrawFromVault(deficit);
        }
    }

    function _ensureLocalLiquidity(uint256 amount) internal {
        uint256 localCash = super.getCashPrior();
        if (localCash >= amount) return;

        uint256 deficit = amount - localCash;
        _withdrawFromVault(deficit);

        uint256 newCash = super.getCashPrior();
        require(newCash >= amount, "FolksBoosted: insufficient liquidity");
    }

    function _depositToVault(uint256 amount) internal {
        if (amount == 0 || vaultPaused) return;
        IERC20(underlying).forceApprove(address(folksVault), amount);
        uint256 shares = folksVault.deposit(amount, address(this));
        emit VaultDeposited(amount, shares);
    }

    function _withdrawFromVault(uint256 amount) internal returns (uint256 withdrawn) {
        if (amount == 0) return 0;
        uint256 maxAvailable = _vaultWithdrawable();
        require(maxAvailable >= amount, "FolksBoosted: vault shortfall");
        withdrawn = folksVault.withdraw(amount, address(this), address(this));
        emit VaultWithdrawn(amount, withdrawn);
    }

    function _vaultAssets() internal view returns (uint256) {
        uint256 shares = folksVault.balanceOf(address(this));
        if (shares == 0) return 0;
        return folksVault.convertToAssets(shares);
    }

    function _vaultWithdrawable() internal view returns (uint256) {
        try folksVault.maxWithdraw(address(this)) returns (uint256 amount) {
            if (amount > 0) return amount;
            return _vaultAssets();
        } catch {
            return _vaultAssets();
        }
    }
}
