// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IAtomicMarginExecutorVault {
    struct Account {
        address sma;
        bool withdrawalsLocked;
        uint64 lastHealthRecalc;
    }

    function getAccount(address user) external view returns (Account memory);
    function depositMarginPTokenFor(address user, address pToken, uint256 amount) external;
    function withdrawMarginPTokenTo(address user, address pToken, uint256 amount, address to) external;
    function maxWithdrawableMarginPToken(address user, address pToken) external view returns (uint256);
}

contract MarginCollateralVault is Ownable {
    using SafeERC20 for IERC20;

    IAtomicMarginExecutorVault public immutable executor;

    mapping(address => bool) public allowedPTokens;
    mapping(address => bool) public allowedRouters;
    mapping(address => mapping(address => uint256)) public marginBalance;

    event PTokenAllowedUpdated(address indexed pToken, bool allowed);
    event RouterAllowedUpdated(address indexed router, bool allowed);
    event MovedToMargin(address indexed user, address indexed pToken, uint256 amount);
    event MovedToEarning(address indexed user, address indexed pToken, uint256 amount);

    constructor(address executor_, address owner_) Ownable(owner_) {
        require(executor_ != address(0), "MarginVault: invalid executor");
        executor = IAtomicMarginExecutorVault(executor_);
    }

    function setPTokenAllowed(address pToken, bool allowed) external onlyOwner {
        require(!allowed || pToken.code.length > 0, "MarginVault: pToken not contract");
        allowedPTokens[pToken] = allowed;
        emit PTokenAllowedUpdated(pToken, allowed);
    }

    function setRouterAllowed(address router, bool allowed) external onlyOwner {
        require(!allowed || router.code.length > 0, "MarginVault: router not contract");
        allowedRouters[router] = allowed;
        emit RouterAllowedUpdated(router, allowed);
    }

    function moveToMargin(address pToken, uint256 amount) external {
        _moveToMargin(msg.sender, pToken, amount);
    }

    function moveToMarginFor(address user, address pToken, uint256 amount) external {
        require(allowedRouters[msg.sender], "MarginVault: not router");
        _moveToMargin(user, pToken, amount);
    }

    function _moveToMargin(address user, address pToken, uint256 amount) internal {
        require(allowedPTokens[pToken], "MarginVault: pToken not allowed");
        require(amount > 0, "MarginVault: zero amount");

        IAtomicMarginExecutorVault.Account memory account = executor.getAccount(user);
        require(account.sma != address(0), "MarginVault: enable margin first");

        IERC20(pToken).safeTransferFrom(user, address(this), amount);
        IERC20(pToken).forceApprove(address(executor), amount);
        executor.depositMarginPTokenFor(user, pToken, amount);
        IERC20(pToken).forceApprove(address(executor), 0);

        marginBalance[user][pToken] += amount;
        emit MovedToMargin(user, pToken, amount);
    }

    function moveToEarning(address pToken, uint256 amount) external {
        _moveToEarning(msg.sender, pToken, amount, msg.sender);
    }

    function moveToEarningFor(address user, address pToken, uint256 amount, address to) external {
        require(allowedRouters[msg.sender], "MarginVault: not router");
        _moveToEarning(user, pToken, amount, to);
    }

    function _moveToEarning(address user, address pToken, uint256 amount, address to) internal {
        require(amount > 0, "MarginVault: zero amount");
        require(to != address(0), "MarginVault: zero recipient");

        uint256 deposited = marginBalance[user][pToken];
        require(amount <= deposited, "MarginVault: amount exceeds balance");

        marginBalance[user][pToken] = deposited - amount;
        executor.withdrawMarginPTokenTo(user, pToken, amount, to);

        emit MovedToEarning(user, pToken, amount);
    }

    function freeMarginBalance(address user, address pToken) external view returns (uint256) {
        uint256 deposited = marginBalance[user][pToken];
        uint256 freeAmount = executor.maxWithdrawableMarginPToken(user, pToken);
        return freeAmount < deposited ? freeAmount : deposited;
    }
}
