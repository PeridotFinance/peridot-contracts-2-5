// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/**
 * @title Mock ERC4626 Vault
 * @notice Simple ERC4626 wrapper that mints shares 1:1 with assets and tracks assets via held balance.
 */
contract MockERC4626Vault is ERC4626 {
    constructor(IERC20Metadata asset_) ERC20("Mock Vault Share", "mSHARE") ERC4626(asset_) {}

    function mintUnderlying(address to, uint256 amount) external {
        IERC20(asset()).transfer(to, amount);
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this));
    }
}
