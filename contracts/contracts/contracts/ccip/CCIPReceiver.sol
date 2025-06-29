// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";

/**
 * @title CCIPReceiver_Unsafe
 * @dev A simple contract to receive and store a message from a CCIP sender.
 *
 * THIS IS AN EXAMPLE CONTRACT THAT USES THE CCIP RECEIVER IN AN UNSAFE WAY.
 * DO NOT USE THIS IN PRODUCTION.
 *
 * It is unsafe because it does not have any access control modifiers on the
 * `s_lastReceivedMessage` and `s_lastReceivedMessageSender` state variables.
 * This means that anyone can call the `getLatestMessageDetails` function to
 * view the latest received message, which may not be desirable for all use cases.
 *
 * It is also unsafe because it does not validate the sender of the message.
 * Any contract on any source chain can send a message to this contract.
 * See the `CCIPReceiver` contract for a more secure example.
 */
contract CCIPReceiver_Unsafe is CCIPReceiver {
    event MessageReceived(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address sender,
        string message
    );

    bytes32 private s_lastReceivedMessageId;
    uint64 private s_lastReceivedSourceChainSelector;
    address private s_lastReceivedMessageSender;
    string private s_lastReceivedMessage;

    /**
     * @dev Constructor initializes the contract with the router address.
     * @param _router The address of the router contract.
     */
    constructor(address _router) CCIPReceiver(_router) {}

    /**
     * @dev The internal function that is called by the Router to forward CCIP messages.
     *      This function should be overridden by contracts that inherit from CCIPReceiver.
     *
     * @param _message The cross-chain message including the sender's address and the message bytes.
     *
     * It is recommended that the overriding function includes the following checks:
     * 1. A check to ensure that the sender is a trusted source.
     * 2. A check to ensure that the message is sent from a trusted source chain.
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory _message
    ) internal override {
        s_lastReceivedMessageId = _message.messageId;
        s_lastReceivedSourceChainSelector = _message.sourceChainSelector;
        s_lastReceivedMessageSender = abi.decode(_message.sender, (address));
        s_lastReceivedMessage = abi.decode(_message.data, (string));

        emit MessageReceived(
            s_lastReceivedMessageId,
            s_lastReceivedSourceChainSelector,
            s_lastReceivedMessageSender,
            s_lastReceivedMessage
        );
    }

    /**
     * @dev Retrieves the details of the last received message.
     * @return messageId The ID of the last received message.
     * @return sourceChainSelector The chain selector of the source chain.
     * @return sender The address of the sender.
     * @return message The last received message.
     */
    function getLatestMessageDetails()
        public
        view
        returns (
            bytes32 messageId,
            uint64 sourceChainSelector,
            address sender,
            string memory message
        )
    {
        return (
            s_lastReceivedMessageId,
            s_lastReceivedSourceChainSelector,
            s_lastReceivedMessageSender,
            s_lastReceivedMessage
        );
    }
}
