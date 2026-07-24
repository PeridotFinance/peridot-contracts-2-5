// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBoostedYieldAdapter} from "../contracts/interfaces/IBoostedYieldAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockInstantYieldAdapter is IBoostedYieldAdapter {
    using SafeERC20 for IERC20;

    address public immutable override owner;
    address public immutable override underlying;
    uint256 public reportBonus;

    constructor(address underlying_, address owner_) {
        underlying = underlying_;
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "adapter: not owner");
        _;
    }

    function totalUnderlying() external view override returns (uint256) {
        return IERC20(underlying).balanceOf(address(this)) + reportBonus;
    }

    function setReportBonus(uint256 bonus) external {
        reportBonus = bonus;
    }

    function deposit(uint256 amount) external override onlyOwner returns (uint256 deposited) {
        if (amount == 0) {
            return 0;
        }
        IERC20(underlying).safeTransferFrom(owner, address(this), amount);
        return amount;
    }

    function withdraw(address recipient, uint256 amount) external override onlyOwner returns (uint256 withdrawn) {
        if (amount == 0) {
            return 0;
        }
        IERC20(underlying).safeTransfer(recipient, amount);
        return amount;
    }

    function withdrawAll(address recipient) external override onlyOwner returns (uint256 withdrawn) {
        uint256 balance = IERC20(underlying).balanceOf(address(this));
        if (balance > 0) {
            IERC20(underlying).safeTransfer(recipient, balance);
        }
        return balance;
    }
}
