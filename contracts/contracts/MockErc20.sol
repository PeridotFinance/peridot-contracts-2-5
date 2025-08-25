// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./EIP20Interface.sol";

/**
 * @title MockErc20
 * @notice Mock ERC20 token for testing purposes
 */
contract MockErc20 is EIP20Interface {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        totalSupply = 0;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "Insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function transfer(address dst, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[dst] += amount;
        emit Transfer(msg.sender, dst, amount);
        return true;
    }

    function transferFrom(address src, address dst, uint256 amount) external override returns (bool) {
        require(balanceOf[src] >= amount, "Insufficient balance");
        require(allowance[src][msg.sender] >= amount, "Insufficient allowance");

        balanceOf[src] -= amount;
        balanceOf[dst] += amount;
        allowance[src][msg.sender] -= amount;

        emit Transfer(src, dst, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    // Events inherited from EIP20Interface
}
