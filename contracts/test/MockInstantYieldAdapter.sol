// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBoostedYieldAdapter} from "../contracts/interfaces/IBoostedYieldAdapter.sol";
import {MockErc20} from "./MockErc20.sol";

contract MockInstantYieldAdapter is IBoostedYieldAdapter {
    address public immutable owner;
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
        return MockErc20(underlying).balanceOf(address(this)) + reportBonus;
    }

    function setReportBonus(uint256 bonus) external {
        reportBonus = bonus;
    }

    function deposit(uint256 amount) external override onlyOwner returns (uint256 deposited) {
        if (amount == 0) {
            return 0;
        }
        require(MockErc20(underlying).transferFrom(owner, address(this), amount), "adapter: deposit transfer failed");
        return amount;
    }

    function withdraw(address recipient, uint256 amount) external override onlyOwner returns (uint256 withdrawn) {
        if (amount == 0) {
            return 0;
        }
        require(MockErc20(underlying).transfer(recipient, amount), "adapter: withdraw transfer failed");
        return amount;
    }

    function withdrawAll(address recipient) external override onlyOwner returns (uint256 withdrawn) {
        uint256 balance = MockErc20(underlying).balanceOf(address(this));
        if (balance > 0) {
            require(MockErc20(underlying).transfer(recipient, balance), "adapter: withdraw all transfer failed");
        }
        return balance;
    }
}
