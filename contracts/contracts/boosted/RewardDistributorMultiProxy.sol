// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

/**
 * @title RewardDistributorMultiProxy
 * @notice Minimal transparent proxy for RewardDistributorMulti (or similar) using EIP-1967 slots.
 */
contract RewardDistributorMultiProxy {
    // EIP-1967 slots: keccak256("eip1967.proxy.implementation") - 1 and keccak256("eip1967.proxy.admin") - 1
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 private constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    event Upgraded(address indexed implementation);
    event AdminChanged(address previousAdmin, address newAdmin);

    constructor(address implementation_, address admin_, bytes memory initData) {
        _setAdmin(admin_);
        _setImplementation(implementation_);
        if (initData.length > 0) {
            (bool ok,) = implementation_.delegatecall(initData);
            require(ok, "init failed");
        }
    }

    function _implementation() internal view returns (address impl) {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            impl := sload(slot)
        }
    }

    function _admin() internal view returns (address adm) {
        bytes32 slot = ADMIN_SLOT;
        assembly {
            adm := sload(slot)
        }
    }

    function admin() external view returns (address) {
        return _admin();
    }

    function implementation() external view returns (address) {
        return _implementation();
    }

    function upgradeTo(address newImplementation) external {
        require(msg.sender == _admin(), "not admin");
        _setImplementation(newImplementation);
        emit Upgraded(newImplementation);
    }

    function changeAdmin(address newAdmin) external {
        address prev = _admin();
        require(msg.sender == prev, "not admin");
        _setAdmin(newAdmin);
        emit AdminChanged(prev, newAdmin);
    }

    function _setImplementation(address impl) internal {
        bytes32 slot = IMPLEMENTATION_SLOT;
        assembly {
            sstore(slot, impl)
        }
    }

    function _setAdmin(address adm) internal {
        bytes32 slot = ADMIN_SLOT;
        assembly {
            sstore(slot, adm)
        }
    }

    fallback() external payable {
        _delegate(_implementation());
    }

    receive() external payable {
        _delegate(_implementation());
    }

    function _delegate(address impl) internal {
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            let size := returndatasize()
            returndatacopy(0, 0, size)
            switch result
            case 0 {
                revert(0, size)
            }
            default {
                return(0, size)
            }
        }
    }
}
