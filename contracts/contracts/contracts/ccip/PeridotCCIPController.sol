// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/**
 * @title PeridotCCIPController
 * @dev A CCIP sender contract that can send state-changing requests to Peridot protocol on other chains.
 */
contract PeridotCCIPController is OwnerIsCreator {
    event CrossChainEnterMarketsRequestSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed user,
        address[] pTokens,
        address receiver,
        uint256 fees
    );

    event CrossChainExitMarketRequestSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed user,
        address pToken,
        address receiver,
        uint256 fees
    );

    // Supported request types (must match PeridotCCIPAdapter)
    enum RequestType {
        ENTER_MARKETS,
        EXIT_MARKET
    }

    IRouterClient private s_router;

    // Mapping to track allowed destination chains
    mapping(uint64 => bool) public allowedDestinationChains;

    // Mapping to track allowed receivers per destination chain
    mapping(uint64 => address) public allowedReceivers;

    // Mapping to track user authorizations for cross-chain operations
    mapping(address => mapping(uint64 => bool)) public userAuthorizations;

    /**
     * @dev Constructor initializes the contract with the router address.
     * @param _router The address of the router contract.
     */
    constructor(address _router) {
        s_router = IRouterClient(_router);
    }

    /**
     * @dev Allow a destination chain to receive messages from this contract.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _allowed Whether the destination chain is allowed.
     */
    function allowlistDestinationChain(
        uint64 _destinationChainSelector,
        bool _allowed
    ) external onlyOwner {
        allowedDestinationChains[_destinationChainSelector] = _allowed;
    }

    /**
     * @dev Set the receiver contract address for a destination chain.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _receiver The address of the receiver contract on the destination chain.
     */
    function setReceiver(
        uint64 _destinationChainSelector,
        address _receiver
    ) external onlyOwner {
        allowedReceivers[_destinationChainSelector] = _receiver;
    }

    /**
     * @dev Authorize cross-chain operations for a user on a specific destination chain.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _authorized Whether the user is authorized.
     */
    function authorizeUserForChain(
        uint64 _destinationChainSelector,
        bool _authorized
    ) external {
        userAuthorizations[msg.sender][_destinationChainSelector] = _authorized;
    }

    /**
     * @dev Request to enter markets on behalf of a user on another chain.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _user The user to enter markets for.
     * @param _pTokens The array of pToken addresses to enter.
     * @param _feeToken The address of the token to pay for fees. Set to address(0) for native gas.
     * @return messageId The ID of the sent message.
     */
    function requestEnterMarkets(
        uint64 _destinationChainSelector,
        address _user,
        address[] calldata _pTokens,
        address _feeToken
    ) external payable returns (bytes32 messageId) {
        // Validate destination chain is allowed
        require(
            allowedDestinationChains[_destinationChainSelector],
            "Destination chain not allowed"
        );

        // Check authorization - either the user themselves or an authorized operator
        require(
            msg.sender == _user ||
                userAuthorizations[_user][_destinationChainSelector],
            "Not authorized to act for this user"
        );

        // Get the receiver address for this destination chain
        address receiver = allowedReceivers[_destinationChainSelector];
        require(
            receiver != address(0),
            "No receiver set for destination chain"
        );

        // Encode the request
        bytes memory requestData = abi.encode(_pTokens);
        bytes memory messageData = abi.encode(
            RequestType.ENTER_MARKETS,
            _user,
            requestData
        );

        // Create the CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: messageData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 500_000})
            ), // Higher gas limit for Peridot calls
            feeToken: _feeToken
        });

        // Calculate fees
        uint256 fees = s_router.getFee(_destinationChainSelector, message);

        // Send the message
        if (_feeToken == address(0)) {
            // Pay with native gas
            require(msg.value >= fees, "Insufficient fee provided");
            messageId = s_router.ccipSend{value: fees}(
                _destinationChainSelector,
                message
            );
        } else {
            // Pay with ERC20 token (LINK)
            messageId = s_router.ccipSend(_destinationChainSelector, message);
        }

        emit CrossChainEnterMarketsRequestSent(
            messageId,
            _destinationChainSelector,
            _user,
            _pTokens,
            receiver,
            fees
        );

        return messageId;
    }

    /**
     * @dev Request to exit a market on behalf of a user on another chain.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _user The user to exit market for.
     * @param _pToken The pToken address to exit.
     * @param _feeToken The address of the token to pay for fees. Set to address(0) for native gas.
     * @return messageId The ID of the sent message.
     */
    function requestExitMarket(
        uint64 _destinationChainSelector,
        address _user,
        address _pToken,
        address _feeToken
    ) external payable returns (bytes32 messageId) {
        // Validate destination chain is allowed
        require(
            allowedDestinationChains[_destinationChainSelector],
            "Destination chain not allowed"
        );

        // Check authorization - either the user themselves or an authorized operator
        require(
            msg.sender == _user ||
                userAuthorizations[_user][_destinationChainSelector],
            "Not authorized to act for this user"
        );

        // Get the receiver address for this destination chain
        address receiver = allowedReceivers[_destinationChainSelector];
        require(
            receiver != address(0),
            "No receiver set for destination chain"
        );

        // Encode the request
        bytes memory requestData = abi.encode(_pToken);
        bytes memory messageData = abi.encode(
            RequestType.EXIT_MARKET,
            _user,
            requestData
        );

        // Create the CCIP message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: messageData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 500_000})
            ),
            feeToken: _feeToken
        });

        // Calculate fees
        uint256 fees = s_router.getFee(_destinationChainSelector, message);

        // Send the message
        if (_feeToken == address(0)) {
            // Pay with native gas
            require(msg.value >= fees, "Insufficient fee provided");
            messageId = s_router.ccipSend{value: fees}(
                _destinationChainSelector,
                message
            );
        } else {
            // Pay with ERC20 token (LINK)
            messageId = s_router.ccipSend(_destinationChainSelector, message);
        }

        emit CrossChainExitMarketRequestSent(
            messageId,
            _destinationChainSelector,
            _user,
            _pToken,
            receiver,
            fees
        );

        return messageId;
    }

    /**
     * @dev Get the fee required to send an enter markets request.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _pTokens The array of pToken addresses.
     * @param _feeToken The address of the token to pay for fees.
     * @return fee The fee required.
     */
    function getFeeForEnterMarketsRequest(
        uint64 _destinationChainSelector,
        address[] calldata _pTokens,
        address _feeToken
    ) external view returns (uint256 fee) {
        address receiver = allowedReceivers[_destinationChainSelector];
        require(
            receiver != address(0),
            "No receiver set for destination chain"
        );

        bytes memory requestData = abi.encode(_pTokens);
        bytes memory messageData = abi.encode(
            RequestType.ENTER_MARKETS,
            msg.sender, // dummy user for fee calculation
            requestData
        );

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: messageData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 500_000})
            ),
            feeToken: _feeToken
        });

        return s_router.getFee(_destinationChainSelector, message);
    }

    /**
     * @dev Get the fee required to send an exit market request.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _pToken The pToken address.
     * @param _feeToken The address of the token to pay for fees.
     * @return fee The fee required.
     */
    function getFeeForExitMarketRequest(
        uint64 _destinationChainSelector,
        address _pToken,
        address _feeToken
    ) external view returns (uint256 fee) {
        address receiver = allowedReceivers[_destinationChainSelector];
        require(
            receiver != address(0),
            "No receiver set for destination chain"
        );

        bytes memory requestData = abi.encode(_pToken);
        bytes memory messageData = abi.encode(
            RequestType.EXIT_MARKET,
            msg.sender, // dummy user for fee calculation
            requestData
        );

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(receiver),
            data: messageData,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            extraArgs: Client._argsToBytes(
                Client.EVMExtraArgsV1({gasLimit: 500_000})
            ),
            feeToken: _feeToken
        });

        return s_router.getFee(_destinationChainSelector, message);
    }

    /**
     * @dev Withdraw native tokens from this contract.
     * @param _beneficiary The address to send the tokens to.
     */
    function withdraw(address _beneficiary) public onlyOwner {
        uint256 amount = address(this).balance;
        require(amount > 0, "Nothing to withdraw");

        (bool sent, ) = _beneficiary.call{value: amount}("");
        require(sent, "Failed to withdraw");
    }

    /**
     * @dev Allow the contract to receive native tokens.
     */
    receive() external payable {}
}
