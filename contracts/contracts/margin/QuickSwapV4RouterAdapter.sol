// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";

interface IQuickSwapV4Factory {
    function poolByPair(address tokenA, address tokenB) external view returns (address pool);
}

interface IQuickSwapV4Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        address deployer;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 limitSqrtPrice;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

/**
 * @notice QuickSwap V4 (Algebra-based) adapter for single-pool margin swaps on Somnia.
 * @dev Uses exactInputSingle against the deployed Algebra router and whitelists by token pair.
 *      routerData format:
 *      - empty bytes: uses stored default deployer, limitSqrtPrice=0 and deadline=block.timestamp + deadlineBuffer
 *      - abi.encode(uint256 deadline): uses stored default deployer
 *      - abi.encode(address deployer, uint160 limitSqrtPrice, uint256 deadline): overrides stored deployer
 */
contract QuickSwapV4RouterAdapter is IMarginRouterAdapter, Ownable {
    using SafeERC20 for IERC20;

    address public manager;
    IQuickSwapV4Router public router;
    IQuickSwapV4Factory public factory;

    uint256 public deadlineBuffer = 300;

    mapping(bytes32 => bool) public pairWhitelist;
    mapping(bytes32 => address) public pairDeployer;
    mapping(address => bool) public operators;
    bool public whitelistEnforced;

    event ManagerUpdated(address indexed newManager);
    event RouterUpdated(address indexed newRouter);
    event FactoryUpdated(address indexed newFactory);
    event PairWhitelistUpdated(
        address indexed token0,
        address indexed token1,
        bool allowed
    );
    event PairDeployerUpdated(
        address indexed token0,
        address indexed token1,
        address deployer
    );
    event OperatorUpdated(address indexed operator, bool allowed);
    event DeadlineBufferUpdated(uint256 newBuffer);
    event WhitelistEnforced(bool enforced);
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

    constructor(address owner_, address router_, address factory_) Ownable(owner_) {
        require(router_ != address(0), "Adapter: zero router");
        require(factory_ != address(0), "Adapter: zero factory");
        require(router_.code.length > 0, "Adapter: router not contract");
        require(factory_.code.length > 0, "Adapter: factory not contract");

        router = IQuickSwapV4Router(router_);
        factory = IQuickSwapV4Factory(factory_);

        emit RouterUpdated(router_);
        emit FactoryUpdated(factory_);
    }

    function setManager(address newManager) external onlyOwner {
        manager = newManager;
        emit ManagerUpdated(newManager);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        require(operator != address(0), "Adapter: zero operator");
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function setRouter(address newRouter) external onlyOwner {
        require(newRouter != address(0), "Adapter: zero router");
        require(newRouter.code.length > 0, "Adapter: router not contract");
        router = IQuickSwapV4Router(newRouter);
        emit RouterUpdated(newRouter);
    }

    function setFactory(address newFactory) external onlyOwner {
        require(newFactory != address(0), "Adapter: zero factory");
        require(newFactory.code.length > 0, "Adapter: factory not contract");
        factory = IQuickSwapV4Factory(newFactory);
        emit FactoryUpdated(newFactory);
    }

    function setDeadlineBuffer(uint256 newBuffer) external onlyOwner {
        require(newBuffer > 0 && newBuffer <= 3600, "Adapter: buffer 1-3600s");
        deadlineBuffer = newBuffer;
        emit DeadlineBufferUpdated(newBuffer);
    }

    function setPairWhitelist(
        address tokenA,
        address tokenB,
        bool allowed
    ) external onlyOwner {
        bytes32 keyAB = _pairKey(tokenA, tokenB);
        bytes32 keyBA = _pairKey(tokenB, tokenA);
        pairWhitelist[keyAB] = allowed;
        pairWhitelist[keyBA] = allowed;
        emit PairWhitelistUpdated(tokenA, tokenB, allowed);
    }

    function setPairDeployer(
        address tokenA,
        address tokenB,
        address deployer
    ) external onlyOwner {
        bytes32 keyAB = _pairKey(tokenA, tokenB);
        bytes32 keyBA = _pairKey(tokenB, tokenA);
        pairDeployer[keyAB] = deployer;
        pairDeployer[keyBA] = deployer;
        emit PairDeployerUpdated(tokenA, tokenB, deployer);
    }

    function setPairConfig(
        address tokenA,
        address tokenB,
        address deployer,
        bool allowed
    ) external onlyOwner {
        bytes32 keyAB = _pairKey(tokenA, tokenB);
        bytes32 keyBA = _pairKey(tokenB, tokenA);
        pairWhitelist[keyAB] = allowed;
        pairWhitelist[keyBA] = allowed;
        pairDeployer[keyAB] = deployer;
        pairDeployer[keyBA] = deployer;
        emit PairWhitelistUpdated(tokenA, tokenB, allowed);
        emit PairDeployerUpdated(tokenA, tokenB, deployer);
    }

    function setWhitelistEnforced(bool enforced) external onlyOwner {
        whitelistEnforced = enforced;
        emit WhitelistEnforced(enforced);
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

        if (whitelistEnforced) {
            require(pairWhitelist[_pairKey(tokenIn, tokenOut)], "Adapter: pair not allowed");
        }

        require(factory.poolByPair(tokenIn, tokenOut) != address(0), "Adapter: pool missing");

        (address deployer, uint160 limitSqrtPrice, uint256 deadline) = _decodeSwapData(
            tokenIn,
            tokenOut,
            data
        );
        uint256 swapDeadline = deadline == 0 ? block.timestamp + deadlineBuffer : deadline;

        IERC20 tokenInContract = IERC20(tokenIn);
        tokenInContract.safeTransferFrom(fromAccount, address(this), amountIn);
        tokenInContract.forceApprove(address(router), amountIn);

        amountOut = router.exactInputSingle(
            IQuickSwapV4Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                deployer: deployer,
                recipient: fromAccount,
                deadline: swapDeadline,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                limitSqrtPrice: limitSqrtPrice
            })
        );

        tokenInContract.forceApprove(address(router), 0);
        require(amountOut >= minAmountOut, "Adapter: insufficient output");

        uint256 leftover = tokenInContract.balanceOf(address(this));
        if (leftover > 0) {
            tokenInContract.safeTransfer(fromAccount, leftover);
        }

        emit SwapExecuted(fromAccount, tokenIn, tokenOut, amountIn, amountOut);
    }

    function _decodeSwapData(
        address tokenIn,
        address tokenOut,
        bytes calldata data
    ) internal view returns (address deployer, uint160 limitSqrtPrice, uint256 deadline) {
        address defaultDeployer = pairDeployer[_pairKey(tokenIn, tokenOut)];
        if (data.length == 0) {
            return (defaultDeployer, 0, 0);
        }
        if (data.length == 32) {
            deadline = abi.decode(data, (uint256));
            return (defaultDeployer, 0, deadline);
        }
        return abi.decode(data, (address, uint160, uint256));
    }

    function _pairKey(address tokenA, address tokenB) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(tokenA, tokenB));
    }
}
