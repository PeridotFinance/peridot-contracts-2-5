// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "../PErc20Delegate.sol";
import "../PeridottrollerInterface.sol";
import "../InterestRateModel.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PancakeBoostedDelegate
 * @notice Compound-style delegate for a PancakeSwap V3 LP vault-backed market.
 * @dev The underlying for this pToken is the V3LPVault4626 share token.
 *      Users first deposit into the V3LPVault4626 to get shares, then supply
 *      those shares here to get pTokens and earn additional lending yield.
 *
 *      This contract does NOT route liquidity into any secondary vault since
 *      the underlying already IS a vault share. It's essentially a standard
 *      PErc20Delegate with additional view helpers for the underlying vault.
 *
 *      Inflation Protection: The vault must have a minimum seed deposited to
 *      a dead address to prevent share inflation attacks.
 */
contract PancakeBoostedDelegate is PErc20Delegate {
    using SafeERC20 for IERC20;

    /// @notice Dead address for inflation protection seed validation.
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice The V3LPVault4626 whose shares are the underlying of this pToken.
    /// @dev Stored in delegate storage (not immutable) since this is used via proxy.
    IERC4626 public lpVault;

    /// @notice Minimum vault shares that must be held by DEAD_ADDRESS for inflation protection.
    uint256 public minVaultSeed;

    // ========== EVENTS ==========

    event LPVaultSet(address indexed vault, uint256 minSeed);
    event VaultInfoQueried(uint256 totalAssets, uint256 totalSupply);

    // ========== INITIALIZATION ==========

    /**
     * @notice Called when becoming the implementation for a delegator.
     * @dev Decodes lpVault address and minVaultSeed from becomeImplementationData.
     */
    function _becomeImplementation(bytes memory data) public override {
        require(msg.sender == admin, "only admin");
        if (data.length > 0) {
            (address vault_, uint256 minSeed_) = abi.decode(data, (address, uint256));
            if (vault_ != address(0)) {
                _setLPVaultInternal(vault_, minSeed_);
            }
        }
    }

    /**
     * @notice Admin function to set the LP vault (for post-deployment setup or changes).
     * @param vault_ The V3LPVault4626 address.
     * @param minSeed_ Minimum vault shares required at DEAD_ADDRESS (0 to skip check).
     */
    function _setLPVault(address vault_, uint256 minSeed_) external {
        require(msg.sender == admin, "only admin");
        require(vault_ != address(0), "zero vault");
        _setLPVaultInternal(vault_, minSeed_);
    }

    /**
     * @notice Internal function to set LP vault with validation.
     */
    function _setLPVaultInternal(address vault_, uint256 minSeed_) internal {
        // Validate that vault_ is an ERC4626
        IERC4626 vault = IERC4626(vault_);
        
        // Validate inflation protection seed if required
        if (minSeed_ > 0) {
            uint256 deadBalance = IERC20(vault_).balanceOf(DEAD_ADDRESS);
            require(deadBalance >= minSeed_, "vault seed missing");
        }

        lpVault = vault;
        minVaultSeed = minSeed_;

        emit LPVaultSet(vault_, minSeed_);
    }

    /**
     * @notice Extended initialize for delegate storage.
     * @dev Called via delegator's constructor through delegatecall.
     */
    function initialize(
        address underlying_,
        PeridottrollerInterface peridottroller_,
        InterestRateModel interestRateModel_,
        uint256 initialExchangeRateMantissa_,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address lpVault_,
        uint256 minVaultSeed_
    ) public {
        require(accrualBlockNumber == 0 && borrowIndex == 0, "already init");

        // Set admin temporarily for initialization
        admin = payable(msg.sender);

        // Set LP vault
        if (lpVault_ != address(0)) {
            _setLPVaultInternal(lpVault_, minVaultSeed_);
        }

        // Initialize base PErc20
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

    // ========== VIEW HELPERS ==========

    /**
     * @notice Returns the total assets managed by the underlying vault.
     * @dev This is the token0-equivalent value of all LP positions.
     */
    function vaultTotalAssets() external view returns (uint256) {
        require(address(lpVault) != address(0), "vault not set");
        return lpVault.totalAssets();
    }

    /**
     * @notice Returns the total supply of vault shares.
     */
    function vaultTotalSupply() external view returns (uint256) {
        require(address(lpVault) != address(0), "vault not set");
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
        require(address(lpVault) != address(0), "vault not set");
        return lpVault.convertToAssets(shares);
    }

    /**
     * @notice Converts underlying asset value to vault shares.
     * @param assets The token0-equivalent value.
     * @return shares Amount of vault shares.
     */
    function convertAssetsToVaultShares(uint256 assets) external view returns (uint256 shares) {
        require(address(lpVault) != address(0), "vault not set");
        return lpVault.convertToShares(assets);
    }

    /**
     * @notice Returns the address of the underlying V3 pool (if available).
     */
    function underlyingPool() external view returns (address) {
        if (address(lpVault) == address(0)) return address(0);
        
        // Try to call pool() on the vault - may revert if not a V3LPVault4626
        try IV3LPVault4626Minimal(address(lpVault)).pool() returns (address poolAddr) {
            return poolAddr;
        } catch {
            return address(0);
        }
    }

    /**
     * @notice Returns the two tokens in the underlying V3 LP position.
     */
    function underlyingTokens() external view returns (address token0, address token1) {
        if (address(lpVault) == address(0)) return (address(0), address(0));
        
        try IV3LPVault4626Extended(address(lpVault)).token0() returns (address t0) {
            token0 = t0;
        } catch {
            return (address(0), address(0));
        }
        
        try IV3LPVault4626Extended(address(lpVault)).token1() returns (address t1) {
            token1 = t1;
        } catch {
            return (token0, address(0));
        }
    }

    /**
     * @notice Returns the managed token amounts in the underlying vault.
     */
    function vaultManagedAmounts() external view returns (uint256 amount0, uint256 amount1) {
        if (address(lpVault) == address(0)) return (0, 0);
        
        try IV3LPVault4626Extended(address(lpVault)).totalManagedToken0() returns (uint256 a0) {
            amount0 = a0;
        } catch {}
        
        try IV3LPVault4626Extended(address(lpVault)).totalManagedToken1() returns (uint256 a1) {
            amount1 = a1;
        } catch {}
    }

    /**
     * @notice Returns the current tick range of the LP position.
     */
    function vaultTickRange() external view returns (int24 tickLower, int24 tickUpper) {
        if (address(lpVault) == address(0)) return (0, 0);
        
        try IV3LPVault4626Extended(address(lpVault)).tickLower() returns (int24 tl) {
            tickLower = tl;
        } catch {}
        
        try IV3LPVault4626Extended(address(lpVault)).tickUpper() returns (int24 tu) {
            tickUpper = tu;
        } catch {}
    }
}

/**
 * @dev Minimal interface for V3LPVault4626 pool() function.
 */
interface IV3LPVault4626Minimal {
    function pool() external view returns (address);
}

/**
 * @dev Extended interface for V3LPVault4626 view functions.
 */
interface IV3LPVault4626Extended {
    function pool() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalManagedToken0() external view returns (uint256);
    function totalManagedToken1() external view returns (uint256);
    function tickLower() external view returns (int24);
    function tickUpper() external view returns (int24);
}

