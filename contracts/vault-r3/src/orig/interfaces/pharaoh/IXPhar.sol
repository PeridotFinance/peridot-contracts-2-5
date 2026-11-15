// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Minimal transfer-restricted xPHAR exit interface.
interface IXPhar {
    function exit(uint256 amount) external returns (uint256 pharReceived);
}
