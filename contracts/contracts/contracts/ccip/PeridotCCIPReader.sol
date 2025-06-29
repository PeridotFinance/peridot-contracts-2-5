// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {PeridottrollerInterface} from "../../PeridottrollerInterface.sol";

/**
 * @title PeridotCCIPReader
 * @dev A CCIP receiver contract that can query Peridot protocol data cross-chain.
 * This contract receives requests from other chains and responds with Peridot data.
 */
contract PeridotCCIPReader is CCIPReceiver {
    event CrossChainLiquidityRequested(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed account,
        address sender
    );

    event CrossChainLiquidityResponse(
        bytes32 indexed messageId,
        address indexed account,
        uint error,
        uint liquidity,
        uint shortfall
    );

    // Supported request types
    enum RequestType {
        GET_ACCOUNT_LIQUIDITY
    }

    // The Peridottroller contract address
    PeridottrollerInterface public immutable peridottroller;

    // Mapping to track allowed source chains
    mapping(uint64 => bool) public allowedSourceChains;

    // Mapping to track allowed senders per source chain
    mapping(uint64 => mapping(address => bool)) public allowedSenders;

    // Only owner can modify access controls
    address public owner;

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner can call this function");
        _;
    }

    /**
     * @dev Constructor initializes the contract with the router and Peridottroller addresses.
     * @param _router The address of the CCIP router contract.
     * @param _peridottroller The address of the Peridottroller contract.
     */
    constructor(
        address _router,
        address _peridottroller
    ) CCIPReceiver(_router) {
        peridottroller = PeridottrollerInterface(_peridottroller);
        owner = msg.sender;
    }

    /**
     * @dev Allow a source chain to send messages to this contract.
     * @param _sourceChainSelector The chain selector of the source chain.
     * @param _allowed Whether the source chain is allowed.
     */
    function allowlistSourceChain(
        uint64 _sourceChainSelector,
        bool _allowed
    ) external onlyOwner {
        allowedSourceChains[_sourceChainSelector] = _allowed;
    }

    /**
     * @dev Allow a sender on a source chain to send messages to this contract.
     * @param _sourceChainSelector The chain selector of the source chain.
     * @param _sender The address of the sender.
     * @param _allowed Whether the sender is allowed.
     */
    function allowlistSender(
        uint64 _sourceChainSelector,
        address _sender,
        bool _allowed
    ) external onlyOwner {
        allowedSenders[_sourceChainSelector][_sender] = _allowed;
    }

    /**
     * @dev The internal function that is called by the Router to forward CCIP messages.
     * @param _message The cross-chain message including the sender's address and the message bytes.
     */
    function _ccipReceive(
        Client.Any2EVMMessage memory _message
    ) internal override {
        // Validate source chain
        require(
            allowedSourceChains[_message.sourceChainSelector],
            "Source chain not allowed"
        );

        // Decode sender address
        address sender = abi.decode(_message.sender, (address));

        // Validate sender
        require(
            allowedSenders[_message.sourceChainSelector][sender],
            "Sender not allowed"
        );

        // Decode the request
        (RequestType requestType, bytes memory requestData) = abi.decode(
            _message.data,
            (RequestType, bytes)
        );

        // Handle different request types
        if (requestType == RequestType.GET_ACCOUNT_LIQUIDITY) {
            _handleAccountLiquidityRequest(_message.messageId, requestData);
        }
    }

    /**
     * @dev Handle account liquidity request.
     * @param _messageId The ID of the cross-chain message.
     * @param _requestData The encoded request data containing the account address.
     */
    function _handleAccountLiquidityRequest(
        bytes32 _messageId,
        bytes memory _requestData
    ) internal {
        // Decode the account address from request data
        address account = abi.decode(_requestData, (address));

        emit CrossChainLiquidityRequested(
            _messageId,
            0, // We don't have access to sourceChainSelector here
            account,
            address(0) // We don't have access to sender here
        );

        // Query the Peridottroller for account liquidity
        (uint error, uint liquidity, uint shortfall) = peridottroller
            .getAccountLiquidity(account);

        // Emit the response event
        emit CrossChainLiquidityResponse(
            _messageId,
            account,
            error,
            liquidity,
            shortfall
        );
    }

    /**
     * @dev Get account liquidity locally (for testing purposes).
     * @param account The account to check liquidity for.
     * @return error The error code (0 if successful).
     * @return liquidity The account's excess liquidity.
     * @return shortfall The account's shortfall.
     */
    function getAccountLiquidity(
        address account
    ) external view returns (uint error, uint liquidity, uint shortfall) {
        return peridottroller.getAccountLiquidity(account);
    }
}
