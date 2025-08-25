// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AxelarExecutableWithToken} from
    "@axelar-network/axelar-gmp-sdk-solidity/contracts/executable/AxelarExecutableWithToken.sol";
import {PErc20CrossChain} from "./PErc20CrossChain.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title PeridotHubHandler
 * @author Peridot
 * @notice This contract is the entry point for all cross-chain messages from spoke chains.
 * It implements the IAxelarExecutable interface to receive messages from the Axelar Gateway.
 */
contract PeridotHubHandler is AxelarExecutableWithToken, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    // --- Events ---

    event BorrowExecuted(address indexed user, address indexed asset, uint256 amount, string sourceChain);
    event SupplyExecuted(address indexed user, address indexed asset, uint256 amount, string sourceChain);
    event TokensSentBack(address indexed user, address indexed token, uint256 amount, string destinationChain);
    event SpokeContractUpdated(string indexed chain, string indexed oldSpokeContract, string indexed newSpokeContract);
    event PTokenMappingUpdated(address indexed underlying, address indexed pToken);

    // --- State ---
    address public immutable gasService;
    mapping(address => address) public underlyingToPToken;
    mapping(string => string) public spokeContracts; // Mapping from chain name to spoke contract address
    mapping(address => bool) public allowedPToken; // allowlist of pTokens
    mapping(address => string) public underlyingToAxelarSymbol; // remove runtime symbol dependency
    address public owner;

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- Constructor ---
    constructor(address _gateway, address _gasService) AxelarExecutableWithToken(_gateway) {
        gasService = _gasService;
        owner = msg.sender;
    }

    // --- External Functions ---
    function setSpokeContract(string calldata chain, string calldata spokeContract) external onlyOwner {
        require(bytes(chain).length > 0, "Invalid chain name");
        require(bytes(spokeContract).length > 0, "Invalid spoke address");
        string memory oldSpokeContract = spokeContracts[chain];
        spokeContracts[chain] = spokeContract;
        emit SpokeContractUpdated(chain, oldSpokeContract, spokeContract);
    }

    function setPToken(address underlying, address pToken) external onlyOwner {
        require(underlying != address(0), "Invalid underlying address");
        require(pToken != address(0), "Invalid pToken address");
        underlyingToPToken[underlying] = pToken;
        emit PTokenMappingUpdated(underlying, pToken);
    }

    function setAllowedPToken(address pToken, bool allowed) external onlyOwner {
        require(pToken != address(0), "Invalid pToken address");
        allowedPToken[pToken] = allowed;
    }

    function setUnderlyingAxelarSymbol(address underlying, string calldata axelarSymbol) external onlyOwner {
        require(underlying != address(0), "Invalid underlying address");
        require(bytes(axelarSymbol).length > 0, "Invalid Axelar symbol");
        underlyingToAxelarSymbol[underlying] = axelarSymbol;
    }

    receive() external payable {}

    // --- Axelar Execution ---
    function _execute(
        bytes32, /*commandId*/
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload
    ) internal override nonReentrant whenNotPaused {
        // This is for borrow requests
        require(
            keccak256(bytes(sourceAddress)) == keccak256(bytes(spokeContracts[sourceChain])),
            "Caller is not the authorized spoke contract"
        );

        (address user, address pTokenAddress, uint256 borrowAmount) = abi.decode(payload, (address, address, uint256));

        PErc20CrossChain pToken = PErc20CrossChain(pTokenAddress);

        // Enforce pToken allowlist and mapping correctness
        require(allowedPToken[pTokenAddress], "pToken not allowed");
        address underlying = pToken.underlying();
        require(underlyingToPToken[underlying] == pTokenAddress, "pToken mismatch for underlying");

        // This contract (HubHandler) will call borrowFor, so it needs to hold the tokens
        pToken.borrowFor(user, borrowAmount);

        // The HubHandler now holds the borrowed tokens. We will send them back to the user on the spoke chain.
        // Resolve axelar symbol from admin-set mapping (no runtime symbol dependency)
        string memory tokenSymbol = underlyingToAxelarSymbol[underlying];
        require(bytes(tokenSymbol).length > 0, "Missing Axelar symbol mapping");

        // Check that this contract has sufficient balance
        uint256 balance = IERC20(underlying).balanceOf(address(this));
        require(balance >= borrowAmount, "Insufficient token balance for return transfer");

        // Encode the payload for the return trip to the spoke chain (user who will receive tokens)
        bytes memory spokePayload = abi.encode(user);

        // Approve the Axelar Gateway to spend the tokens
        IERC20(underlying).approve(address(gatewayWithToken()), borrowAmount);

        // Call the gateway to send the tokens and message back to the source chain
        gatewayWithToken().callContractWithToken(
            sourceChain,
            sourceAddress, // Send back to the original spoke contract
            spokePayload,
            tokenSymbol,
            borrowAmount
        );

        // Emit events for monitoring
        emit BorrowExecuted(user, underlying, borrowAmount, sourceChain);
        emit TokensSentBack(user, underlying, borrowAmount, sourceChain);
    }

    function _executeWithToken(
        bytes32, /*commandId*/
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) internal override nonReentrant whenNotPaused {
        // This is for supply requests
        require(
            keccak256(bytes(sourceAddress)) == keccak256(bytes(spokeContracts[sourceChain])),
            "Caller is not the authorized spoke contract"
        );

        address user = abi.decode(payload, (address));

        // Get the token address on this chain (hub chain)
        address hubTokenAddress = gatewayWithToken().tokenAddresses(tokenSymbol);
        require(hubTokenAddress != address(0), "Token not supported by Axelar");

        // The tokens have been transferred to this contract by the Axelar Gateway.
        // We need to approve the pToken contract to spend them.
        address pToken = underlyingToPToken[hubTokenAddress];
        require(pToken != address(0), "pToken not found for underlying");

        // The underlying token is what the HubHandler holds and needs to approve
        IERC20(hubTokenAddress).approve(pToken, amount);

        // Directly call mintFor on the pToken contract
        PErc20CrossChain(pToken).mintFor(user, amount);

        // Emit event for monitoring
        emit SupplyExecuted(user, hubTokenAddress, amount, sourceChain);
    }
}
