// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";

interface IPancakeV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external returns (uint256 amountOut);
}

/**
 * @notice PancakeSwap V3 Router Adapter for margin trading
 * @dev SECURITY CONSIDERATIONS:
 *      - Only operators can call swap() - the manager should be the primary operator
 *      - The owner can add/remove operators, so owner key security is critical
 *      - In production, owner should be a multisig or timelock contract
 *      - Operators have significant power but are limited to whitelisted pools
 *      - Users implicitly trust operators when granting allowance to their margin accounts
 */
contract PancakeV3RouterAdapter is IMarginRouterAdapter, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_ACTION_DELAY = 1 hours;

    struct PoolConfig {
        bool allowed;
    }

    address public manager;
    IPancakeV3Router public router;

    // Default deadline buffer: 5 minutes
    uint256 public deadlineBuffer = 300;
    uint256 public actionDelay;

    mapping(bytes32 => PoolConfig) public poolWhitelist;
    mapping(address => bool) public operators;
    mapping(bytes32 => uint256) public queuedActions;

    event ManagerUpdated(address indexed newManager);
    event RouterUpdated(address indexed newRouter);
    event PoolWhitelistUpdated(
        address indexed token0,
        address indexed token1,
        uint24 fee,
        bool allowed
    );
    event OperatorUpdated(address indexed operator, bool allowed);
    event DeadlineBufferUpdated(uint256 newBuffer);
    event ActionDelayUpdated(uint256 newDelay);
    event ActionQueued(bytes32 indexed actionId, uint256 executeAfter);
    event ActionCanceled(bytes32 indexed actionId);
    event ActionExecuted(bytes32 indexed actionId);
    event SwapExecuted(
        address indexed fromAccount,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    modifier onlyOperator() {
        require(operators[msg.sender], "Adapter: not authorized");
        _;
    }

    constructor(address owner_, address router_, uint256 actionDelay_) Ownable(owner_) {
        require(actionDelay_ >= MIN_ACTION_DELAY, "Adapter: delay too short");
        actionDelay = actionDelay_;
        router = IPancakeV3Router(router_);
        emit RouterUpdated(router_);
        emit ActionDelayUpdated(actionDelay_);
    }

    function setActionDelay(uint256 newDelay) external onlyOwner {
        require(newDelay >= actionDelay, "Adapter: delay cannot decrease");
        require(newDelay >= MIN_ACTION_DELAY, "Adapter: delay too short");
        actionDelay = newDelay;
        emit ActionDelayUpdated(newDelay);
    }

    function cancelAction(bytes32 actionId) external onlyOwner {
        require(queuedActions[actionId] != 0, "Adapter: action not queued");
        delete queuedActions[actionId];
        emit ActionCanceled(actionId);
    }

    function queueSetManager(address newManager) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setManager", newManager)));
    }

    function queueSetOperator(address operator, bool allowed) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setOperator", operator, allowed)));
    }

    function queueSetRouter(address newRouter) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setRouter", newRouter)));
    }

    function queueSetDeadlineBuffer(uint256 newBuffer) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setDeadlineBuffer", newBuffer)));
    }

    function queueSetPoolWhitelist(
        address tokenA,
        address tokenB,
        uint24 fee,
        bool allowed
    ) external onlyOwner returns (bytes32 actionId) {
        actionId = _queueAction(keccak256(abi.encode("setPoolWhitelist", tokenA, tokenB, fee, allowed)));
    }

    function setManager(address newManager) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setManager", newManager));
        _consumeAction(actionId);
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
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Add or remove an operator
     * @dev IMPORTANT: Operators have significant privileges - they can initiate swaps
     *      from any margin account that has given allowance to this adapter.
     *      In production, the owner should be a multisig or timelock contract.
     *      Operators are typically the MarginManager or MarginLiquidation contracts.
     * @param operator The operator address
     * @param allowed True to add, false to remove
     */
    function setOperator(address operator, bool allowed) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setOperator", operator, allowed));
        _consumeAction(actionId);
        require(operator != address(0), "Adapter: zero address");
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
        emit ActionExecuted(actionId);
    }

    function setRouter(address newRouter) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setRouter", newRouter));
        _consumeAction(actionId);
        require(newRouter != address(0), "Adapter: zero address");
        require(newRouter.code.length > 0, "Adapter: router must be contract");
        router = IPancakeV3Router(newRouter);
        emit RouterUpdated(newRouter);
        emit ActionExecuted(actionId);
    }

    /**
     * @notice Set the deadline buffer for swaps
     * @dev Default is 300 seconds (5 minutes). Increase if transactions frequently fail.
     * @param newBuffer Seconds to add to block.timestamp for swap deadline
     */
    function setDeadlineBuffer(uint256 newBuffer) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setDeadlineBuffer", newBuffer));
        _consumeAction(actionId);
        require(
            newBuffer > 0 && newBuffer <= 3600,
            "Adapter: buffer must be 1-3600 seconds"
        );
        deadlineBuffer = newBuffer;
        emit DeadlineBufferUpdated(newBuffer);
        emit ActionExecuted(actionId);
    }

    function setPoolWhitelist(
        address tokenA,
        address tokenB,
        uint24 fee,
        bool allowed
    ) external onlyOwner {
        bytes32 actionId = keccak256(abi.encode("setPoolWhitelist", tokenA, tokenB, fee, allowed));
        _consumeAction(actionId);
        bytes32 key = _poolKey(tokenA, tokenB, fee);
        poolWhitelist[key] = PoolConfig({allowed: allowed});
        poolWhitelist[_poolKey(tokenB, tokenA, fee)] = PoolConfig({
            allowed: allowed
        });
        emit PoolWhitelistUpdated(tokenA, tokenB, fee, allowed);
        emit ActionExecuted(actionId);
    }

    function swap(
        address fromAccount,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override onlyOperator returns (uint256 amountOut) {
        require(amountIn > 0, "Adapter: zero amount");
        (uint24 fee, uint160 sqrtPriceLimitX96) = abi.decode(
            data,
            (uint24, uint160)
        );

        bytes32 key = _poolKey(tokenIn, tokenOut, fee);
        PoolConfig memory config = poolWhitelist[key];
        require(config.allowed, "Adapter: pool not allowed");

        IERC20 tokenInContract = IERC20(tokenIn);
        IERC20 tokenOutContract = IERC20(tokenOut);

        tokenInContract.safeTransferFrom(fromAccount, address(this), amountIn);
        tokenInContract.forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee,
                recipient: fromAccount,
                deadline: block.timestamp + deadlineBuffer,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                sqrtPriceLimitX96: sqrtPriceLimitX96
            })
        );

        tokenInContract.forceApprove(address(router), 0);

        require(amountOut >= minAmountOut, "Adapter: insufficient output");

        uint256 adapterBalance = tokenOutContract.balanceOf(address(this));
        if (adapterBalance > 0) {
            tokenOutContract.safeTransfer(fromAccount, adapterBalance);
        }

        emit SwapExecuted(fromAccount, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _poolKey(
        address tokenA,
        address tokenB,
        uint24 fee
    ) private pure returns (bytes32) {
        return keccak256(abi.encode(tokenA, tokenB, fee));
    }

    function _queueAction(bytes32 actionId) internal returns (bytes32) {
        require(queuedActions[actionId] == 0, "Adapter: action already queued");
        uint256 executeAfter = block.timestamp + actionDelay;
        queuedActions[actionId] = executeAfter;
        emit ActionQueued(actionId, executeAfter);
        return actionId;
    }

    function _consumeAction(bytes32 actionId) internal {
        uint256 executeAfter = queuedActions[actionId];
        require(executeAfter != 0, "Adapter: action not queued");
        require(block.timestamp >= executeAfter, "Adapter: action not ready");
        delete queuedActions[actionId];
    }
}
