// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library SafeCast {
    function toUint128(uint256 value) internal pure returns (uint128) {
        require(value <= type(uint128).max, "uint128 overflow");
        return uint128(value);
    }

    function toInt128(int256 value) internal pure returns (int128) {
        require(value >= type(int128).min && value <= type(int128).max, "int128 overflow");
        return int128(value);
    }

    function toInt24(int256 value) internal pure returns (int24) {
        require(value >= type(int24).min && value <= type(int24).max, "int24 overflow");
        return int24(value);
    }
}
