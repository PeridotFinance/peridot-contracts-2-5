// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAxelarGateway, IAxelarExecutable, IAxelarGasService} from "./interfaces/AxelarInterfaces.sol";
import {PeridotForwarder} from "./PeridotForwarder.sol";
import {PErc20} from "./PErc20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PeridotHubHandler
 * @author Peridot
 * @notice This contract is the entry point for all cross-chain messages from spoke chains.
 * It implements the IAxelarExecutable interface to receive messages from the Axelar Gateway.
 */
contract PeridotHubHandler is IAxelarExecutable {
    // --- State ---
    address public immutable gasService;
    mapping(address => address) public underlyingToPToken;
    address public peridotForwarder;
    address public owner;

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    // --- Constructor ---
    constructor(address _gateway, address _gasService, address _peridotForwarder)
        IAxelarExecutable(_gateway)
    {
        gasService = _gasService;
        peridotForwarder = _peridotForwarder;
        owner = msg.sender;
    }

    // --- External Functions ---
    function setPeridotForwarder(address _forwarder) external onlyOwner {
        peridotForwarder = _forwarder;
    }

    function setPToken(address underlying, address pToken) external {
        underlyingToPToken[underlying] = pToken;
    }

    receive() external payable {}

    // --- Axelar Execution ---
    function _execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal override {
        // This is for borrow requests
        (PeridotForwarder.UserAction memory action, bytes memory signature) = abi.decode(
            payload,
            (PeridotForwarder.UserAction, bytes)
        );

        // Forward the call to the forwarder to execute the borrow
        // For borrow, action.asset is already the pToken address
        PeridotForwarder(peridotForwarder).borrowFor(action, signature);

        // The forwarder now holds the borrowed tokens. We will send them back to the user on the spoke chain.
        address underlying = PErc20(action.asset).underlying();
        string memory tokenSymbol = PErc20(action.asset).symbol();

        // Encode the payload for the return trip to the spoke chain
        bytes memory spokePayload = abi.encode(action.user, underlying);

        // Approve the Axelar Gateway to spend the tokens
        IERC20(underlying).approve(address(gateway), action.amount);

        // Call the gateway to send the tokens and message back to the source chain
        IAxelarGateway(gateway).callContractWithToken(sourceChain, sourceAddress, spokePayload, tokenSymbol, action.amount);
    }

    function _executeWithToken(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) internal override returns (bytes memory) {
        // This is for supply requests
        (PeridotForwarder.UserAction memory action, bytes memory signature) = abi.decode(
            payload,
            (PeridotForwarder.UserAction, bytes)
        );

        // The tokens have been transferred to this contract by the Axelar Gateway.
        // We need to approve the PeridotForwarder to spend them.
        address pToken = underlyingToPToken[action.asset];
        require(pToken != address(0), "pToken not found for underlying");

        // The underlying token is what the HubHandler holds and needs to approve
        IERC20(action.asset).approve(peridotForwarder, amount);

        // Forward the call to the forwarder to execute the supply
        // We pass the pToken address separately to avoid mutating the signed action
        PeridotForwarder(peridotForwarder).supplyFor(action, pToken, signature);

        return bytes("");
    }
}
