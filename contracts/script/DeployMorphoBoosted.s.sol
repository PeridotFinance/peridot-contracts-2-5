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
        address underlying = 0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a;
        address comptroller = 0x6D208789f0a978aF789A3C8Ba515749598940716;
        address irm = 0x5710017eCdF44f39b5Ae885965140726B7d81099;
        address vault = 0xbeeffeA75cFC4128ebe10C8D7aE22016D215060D;
        address admin = 0xCED23360932B80d18fdEAEAa573202E80A584804;

        uint256 initialExchangeRate = 2e14;
        uint256 bufferMantissa = 0; // 0% buffer; set >0 to keep idle underlying
        uint256 minSeedShares = vm.envOr("MORPHO_VAULT_MIN_SEED", uint256(1e9)); // Morpho vault dead-address seed

        string memory name = "Peridot Morpho Steakhouse High Yield AUSD";
        string memory symbol = "pbbqAUSD";

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
