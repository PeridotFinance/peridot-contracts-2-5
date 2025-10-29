// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {INonfungiblePositionManager} from "../../contracts/pancakev3/interfaces/INonfungiblePositionManager.sol";
import {IPancakeV3Pool} from "../../contracts/pancakev3/interfaces/IPancakeV3Pool.sol";
import {LiquidityAmounts} from "../../contracts/pancakev3/libraries/LiquidityAmounts.sol";
import {TickMath} from "../../contracts/pancakev3/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockPancakeV3PositionManager is INonfungiblePositionManager {
    using SafeERC20 for IERC20;

    struct Position {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    uint256 private nextId = 1;
    mapping(uint256 => Position) internal positions_;
    mapping(bytes32 => address) internal pools;

    function configurePool(address token0, address token1, uint24 fee, address pool) external {
        require(pool != address(0), "pool zero");
        (address t0, address t1) = token0 < token1 ? (token0, token1) : (token1, token0);
        pools[_poolKey(t0, t1, fee)] = pool;
    }

    function mint(MintParams calldata params)
        external
        override
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        address pool = _poolFor(params.token0, params.token1, params.fee);
        (uint160 sqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();

        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(params.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(params.tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, params.amount0Desired, params.amount1Desired
        );
        require(liquidity > 0, "zero liquidity");

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
        require(amount0 <= params.amount0Desired && amount1 <= params.amount1Desired, "amount exceeded");

        IERC20(params.token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(params.token1).safeTransferFrom(msg.sender, address(this), amount1);

        tokenId = nextId++;

        positions_[tokenId] = Position({
            token0: params.token0,
            token1: params.token1,
            fee: params.fee,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1,
            tokensOwed0: 0,
            tokensOwed1: 0
        });
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        override
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        Position storage pos = positions_[params.tokenId];
        require(pos.liquidity > 0, "position missing");

        address pool = _poolFor(pos.token0, pos.token1, pos.fee);
        (uint160 sqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(pos.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(pos.tickUpper);

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLower, sqrtUpper, params.amount0Desired, params.amount1Desired
        );
        require(liquidity > 0, "zero liquidity");

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, liquidity);
        require(amount0 <= params.amount0Desired && amount1 <= params.amount1Desired, "amount exceeded");

        IERC20(pos.token0).safeTransferFrom(msg.sender, address(this), amount0);
        IERC20(pos.token1).safeTransferFrom(msg.sender, address(this), amount1);

        pos.amount0 += amount0;
        pos.amount1 += amount1;
        pos.liquidity += liquidity;
    }

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        override
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = positions_[params.tokenId];
        require(pos.liquidity >= params.liquidity && params.liquidity > 0, "insufficient liquidity");

        address pool = _poolFor(pos.token0, pos.token1, pos.fee);
        (uint160 sqrtPriceX96,,,,,,) = IPancakeV3Pool(pool).slot0();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(pos.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(pos.tickUpper);

        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLower, sqrtUpper, params.liquidity);

        pos.amount0 -= amount0;
        pos.amount1 -= amount1;
        pos.liquidity -= params.liquidity;

        pos.tokensOwed0 += uint128(amount0);
        pos.tokensOwed1 += uint128(amount1);
    }

    function collect(CollectParams calldata params) external override returns (uint256 amount0, uint256 amount1) {
        Position storage pos = positions_[params.tokenId];

        amount0 = params.amount0Max < pos.tokensOwed0 ? params.amount0Max : pos.tokensOwed0;
        amount1 = params.amount1Max < pos.tokensOwed1 ? params.amount1Max : pos.tokensOwed1;

        pos.tokensOwed0 -= uint128(amount0);
        pos.tokensOwed1 -= uint128(amount1);

        if (amount0 > 0) {
            IERC20(pos.token0).safeTransfer(params.recipient, amount0);
        }
        if (amount1 > 0) {
            IERC20(pos.token1).safeTransfer(params.recipient, amount1);
        }
    }

    function positions(uint256 tokenId)
        external
        view
        override
        returns (
            uint96 nonce,
            address operator,
            address token0Addr,
            address token1Addr,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position storage pos = positions_[tokenId];
        token0Addr = pos.token0;
        token1Addr = pos.token1;
        fee = pos.fee;
        tickLower = pos.tickLower;
        tickUpper = pos.tickUpper;
        liquidity = pos.liquidity;
        tokensOwed0 = pos.tokensOwed0;
        tokensOwed1 = pos.tokensOwed1;
        operator = address(0);
        feeGrowthInside0LastX128 = 0;
        feeGrowthInside1LastX128 = 0;
        nonce = 0;
    }

    function _poolKey(address token0, address token1, uint24 fee) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(token0, token1, fee));
    }

    function _poolFor(address token0, address token1, uint24 fee) private view returns (address pool) {
        (address t0, address t1) = token0 < token1 ? (token0, token1) : (token1, token0);
        pool = pools[_poolKey(t0, t1, fee)];
        require(pool != address(0), "pool missing");
    }
}
