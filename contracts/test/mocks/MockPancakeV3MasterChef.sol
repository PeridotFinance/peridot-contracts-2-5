// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPancakeV3MasterChef} from "../../contracts/pancakev3/interfaces/IPancakeV3MasterChef.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockPancakeV3MasterChef is IPancakeV3MasterChef {
    using SafeERC20 for IERC20;

    mapping(uint256 => address) public stakerOf;
    IERC20 public rewardToken;
    uint256 public rewardAmount;

    event Deposited(uint256 indexed pid, uint256 indexed tokenId, address indexed to);
    event Withdrawn(uint256 indexed pid, uint256 indexed tokenId, address indexed to);
    event Harvested(uint256 indexed pid, address indexed to, uint256 reward);

    function setRewardToken(address token) external {
        rewardToken = IERC20(token);
    }

    function setRewardAmount(uint256 amount) external {
        rewardAmount = amount;
    }

    function deposit(uint256 pid, uint256 tokenId, address to) external override {
        stakerOf[tokenId] = to;
        emit Deposited(pid, tokenId, to);
    }

    function withdraw(uint256 pid, uint256 tokenId, address to) external override {
        require(stakerOf[tokenId] != address(0), "not staked");
        delete stakerOf[tokenId];
        emit Withdrawn(pid, tokenId, to);
    }

    function harvest(uint256 pid, address to) external override {
        if (address(rewardToken) != address(0) && rewardAmount > 0) {
            rewardToken.safeTransfer(to, rewardAmount);
        }
        emit Harvested(pid, to, rewardAmount);
    }
}
