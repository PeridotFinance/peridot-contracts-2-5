// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PharaohTickMath} from "./PharaohTickMath.sol";

/// @notice TWAP and tick quote helpers compatible with Pharaoh concentrated-liquidity pools.
library PharaohOracleMath {
    function arithmeticMeanTick(int56 tickCumulativeDelta, uint32 period) internal pure returns (int24 tick) {
        int56 periodInt = int56(uint56(period));
        tick = int24(tickCumulativeDelta / periodInt);
        if (tickCumulativeDelta < 0 && tickCumulativeDelta % periodInt != 0) tick--;
    }

    /// @notice Quotes `baseAmount` at `tick`; token address ordering identifies price direction.
    function getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
        internal
        pure
        returns (uint256 quoteAmount)
    {
        uint160 sqrtRatioX96 = PharaohTickMath.getSqrtRatioAtTick(tick);

        if (sqrtRatioX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
            quoteAmount = baseToken < quoteToken
                ? Math.mulDiv(ratioX192, baseAmount, 1 << 192)
                : Math.mulDiv(1 << 192, baseAmount, ratioX192);
        } else {
            uint256 ratioX128 = Math.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
            quoteAmount = baseToken < quoteToken
                ? Math.mulDiv(ratioX128, baseAmount, 1 << 128)
                : Math.mulDiv(1 << 128, baseAmount, ratioX128);
        }
    }
}
