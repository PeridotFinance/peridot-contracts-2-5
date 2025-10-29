// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library FixedPoint96 {
    uint8 internal constant RESOLUTION = 96;
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant Q192 = Q96 * Q96;
}
