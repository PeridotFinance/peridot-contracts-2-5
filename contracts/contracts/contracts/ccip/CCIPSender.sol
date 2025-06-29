// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver_Unsafe} from "./CCIPReceiver.sol";

/**
 * @title CCIPSender_Unsafe
 * @dev A simple contract to send a message to a CCIP receiver.
 *
 * THIS IS AN EXAMPLE CONTRACT THAT USES THE CCIP SENDER IN AN UNSAFE WAY.
 * DO NOT USE THIS IN PRODUCTION.
 *
 * It is unsafe because it does not have any access control modifiers on the
 * `s_lastMessageId` state variable. This means that anyone can call the
 * `getLastMessageId` function to view the latest sent message id, which may
 * not be desirable for all use cases.
 *
 * It is also unsafe because it does not have a whitelist of allowed receivers.
 * Any address can be passed to the `sendMessage` function, which could
 * lead to messages being sent to unintended recipients.
 */
contract CCIPSender_Unsafe is OwnerIsCreator {
    event MessageSent(bytes32 indexed messageId);

    IRouterClient private s_router;

    bytes32 private s_lastMessageId;

    /**
     * @dev Constructor initializes the contract with the router address.
     * @param _router The address of the router contract.
     */
    constructor(address _router) {
        s_router = IRouterClient(_router);
    }

    /**
     * @dev Sends a message to a receiver contract on a destination chain.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _receiver The address of the receiver contract on the destination chain.
     * @param _message The message to send.
     * @param _feeToken The address of the token to pay for fees. Set to address(0) for native gas.
     */
    function sendMessage(
        uint64 _destinationChainSelector,
        address _receiver,
        string calldata _message,
        address _feeToken
    ) external onlyOwner {
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_receiver),
            data: abi.encode(_message),
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 200_000})
            ), // Set gas limit
            feeToken: _feeToken
        });

        uint256 fees = s_router.getFee(_destinationChainSelector, message);

        if (_feeToken == address(0)) {
            s_lastMessageId = s_router.ccipSend{value: fees}(
                _destinationChainSelector,
                message
            );
        } else {
            // This is not going to work because we have not approved the router to spend our tokens.
            // This is just for demonstration purposes.
            // In a real-world scenario, you would need to approve the router to spend your tokens.
            // For example:
            // IERC20(_feeToken).approve(address(s_router), fees);
            s_lastMessageId = s_router.ccipSend(
                _destinationChainSelector,
                message
            );
        }

        emit MessageSent(s_lastMessageId);
    }
}
