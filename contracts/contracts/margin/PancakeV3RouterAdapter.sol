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

contract PancakeV3RouterAdapter is IMarginRouterAdapter, Ownable {
    using SafeERC20 for IERC20;

    struct PoolConfig {
        bool allowed;
    }

    address public manager;
    IPancakeV3Router public router;

    mapping(bytes32 => PoolConfig) public poolWhitelist;
    mapping(address => bool) public operators;

    event ManagerUpdated(address indexed newManager);
    event RouterUpdated(address indexed newRouter);
    event PoolWhitelistUpdated(
        address indexed token0,
        address indexed token1,
        uint24 fee,
        bool allowed
    );
    event OperatorUpdated(address indexed operator, bool allowed);
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

    constructor(address owner_, address router_) Ownable(owner_) {
        router = IPancakeV3Router(router_);
        emit RouterUpdated(router_);
    }

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

    function setRouter(address newRouter) external onlyOwner {
        router = IPancakeV3Router(newRouter);
        emit RouterUpdated(newRouter);
    }

    function setPoolWhitelist(
        address tokenA,
        address tokenB,
        uint24 fee,
        bool allowed
    ) external onlyOwner {
        bytes32 key = _poolKey(tokenA, tokenB, fee);
        poolWhitelist[key] = PoolConfig({allowed: allowed});
        poolWhitelist[_poolKey(tokenB, tokenA, fee)] = PoolConfig({allowed: allowed});
        emit PoolWhitelistUpdated(tokenA, tokenB, fee, allowed);
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
                deadline: block.timestamp,
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
}
