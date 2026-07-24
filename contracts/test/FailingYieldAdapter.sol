// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBoostedYieldAdapter} from "../contracts/interfaces/IBoostedYieldAdapter.sol";
import {MockErc20} from "./MockErc20.sol";

contract FailingYieldAdapter is IBoostedYieldAdapter {
    address public immutable override owner;
    address public immutable override underlying;

    bool public failTotalUnderlying;
    bool public failDeposit;
    bool public failWithdraw;
    bool public failWithdrawAll;

    constructor(address underlying_, address owner_) {
        underlying = underlying_;
        owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "adapter: not owner");
        _;
    }

    function setFailFlags(bool totalUnderlyingFail, bool depositFail, bool withdrawFail, bool withdrawAllFail)
        external
        onlyOwner
    {
        failTotalUnderlying = totalUnderlyingFail;
        failDeposit = depositFail;
        failWithdraw = withdrawFail;
        failWithdrawAll = withdrawAllFail;
    }

    function totalUnderlying() external view override returns (uint256) {
        require(!failTotalUnderlying, "adapter: totalUnderlying fail");
        return MockErc20(underlying).balanceOf(address(this));
    }

    function deposit(uint256 amount) external override onlyOwner returns (uint256 deposited) {
        require(!failDeposit, "adapter: deposit fail");
        if (amount == 0) {
            return 0;
        }
        require(MockErc20(underlying).transferFrom(owner, address(this), amount), "adapter: deposit transfer failed");
        return amount;
    }

    function withdraw(address recipient, uint256 amount) external override onlyOwner returns (uint256 withdrawn) {
        require(!failWithdraw, "adapter: withdraw fail");
        if (amount == 0) {
            return 0;
        }
        require(MockErc20(underlying).transfer(recipient, amount), "adapter: withdraw transfer failed");
        return amount;
    }

    function withdrawAll(address recipient) external override onlyOwner returns (uint256 withdrawn) {
        require(!failWithdrawAll, "adapter: withdraw all fail");
        uint256 balance = MockErc20(underlying).balanceOf(address(this));
        if (balance > 0) {
            require(MockErc20(underlying).transfer(recipient, balance), "adapter: withdraw all transfer failed");
        }
        return balance;
    }
}
