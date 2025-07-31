// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAxelarGateway, IAxelarGasService} from "./interfaces/AxelarInterfaces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EIP20Interface} from "./EIP20Interface.sol";

/**
 * @title PeridotSpoke
 * @author Peridot
 * @notice This contract allows users on a spoke chain to supply and borrow assets from the Peridot hub chain.
 * It captures user intents via EIP-712 signatures and relays them to the hub via Axelar GMP.
 */
contract PeridotSpoke is EIP712 {
    // --- Constants ---
    string public constant SUPPLY_ACTION = "supply";
    string public constant BORROW_ACTION = "borrow";

    // --- State ---
    IAxelarGateway public immutable gateway;
    string public hubChainName;
    string public hubContractAddress;
    address public pTokenAddr;

    // --- Events ---
    event SupplyToHubRequested(
        address indexed user,
        address indexed asset,
        uint256 amount,
        bytes signature
    );
    event BorrowFromHubRequested(
        address indexed user,
        address indexed asset,
        uint256 amount,
        bytes signature
    );

    // --- Structs ---
    struct UserAction {
        address user;
        address asset;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    // --- Constructor ---
    constructor(
        address _gateway,
        string memory _hubChainName,
        string memory _hubContractAddress
    ) EIP712("PeridotSpoke", "1") {
        gateway = IAxelarGateway(_gateway);
        hubChainName = _hubChainName;
        hubContractAddress = _hubContractAddress;
    }

    function setPToken(address _pTokenAddr) external {
        pTokenAddr = _pTokenAddr;
    }

    receive() external payable {}

    // --- External Functions ---

    /**
     * @notice Supply assets to the Peridot hub.
     * @param user The address of the user.
     * @param asset The address of the asset to supply.
     * @param amount The amount of the asset to supply.
     * @param signature The EIP-712 signature from the user authorizing the action.
     */
    function supplyToPeridot(
        address user,
        address asset,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external payable {
        _execute(user, asset, amount, nonce, deadline, signature, amount);
        emit SupplyToHubRequested(user, asset, amount, signature);
    }

    /**
     * @notice Borrow assets from the Peridot hub.
     * @param user The address of the user.
     * @param asset The address of the asset to borrow.
     * @param amount The amount of the asset to borrow.
     * @param signature The EIP-712 signature from the user authorizing the action.
     */
    function borrowFromPeridot(
        address user,
        address asset,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external payable {
        // For a borrow, the amount transferred on the spoke chain is 0.
        // The `amount` in the UserAction payload tells the hub how much to borrow.
        _execute(user, asset, amount, nonce, deadline, signature, 0);
        emit BorrowFromHubRequested(user, asset, amount, signature);
    }

    function _execute(
        address user,
        address asset,
        uint256 amount,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature,
        uint256 supplyAmount
    ) internal {
        UserAction memory action = UserAction(user, asset, amount, nonce, deadline);

        if (supplyAmount > 0) {
            // Supply operation: send tokens with the message
            bytes memory payload = abi.encode(action, signature);
            string memory tokenSymbol = EIP20Interface(asset).symbol();
            gateway.callContractWithToken{value: msg.value}(hubChainName, hubContractAddress, payload, tokenSymbol, supplyAmount);
        } else {
            // Borrow operation: send only a message, no tokens
            bytes memory payload = abi.encode(action, signature);
            gateway.callContract{value: msg.value}(hubChainName, hubContractAddress, payload);
        }
    }

    // --- Internal Functions ---

    function _getActionHash(UserAction memory action) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    keccak256("UserAction(address user,address asset,uint256 amount,uint256 nonce,uint256 deadline)"),
                    action.user,
                    action.asset,
                    action.amount,
                    action.nonce,
                    action.deadline
                )
            )
        );
    }
}
