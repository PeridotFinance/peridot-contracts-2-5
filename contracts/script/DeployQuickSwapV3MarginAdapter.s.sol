// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {QuickSwapV3RouterAdapter} from "../contracts/margin/QuickSwapV3RouterAdapter.sol";

contract DeployQuickSwapV3MarginAdapter is Script {
    struct PoolConfig {
        address token0;
        address token1;
        uint16 fee;
        bool allowed;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address router = vm.envAddress("QS_ROUTER");
        address ownerOverride = _tryEnvAddress("QS_OWNER");
        address owner = ownerOverride != address(0) ? ownerOverride : vm.addr(deployerKey);
        address manager = _tryEnvAddress("QS_MANAGER");

        uint256 deadlineBuffer = _tryEnvUint("QS_DEADLINE_BUFFER");
        if (deadlineBuffer == 0) deadlineBuffer = 300;

        bool whitelistEnforced = _tryEnvBool("QS_WHITELIST_ENFORCED", true);

        PoolConfig[] memory pools = _loadPoolConfigs();
        address[] memory operators = _loadOperators();

        console.log("Deploying QuickSwapV3RouterAdapter");
        console.log("  Router:", router);
        console.log("  Owner:", owner);
        console.log("  Manager:", manager);
        console.log("  Deadline buffer:", deadlineBuffer);
        console.log("  Whitelist enforced:", whitelistEnforced);

        vm.startBroadcast(deployerKey);

        QuickSwapV3RouterAdapter adapter = new QuickSwapV3RouterAdapter(owner, router);
        console.log("Adapter deployed:", address(adapter));

        adapter.setDeadlineBuffer(deadlineBuffer);
        adapter.setWhitelistEnforced(whitelistEnforced);

        if (manager != address(0)) {
            adapter.setManager(manager);
            adapter.setOperator(manager, true);
            console.log("Manager set + operator:", manager);
        }

        for (uint256 i = 0; i < operators.length; i++) {
            adapter.setOperator(operators[i], true);
            console.log("Operator added:", operators[i]);
        }

        for (uint256 i = 0; i < pools.length; i++) {
            PoolConfig memory pool = pools[i];
            adapter.setPoolWhitelist(pool.token0, pool.token1, pool.fee, pool.allowed);
            console.log("Pool whitelist set token0:", pool.token0);
            console.log("  token1:", pool.token1);
            console.log("  fee:", uint256(pool.fee));
            console.log("  allowed:", pool.allowed);
        }

        vm.stopBroadcast();
    }

    function _loadPoolConfigs() internal view returns (PoolConfig[] memory) {
        uint256 count = _tryEnvUint("QS_POOL_COUNT");
        if (count == 0) return new PoolConfig[](0);
        PoolConfig[] memory pools = new PoolConfig[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory prefix = string.concat("QS_POOL_", vm.toString(i), "_");
            pools[i] = PoolConfig({
                token0: vm.envAddress(string.concat(prefix, "TOKEN0")),
                token1: vm.envAddress(string.concat(prefix, "TOKEN1")),
                fee: uint16(vm.envUint(string.concat(prefix, "FEE"))),
                allowed: _tryEnvBool(string.concat(prefix, "ALLOWED"), true)
            });
        }
        return pools;
    }

    function _loadOperators() internal view returns (address[] memory) {
        uint256 count = _tryEnvUint("QS_OPERATOR_COUNT");
        if (count == 0) return new address[](0);
        address[] memory ops = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory key = string.concat("QS_OPERATOR_", vm.toString(i));
            ops[i] = vm.envAddress(key);
        }
        return ops;
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

    function _tryEnvBool(string memory key, bool fallbackValue) internal view returns (bool) {
        try vm.envBool(key) returns (bool value) {
            return value;
        } catch {
            return fallbackValue;
        }
    }
}
