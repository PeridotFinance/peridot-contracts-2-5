// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IAxelarGatewayWithToken} from
    "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGatewayWithToken.sol";

/**
 * @title AxelarExecutableWithTokenUpgradeable
 * @notice Upgradeable variant holding the Axelar gateway in storage (not immutable).
 *         Mirrors the external Axelar base but suitable for proxy deployments.
 */
abstract contract AxelarExecutableWithTokenUpgradeable is Initializable {
    IAxelarGatewayWithToken public gateway;

    function __AxelarExecutableWithTokenUpgradeable_init(address _gateway) internal onlyInitializing {
        require(_gateway != address(0), "Invalid gateway");
        gateway = IAxelarGatewayWithToken(_gateway);
    }

    function gatewayWithToken() internal view returns (IAxelarGatewayWithToken) {
        return gateway;
    }

    function _execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal virtual;

    function _executeWithToken(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) internal virtual;

    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) external payable {
        require(msg.sender == address(gateway), "Not gateway");
        _execute(commandId, sourceChain, sourceAddress, payload);
    }

    function executeWithToken(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) external payable {
        require(msg.sender == address(gateway), "Not gateway");
        _executeWithToken(commandId, sourceChain, sourceAddress, payload, tokenSymbol, amount);
    }
}
