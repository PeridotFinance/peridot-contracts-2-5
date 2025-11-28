// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20.sol";
import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Pancake-boosted pToken
 * @notice Wraps an ERC4626 LP vault (e.g., V3LPVault4626 share token) to integrate with Peridot markets.
 * @dev The underlying for this pToken is the vault share token itself; buffer and pause logic mirror other boosted markets.
 */
contract PancakeBoostedPErc20 is PErc20 {
    using SafeERC20 for IERC20;

    uint256 internal constant MANTISSA_ONE = 1e18;

    /// @notice ERC4626 vault whose shares are the underlying of this pToken.
    IERC4626 public immutable lpVault;

    /// @notice Fraction of total managed shares to keep idle on the pToken (scaled by 1e18).
    uint256 public vaultBufferMantissa;

    /// @notice When true, deposits are paused and shares are pulled back.
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
        require(address(vault_) != address(0), "PancakeBoosted: vault zero");
        require(vault_.asset() == underlying_, "PancakeBoosted: asset mismatch");

        // Temporary admin for initialization
        admin = payable(msg.sender);
        lpVault = vault_;

        initialize(
            underlying_, peridottroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_
        );

        _setVaultBufferInternal(vaultBufferMantissa_);

        // Transfer admin rights to the designated address
        admin = admin_;
    }

    function setVaultBufferMantissa(uint256 newMantissa) external {
        require(msg.sender == admin, "PancakeBoosted: only admin");
        _setVaultBufferInternal(newMantissa);
        _rebalanceVault();
    }

    function setVaultPaused(bool pause) external {
        require(msg.sender == admin, "PancakeBoosted: only admin");
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
        require(newMantissa <= MANTISSA_ONE, "PancakeBoosted: invalid buffer");
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
        require(newCash >= amount, "PancakeBoosted: insufficient liquidity");
    }

    function _depositToVault(uint256 amount) internal {
        if (amount == 0 || vaultPaused) return;
        IERC20(underlying).forceApprove(address(lpVault), amount);
        uint256 shares = lpVault.deposit(amount, address(this));
        emit VaultDeposited(amount, shares);
    }

    function _withdrawFromVault(uint256 amount) internal returns (uint256 withdrawn) {
        if (amount == 0) return 0;
        uint256 maxAvailable = _vaultWithdrawable();
        require(maxAvailable >= amount, "PancakeBoosted: vault shortfall");
        withdrawn = lpVault.withdraw(amount, address(this), address(this));
        emit VaultWithdrawn(amount, withdrawn);
    }

    function _vaultAssets() internal view returns (uint256) {
        uint256 shares = lpVault.balanceOf(address(this));
        if (shares == 0) return 0;
        return lpVault.convertToAssets(shares);
    }

    function _vaultWithdrawable() internal view returns (uint256) {
        try lpVault.maxWithdraw(address(this)) returns (uint256 amount) {
            return amount;
        } catch {
            return _vaultAssets();
        }
    }
}
