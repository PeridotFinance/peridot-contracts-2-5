// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAxelarExecutable} from "./interfaces/AxelarInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PeridotSpokeReceiver
 * @author Peridot
 * @notice This contract receives borrowed assets from the hub chain and transfers them to the user.
 */
contract PeridotSpokeReceiver is IAxelarExecutable {
    constructor(address gateway) IAxelarExecutable(gateway) {}

    function _executeWithToken(bytes32 commandId, string calldata sourceChain, string calldata sourceAddress, bytes calldata payload, string calldata tokenSymbol, uint256 amount) internal override returns (bytes memory) {
        (address user, address token) = abi.decode(payload, (address, address));
        IERC20(token).transfer(user, amount);
        return bytes("");
    }

    function _execute(bytes32 commandId, string calldata, string calldata, bytes calldata) internal pure override {
        revert("Cannot execute without token");
    }
}
