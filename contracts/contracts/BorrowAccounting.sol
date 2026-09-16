// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

/// @dev ERC-7201 storage; no fields are appended to PTokenStorage or its derived layouts.
library BorrowAccounting {
    uint256 internal constant SCALE = 1e36;
    bytes32 internal constant SLOT = 0xe730f71cfe4f5b50c65508b2ca4b864ce7682a04ce43876ecdb364c635640500;

    struct State {
        bool enabled;
        uint256 totalShares;
        mapping(address => uint256) shares;
    }

    function state() internal pure returns (State storage s) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            s.slot := slot
        }
    }
}
