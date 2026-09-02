// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";

interface ILFJLBRouter {
    enum Version {
        V1,
        V2,
        V2_1,
        V2_2
    }

    struct Path {
        uint256[] pairBinSteps;
        Version[] versions;
        IERC20[] tokenPath;
    }

    function getWNATIVE() external view returns (address);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Path memory path,
        address to,
        uint256 deadline
    ) external returns (uint256 amountOut);
}

/**
 * @notice Timelocked, one-hop LFJ Liquidity Book adapter for isolated margin.
 * @dev Supports only LB V2.1 and V2.2 ERC-20 routes explicitly approved by governance.
 *      The router is immutable; changing venues requires a new adapter plus the margin-config delay.
 */
contract LFJLBRouterAdapter is IMarginRouterAdapter, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_ACTION_DELAY = 1 hours;
    uint256 public constant SWAP_DEADLINE_BUFFER = 5 minutes;

    ILFJLBRouter public immutable router;
    uint256 public immutable actionDelay;

    mapping(address operator => bool allowed) public operators;
    mapping(bytes32 route => bool allowed) public allowedRoutes;
    mapping(bytes32 action => uint256 executeAfter) public queuedActions;

    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event OperatorConfigured(address indexed operator, bool allowed);
    event RouteConfigured(
        address indexed tokenA, address indexed tokenB, uint256 binStep, ILFJLBRouter.Version version, bool allowed
    );
    event SwapExecuted(
        address indexed fromAccount,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    modifier onlyOperator() {
        require(operators[msg.sender], "LFJAdapter: not operator");
        _;
    }

    constructor(address owner_, address router_, uint256 actionDelay_) Ownable(owner_) {
        require(router_.code.length > 0, "LFJAdapter: router not contract");
        require(actionDelay_ >= MIN_ACTION_DELAY, "LFJAdapter: delay too short");
        router = ILFJLBRouter(router_);
        actionDelay = actionDelay_;
    }

    function queueOperator(address operator, bool allowed) external onlyOwner returns (bytes32 actionId) {
        require(operator != address(0), "LFJAdapter: zero operator");
        actionId = keccak256(abi.encode("operator", operator, allowed));
        _queue(actionId);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), "LFJAdapter: zero operator");
        bytes32 actionId = keccak256(abi.encode("operator", operator, allowed));
        _consume(actionId);
        operators[operator] = allowed;
        emit OperatorConfigured(operator, allowed);
    }

    function queueRoute(address tokenA, address tokenB, uint256 binStep, uint8 version, bool allowed)
        external
        onlyOwner
        returns (bytes32 actionId)
    {
        _validateRoute(tokenA, tokenB, binStep, version);
        actionId = keccak256(abi.encode("route", routeKey(tokenA, tokenB, binStep, version), allowed));
        _queue(actionId);
    }

    function setRoute(address tokenA, address tokenB, uint256 binStep, uint8 version, bool allowed) external onlyOwner {
        _validateRoute(tokenA, tokenB, binStep, version);
        bytes32 key = routeKey(tokenA, tokenB, binStep, version);
        bytes32 actionId = keccak256(abi.encode("route", key, allowed));
        _consume(actionId);
        allowedRoutes[key] = allowed;
        emit RouteConfigured(tokenA, tokenB, binStep, ILFJLBRouter.Version(version), allowed);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        require(queuedActions[actionId] != 0, "LFJAdapter: action not queued");
        delete queuedActions[actionId];
        emit ActionCanceled(actionId);
    }

    function routeKey(address tokenA, address tokenB, uint256 binStep, uint8 version) public pure returns (bytes32) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encode(token0, token1, binStep, version));
    }

    /**
     * @param data abi.encode(uint256 binStep, uint8 version), where version 2 is V2.1 and 3 is V2.2.
     */
    function swap(
        address fromAccount,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override onlyOperator returns (uint256 amountOut) {
        require(fromAccount != address(0), "LFJAdapter: zero account");
        require(tokenIn != tokenOut && amountIn > 0, "LFJAdapter: invalid swap");
        (uint256 binStep, uint8 version) = abi.decode(data, (uint256, uint8));
        require(allowedRoutes[routeKey(tokenIn, tokenOut, binStep, version)], "LFJAdapter: route not allowed");

        IERC20 input = IERC20(tokenIn);
        IERC20 output = IERC20(tokenOut);
        uint256 adapterInputBefore = input.balanceOf(address(this));
        uint256 recipientOutputBefore = output.balanceOf(fromAccount);

        input.safeTransferFrom(fromAccount, address(this), amountIn);
        require(input.balanceOf(address(this)) - adapterInputBefore == amountIn, "LFJAdapter: unsupported input");
        input.forceApprove(address(router), amountIn);

        uint256[] memory binSteps = new uint256[](1);
        binSteps[0] = binStep;
        ILFJLBRouter.Version[] memory versions = new ILFJLBRouter.Version[](1);
        versions[0] = ILFJLBRouter.Version(version);
        IERC20[] memory tokenPath = new IERC20[](2);
        tokenPath[0] = input;
        tokenPath[1] = output;

        amountOut = router.swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            ILFJLBRouter.Path({pairBinSteps: binSteps, versions: versions, tokenPath: tokenPath}),
            fromAccount,
            block.timestamp + SWAP_DEADLINE_BUFFER
        );
        input.forceApprove(address(router), 0);

        require(input.balanceOf(address(this)) == adapterInputBefore, "LFJAdapter: input residual");
        require(amountOut >= minAmountOut, "LFJAdapter: insufficient output");
        require(output.balanceOf(fromAccount) - recipientOutputBefore == amountOut, "LFJAdapter: output mismatch");

        emit SwapExecuted(fromAccount, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _validateRoute(address tokenA, address tokenB, uint256 binStep, uint8 version) private view {
        require(tokenA != tokenB && tokenA.code.length > 0 && tokenB.code.length > 0, "LFJAdapter: invalid tokens");
        require(binStep > 0 && binStep <= type(uint16).max, "LFJAdapter: invalid bin step");
        require(
            version >= uint8(ILFJLBRouter.Version.V2_1) && version <= uint8(ILFJLBRouter.Version.V2_2),
            "LFJAdapter: unsupported version"
        );
    }

    function _queue(bytes32 actionId) private {
        require(queuedActions[actionId] == 0, "LFJAdapter: action already queued");
        uint256 executeAfter = block.timestamp + actionDelay;
        queuedActions[actionId] = executeAfter;
        emit ActionQueued(actionId, executeAfter);
    }

    function _consume(bytes32 actionId) private {
        uint256 executeAfter = queuedActions[actionId];
        require(executeAfter != 0, "LFJAdapter: action not queued");
        require(block.timestamp >= executeAfter, "LFJAdapter: action not ready");
        delete queuedActions[actionId];
    }
}
