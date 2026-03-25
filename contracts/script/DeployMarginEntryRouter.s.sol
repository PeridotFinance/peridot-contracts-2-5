// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {MarginEntryRouter} from "../contracts/margin/MarginEntryRouter.sol";

contract DeployMarginEntryRouter is Script {
    function run() external returns (MarginEntryRouter router) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address executor = vm.envAddress("MARGIN_EXECUTOR");
        address collateralVault = vm.envAddress("MARGIN_COLLATERAL_VAULT");
        address owner = vm.envOr("MARGIN_ENTRY_ROUTER_OWNER", vm.addr(deployerKey));

        vm.startBroadcast(deployerKey);
        router = new MarginEntryRouter(executor, collateralVault, owner);
        vm.stopBroadcast();

        console2.log("MarginEntryRouter deployed:", address(router));
        console2.log("Executor:", executor);
        console2.log("CollateralVault:", collateralVault);
        console2.log("Owner:", owner);
    }
}
