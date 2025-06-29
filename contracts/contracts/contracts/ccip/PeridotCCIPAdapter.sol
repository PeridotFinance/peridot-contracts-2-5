// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";
import {CCIPReceiver} from "@chainlink/contracts-ccip/contracts/applications/CCIPReceiver.sol";
import {PeridottrollerInterface} from "../../PeridottrollerInterface.sol";

/**
 * @title PeridotCCIPAdapter
 * @dev A CCIP receiver contract that can execute state-changing operations on the Peridot protocol.
 * This contract receives cross-chain requests and executes them on behalf of users.
 */
contract PeridotCCIPAdapter is CCIPReceiver {
    event CrossChainEnterMarketsRequested(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed user,
        address[] pTokens,
        address sender
    );

    event CrossChainEnterMarketsExecuted(
        bytes32 indexed messageId,
        address indexed user,
        address[] pTokens,
        uint[] results
    );

    event CrossChainExitMarketRequested(
        bytes32 indexed messageId,
        uint64 indexed sourceChainSelector,
        address indexed user,
        address pToken,
        address sender
    );

    event CrossChainExitMarketExecuted(
        bytes32 indexed messageId,
        address indexed user,
        address pToken,
        uint result
    );

    // Supported request types
    enum RequestType {
        ENTER_MARKETS,
        EXIT_MARKET
    }

    // The Peridottroller contract
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
        (RequestType requestType, address user, bytes memory requestData) = abi
            .decode(_message.data, (RequestType, address, bytes));

        // Handle different request types
        if (requestType == RequestType.ENTER_MARKETS) {
            _handleEnterMarketsRequest(
                _message.messageId,
                _message.sourceChainSelector,
                user,
                requestData,
                sender
            );
        } else if (requestType == RequestType.EXIT_MARKET) {
            _handleExitMarketRequest(
                _message.messageId,
                _message.sourceChainSelector,
                user,
                requestData,
                sender
            );
        }
    }

    /**
     * @dev Handle enter markets request.
     * @param _messageId The ID of the cross-chain message.
     * @param _sourceChainSelector The source chain selector.
     * @param _user The user to enter markets for.
     * @param _requestData The encoded request data containing the pTokens array.
     * @param _sender The sender of the original message.
     */
    function _handleEnterMarketsRequest(
        bytes32 _messageId,
        uint64 _sourceChainSelector,
        address _user,
        bytes memory _requestData,
        address _sender
    ) internal {
        // Decode the pTokens array from request data
        address[] memory pTokens = abi.decode(_requestData, (address[]));

        emit CrossChainEnterMarketsRequested(
            _messageId,
            _sourceChainSelector,
            _user,
            pTokens,
            _sender
        );

        // Execute the enterMarkets call on behalf of the user
        // Note: This is a simplified implementation. In production, you might want
        // additional authorization checks to ensure the user has authorized this action.
        uint[] memory results = peridottroller.enterMarkets(pTokens);

        // Emit the response event
        emit CrossChainEnterMarketsExecuted(
            _messageId,
            _user,
            pTokens,
            results
        );
    }

    /**
     * @dev Handle exit market request.
     * @param _messageId The ID of the cross-chain message.
     * @param _sourceChainSelector The source chain selector.
     * @param _user The user to exit market for.
     * @param _requestData The encoded request data containing the pToken address.
     * @param _sender The sender of the original message.
     */
    function _handleExitMarketRequest(
        bytes32 _messageId,
        uint64 _sourceChainSelector,
        address _user,
        bytes memory _requestData,
        address _sender
    ) internal {
        // Decode the pToken address from request data
        address pToken = abi.decode(_requestData, (address));

        emit CrossChainExitMarketRequested(
            _messageId,
            _sourceChainSelector,
            _user,
            pToken,
            _sender
        );

        // Execute the exitMarket call on behalf of the user
        // Note: This is a simplified implementation. In production, you might want
        // additional authorization checks to ensure the user has authorized this action.
        uint result = peridottroller.exitMarket(pToken);

        // Emit the response event
        emit CrossChainExitMarketExecuted(_messageId, _user, pToken, result);
    }

    /**
     * @dev Enter markets locally (for testing purposes).
     * @param pTokens The array of pToken addresses to enter.
     * @return results Array of results for each market entry attempt.
     */
    function enterMarkets(
        address[] calldata pTokens
    ) external returns (uint[] memory results) {
        return peridottroller.enterMarkets(pTokens);
    }

    /**
     * @dev Exit market locally (for testing purposes).
     * @param pToken The pToken address to exit.
     * @return result The result of the exit attempt.
     */
    function exitMarket(address pToken) external returns (uint result) {
        return peridottroller.exitMarket(pToken);
    }
}
