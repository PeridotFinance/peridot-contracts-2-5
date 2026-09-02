// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {ILFJLBRouter, LFJLBRouterAdapter} from "../contracts/margin/LFJLBRouterAdapter.sol";

/**
 * @notice Deploys the timelocked LFJ Liquidity Book adapter on Avalanche Fuji.
 * @dev Use MARGIN_DEPLOYER with Forge's --account and --sender options; never export a raw private key.
 */
contract DeployLFJLBRouterAdapterAvalanche is Script {
    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;

    function run() external returns (LFJLBRouterAdapter adapter) {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "DeployLFJAdapter: Fuji only");
        address deployer = vm.envAddress("MARGIN_DEPLOYER");
        address owner = vm.envAddress("MARGIN_OWNER");
        address router = vm.envAddress("LFJ_LB_ROUTER");
        uint256 actionDelay = vm.envOr("MARGIN_ACTION_DELAY", uint256(24 hours));

        require(deployer != address(0), "DeployLFJAdapter: zero deployer");
        require(owner != address(0), "DeployLFJAdapter: zero owner");
        require(router.code.length > 0, "DeployLFJAdapter: router not contract");
        require(ILFJLBRouter(router).getWNATIVE().code.length > 0, "DeployLFJAdapter: WNATIVE not contract");

        vm.startBroadcast(deployer);
        adapter = new LFJLBRouterAdapter(owner, router, actionDelay);
        vm.stopBroadcast();

        console2.log("LFJ LB router", router);
        console2.log("LFJ margin adapter", address(adapter));
        console2.log("Adapter owner", owner);
        console2.log("Adapter actions remain timelocked and unconfigured");
    }
}
