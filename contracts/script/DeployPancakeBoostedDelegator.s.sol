// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../contracts/PErc20Delegator.sol";
import "../contracts/boosted/PancakeBoostedDelegate.sol";

/**
 * @title DeployPancakeBoostedDelegator
 * @notice Deploys the PancakeBoostedDelegate implementation and PErc20Delegator proxy.
 *
 * Usage:
 *   forge script script/DeployPancakeBoostedDelegator.s.sol \
 *     --rpc-url $MONAD_MAINNET_RPC_URL \
 *     --private-key $PRIVATE_KEY \
 *     --broadcast
 *
 * Required environment variables (or pass via --env-file):
 *   - VAULT_ADDRESS: The V3LPVault4626 address
 *   - PERIDOTTROLLER: The Peridottroller address
 *   - INTEREST_RATE_MODEL: The interest rate model address
 *
 * Optional:
 *   - ADMIN: Admin address (defaults to deployer)
 *   - MIN_VAULT_SEED: Minimum seed required at dead address (default: 1000)
 *   - INITIAL_EXCHANGE_RATE: Initial exchange rate mantissa (default: 2e26)
 *   - PTOKEN_NAME: Name for the pToken (default: "Peridot PancakeV3 LP Vault")
 *   - PTOKEN_SYMBOL: Symbol for the pToken (default: "pPCSv3LP")
 */
contract DeployPancakeBoostedDelegator is Script {
    // Monad Mainnet defaults
    address constant DEFAULT_PERIDOTTROLLER =
        0x6D208789f0a978aF789A3C8Ba515749598940716;
    address constant DEFAULT_IRM = 0x5710017eCdF44f39b5Ae885965140726B7d81099; // JumpRateModelBoosted

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // Required
        address vault = vm.envAddress("VAULT_ADDRESS");

        // Optional with defaults
        address peridottroller = _tryEnvAddress(
            "PERIDOTTROLLER",
            DEFAULT_PERIDOTTROLLER
        );
        address irm = _tryEnvAddress("INTEREST_RATE_MODEL", DEFAULT_IRM);
        address admin = _tryEnvAddress("ADMIN", deployer);

        uint256 minVaultSeed = vm.envOr("MIN_VAULT_SEED", uint256(1000));
        uint256 initialExchangeRate = vm.envOr(
            "INITIAL_EXCHANGE_RATE",
            uint256(2e26)
        );
        string memory name = vm.envOr(
            "PTOKEN_NAME",
            string("Peridot Pancake V3 AUSD/USDC 005")
        );
        string memory symbol = vm.envOr(
            "PTOKEN_SYMBOL",
            string("pPCSv3-AUSD/USDC-05")
        );
        uint8 decimals = 18;

        console2.log("=== Deploy PancakeBoosted Delegator ===");
        console2.log("Deployer:", deployer);
        console2.log("Admin:", admin);
        console2.log("Vault (underlying):", vault);
        console2.log("Peridottroller:", peridottroller);
        console2.log("Interest Rate Model:", irm);
        console2.log("Min Vault Seed:", minVaultSeed);
        console2.log("Name:", name);
        console2.log("Symbol:", symbol);

        vm.startBroadcast(deployerKey);

        // 1. Deploy the delegate implementation
        PancakeBoostedDelegate delegate = new PancakeBoostedDelegate();
        console2.log(
            "PancakeBoostedDelegate implementation:",
            address(delegate)
        );

        // 2. Encode becomeImplementation data (lpVault, minVaultSeed)
        bytes memory becomeImplData = abi.encode(vault, minVaultSeed);

        // 3. Deploy the delegator (proxy)
        PErc20Delegator delegator = new PErc20Delegator(
            vault, // underlying (vault shares)
            PeridottrollerInterface(peridottroller),
            InterestRateModel(irm),
            initialExchangeRate,
            name,
            symbol,
            decimals,
            payable(admin),
            address(delegate),
            becomeImplData
        );
        console2.log("PErc20Delegator (pToken proxy):", address(delegator));

        vm.stopBroadcast();

        // Verification info
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("Delegate Implementation:", address(delegate));
        console2.log("pToken (Delegator):", address(delegator));
        console2.log("");
        console2.log("=== Next Steps ===");
        console2.log("1. Support market in Peridottroller:");
        console2.log("   cast send", peridottroller);
        console2.log("   '_supportMarket(address)' ", address(delegator));
        console2.log("");
        console2.log("2. Set collateral factor:");
        console2.log("   cast send", peridottroller);
        console2.log(
            "   '_setCollateralFactor(address,uint256)'",
            address(delegator),
            "500000000000000000"
        );
        console2.log("");
        console2.log("3. Set reserve factor:");
        console2.log("   cast send", address(delegator));
        console2.log("   '_setReserveFactor(uint256)' 100000000000000000");
    }

    function _tryEnvAddress(
        string memory key,
        address defaultValue
    ) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            return val;
        } catch {
            return defaultValue;
        }
    }
}
