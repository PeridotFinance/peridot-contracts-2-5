// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {AxelarExecutableWithTokenUpgradeable} from "./helpers/AxelarExecutableWithTokenUpgradeable.sol";
import {IAxelarGasService} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGasService.sol";
import {IAxelarGateway} from "@axelar-network/axelar-gmp-sdk-solidity/contracts/interfaces/IAxelarGateway.sol";

/**
 * @title PeridotSpoke
 * @author Peridot
 * @notice This contract allows users on a spoke chain to supply and borrow assets from the Peridot hub chain.
 * It relays user actions to the hub via Axelar GMP.
 */
contract PeridotSpoke is Initializable, AxelarExecutableWithTokenUpgradeable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    // --- State ---

    IAxelarGasService public gasService;
    string public hubChainName;
    string public hubContractAddress;
    address public owner;

    // --- Events ---
    event SupplyToHubRequested(address indexed user, address indexed asset, uint256 amount);
    event BorrowFromHubRequested(address indexed user, address indexed pToken, uint256 amount);
    event TokensReceived(address indexed user, address indexed token, uint256 amount, string sourceChain);
    event HubConfigUpdated(string hubChainName, string hubContractAddress);

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

    // --- Initializer ---
    function initialize(
        address _gateway,
        address _gasService,
        string memory _hubChainName,
        string memory _hubContractAddress,
        address _owner
    ) external initializer {
        __AxelarExecutableWithTokenUpgradeable_init(_gateway);
        require(_gasService != address(0), "Invalid gas service address");
        require(bytes(_hubChainName).length > 0, "Invalid hub chain name");
        require(bytes(_hubContractAddress).length > 0, "Invalid hub contract address");
        require(_owner != address(0), "Invalid owner");

        gasService = IAxelarGasService(_gasService);
        hubChainName = _hubChainName;
        hubContractAddress = _hubContractAddress;
        owner = _owner;
    }

    function setHubConfig(string memory _hubChainName, string memory _hubContractAddress) external onlyOwner {
        require(bytes(_hubChainName).length > 0, "Invalid hub chain name");
        require(bytes(_hubContractAddress).length > 0, "Invalid hub contract address");

        hubChainName = _hubChainName;
        hubContractAddress = _hubContractAddress;
        emit HubConfigUpdated(_hubChainName, _hubContractAddress);
    }

    receive() external payable {}

    function getGateway() external view returns (IAxelarGateway) {
        return gatewayWithToken();
    }

    // --- External Functions ---

    /**
     * @notice Supply assets to the Peridot hub.
     * @param assetSymbol The symbol of the asset to supply (e.g., "WBNB").
     * @param amount The amount of the asset to supply.
     */
    function supplyToPeridot(string calldata assetSymbol, uint256 amount) external payable nonReentrant whenNotPaused {
        require(msg.value > 0, "Gas payment is required");
        require(amount > 0, "Amount must be greater than 0");

        // Resolve token symbol to local address
        address tokenAddress = gatewayWithToken().tokenAddresses(assetSymbol);
        require(tokenAddress != address(0), "Token not supported by Axelar");

        // Transfer tokens from user (msg.sender) to this contract
        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);

        // The user is the message sender
        bytes memory payload = abi.encode(msg.sender);

        // Approve gateway to spend tokens (using simple approve like v1)
        IERC20(tokenAddress).approve(address(gatewayWithToken()), amount);

        // Pay gas for cross-chain execution
        gasService.payNativeGasForContractCallWithToken{value: msg.value}(
            address(this), hubChainName, hubContractAddress, payload, assetSymbol, amount, msg.sender
        );

        // Send tokens and message to hub
        gatewayWithToken().callContractWithToken(hubChainName, hubContractAddress, payload, assetSymbol, amount);

        emit SupplyToHubRequested(msg.sender, tokenAddress, amount);
    }

    /**
     * @notice Borrow assets from the Peridot hub.
     * @param pTokenAddress The address of the pToken to borrow against on the hub chain.
     * @param borrowAmount The amount of the asset to borrow.
     */
    function borrowFromPeridot(address pTokenAddress, uint256 borrowAmount)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        require(msg.value > 0, "Gas payment is required");
        require(borrowAmount > 0, "Amount must be greater than 0");

        // For a borrow, the payload contains the user, the pToken to borrow against, and the amount
        bytes memory payload = abi.encode(msg.sender, pTokenAddress, borrowAmount);

        // Pay gas for cross-chain execution (message only, no tokens)
        gasService.payNativeGasForContractCall{value: msg.value}(
            address(this), hubChainName, hubContractAddress, payload, msg.sender
        );

        // Send message to hub
        gatewayWithToken().callContract(hubChainName, hubContractAddress, payload);

        emit BorrowFromHubRequested(msg.sender, pTokenAddress, borrowAmount);
    }

    // --- Axelar Execution Functions ---

    /**
     * @notice Handles incoming messages from the hub (should not be used for this protocol)
     */
    function _execute(
        bytes32, /* commandId */
        string calldata, /* sourceChain */
        string calldata, /* sourceAddress */
        bytes calldata /* payload */
    ) internal override whenNotPaused {
        revert("Unexpected message without tokens");
    }

    /**
     * @notice Receives borrowed tokens from the hub chain.
     */
    function _executeWithToken(
        bytes32, /* commandId */
        string calldata sourceChain,
        string calldata sourceAddress,
        bytes calldata payload,
        string calldata tokenSymbol,
        uint256 amount
    ) internal override nonReentrant whenNotPaused {
        // Validate the message is from our hub
        require(
            keccak256(abi.encodePacked(sourceChain)) == keccak256(abi.encodePacked(hubChainName)),
            "Invalid source chain"
        );
        require(
            keccak256(abi.encodePacked(sourceAddress)) == keccak256(abi.encodePacked(hubContractAddress)),
            "Invalid source address"
        );

        // Decode the payload to get the user who should receive the tokens
        address user = abi.decode(payload, (address));

        // Get local token address
        address tokenAddress = gatewayWithToken().tokenAddresses(tokenSymbol);
        require(tokenAddress != address(0), "Unsupported token");

        // Transfer tokens to the user
        IERC20(tokenAddress).safeTransfer(user, amount);

        // Emit event for monitoring
        emit TokensReceived(user, tokenAddress, amount, sourceChain);
    }
}
