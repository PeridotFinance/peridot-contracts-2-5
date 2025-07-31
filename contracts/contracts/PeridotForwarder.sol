// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {PErc20CrossChain} from "./PErc20CrossChain.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title PeridotForwarder
 * @author Peridot
 * @notice This contract verifies user signatures and executes actions on the Peridot hub on their behalf.
 * It is the only contract authorized to call `mintFor` and `borrowFor` on the pTokens.
 */
contract PeridotForwarder is EIP712 {
    mapping(address => uint256) public nonces;

    constructor() EIP712("PeridotForwarder", "1") {}

    struct UserAction {
        address user;
        address asset;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    function supplyFor(UserAction calldata action, address pToken, bytes calldata signature) external {
        _verifySignature(action, signature);
        nonces[action.user]++;

        // The user action is signed on the underlying, but the minting happens on the pToken.
        address underlying = PErc20CrossChain(pToken).underlying();
        require(underlying == action.asset, "pToken does not match underlying asset");

        // Move underlying tokens from the caller (HubHandler) to this contract
        IERC20(underlying).transferFrom(msg.sender, address(this), action.amount);

        // Approve pToken to pull underlying from this contract
        IERC20(underlying).approve(pToken, action.amount);

        // Forward the call to the pToken contract which will pull the tokens and mint pTokens to the user
        PErc20CrossChain(pToken).mintFor(action.user, action.amount);
    }

    function borrowFor(UserAction calldata action, bytes calldata signature) external {
        _verifySignature(action, signature);
        nonces[action.user]++;

        // Borrow on behalf of the user. pToken will send the tokens to this contract.
        PErc20CrossChain(action.asset).borrowFor(action.user, action.amount);

        // After receiving the borrowed tokens, forward them to the HubHandler (msg.sender)
        address underlying = PErc20CrossChain(action.asset).underlying();
        IERC20(underlying).transfer(msg.sender, action.amount);
    }

    function getTypedDataHash(UserAction calldata action) public view returns (bytes32) {
        return _getTypedDataHash(action);
    }

    function _getTypedDataHash(UserAction calldata action) internal view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            keccak256("UserAction(address user,address asset,uint256 amount,uint256 nonce,uint256 deadline)"),
            action.user,
            action.asset,
            action.amount,
            action.nonce,
            action.deadline
        )));
    }

    function _verify(UserAction calldata action, bytes calldata signature) internal view returns (address) {
        bytes32 digest = _getTypedDataHash(action);
        address signer = ECDSA.recover(digest, signature);
        require(signer == action.user, "Invalid signature: signer != action.user");
        return signer;
    }

    function _verifySignature(UserAction calldata action, bytes calldata signature) internal view {
        _verify(action, signature);
        // If deadline is set (non-zero) enforce it, otherwise treat 0 as no expiry
        if (action.deadline != 0) {
            require(block.timestamp <= action.deadline, "Signature expired");
        }
        require(nonces[action.user] == action.nonce, "Invalid nonce");
    }
}
