// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../contracts/boosted/PancakeBoostedPErc20.sol";
import "../contracts/PeridottrollerInterface.sol";
import "../contracts/InterestRateModel.sol";
import {IERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Deployment script for a Pancake LP boosted pToken (wraps an ERC4626 LP vault share token).
contract DeployPancakeBoosted is Script {
    function run() external {
        address shareToken = vm.envAddress("UNDERLYING"); // the ERC4626 share token (e.g., V3LPVault4626)
        address comptroller = vm.envAddress("PERIDOTTROLLER");
        address irm = vm.envAddress("INTEREST_RATE_MODEL");
        address vault = vm.envAddress("LP_VAULT"); // the same ERC4626 vault whose shares are underlying
        address admin = vm.envAddress("ADMIN");

        uint256 initialExchangeRate = vm.envOr("INITIAL_EXCHANGE_RATE", uint256(1e18));
        uint256 bufferMantissa = vm.envOr("VAULT_BUFFER_MANTISSA", uint256(1e17)); // 10% buffer
        string memory name = vm.envOr("PTOKEN_NAME", string("Peridot Pancake Boosted"));
        string memory symbol = vm.envOr("PTOKEN_SYMBOL", string("ppBoost"));

        uint8 decimals = IERC20Metadata(shareToken).decimals();

        vm.startBroadcast();
        PancakeBoostedPErc20 pToken = new PancakeBoostedPErc20(
            shareToken,
            PeridottrollerInterface(comptroller),
            InterestRateModel(irm),
            initialExchangeRate,
            name,
            symbol,
            decimals,
            payable(admin),
            IERC4626(vault),
            bufferMantissa
        );
        console2.log("PancakeBoostedPErc20 deployed at:", address(pToken));
        vm.stopBroadcast();
    }
}
