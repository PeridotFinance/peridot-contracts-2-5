// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {QuickSwapV4RouterAdapter} from "../contracts/margin/QuickSwapV4RouterAdapter.sol";

contract DeployQuickSwapV4MarginAdapter is Script {
    struct PairConfig {
        address token0;
        address token1;
        address deployer;
        bool allowed;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address router = vm.envAddress("QS_ROUTER");
        address factory = vm.envAddress("QS_FACTORY");
        address ownerOverride = _tryEnvAddress("QS_OWNER");
        address owner = ownerOverride != address(0) ? ownerOverride : vm.addr(deployerKey);
        address manager = _tryEnvAddress("QS_MANAGER");

        uint256 deadlineBuffer = _tryEnvUint("QS_DEADLINE_BUFFER");
        if (deadlineBuffer == 0) deadlineBuffer = 300;

        bool whitelistEnforced = _tryEnvBool("QS_WHITELIST_ENFORCED", true);

        PairConfig[] memory pairs = _loadPairs();
        address[] memory operators = _loadOperators();

        console.log("Deploying QuickSwapV4RouterAdapter");
        console.log("  Router:", router);
        console.log("  Factory:", factory);
        console.log("  Owner:", owner);
        console.log("  Manager:", manager);
        console.log("  Deadline buffer:", deadlineBuffer);
        console.log("  Whitelist enforced:", whitelistEnforced);

        vm.startBroadcast(deployerKey);

        QuickSwapV4RouterAdapter adapter = new QuickSwapV4RouterAdapter(owner, router, factory);
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

        for (uint256 i = 0; i < pairs.length; i++) {
            PairConfig memory pair = pairs[i];
            adapter.setPairConfig(pair.token0, pair.token1, pair.deployer, pair.allowed);
            console.log("Pair whitelist set token0:", pair.token0);
            console.log("  token1:", pair.token1);
            console.log("  deployer:", pair.deployer);
            console.log("  allowed:", pair.allowed);
        }

        vm.stopBroadcast();
    }

    function _loadPairs() internal view returns (PairConfig[] memory) {
        uint256 count = _tryEnvUint("QS_PAIR_COUNT");
        if (count == 0) return new PairConfig[](0);
        PairConfig[] memory pairs = new PairConfig[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory prefix = string.concat("QS_PAIR_", vm.toString(i), "_");
            pairs[i] = PairConfig({
                token0: vm.envAddress(string.concat(prefix, "TOKEN0")),
                token1: vm.envAddress(string.concat(prefix, "TOKEN1")),
                deployer: _tryEnvAddress(string.concat(prefix, "DEPLOYER")),
                allowed: _tryEnvBool(string.concat(prefix, "ALLOWED"), true)
            });
        }
        return pairs;
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
