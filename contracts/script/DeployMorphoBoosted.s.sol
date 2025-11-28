// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/boosted/MorphoBoostedPErc20.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Example deployment script for a Morpho-boosted market on Monad.
contract DeployMorphoBoosted is Script {
    function run() external {
        address underlying = vm.envAddress("UNDERLYING");
        address comptroller = vm.envAddress("PERIDOTTROLLER");
        address irm = vm.envAddress("INTEREST_RATE_MODEL");
        address vault = vm.envAddress("MORPHO_VAULT");
        address admin = vm.envAddress("ADMIN");

        uint256 initialExchangeRate = vm.envOr("INITIAL_EXCHANGE_RATE", uint256(1e18));
        uint256 bufferMantissa = vm.envOr("VAULT_BUFFER_MANTISSA", uint256(1e17)); // default 10%
        uint256 minSeedShares = vm.envOr("MORPHO_VAULT_MIN_SEED", uint256(1e9)); // Morpho vault dead-address seed

        string memory name = vm.envOr("PTOKEN_NAME", string("Peridot Morpho Vault"));
        string memory symbol = vm.envOr("PTOKEN_SYMBOL", string("pmVault"));

        vm.startBroadcast();

        MorphoBoostedPErc20 pToken = new MorphoBoostedPErc20(
            underlying,
            PeridottrollerInterface(comptroller),
            InterestRateModel(irm),
            initialExchangeRate,
            name,
            symbol,
            IERC20Metadata(underlying).decimals(),
            payable(admin),
            IERC4626(vault),
            bufferMantissa,
            minSeedShares
        );

        console2.log("MorphoBoostedPErc20 deployed at:", address(pToken));
        vm.stopBroadcast();
    }
}
