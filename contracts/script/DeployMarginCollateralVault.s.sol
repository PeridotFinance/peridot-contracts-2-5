// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {MarginCollateralVault} from "../contracts/margin/MarginCollateralVault.sol";

contract DeployMarginCollateralVault is Script {
    function run() external returns (MarginCollateralVault vault) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address executor = vm.envAddress("MARGIN_EXECUTOR");
        address owner = vm.envOr("MARGIN_COLLATERAL_VAULT_OWNER", vm.addr(deployerKey));

        uint256 allowedCount = vm.envOr("MARGIN_COLLATERAL_ALLOWED_COUNT", uint256(0));

        vm.startBroadcast(deployerKey);

        vault = new MarginCollateralVault(executor, owner);
        console2.log("MarginCollateralVault deployed:", address(vault));
        console2.log("Executor:", executor);
        console2.log("Owner:", owner);

        for (uint256 i = 0; i < allowedCount; i++) {
            address pToken = vm.envAddress(string.concat("MARGIN_COLLATERAL_ALLOWED_", vm.toString(i)));
            vault.setPTokenAllowed(pToken, true);
            console2.log("Allowed pToken:", pToken);
        }

        vm.stopBroadcast();
    }
}
