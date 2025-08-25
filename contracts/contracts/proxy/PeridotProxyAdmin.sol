// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

/**
 * @title PeridotProxyAdmin
 * @notice Admin contract to manage Peridot transparent proxies (upgrade, change admin).
 * @dev Uses EIP-1967 storage slots to avoid storage collisions with implementations.
 */
contract PeridotProxyAdmin is ProxyAdmin {
    constructor(address initialOwner) ProxyAdmin(initialOwner) {}
}
