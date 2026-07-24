// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockVaiVault {
    using SafeERC20 for IERC20;

    IERC20 public immutable vai;
    address public admin;
    bool public vaultPaused;
    uint256 public withdrawalShortfall;

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    mapping(address => UserInfo) public userInfo;

    constructor(address vai_) {
        vai = IERC20(vai_);
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "MockVaiVault: not admin");
        _;
    }

    function setVaultPaused(bool paused) external onlyAdmin {
        vaultPaused = paused;
    }

    function setWithdrawalShortfall(uint256 shortfall) external onlyAdmin {
        withdrawalShortfall = shortfall;
    }

    function deposit(uint256 amount) external {
        require(!vaultPaused, "MockVaiVault: paused");
        if (amount == 0) {
            return;
        }
        vai.safeTransferFrom(msg.sender, address(this), amount);
        userInfo[msg.sender].amount += amount;
    }

    function withdraw(uint256 amount) external {
        UserInfo storage info = userInfo[msg.sender];
        require(amount <= info.amount, "MockVaiVault: insufficient stake");
        info.amount -= amount;
        uint256 sent = amount > withdrawalShortfall ? amount - withdrawalShortfall : 0;
        vai.safeTransfer(msg.sender, sent);
    }

    function pendingRewards(address account) external view returns (uint256) {
        account; // silence warning
        return 0;
    }
}
