// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";

/**
 * @title WhitelistRouterAdapter
 * @notice Adapter that forwards swaps to pre-approved venues and enforces selector allowlists.
 */
contract WhitelistRouterAdapter is IMarginRouterAdapter, Ownable {
    using SafeERC20 for IERC20;

    struct SelectorConfig {
        bool useSelectorWhitelist;
    }

    address public manager;

    mapping(address => bool) public whitelistedTargets;
    mapping(address => mapping(bytes4 => bool)) public whitelistedSelectors;
    mapping(address => SelectorConfig) public targetSelectorConfig;
    mapping(address => bool) public operators;

    event ManagerUpdated(address indexed newManager);
    event TargetWhitelistUpdated(address indexed target, bool allowed);
    event SelectorWhitelistUpdated(address indexed target, bytes4 indexed selector, bool allowed);
    event OperatorUpdated(address indexed operator, bool allowed);
    event SwapForwarded(
        address indexed fromAccount,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    modifier onlyManager() {
        require(operators[msg.sender], "Adapter: not authorized");
        _;
    }

    constructor(address owner_) Ownable(owner_) {}

    function setManager(address newManager) external onlyOwner {
        if (manager != address(0)) {
            operators[manager] = false;
            emit OperatorUpdated(manager, false);
        }
        manager = newManager;
        if (newManager != address(0)) {
            operators[newManager] = true;
            emit OperatorUpdated(newManager, true);
        }
        emit ManagerUpdated(newManager);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function setTargetWhitelist(address target, bool allowed, bool enforceSelectorWhitelist) external onlyOwner {
        whitelistedTargets[target] = allowed;
        targetSelectorConfig[target].useSelectorWhitelist = enforceSelectorWhitelist && allowed;
        emit TargetWhitelistUpdated(target, allowed);
    }

    function setSelectorWhitelist(address target, bytes4 selector, bool allowed) external onlyOwner {
        whitelistedSelectors[target][selector] = allowed;
        emit SelectorWhitelistUpdated(target, selector, allowed);
    }

    function swap(
        address fromAccount,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override onlyManager returns (uint256 amountOut) {
        (address target, bytes memory callData) = abi.decode(data, (address, bytes));
        require(whitelistedTargets[target], "Adapter: target not allowed");

        if (targetSelectorConfig[target].useSelectorWhitelist && callData.length >= 4) {
            bytes4 selector;
            assembly {
                selector := mload(add(callData, 32))
            }
            require(whitelistedSelectors[target][selector], "Adapter: selector not allowed");
        }

        IERC20 tokenInContract = IERC20(tokenIn);
        IERC20 tokenOutContract = IERC20(tokenOut);

        uint256 adapterTokenOutBefore = tokenOutContract.balanceOf(address(this));
        uint256 accountTokenOutBefore = tokenOutContract.balanceOf(fromAccount);

        tokenInContract.safeTransferFrom(fromAccount, address(this), amountIn);
        tokenInContract.forceApprove(target, amountIn);

        (bool success,) = target.call(callData);
        require(success, "Adapter: venue call failed");

        tokenInContract.forceApprove(target, 0);

        uint256 adapterTokenOutAfter = tokenOutContract.balanceOf(address(this));
        uint256 adapterDelta = adapterTokenOutAfter - adapterTokenOutBefore;

        if (adapterDelta > 0) {
            amountOut = adapterDelta;
            tokenOutContract.safeTransfer(fromAccount, adapterDelta);
        } else {
            uint256 accountTokenOutAfter = tokenOutContract.balanceOf(fromAccount);
            amountOut = accountTokenOutAfter - accountTokenOutBefore;
        }

        require(amountOut >= minAmountOut, "Adapter: insufficient output");

        emit SwapForwarded(fromAccount, tokenIn, tokenOut, amountIn, amountOut);

        uint256 leftoverIn = tokenInContract.balanceOf(address(this));
        if (leftoverIn > 0) {
            tokenInContract.safeTransfer(fromAccount, leftoverIn);
        }
    }
}
