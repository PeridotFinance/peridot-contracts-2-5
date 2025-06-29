// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {OwnerIsCreator} from "@chainlink/contracts/src/v0.8/shared/access/OwnerIsCreator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/**
 * @title PeridotCCIPSender
 * @dev A CCIP sender contract that can request Peridot protocol data from other chains.
 */
contract PeridotCCIPSender is OwnerIsCreator {
    event CrossChainLiquidityRequestSent(
        bytes32 indexed messageId,
        uint64 indexed destinationChainSelector,
        address indexed account,
        address receiver,
        uint256 fees
    );

    // Supported request types (must match PeridotCCIPReader)
    enum RequestType {
        GET_ACCOUNT_LIQUIDITY
    }

    IRouterClient private s_router;

    // Mapping to track allowed destination chains
    mapping(uint64 => bool) public allowedDestinationChains;

    // Mapping to track allowed receivers per destination chain
    mapping(uint64 => address) public allowedReceivers;

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
     * @dev Request account liquidity from a Peridot protocol on another chain.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _account The account to check liquidity for.
     * @param _feeToken The address of the token to pay for fees. Set to address(0) for native gas.
     * @return messageId The ID of the sent message.
     */
    function requestAccountLiquidity(
        uint64 _destinationChainSelector,
        address _account,
        address _feeToken
    ) external payable onlyOwner returns (bytes32 messageId) {
        // Validate destination chain is allowed
        require(
            allowedDestinationChains[_destinationChainSelector],
            "Destination chain not allowed"
        );

        // Get the receiver address for this destination chain
        address receiver = allowedReceivers[_destinationChainSelector];
        require(
            receiver != address(0),
            "No receiver set for destination chain"
        );

        // Encode the request
        bytes memory requestData = abi.encode(_account);
        bytes memory messageData = abi.encode(
            RequestType.GET_ACCOUNT_LIQUIDITY,
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
            // Note: The caller must have approved this contract to spend the fee token
            messageId = s_router.ccipSend(_destinationChainSelector, message);
        }

        emit CrossChainLiquidityRequestSent(
            messageId,
            _destinationChainSelector,
            _account,
            receiver,
            fees
        );

        return messageId;
    }

    /**
     * @dev Get the fee required to send a liquidity request.
     * @param _destinationChainSelector The chain selector of the destination chain.
     * @param _account The account to check liquidity for.
     * @param _feeToken The address of the token to pay for fees.
     * @return fee The fee required.
     */
    function getFeeForLiquidityRequest(
        uint64 _destinationChainSelector,
        address _account,
        address _feeToken
    ) external view returns (uint256 fee) {
        // Get the receiver address for this destination chain
        address receiver = allowedReceivers[_destinationChainSelector];
        require(
            receiver != address(0),
            "No receiver set for destination chain"
        );

        // Encode the request (same as in requestAccountLiquidity)
        bytes memory requestData = abi.encode(_account);
        bytes memory messageData = abi.encode(
            RequestType.GET_ACCOUNT_LIQUIDITY,
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
