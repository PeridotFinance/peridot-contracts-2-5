// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";

interface IAlgebraSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(
        ExactInputParams calldata params
    ) external payable returns (uint256 amountOut);
}

/**
 * @notice QuickSwap (Algebra V3-style) router adapter for margin trading on Somnia.
 * @dev Stateless adapter; callable only by approved operators (e.g., MarginManager / liquidation bots).
 *      Uses exactInput with a V3-style path (token + fee(uint16) + token + ...).
 */
contract QuickSwapV3RouterAdapter is IMarginRouterAdapter, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_PATH_LEN = 42; // 20 token + 2 fee + 20 token
    uint256 public constant MAX_HOPS = 3; // configurable via code change if needed

    address public manager;
    IAlgebraSwapRouter public router;

    // Default deadline buffer: 5 minutes
    uint256 public deadlineBuffer = 300;

    mapping(bytes32 => bool) public poolWhitelist; // key: keccak(token0, token1, fee16)
    mapping(address => bool) public operators;
    bool public whitelistEnforced;

    event ManagerUpdated(address indexed newManager);
    event RouterUpdated(address indexed newRouter);
    event PoolWhitelistUpdated(
        address indexed token0,
        address indexed token1,
        uint16 fee,
        bool allowed
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

    constructor(address owner_, address router_) Ownable(owner_) {
        require(router_ != address(0), "Adapter: zero router");
        router = IAlgebraSwapRouter(router_);
        emit RouterUpdated(router_);
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
        router = IAlgebraSwapRouter(newRouter);
        emit RouterUpdated(newRouter);
    }

    function setDeadlineBuffer(uint256 newBuffer) external onlyOwner {
        require(newBuffer > 0 && newBuffer <= 3600, "Adapter: buffer 1-3600s");
        deadlineBuffer = newBuffer;
        emit DeadlineBufferUpdated(newBuffer);
    }

    function setPoolWhitelist(
        address tokenA,
        address tokenB,
        uint16 fee,
        bool allowed
    ) external onlyOwner {
        bytes32 keyAB = _poolKey(tokenA, tokenB, fee);
        bytes32 keyBA = _poolKey(tokenB, tokenA, fee);
        poolWhitelist[keyAB] = allowed;
        poolWhitelist[keyBA] = allowed;
        emit PoolWhitelistUpdated(tokenA, tokenB, fee, allowed);
    }

    function setWhitelistEnforced(bool enforced) external onlyOwner {
        whitelistEnforced = enforced;
        emit WhitelistEnforced(enforced);
    }

    /**
     * @param fromAccount Account providing funds and receiving output (SMA or manager-held account)
     * @param tokenIn Input token
     * @param tokenOut Output token
     * @param amountIn Exact amount of tokenIn to swap
     * @param minAmountOut Minimum acceptable output (slippage guard)
     * @param data abi.encode(bytes path, uint256 deadline)
     */
    function swap(
        address fromAccount,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override onlyOperator returns (uint256 amountOut) {
        require(amountIn > 0, "Adapter: zero amount");
        (bytes memory path, uint256 deadline) = abi.decode(data, (bytes, uint256));
        _validatePath(path, tokenIn, tokenOut);

        IERC20 tokenInContract = IERC20(tokenIn);
        tokenInContract.safeTransferFrom(fromAccount, address(this), amountIn);
        tokenInContract.forceApprove(address(router), amountIn);

        uint256 swapDeadline = deadline == 0 ? block.timestamp + deadlineBuffer : deadline;

        amountOut = router.exactInput(
            IAlgebraSwapRouter.ExactInputParams({
                path: path,
                recipient: fromAccount,
                deadline: swapDeadline,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
            })
        );

        require(amountOut >= minAmountOut, "Adapter: slippage");

        emit SwapExecuted(fromAccount, tokenIn, tokenOut, amountIn, amountOut);
    }

    // --- internal helpers ---

    function _validatePath(bytes memory path, address tokenIn, address tokenOut) internal view {
        require(path.length >= MIN_PATH_LEN, "Adapter: path too short");

        address first;
        address last;
        assembly {
            first := shr(96, mload(add(path, 32)))
            last := shr(96, mload(add(add(path, 32), sub(mload(path), 20))))
        }
        require(first == tokenIn, "Adapter: path tokenIn mismatch");
        require(last == tokenOut, "Adapter: path tokenOut mismatch");

        uint256 rem = path.length - 20;
        require(rem % 22 == 0, "Adapter: bad path stride");
        uint256 hops = rem / 22;
        require(hops > 0 && hops <= MAX_HOPS, "Adapter: hop limit");

        // optional per-hop whitelist check
        if (whitelistEnforced) {
            uint256 offset = 0;
            for (uint256 i = 0; i < hops; i++) {
                address a = _readAddress(path, offset);
                uint16 fee = _readFee(path, offset + 20);
                address b = _readAddress(path, offset + 22);
                bytes32 key = _poolKey(a, b, fee);
                require(poolWhitelist[key], "Adapter: pool not allowed");
                offset += 22;
            }
        }
    }

    function _readAddress(bytes memory data, uint256 offset) private pure returns (address addr) {
        assembly {
            addr := shr(96, mload(add(add(data, 32), offset)))
        }
    }

    function _readFee(bytes memory data, uint256 offset) private pure returns (uint16 fee) {
        assembly {
            fee := shr(240, mload(add(add(data, 32), offset)))
        }
    }

    function _poolKey(address token0, address token1, uint16 fee) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1, fee));
    }
}
