// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {PancakeV3RouterAdapter} from "../contracts/margin/PancakeV3RouterAdapter.sol";

contract DeployPancakeV3MarginAdapter is Script {
    struct PoolConfig {
        address token0;
        address token1;
        uint24 fee;
        bool allowed;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address router = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
        address manager = _tryEnvAddress("MARGIN_MANAGER");
        address ownerOverride = 0xCED23360932B80d18fdEAEAa573202E80A584804;
        address owner = ownerOverride != address(0)
            ? ownerOverride
            : vm.addr(deployerKey);
        uint256 actionDelay = _tryEnvUint("ADAPTER_ACTION_DELAY");
        if (actionDelay == 0) {
            actionDelay = 1 days;
        }

        PoolConfig[] memory pools = _loadPoolConfigs();
        address[] memory operators = _loadOperators();

        console.log("Deploying PancakeV3RouterAdapter");
        console.log("  Router:", router);
        console.log("  Owner:", owner);

        vm.startBroadcast(deployerKey);

        PancakeV3RouterAdapter adapter = new PancakeV3RouterAdapter(owner, router, actionDelay);
        console.log("Adapter deployed:", address(adapter));
        console.log("Action delay:", actionDelay);

        if (manager != address(0)) {
            bytes32 actionId = adapter.queueSetManager(manager);
            console.log("  Manager queued:", manager);
            console.logBytes32(actionId);
        }

        for (uint256 i = 0; i < operators.length; i++) {
            bytes32 actionId = adapter.queueSetOperator(operators[i], true);
            console.log("  Operator queued:", operators[i]);
            console.logBytes32(actionId);
        }

        for (uint256 i = 0; i < pools.length; i++) {
            PoolConfig memory pool = pools[i];
            bytes32 actionId = adapter.queueSetPoolWhitelist(pool.token0, pool.token1, pool.fee, pool.allowed);
            console.log("  Pool whitelist queued token0:", pool.token0);
            console.log("    token1:", pool.token1);
            console.log("    fee:", uint256(pool.fee));
            console.log("    allowed:", pool.allowed);
            console.logBytes32(actionId);
        }

        vm.stopBroadcast();
    }

    function _loadPoolConfigs() internal view returns (PoolConfig[] memory) {
        uint256 count = _tryEnvUint("ADAPTER_POOL_COUNT");
        if (count == 0) {
            return new PoolConfig[](0);
        }
        PoolConfig[] memory pools = new PoolConfig[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory prefix = string.concat(
                "ADAPTER_POOL_",
                vm.toString(i),
                "_"
            );
            pools[i] = PoolConfig({
                token0: vm.envAddress(string.concat(prefix, "TOKEN0")),
                token1: vm.envAddress(string.concat(prefix, "TOKEN1")),
                fee: uint24(vm.envUint(string.concat(prefix, "FEE"))),
                allowed: _tryEnvBool(string.concat(prefix, "ALLOWED"), true)
            });
        }
        return pools;
    }

    function _loadOperators() internal view returns (address[] memory) {
        uint256 count = _tryEnvUint("ADAPTER_OPERATOR_COUNT");
        if (count == 0) {
            return new address[](0);
        }
        address[] memory operators = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory key = string.concat(
                "ADAPTER_OPERATOR_",
                vm.toString(i)
            );
            operators[i] = vm.envAddress(key);
        }
        return operators;
    }

    function _tryEnvAddress(string memory key) internal view returns (address) {
        try vm.envAddress(key) returns (address value) {
            return value;
        } catch {
            return address(0);
        }
    }

    function _tryEnvUint(string memory key) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 value) {
            return value;
        } catch {
            return 0;
        }
    }

    function _tryEnvBool(
        string memory key,
        bool fallbackValue
    ) internal view returns (bool) {
        try vm.envBool(key) returns (bool value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }
}
