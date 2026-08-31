// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PErc20Delegate} from "../PErc20Delegate.sol";

/**
 * @title PharaohBoostedDelegate
 * @notice Delegate implementation for a market whose underlying is a Pharaoh ERC-4626 vault share.
 * @dev The vault share itself is the market underlying. The pToken does not deposit USDC/WAVAX into
 *      the vault, so Pharaoh entry and exit slippage is borne by the account entering or exiting the
 *      vault rather than being socialized across the lending market.
 *
 *      The vault is pinned to `underlying` when the implementation is installed. Conservative vault
 *      accounting and USD conversion are handled by PharaohVaultShareOracle.
 */
contract PharaohBoostedDelegate is PErc20Delegate {
    IERC4626 public pharaohVault;
    uint256 public minimumVaultSupplyAtListing;

    error PharaohBoosted__InvalidConfiguration();
    error PharaohBoosted__InvalidVault();
    error PharaohBoosted__InsufficientVaultSeed();

    event PharaohVaultConfigured(address indexed vault, address indexed asset, uint256 minimumVaultSupply);

    /**
     * @notice Pins and validates the Pharaoh vault when this implementation is installed.
     * @param data ABI encoding of `(address vault, uint256 minimumVaultSupply)`.
     */
    function _becomeImplementation(bytes memory data) public override {
        if (msg.sender != admin) revert PharaohBoosted__InvalidConfiguration();
        if (data.length == 0) revert PharaohBoosted__InvalidConfiguration();

        (address vaultAddress, uint256 minimumVaultSupply) = abi.decode(data, (address, uint256));
        _configureVault(vaultAddress, minimumVaultSupply);
    }

    function vaultAsset() external view returns (address) {
        return pharaohVault.asset();
    }

    function vaultTotalAssets() external view returns (uint256) {
        return pharaohVault.totalAssets();
    }

    function vaultTotalSupply() external view returns (uint256) {
        return pharaohVault.totalSupply();
    }

    function vaultAssetsPerWholeShare() external view returns (uint256) {
        return pharaohVault.convertToAssets(10 ** IERC20Metadata(address(pharaohVault)).decimals());
    }

    function _configureVault(address vaultAddress, uint256 minimumVaultSupply) private {
        if (
            vaultAddress == address(0) || vaultAddress != underlying || vaultAddress.code.length == 0
                || minimumVaultSupply == 0
        ) revert PharaohBoosted__InvalidConfiguration();

        IERC4626 vault = IERC4626(vaultAddress);
        address asset;
        uint8 shareDecimals;
        uint256 vaultSupply;

        try vault.asset() returns (address returnedAsset) {
            asset = returnedAsset;
        } catch {
            revert PharaohBoosted__InvalidVault();
        }
        if (asset == address(0) || asset.code.length == 0) revert PharaohBoosted__InvalidVault();

        try IERC20Metadata(vaultAddress).decimals() returns (uint8 returnedDecimals) {
            shareDecimals = returnedDecimals;
        } catch {
            revert PharaohBoosted__InvalidVault();
        }
        if (shareDecimals > 18) revert PharaohBoosted__InvalidVault();

        try vault.totalSupply() returns (uint256 returnedSupply) {
            vaultSupply = returnedSupply;
        } catch {
            revert PharaohBoosted__InvalidVault();
        }
        if (vaultSupply < minimumVaultSupply) revert PharaohBoosted__InsufficientVaultSeed();

        try vault.convertToAssets(10 ** shareDecimals) returns (uint256 assetsPerWholeShare) {
            if (assetsPerWholeShare == 0) revert PharaohBoosted__InvalidVault();
        } catch {
            revert PharaohBoosted__InvalidVault();
        }

        pharaohVault = vault;
        minimumVaultSupplyAtListing = minimumVaultSupply;
        emit PharaohVaultConfigured(vaultAddress, asset, minimumVaultSupply);
    }
}
