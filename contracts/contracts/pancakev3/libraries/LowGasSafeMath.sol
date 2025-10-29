// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library LowGasSafeMath {
    function add(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x + y) >= x, "add overflow");
    }

    function sub(uint256 x, uint256 y) internal pure returns (uint256 z) {
        require((z = x - y) <= x, "sub underflow");
    }

    function add128(uint128 x, uint128 y) internal pure returns (uint128) {
        uint128 z = x + y;
        require(z >= x, "add128 overflow");
        return z;
    }

    function sub128(uint128 x, uint128 y) internal pure returns (uint128) {
        require(x >= y, "sub128 underflow");
        return x - y;
    }
}
