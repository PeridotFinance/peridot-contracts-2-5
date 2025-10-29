// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPancakeV3MasterChef {
    function deposit(uint256 pid, uint256 tokenId, address to) external;

    function withdraw(uint256 pid, uint256 tokenId, address to) external;

    function harvest(uint256 pid, address to) external;
}
