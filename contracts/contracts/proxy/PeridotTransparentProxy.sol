// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/**
 * @title PeridotTransparentProxy
 * @notice Minimal wrapper around TransparentUpgradeableProxy for clarity in deployment scripts.
 */
contract PeridotTransparentProxy is TransparentUpgradeableProxy {
    constructor(address _logic, address admin_, bytes memory _data)
        TransparentUpgradeableProxy(_logic, admin_, _data)
    {}
}
