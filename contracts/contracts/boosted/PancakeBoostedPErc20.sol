// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20.sol";
import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PancakeBoostedPErc20
 * @notice pToken wrapper for V3LPVault4626 share tokens.
 * @dev The underlying for this pToken is the vault share token itself.
 *      Users first deposit into the V3LPVault4626 to get shares, then supply
 *      those shares here to get pTokens and earn additional yield.
 *
 *      This contract does NOT route liquidity into any secondary vault since
 *      the underlying already IS a vault share. It's essentially a standard
 *      PErc20 with additional view helpers for the underlying vault.
 *
 *      Inflation Protection: The vault must have a minimum seed deposited to
 *      a dead address to prevent share inflation attacks.
 */
contract PancakeBoostedPErc20 is PErc20 {
    using SafeERC20 for IERC20;

    /// @notice Dead address for inflation protection seed validation.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The V3LPVault4626 whose shares are the underlying of this pToken.
    IERC4626 public immutable lpVault;

    /// @notice Minimum vault shares that must be held by DEAD_ADDRESS for inflation protection.
    uint256 public immutable minVaultSeed;

    event VaultInfoQueried(uint256 totalAssets, uint256 totalSupply);

    /**
     * @param underlying_ The vault share token address (same as vault address for ERC4626).
     * @param peridottroller_ The Peridottroller address.
     * @param interestRateModel_ The interest rate model address.
     * @param initialExchangeRateMantissa_ Initial exchange rate (scaled by 1e18).
     * @param name_ ERC20 name for the pToken.
     * @param symbol_ ERC20 symbol for the pToken.
     * @param decimals_ ERC20 decimals for the pToken.
     * @param admin_ Admin address for the pToken.
     * @param minVaultSeed_ Minimum vault shares required at DEAD_ADDRESS (0 to skip check).
     */
    constructor(
        address underlying_,
        PeridottrollerInterface peridottroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address payable admin_,
        uint256 minVaultSeed_
    ) {
        // Validate that underlying is an ERC4626 vault
        lpVault = IERC4626(underlying_);
        require(address(lpVault) != address(0), "PancakeBoosted: vault zero");
        try lpVault.asset() returns (address asset_) {
            require(asset_ != address(0), "PancakeBoosted: vault asset zero");
        } catch {
            revert("PancakeBoosted: non-ERC4626");
        }

        // Validate inflation protection seed if required
        if (minVaultSeed_ > 0) {
            uint256 deadBalance = IERC20(underlying_).balanceOf(DEAD_ADDRESS);
            require(deadBalance >= minVaultSeed_, "PancakeBoosted: vault seed missing");
        }
        minVaultSeed = minVaultSeed_;

        // Temporary admin for initialization
        admin = payable(msg.sender);

        // Initialize the PErc20 base
        initialize(
            underlying_, peridottroller_, interestRateModel_, initialExchangeRateMantissa_, name_, symbol_, decimals_
        );

        // Transfer admin rights to the designated address
        admin = admin_;
    }

    // ========== VIEW HELPERS ==========

    /**
     * @notice Returns the total assets managed by the underlying vault.
     * @dev This is the token0-equivalent value of all LP positions.
     */
    function vaultTotalAssets() external view returns (uint256) {
        return lpVault.totalAssets();
    }

    /**
     * @notice Returns the total supply of vault shares.
     */
    function vaultTotalSupply() external view returns (uint256) {
        return lpVault.totalSupply();
    }

    /**
     * @notice Returns the vault share balance held by this pToken contract.
     * @dev This is the "cash" available for borrows/redemptions.
     */
    function vaultSharesHeld() external view returns (uint256) {
        return IERC20(underlying).balanceOf(address(this));
    }

    /**
     * @notice Converts vault shares to their underlying asset value.
     * @param shares Amount of vault shares.
     * @return assets The token0-equivalent value.
     */
    function convertVaultSharesToAssets(uint256 shares) external view returns (uint256 assets) {
        return lpVault.convertToAssets(shares);
    }

    /**
     * @notice Converts underlying asset value to vault shares.
     * @param assets The token0-equivalent value.
     * @return shares Amount of vault shares.
     */
    function convertAssetsToVaultShares(uint256 assets) external view returns (uint256 shares) {
        return lpVault.convertToShares(assets);
    }

    /**
     * @notice Returns the address of the underlying V3 pool (if available).
     */
    function underlyingPool() external view returns (address) {
        // Try to call pool() on the vault - may revert if not a V3LPVault4626
        try IV3LPVault4626Minimal(address(lpVault)).pool() returns (address poolAddr) {
            return poolAddr;
        } catch {
            return address(0);
        }
    }
}

/**
 * @dev Minimal interface for V3LPVault4626 pool() function.
 */
interface IV3LPVault4626Minimal {
    function pool() external view returns (address);
}
