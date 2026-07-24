// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {RobinhoodBoostedDelegate} from "../contracts/boosted/RobinhoodBoostedDelegate.sol";
import {IRobinhoodBoostedVault} from "../contracts/interfaces/IRobinhoodBoostedVault.sol";

/**
 * @notice Builds one pUSDG admin payload for the two-step vault activation.
 * @dev Payload output is the default because the pToken admin should be a timelock.
 *      Direct EOA execution requires DIRECT_ADMIN_BROADCAST=true.
 */
contract ConfigureRobinhoodBoostedDelegator is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    bytes32 public constant PAIR_ID = keccak256("NVDA/USDG");

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "WRONG_CHAIN");
        RobinhoodBoostedDelegate pToken = RobinhoodBoostedDelegate(vm.envAddress("PUSDG_DELEGATOR"));
        address vault = vm.envAddress("ROBINHOOD_VAULT");
        address operator = vm.envAddress("VAULT_OPERATOR");
        uint256 buffer = vm.envUint("VAULT_BUFFER_MANTISSA");
        require(address(pToken).code.length != 0, "PUSDG_NOT_CONTRACT");
        require(vault.code.length != 0, "VAULT_NOT_CONTRACT");
        require(operator != address(0) && buffer <= 1e18, "INVALID_VAULT_CONFIG");
        require(
            IRobinhoodBoostedVault(vault).sideAccount(PAIR_ID, pToken.underlying()) == address(pToken),
            "PUSDG_NOT_SIDE_ACCOUNT"
        );

        bytes32 action = keccak256(bytes(vm.envString("PUSDG_ADMIN_ACTION")));
        bytes memory data;
        bytes32 expectedActionId;
        if (action == keccak256("queue-config")) {
            data = abi.encodeCall(RobinhoodBoostedDelegate.queueSetVaultConfig, (vault, PAIR_ID, buffer, operator));
            expectedActionId = keccak256(abi.encode("setVaultConfig", vault, PAIR_ID, buffer, operator));
        } else if (action == keccak256("execute-config")) {
            data = abi.encodeCall(RobinhoodBoostedDelegate._setVaultConfig, (vault, PAIR_ID, buffer, operator));
            expectedActionId = keccak256(abi.encode("setVaultConfig", vault, PAIR_ID, buffer, operator));
        } else if (action == keccak256("queue-unpause")) {
            data = abi.encodeCall(RobinhoodBoostedDelegate.queueSetVaultPaused, (false));
            expectedActionId = keccak256(abi.encode("setVaultPaused", false));
        } else if (action == keccak256("execute-unpause")) {
            data = abi.encodeCall(RobinhoodBoostedDelegate._setVaultPaused, (false));
            expectedActionId = keccak256(abi.encode("setVaultPaused", false));
        } else {
            revert("UNKNOWN_PUSDG_ADMIN_ACTION");
        }

        console2.log("expected internal action id");
        console2.logBytes32(expectedActionId);
        if (!vm.envOr("DIRECT_ADMIN_BROADCAST", false)) {
            console2.log("target", address(pToken));
            console2.log("value", uint256(0));
            console2.log("calldata");
            console2.logBytes(data);
            return;
        }

        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");
        vm.startBroadcast(adminKey);
        (bool success, bytes memory returnData) = address(pToken).call(data);
        vm.stopBroadcast();
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
