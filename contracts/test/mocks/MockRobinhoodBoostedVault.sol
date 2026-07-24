// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRobinhoodBoostedVault} from "../../contracts/interfaces/IRobinhoodBoostedVault.sol";
import {MockErc20} from "../MockErc20.sol";

contract MockRobinhoodBoostedVault is IRobinhoodBoostedVault {
    MockErc20 public immutable token;
    bytes32 public immutable pairId;
    address public account;
    uint256 public accounted;
    uint256 public liquid;
    uint256 public pendingLoss;
    bool public withdrawalReverts;
    address public lastDepositor;

    constructor(MockErc20 token_, bytes32 pairId_) {
        token = token_;
        pairId = pairId_;
    }

    function setSideAccount(address account_) external {
        account = account_;
    }

    function setPendingLoss(uint256 amount) external {
        pendingLoss = amount;
    }

    function setWithdrawalReverts(bool value) external {
        withdrawalReverts = value;
    }

    function investAll() external {
        liquid = 0;
    }

    function depositForPair(bytes32 pairId_, address token_, uint256 amount)
        external
        override
        returns (uint256 received)
    {
        require(pairId_ == pairId && token_ == address(token), "mock: wrong pair");
        require(msg.sender == account, "mock: wrong account");
        uint256 balanceBefore = token.balanceOf(address(this));
        token.transferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - balanceBefore;
        accounted += received;
        liquid += received;
        lastDepositor = msg.sender;
    }

    function withdrawForSide(bytes32 pairId_, address token_, uint256 requested, address receiver, uint256)
        external
        override
        returns (uint256 returned, uint256 realizedLoss)
    {
        require(pairId_ == pairId && token_ == address(token), "mock: wrong pair");
        require(msg.sender == account, "mock: wrong account");
        require(!withdrawalReverts, "mock: withdrawal blocked");

        realizedLoss = pendingLoss > accounted ? accounted : pendingLoss;
        pendingLoss = 0;
        if (realizedLoss != 0) {
            accounted -= realizedLoss;
            token.burn(address(this), realizedLoss);
            if (liquid > accounted) liquid = accounted;
        }

        returned = requested > accounted ? accounted : requested;
        uint256 balance = token.balanceOf(address(this));
        if (returned > balance) returned = balance;
        accounted -= returned;
        if (returned >= liquid) liquid = 0;
        else liquid -= returned;
        token.transfer(receiver, returned);
    }

    function accountedAssets(bytes32 pairId_, address token_) external view override returns (uint256) {
        require(pairId_ == pairId && token_ == address(token), "mock: wrong pair");
        return accounted;
    }

    function liquidAssets(bytes32 pairId_, address token_) external view override returns (uint256) {
        require(pairId_ == pairId && token_ == address(token), "mock: wrong pair");
        return liquid;
    }

    function sideAccount(bytes32 pairId_, address token_) external view override returns (address) {
        require(pairId_ == pairId && token_ == address(token), "mock: wrong pair");
        return account;
    }
}
