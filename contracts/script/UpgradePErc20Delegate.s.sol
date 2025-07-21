// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "../contracts/PErc20Delegate.sol";
import "../contracts/PErc20Delegator.sol";

/// @title UpgradePErc20Delegate
/// @notice Deploys a new PErc20Delegate implementation and points an existing PErc20Delegator proxy at it.
/// @dev Run with: forge script script/UpgradePErc20Delegate.s.sol:UpgradePErc20Delegate --rpc-url <RPC> --private-key <PK> --broadcast
contract UpgradePErc20Delegate is Script {
    // Existing PErc20Delegator proxy address you want to upgrade
    address public constant DELEGATOR_ADDRESS =
        0x60a0e1A24C4F5DD389a155182DC78a5da061C265

    // Whether the old implementation should call _resignImplementation() during upgrade
    bool public constant ALLOW_RESIGN = true;

    // Optional encoded params for new implementation's _becomeImplementation().
    // For most simple delegates, an empty bytes value is fine.
    bytes public constant BECOME_IMPL_DATA = "";

    /// ---------------------------------------------------------------------
    /// Script entrypoint
    /// ---------------------------------------------------------------------
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);

        console.log("Deploying new PErc20Delegate implementation...");
        PErc20Delegate newImplementation = new PErc20Delegate();
        console.log(
            "New PErc20Delegate deployed at:",
            address(newImplementation)
        );

        // Upgrade the delegator
        PErc20Delegator delegator = PErc20Delegator(DELEGATOR_ADDRESS);
        console.log("Upgrading delegator at:", DELEGATOR_ADDRESS);

        // Caller must be the admin of the proxy
        delegator._setImplementation(
            address(newImplementation),
            ALLOW_RESIGN,
            BECOME_IMPL_DATA
        );

        console.log(
            "Upgrade successful! Delegator now delegates to:",
            address(newImplementation)
        );

        vm.stopBroadcast();
    }
}
