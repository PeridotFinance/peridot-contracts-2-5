// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAxelarGateway, IAxelarGasService, IAxelarExecutable} from "../contracts/interfaces/AxelarInterfaces.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {PeridotHubHandler} from "../contracts/PeridotHubHandler.sol";

contract MockAxelarGateway is IAxelarGateway, IAxelarGasService {
    // Local struct mirroring PeridotForwarder.UserAction for decoding
    struct UserAction {
        address user;
        address asset;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }
    address public gasService;
    address payable public hubHandler;

    constructor() {
        gasService = address(this);
    }

    function setHubHandler(address payable _hubHandler) public {
        hubHandler = _hubHandler;
    }

    function callContractWithToken(
        string calldata destinationChain,
        string calldata destinationAddress,
        bytes calldata payload,
        string calldata symbol,
        uint256 amount
    ) external payable {
        if (msg.sender == hubHandler) {
            // This is a hub-to-spoke transfer (borrow return trip)
            // Decode the payload to get the user address and token address
            (address user, address tokenAddr) = abi.decode(payload, (address, address));
            
            // Transfer tokens from hub handler to the user (simulating cross-chain delivery)
            if (amount > 0) {
                IERC20(tokenAddr).transferFrom(hubHandler, user, amount);
            }
        } else {
            // This is a spoke-to-hub transfer (supply operation)
            (address user, address tokenAddr, ) = decodeUserAction(payload);
            
            // The gateway pulls the tokens from the user and forwards them to the hub handler
            if (amount > 0) {
                IERC20(tokenAddr).transferFrom(user, hubHandler, amount);
            }

            string memory sourceAddress = Strings.toHexString(uint256(uint160(user)));
            if (amount > 0) {
                PeridotHubHandler(hubHandler).executeWithToken{value: msg.value}(bytes32(0), "SpokeChain", sourceAddress, payload, symbol, amount);
            } else {
                PeridotHubHandler(hubHandler).execute{value: msg.value}(bytes32(0), "SpokeChain", sourceAddress, payload);
            }
        }
    }

    function callContract(string calldata destinationChain, string calldata destinationAddress, bytes calldata payload) external payable {
        (address user, address tokenAddr, uint256 amount) = decodeUserAction(payload);
        string memory sourceAddress = Strings.toHexString(uint256(uint160(user)));
        // callContract is used for borrow operations - always call execute, never executeWithToken
        PeridotHubHandler(hubHandler).execute{value: msg.value}(bytes32(0), "SpokeChain", sourceAddress, payload);
    }

    function payNativeGasForContractCallWithToken(
        address, // source
        string calldata, // destinationChain
        string calldata, // destinationContract (address in string form)
        bytes calldata, // payload
        string calldata, // symbol
        uint256, // amount
        address // refundAddress
    ) external payable {}

    function payNativeGasForContractCall(
        address,
        string calldata,
        string calldata, // destinationAddress
        bytes calldata,
        address
    ) external payable {}

    // ----------------- Helper decoding functions -----------------
    // These helper functions are used via try/catch to safely extract token address information from arbitrary payloads.

    /**
     * @notice Decode a supply payload of form abi.encode(UserAction, signature)
     * @param payload The calldata payload
     * @return user The user address contained in the UserAction struct
     * @return asset The asset address contained in the UserAction struct
     * @return amount The amount contained in the UserAction struct
     */
    function decodeUserAction(bytes memory payload) public pure returns (address user, address asset, uint256 amount) {
        (UserAction memory action, /* bytes memory signature */) = abi.decode(payload, (UserAction, bytes));
        user = action.user;
        asset = action.asset;
        amount = action.amount;
    }

    function decodeUserActionAsset(bytes memory payload) public pure returns (address asset) {
        (UserAction memory action, /* bytes memory signature */) = abi.decode(payload, (UserAction, bytes));
        asset = action.asset;
    }

    /**
     * @notice Decode a borrow-return payload of form abi.encode(user, tokenAddr)
     * @param payload The calldata payload
     * @return token The token address
     */
    function decodeTokenAddr(bytes memory payload) external pure returns (address token) {
        (/* address user */, address tokenAddr) = abi.decode(payload, (address, address));
        token = tokenAddr;
    }


}
