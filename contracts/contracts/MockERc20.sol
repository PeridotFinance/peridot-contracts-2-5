// SPDX-License-Identifier: MIT
// Peridotatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.22;

import {ERC20} from "../node_modules/@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "../node_modules/@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "../node_modules/@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Ownable} from "../node_modules/@openzeppelin/contracts/access/Ownable.sol";

contract USDT is ERC20, ERC20Burnable, Ownable, ERC20Permit {
    constructor(
        address initialOwner
    ) ERC20("USD tETHER", "USDT") Ownable(initialOwner) ERC20Permit("USDT") {}

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
