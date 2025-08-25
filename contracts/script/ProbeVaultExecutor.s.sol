// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IVaultExec {
    function setAuthorizedManager(address manager, bool authorized) external;

    function redeemAndSupplyToProtocol(
        address user,
        address cToken,
        uint256 cTokenAmount
    ) external returns (uint256 underlyingAmount);
}

contract ProbeVaultExecutor is Script {
    function run() external {
        // Required env vars
        address vault = 0x3141354f70D9519469501A32d59d915fc82D7593;
        address cToken = 0xfB68C6469A67873f7FA2Df6CeAcC5da12abF6c8c;
        address user = 0xF450B38cccFdcfAD2f98f7E4bB533151a2fB00E9; // holder of cTokens

        // Private keys
        uint256 ownerPk = vm.envUint("PRIVATE_KEY"); // VaultExecutor owner key
        uint256 authPk = vm.envUint("PRIVATE_KEY"); // account to authorize and use for probe (can be USER's pk)

        // Amount in cToken units to probe
        uint256 amount = _tryEnvUint("AMOUNT_CTOKEN", 1e6); // default tiny amount

        console.log("Vault: ", vault);
        console.log("cToken:", cToken);
        console.log("User:  ", user);
        console.log("Amount:", amount);

        // 1) Authorize the probe caller on the vault (owner only)
        vm.startBroadcast(ownerPk);
        IVaultExec(vault).setAuthorizedManager(vm.addr(authPk), true);
        vm.stopBroadcast();

        // 2) Approve cToken and call redeemAndSupplyToProtocol
        vm.startBroadcast(authPk);
        try IERC20(cToken).transferFrom(user, vault, amount) returns (
            bool success
        ) {
            console.log("transferFrom returned:", success);
            if (!success) {
                console.log(
                    "!!! TransferFrom returned false, this is the issue."
                );
            }
        } catch (bytes memory errData) {
            console.log("transferFrom reverted with data:");
            console.logBytes(errData);
        }
        vm.stopBroadcast();
    }

    function _tryEnvUint(
        string memory key,
        uint256 fallbackVal
    ) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 v) {
            return v;
        } catch {
            return fallbackVal;
        }
    }
}
