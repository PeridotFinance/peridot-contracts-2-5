// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PeridottrollerInterface} from "../PeridottrollerInterface.sol";
import {PErc20} from "../PErc20.sol";

/**
 * @title SmartMarginAccount
 * @notice Minimal proxy-owned account that custodies collateral and executes trades for a user.
 * @dev Instances are deployed as EIP-1167 clones and must be initialized exactly once.
 */
contract SmartMarginAccount {
    using SafeERC20 for IERC20;

    address public manager;
    address public owner;

    event ManagerUpdated(address indexed newManager);
    event OwnerUpdated(address indexed newOwner);
    event RouterCallExecuted(address indexed target, bytes data);

    modifier onlyManager() {
        require(msg.sender == manager, "SMA: not manager");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "SMA: not owner");
        _;
    }

    function initialize(address _manager, address _owner) external {
        require(manager == address(0), "SMA: initialized");
        require(_manager != address(0), "SMA: invalid manager");
        require(_owner != address(0), "SMA: invalid owner");

        manager = _manager;
        owner = _owner;

        emit ManagerUpdated(_manager);
        emit OwnerUpdated(_owner);
    }

    function setOwner(address newOwner) external onlyManager {
        require(newOwner != address(0), "SMA: invalid owner");
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function setManager(address newManager) external onlyManager {
        require(newManager != address(0), "SMA: invalid manager");
        manager = newManager;
        emit ManagerUpdated(newManager);
    }

    function enterMarket(address comptroller, address cToken) external onlyManager returns (uint256) {
        address[] memory markets = new address[](1);
        markets[0] = cToken;
        uint256[] memory results = PeridottrollerInterface(comptroller).enterMarkets(markets);
        require(results[0] == 0, "SMA: enter market failed");
        return results[0];
    }

    function exitMarket(address comptroller, address cToken) external onlyManager returns (uint256) {
        return PeridottrollerInterface(comptroller).exitMarket(cToken);
    }

    function borrow(address cToken, uint256 amount) external onlyManager returns (uint256) {
        return PErc20(cToken).borrow(amount);
    }

    function repayBorrow(address cToken, uint256 amount) external onlyManager returns (uint256) {
        IERC20 underlying = IERC20(PErc20(cToken).underlying());
        underlying.forceApprove(cToken, amount);
        return PErc20(cToken).repayBorrow(amount);
    }

    function mint(address cToken, uint256 underlyingAmount) external onlyManager returns (uint256) {
        IERC20 underlying = IERC20(PErc20(cToken).underlying());
        underlying.forceApprove(cToken, underlyingAmount);
        return PErc20(cToken).mint(underlyingAmount);
    }

    function redeem(address cToken, uint256 amount) external onlyManager returns (uint256) {
        return PErc20(cToken).redeem(amount);
    }

    function redeemUnderlying(address cToken, uint256 underlyingAmount) external onlyManager returns (uint256) {
        return PErc20(cToken).redeemUnderlying(underlyingAmount);
    }

    function transferOut(address token, address to, uint256 amount) external onlyManager {
        require(to != address(0), "SMA: invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }

    function approve(address token, address spender, uint256 amount) external onlyManager {
        IERC20(token).forceApprove(spender, amount);
    }

    function callRouter(address target, bytes calldata data) external onlyManager returns (bytes memory) {
        require(target.code.length > 0, "SMA: target not contract");

        (bool success, bytes memory response) = target.call(data);
        if (!success) {
            if (response.length > 0) {
                assembly {
                    let returndata_size := mload(response)
                    revert(add(32, response), returndata_size)
                }
            }
            revert("SMA: router call failed");
        }

        emit RouterCallExecuted(target, data);
        return response;
    }

    function rescueToken(address token, address to, uint256 amount) external onlyManager {
        require(to != address(0), "SMA: invalid rescue to");
        IERC20(token).safeTransfer(to, amount);
    }
}
