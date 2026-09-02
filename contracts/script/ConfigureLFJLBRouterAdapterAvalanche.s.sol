// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {LFJLBRouterAdapter} from "../contracts/margin/LFJLBRouterAdapter.sol";

/**
 * @notice Queues or executes the isolated-margin operator and one LFJ route on Avalanche Fuji.
 * @dev Queue after the margin stack is deployed, wait adapter.actionDelay(), then execute.
 *      Use MARGIN_DEPLOYER with Forge's --account and --sender options; never export a raw private key.
 */
contract ConfigureLFJLBRouterAdapterAvalanche is Script {
    using SafeCast for uint256;

    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;

    function run() external returns (bytes32 operatorActionId, bytes32 routeActionId) {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "ConfigureLFJAdapter: Fuji only");
        address deployer = vm.envAddress("MARGIN_DEPLOYER");
        LFJLBRouterAdapter adapter = LFJLBRouterAdapter(vm.envAddress("LFJ_MARGIN_ADAPTER"));
        address operator = vm.envAddress("ISOLATED_MARGIN_SWAP_MODULE");
        address tokenA = vm.envAddress("LFJ_TOKEN_A");
        address tokenB = vm.envAddress("LFJ_TOKEN_B");
        uint256 binStep = vm.envUint("LFJ_BIN_STEP");
        uint8 version = vm.envUint("LFJ_VERSION").toUint8();
        bool allowed = vm.envOr("LFJ_ROUTE_ALLOWED", true);

        require(deployer != address(0), "ConfigureLFJAdapter: zero deployer");
        require(address(adapter).code.length > 0, "ConfigureLFJAdapter: adapter not contract");
        require(adapter.owner() == deployer, "ConfigureLFJAdapter: broadcaster not owner");
        require(operator.code.length > 0, "ConfigureLFJAdapter: operator not contract");

        operatorActionId = keccak256(abi.encode("operator", operator, true));
        routeActionId = keccak256(abi.encode("route", adapter.routeKey(tokenA, tokenB, binStep, version), allowed));

        vm.startBroadcast(deployer);
        if (vm.envOr("EXECUTE", false)) {
            adapter.setOperator(operator, true);
            adapter.setRoute(tokenA, tokenB, binStep, version, allowed);
            console2.log("Executed LFJ operator and route actions");
        } else {
            adapter.queueOperator(operator, true);
            adapter.queueRoute(tokenA, tokenB, binStep, version, allowed);
            console2.log("Queued LFJ operator and route actions");
            console2.log("Execute operator after", adapter.queuedActions(operatorActionId));
            console2.log("Execute route after", adapter.queuedActions(routeActionId));
        }
        vm.stopBroadcast();

        console2.logBytes32(operatorActionId);
        console2.logBytes32(routeActionId);
    }
}
