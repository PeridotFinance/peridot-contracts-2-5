// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "../../lib/openzeppelin-contracts/contracts/proxy/Proxy.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol";
import "../../lib/openzeppelin-contracts/contracts/utils/Address.sol";

/**
 * @title EIP1967Proxy
 * @dev This contract implements a proxy that conforms to EIP-1967 storage slots
 * and provides basic admin controls for upgrades.
 * It inherits the delegatecall mechanism from OpenZeppelin's Proxy contract.
 */
contract EIP1967Proxy is Proxy {
    // Storage slot for the implementation address following EIP-1967 standard
    bytes32 internal constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    // Storage slot for the admin address following EIP-1967 standard (optional but good practice)
    bytes32 internal constant _ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /**
     * @dev Emitted when the implementation is upgraded.
     */
    event Upgraded(address indexed implementation);

    /**
     * @dev Emitted when the admin is changed.
     */
    event AdminChanged(address previousAdmin, address newAdmin);

    /**
     * @dev Modifier to check that the sender is the admin. Will revert otherwise.
     */
    modifier onlyAdmin() {
        require(
            msg.sender == _getAdmin(),
            "EIP1967Proxy: caller is not the admin"
        );
        _;
    }

    /**
     * @dev Initializes the proxy with an initial implementation contract and sets the deploying address as the admin.
     * @param initialImplementation The address of the initial implementation contract.
     * @param initialAdmin The address designated as the initial admin.
     */
    constructor(address initialImplementation, address initialAdmin) {
        require(
            initialImplementation != address(0),
            "EIP1967Proxy: implementation cannot be zero address"
        );
        require(
            initialImplementation.code.length > 0,
            "EIP1967Proxy: implementation is not a contract"
        );
        _setImplementation(initialImplementation); // Sets the implementation slot

        require(
            initialAdmin != address(0),
            "EIP1967Proxy: admin cannot be zero address"
        );
        _setAdmin(initialAdmin); // Sets the admin slot
    }

    /**
     * @dev Returns the current implementation address.
     */
    function _implementation() internal view override returns (address) {
        return StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value;
    }

    /**
     * @dev Returns the current admin address.
     */
    function _getAdmin() internal view returns (address) {
        return StorageSlot.getAddressSlot(_ADMIN_SLOT).value;
    }

    /**
     * @dev Sets the implementation address in storage.
     * @param newImplementation The address of the new implementation contract.
     */
    function _setImplementation(address newImplementation) private {
        StorageSlot
            .getAddressSlot(_IMPLEMENTATION_SLOT)
            .value = newImplementation;
    }

    /**
     * @dev Sets the admin address in storage.
     * @param newAdmin The address of the new admin.
     */
    function _setAdmin(address newAdmin) private {
        StorageSlot.getAddressSlot(_ADMIN_SLOT).value = newAdmin;
    }

    /**
     * @dev Upgrades the proxy to a new implementation.
     * Can only be called by the current admin.
     * Emits an {Upgraded} event.
     * @param newImplementation Address of the new implementation contract.
     */
    function upgradeTo(address newImplementation) external virtual onlyAdmin {
        require(
            newImplementation != address(0),
            "EIP1967Proxy: new implementation cannot be zero address"
        );
        require(
            newImplementation.code.length > 0,
            "EIP1967Proxy: new implementation is not a contract"
        );
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
    }

    /**
     * @dev Changes the admin of the proxy.
     * Can only be called by the current admin.
     * Emits an {AdminChanged} event.
     * @param newAdmin Address of the new admin.
     */
    function changeAdmin(address newAdmin) external virtual onlyAdmin {
        require(
            newAdmin != address(0),
            "EIP1967Proxy: new admin cannot be zero address"
        );
        address previousAdmin = _getAdmin();
        _setAdmin(newAdmin);
        emit AdminChanged(previousAdmin, newAdmin);
    }

    /**
     * @dev Returns the current admin.
     * Added for external visibility.
     */
    function admin() external view returns (address) {
        return _getAdmin();
    }

    /**
     * @dev Returns the current implementation.
     * Added for external visibility.
     */
    function implementation() external view returns (address) {
        return _implementation();
    }
}
