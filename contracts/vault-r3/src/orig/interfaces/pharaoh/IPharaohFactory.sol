// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

/// @notice Minimal interface for the Pharaoh Ramses V3 factory.
interface IPharaohFactory {
    function ramsesV3PoolDeployer() external view returns (address);
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}
