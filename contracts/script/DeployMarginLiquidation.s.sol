// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {MarginLiquidation} from "../contracts/margin/MarginLiquidation.sol";

contract DeployMarginLiquidation is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address manager = vm.envAddress("MARGIN_MANAGER");

        address ownerOverride = _tryEnvAddress("LIQ_OWNER");
        address owner = ownerOverride != address(0)
            ? ownerOverride
            : vm.addr(deployerKey);

        address[] memory adaptersToAllow = _loadAllowedAdapters();

        console.log("Deploying MarginLiquidation with manager:", manager);
        console.log("Owner:", owner);

        vm.startBroadcast(deployerKey);

        MarginLiquidation liquidation = new MarginLiquidation(manager, owner);
        console.log("MarginLiquidation deployed:", address(liquidation));

        for (uint256 i = 0; i < adaptersToAllow.length; i++) {
            liquidation.setAdapter(adaptersToAllow[i], true);
            console.log("  Adapter allowed:", adaptersToAllow[i]);
        }

        vm.stopBroadcast();
    }

    function _loadAllowedAdapters() internal view returns (address[] memory) {
        uint256 count = _tryEnvUint("LIQUIDATION_ALLOWED_ADAPTER_COUNT");
        if (count == 0) {
            return new address[](0);
        }
        address[] memory adapters = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            string memory key = string.concat(
                "LIQUIDATION_ALLOWED_ADAPTER_",
                vm.toString(i)
            );
            adapters[i] = vm.envAddress(key);
        }
        return adapters;
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
}
