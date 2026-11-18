// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice The pair's hook = the DLMM rewarder (a BeaconProxy, address 0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC, implementation
///         `DLMMRewarder` 0x9b9d60557b639EDa795BCc28822fa6214C29CEb2 read through the beacon). Source: Routescan verified, solc 0.8.30.
///         `claim` requires `user == msg.sender`, the rewarder still linked as the pair hook, pays PHAR (the reward token) to `user`.
interface IDLMMRewarder {
    function isLinked() external view returns (bool);
    function getRewardToken() external view returns (address);
    function getPendingRewards(address user, uint256[] calldata ids) external view returns (uint256);
    function claim(address user, uint256[] calldata ids) external;
    /// the voter (OwnableUpgradeable); the voter exposes isAuthorizedDLMMManager and dlmmRewarderFactory
    function owner() external view returns (address);
}

/// @notice Voter reads used by the vault (the rewarder's owner; EIP-1967 proxy at 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7).
interface IDLMMVoter {
    function isAuthorizedDLMMManager(address manager) external view returns (bool);
    /// the beacon of the DLMM rewarder BeaconProxies (`DLMMRewarderFactory`, 0xd28467eD...548C)
    function dlmmRewarderFactory() external view returns (address);
}

/// @notice The rewarder beacon `DLMMRewarderFactory` (verified): `implementation()` is what the rewarder proxy delegates to; `getRewarder(pool)` the registry.
interface IDLMMRewarderBeacon {
    function implementation() external view returns (address);
    function getRewarder(address pool) external view returns (address);
}
