// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/boosted/PancakeBoostedPErc20.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Deployment script for a Pancake LP boosted pToken (wraps V3LPVault4626 share tokens).
/// @notice The underlying for this pToken is the vault share token itself.
///         Users first deposit into V3LPVault4626 to get shares, then supply those shares here.
contract DeployPancakeBoosted is Script {
    /// @dev Dead address used for inflation protection seed validation.
    address public constant DEAD_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // ===== MONAD MAINNET DEFAULTS =====
    address public constant DEFAULT_PERIDOTTROLLER =
        0x6D208789f0a978aF789A3C8Ba515749598940716;
    address public constant DEFAULT_INTEREST_RATE_MODEL =
        0x5710017eCdF44f39b5Ae885965140726B7d81099; // JumpRateModelBoosted

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Required: V3LPVault4626 address (must be deployed first)
        address vaultShareToken = vm.envAddress("UNDERLYING");

        // Optional with Monad defaults
        address comptroller = _tryEnvAddress(
            "PERIDOTTROLLER",
            DEFAULT_PERIDOTTROLLER
        );
        address irm = _tryEnvAddress(
            "INTEREST_RATE_MODEL",
            DEFAULT_INTEREST_RATE_MODEL
        );
        address admin = _tryEnvAddress("ADMIN", deployer);

        // Optional configuration
        string memory name = vm.envOr(
            "PTOKEN_NAME",
            string("Peridot Pancake V3 LP")
        );
        string memory symbol = vm.envOr("PTOKEN_SYMBOL", string("pPCSV3"));
        uint256 minVaultSeed = vm.envOr("MIN_VAULT_SEED", uint256(1000)); // minimum shares at DEAD_ADDRESS

        uint8 decimals = IERC20Metadata(vaultShareToken).decimals();
        // Standard initial exchange rate: 0.02 underlying per pToken
        // For 6 decimal underlying: 2e14, for 18 decimal: 2e26
        uint256 initialExchangeRate = decimals == 6 ? 2e14 : 2e26;

        // Log configuration
        console2.log("=== PancakeBoostedPErc20 Deployment ===");
        console2.log("Vault/Underlying:", vaultShareToken);
        console2.log("Comptroller:", comptroller);
        console2.log("Interest Rate Model:", irm);
        console2.log("Admin:", admin);
        console2.log("Name:", name);
        console2.log("Symbol:", symbol);
        console2.log("Decimals:", decimals);
        console2.log("Initial Exchange Rate:", initialExchangeRate);
        console2.log("Min Vault Seed:", minVaultSeed);

        // Validate vault seed if required
        if (minVaultSeed > 0) {
            uint256 deadBalance = IERC20(vaultShareToken).balanceOf(
                DEAD_ADDRESS
            );
            console2.log("Dead address balance:", deadBalance);
            require(
                deadBalance >= minVaultSeed,
                "Vault seed not deposited to dead address"
            );
        }

        vm.startBroadcast(deployerKey);

        PancakeBoostedPErc20 pToken = new PancakeBoostedPErc20(
            vaultShareToken,
            PeridottrollerInterface(comptroller),
            InterestRateModel(irm),
            initialExchangeRate,
            name,
            symbol,
            decimals,
            payable(admin),
            minVaultSeed
        );

        console2.log("=== Deployment Complete ===");
        console2.log("PancakeBoostedPErc20:", address(pToken));
        console2.log("Underlying (vault shares):", pToken.underlying());
        console2.log("LP Vault:", address(pToken.lpVault()));

        vm.stopBroadcast();
    }

    function _tryEnvAddress(
        string memory key,
        address fallback_
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return fallback_;
        }
    }
}
