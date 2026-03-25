// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";

contract DeploySimpleFlashLoanVault is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address ownerOverride = _tryEnvAddress("FLASH_VAULT_OWNER");
        address owner = ownerOverride != address(0)
            ? ownerOverride
            : vm.addr(deployerKey);

        uint256 feeBps = _tryEnvUint("FLASH_VAULT_FEE_BPS");
        if (feeBps == 0) feeBps = 5;

        uint256 tokenCount = _tryEnvUint("FLASH_VAULT_TOKEN_COUNT");

        vm.startBroadcast(deployerKey);

        SimpleFlashLoanVault vault = new SimpleFlashLoanVault(owner);
        console.log("SimpleFlashLoanVault deployed:", address(vault));

        if (feeBps != vault.feeBps()) {
            vault.setFeeBps(feeBps);
        }
        console.log("Fee bps:", feeBps);

        for (uint256 i = 0; i < tokenCount; i++) {
            string memory key = string.concat("FLASH_VAULT_TOKEN_", vm.toString(i));
            address token = vm.envAddress(key);
            vault.setTokenAllowed(token, true);
            console.log("Allowed token:", token);
        }

        vm.stopBroadcast();
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
