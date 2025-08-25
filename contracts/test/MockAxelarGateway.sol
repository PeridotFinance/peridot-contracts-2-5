// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAxelarGateway, IAxelarGasService, IAxelarExecutable} from "../contracts/interfaces/AxelarInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PeridotHubHandler} from "../contracts/PeridotHubHandler.sol";

contract MockAxelarGateway is IAxelarGateway, IAxelarGasService {
    address public gasService;
    address payable public hubHandler;

    constructor() {
        gasService = address(this);
    }

    function setHubHandler(address payable _hubHandler) public {
        hubHandler = _hubHandler;
    }

    // Simulates a cross-chain call that includes a token transfer.
    function callContractWithToken(
        string calldata, // destinationChain
        string calldata, // destinationAddress
        bytes calldata payload,
        string calldata symbol,
        uint256 amount
    ) external payable {
        if (msg.sender == hubHandler) {
            // --- Hub-to-Spoke Transfer (Borrow Return Trip) ---
            // The hub sends tokens back to a user on the spoke chain.
            address tokenAddr = tokenAddresses(symbol);
            address user = abi.decode(payload, (address));

            // Simulate the token transfer from the HubHandler to the end user.
            IERC20(tokenAddr).transferFrom(hubHandler, user, amount);
        } else {
            // --- Spoke-to-Hub Transfer (Supply Operation) ---
            // 1. Simulate the gateway pulling tokens from the Spoke contract (msg.sender).
            address tokenAddr = tokenAddresses(symbol);
            IERC20(tokenAddr).transferFrom(msg.sender, hubHandler, amount);

            // 2. Simulate the gateway calling the HubHandler.
            // The sourceAddress in a real transaction would be the Spoke contract's address as a string.
            string memory sourceAddressStr = Strings.toHexString(uint256(uint160(msg.sender)), 20);

            PeridotHubHandler(hubHandler).executeWithToken(
                bytes32(0),
                "Ethereum", // Mock source chain
                sourceAddressStr,
                payload,
                symbol,
                amount
            );
        }
    }

    // Simulates a cross-chain call without a token transfer.
    function callContract(
        string calldata, // destinationChain
        string calldata, // destinationAddress
        bytes calldata payload
    ) external payable {
        // --- Spoke-to-Hub Transfer (Borrow Request) ---
        // This is a message from the Spoke contract to the HubHandler to initiate a borrow.
        // The sourceAddress is the Spoke contract's address.
        string memory sourceAddressStr = Strings.toHexString(uint256(uint160(msg.sender)), 20);

        PeridotHubHandler(hubHandler).execute(
            bytes32(0),
            "Ethereum", // Mock source chain
            sourceAddressStr,
            payload
        );
    }

    // --- Mock Gas Service Functions ---
    function payNativeGasForContractCallWithToken(
        address,
        string calldata,
        string calldata,
        bytes calldata,
        string calldata,
        uint256,
        address
    ) external payable {}

    function payNativeGasForContractCall(address, string calldata, string calldata, bytes calldata, address)
        external
        payable
    {}

    // --- Mock Token Registry ---
    mapping(string => address) private _tokenAddresses;

    function setTokenAddress(string memory symbol, address token) external {
        _tokenAddresses[symbol] = token;
    }

    function tokenAddresses(string memory symbol) public view returns (address) {
        return _tokenAddresses[symbol];
    }

    // --- Mock Validation Functions (Always true for tests) ---
    function validateContractCallAndMint(bytes32, string calldata, string calldata, bytes32, string calldata, uint256)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function validateContractCall(bytes32, string calldata, string calldata, bytes32) external pure returns (bool) {
        return true;
    }
}
