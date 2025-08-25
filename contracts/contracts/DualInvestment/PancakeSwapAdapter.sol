// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPancakeV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);
}

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

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external returns (uint256 amountOut);

    function exactInput(
        ExactInputParams calldata params
    ) external returns (uint256 amountOut);
}

interface IPancakeV3QuoterV2 {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee,
        uint160 sqrtPriceLimitX96
    )
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );

    function quoteExactInput(
        bytes memory path,
        uint256 amountIn
    )
        external
        returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
}

contract PancakeSwapAdapter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public v2Router; // 0xD99D1c33F9fC3444f8101754aBC46c52416550D1 on BSC testnet
    address public v3Router; // 0x1b81D678ffb9C0263b24A97847620C99d213eB14 on BSC testnet
    address public v3Quoter; // 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997 on BSC testnet

    // Optional per-pair v3 fee (500/3000/10000). Defaults to 3000 if unset
    mapping(address => mapping(address => uint24)) public v3FeeForPair;

    event RoutersUpdated(address v2Router, address v3Router, address v3Quoter);
    event V3FeeUpdated(address tokenIn, address tokenOut, uint24 fee);

    constructor(address _v2, address _v3, address _quoter) Ownable(msg.sender) {
        v2Router = _v2;
        v3Router = _v3;
        v3Quoter = _quoter;
        emit RoutersUpdated(_v2, _v3, _quoter);
    }

    function setRouters(
        address _v2,
        address _v3,
        address _quoter
    ) external onlyOwner {
        v2Router = _v2;
        v3Router = _v3;
        v3Quoter = _quoter;
        emit RoutersUpdated(_v2, _v3, _quoter);
    }

    function setV3Fee(
        address tokenIn,
        address tokenOut,
        uint24 fee
    ) external onlyOwner {
        v3FeeForPair[tokenIn][tokenOut] = fee;
        emit V3FeeUpdated(tokenIn, tokenOut, fee);
    }

    // Quotes
    function quoteV2(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address via
    ) public view returns (uint256 amountOut) {
        require(v2Router != address(0), "v2 not set");
        address[] memory path;
        if (via == address(0)) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = via;
            path[2] = tokenOut;
        }
        uint256[] memory amounts = IPancakeV2Router(v2Router).getAmountsOut(
            amountIn,
            path
        );
        return amounts[amounts.length - 1];
    }

    function quoteV3Single(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint24 fee
    ) public returns (uint256 amountOut) {
        require(v3Quoter != address(0), "v3 quoter not set");
        (amountOut, , , ) = IPancakeV3QuoterV2(v3Quoter).quoteExactInputSingle(
            tokenIn,
            tokenOut,
            amountIn,
            fee == 0 ? 3000 : fee,
            0
        );
    }

    // Swaps
    function swapV2(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to,
        address via
    ) external nonReentrant returns (uint256 amountOut) {
        require(v2Router != address(0), "v2 not set");
        IERC20(tokenIn).forceApprove(v2Router, amountIn);
        address[] memory path;
        if (via == address(0)) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = via;
            path[2] = tokenOut;
        }
        uint256 pre = IERC20(tokenOut).balanceOf(to);
        IPancakeV2Router(v2Router).swapExactTokensForTokens(
            amountIn,
            minOut,
            path,
            to,
            block.timestamp + 1200
        );
        uint256 post = IERC20(tokenOut).balanceOf(to);
        amountOut = post - pre;
    }

    function swapV3Single(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        address to,
        uint24 fee
    ) external nonReentrant returns (uint256 amountOut) {
        require(v3Router != address(0), "v3 not set");
        IERC20(tokenIn).forceApprove(v3Router, amountIn);
        amountOut = IPancakeV3Router(v3Router).exactInputSingle(
            IPancakeV3Router.ExactInputSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                fee: fee == 0
                    ? (
                        v3FeeForPair[tokenIn][tokenOut] == 0
                            ? 3000
                            : v3FeeForPair[tokenIn][tokenOut]
                    )
                    : fee,
                recipient: to,
                deadline: block.timestamp + 1200,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
    }
}
