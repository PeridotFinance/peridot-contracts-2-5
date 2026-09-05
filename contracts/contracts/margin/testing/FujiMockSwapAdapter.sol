// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMarginRouterAdapter} from "../IMarginRouterAdapter.sol";
import {FujiMockToken, FujiMockPriceFeed} from "./FujiMockAssets.sol";

/// @notice Funded fixed-price TEST venue, not LFJ or a realistic AMM.
/// @dev Quotes follow the two mock feeds. Owner can apply an execution haircut for slippage tests.
///      Only the configured margin swap module may spend its own allowance; arbitrary victims cannot be charged.
contract FujiMockSwapAdapter is Ownable, IMarginRouterAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_PRICE_AGE = 1_200;
    FujiMockToken public immutable mockAvax;
    FujiMockToken public immutable mockUsd;
    FujiMockPriceFeed public immutable avaxFeed;
    FujiMockPriceFeed public immutable usdFeed;
    address public operator;
    bool public paused = true;
    uint16 public executionBps = 10_000;
    bool public constant IS_FUJI_MOCK = true;

    event OperatorConfigured(address indexed operator);
    event PausedUpdated(bool paused);
    event ExecutionBpsUpdated(uint16 executionBps);
    event MockSwap(address indexed tokenIn, uint256 amountIn, uint256 amountOut);

    constructor(
        address owner_,
        FujiMockToken avax_,
        FujiMockToken usd_,
        FujiMockPriceFeed avaxFeed_,
        FujiMockPriceFeed usdFeed_
    ) Ownable(owner_) {
        require(block.chainid == 43_113, "FujiMock: Fuji only");
        require(address(avax_) != address(usd_), "FujiMock: duplicate token");
        require(avax_.IS_FUJI_MOCK() && usd_.IS_FUJI_MOCK(), "FujiMock: not mock assets");
        require(avax_.decimals() == 18 && usd_.decimals() == 6, "FujiMock: decimals");
        require(avaxFeed_.IS_FUJI_MOCK() && usdFeed_.IS_FUJI_MOCK(), "FujiMock: not mock feeds");
        mockAvax = avax_;
        mockUsd = usd_;
        avaxFeed = avaxFeed_;
        usdFeed = usdFeed_;
    }

    function setOperator(address operator_) external onlyOwner {
        require(operator == address(0) && operator_.code.length > 0, "FujiMock: operator already set or invalid");
        operator = operator_;
        emit OperatorConfigured(operator_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedUpdated(paused_);
    }

    function setExecutionBps(uint16 bps) external onlyOwner {
        require(bps > 0 && bps <= 10_000, "FujiMock: execution bounds");
        executionBps = bps;
        emit ExecutionBpsUpdated(bps);
    }

    function quote(address tokenIn, address tokenOut, uint256 amountIn) public view returns (uint256) {
        bool sellAvax = tokenIn == address(mockAvax) && tokenOut == address(mockUsd);
        require(
            sellAvax || (tokenIn == address(mockUsd) && tokenOut == address(mockAvax)), "FujiMock: unsupported pair"
        );
        uint256 avaxPrice = _price(avaxFeed);
        uint256 usdPrice = _price(usdFeed);
        uint256 value = Math.mulDiv(amountIn, sellAvax ? avaxPrice : usdPrice, sellAvax ? 1e18 : 1e6);
        uint256 out = Math.mulDiv(value, sellAvax ? 1e6 : 1e18, sellAvax ? usdPrice : avaxPrice);
        return Math.mulDiv(out, executionBps, 10_000);
    }

    function swap(
        address fromAccount,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata
    ) external override returns (uint256 amountOut) {
        require(!paused, "FujiMock: paused");
        require(msg.sender == operator && fromAccount == msg.sender, "FujiMock: unauthorized payer");
        require(amountIn > 0, "FujiMock: zero input");
        amountOut = quote(tokenIn, tokenOut, amountIn);
        require(amountOut > 0 && amountOut >= minAmountOut, "FujiMock: minimum output");
        require(IERC20(tokenOut).balanceOf(address(this)) >= amountOut, "FujiMock: insufficient liquidity");
        IERC20(tokenIn).safeTransferFrom(fromAccount, address(this), amountIn);
        IERC20(tokenOut).safeTransfer(fromAccount, amountOut);
        emit MockSwap(tokenIn, amountIn, amountOut);
    }

    function _price(FujiMockPriceFeed feed) private view returns (uint256) {
        (uint80 round, int256 answer,, uint256 updated, uint80 answered) = feed.latestRoundData();
        require(
            round > 0 && answered >= round && answer > 0 && updated > 0 && updated <= block.timestamp
                && block.timestamp - updated <= MAX_PRICE_AGE,
            "FujiMock: stale price"
        );
        // Match the production margin oracle's 18-decimal valuation, including its rounding order.
        return uint256(answer) * 1e10;
    }
}
