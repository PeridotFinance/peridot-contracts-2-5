// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../contracts/MockErc20.sol";

/**
 * @title MockPErc20
 * @notice Simple mock for PErc20 for testing purposes
 */
contract MockPErc20 {
    address public underlying;
    string public symbol;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor(address _underlying, string memory _symbol) {
        underlying = _underlying;
        symbol = _symbol;
    }

    function mint(uint256 amount) external returns (uint256) {
        balanceOf[msg.sender] += amount;
        totalSupply += amount;
        return 0; // Success
    }

    function redeem(uint256 amount) external returns (uint256) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        return 0; // Success
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address src, address dst, uint256 amount) external returns (bool) {
        require(balanceOf[src] >= amount, "Insufficient balance");
        balanceOf[src] -= amount;
        balanceOf[dst] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        // Simplified approval - not tracking allowances for mock
        return true;
    }

    function exchangeRateStored() external pure returns (uint256) {
        return 1e18; // 1:1 exchange rate for simplicity
    }

    function borrow(uint256 amount) external returns (uint256) {
        // Mock implementation - just transfer tokens to user
        return 0; // Success
    }
}
