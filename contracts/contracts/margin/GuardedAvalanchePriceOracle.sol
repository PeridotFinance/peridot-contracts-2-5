// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {PriceOracle} from "../PriceOracle.sol";
import {PToken} from "../PToken.sol";
import {IMarginPriceOracle} from "./interfaces/IMarginPriceOracle.sol";

interface IAvalanchePriceOracleSource {
    function feeds(address asset)
        external
        view
        returns (AggregatorV3Interface feed, uint32 maxAge, uint8 feedDecimals, bool enabled);
    function marketAsset(address pToken) external view returns (address);
    function assetDecimals(address asset) external view returns (uint8);
}

/**
 * @notice Guarded price source for Avalanche lending and margin (handoff 09 section 3b).
 * @dev Reads the feed configuration of an `AvalanchePriceOracle` but re-reads the Chainlink round itself and
 *      NEVER consults the inner oracle's owner-set emergency price. A stale, zero, negative, future-dated,
 *      reverting or malformed round returns 0 ("price unavailable"), which the controller and margin risk engine
 *      already treat as fail-closed. Any recovery valuation must be a separate, explicitly permissioned path.
 *      Stateless and ownerless, but TRUST: feed address, `maxAge`, asset decimals and the pToken->asset map all
 *      come from the source's owner, who can still widen `maxAge` or point a feed at a non-Chainlink contract.
 *      "Live round" therefore means "live as judged by the source owner's configuration"; the source owner must
 *      be the same governance that controls the market. Aggregator min/max answer clamps are not checked.
 */
contract GuardedAvalanchePriceOracle is PriceOracle, IMarginPriceOracle {
    IAvalanchePriceOracleSource public immutable source;

    constructor(IAvalanchePriceOracleSource source_) {
        require(address(source_).code.length > 0, "GuardedOracle: source not contract");
        source = source_;
    }

    function marketAsset(address pToken) external view override returns (address) {
        return source.marketAsset(pToken);
    }

    function getPrice(address asset) public view override returns (uint256) {
        (AggregatorV3Interface feed, uint32 maxAge, uint8 feedDecimals, bool enabled) = source.feeds(asset);
        if (!enabled || address(feed).code.length == 0) return 0;
        // Low-level call: a reverting feed, short/malformed returndata or a feed without code all return 0
        // instead of reverting in this contract (a revert here would brick every controller liquidity query).
        (bool ok, bytes memory ret) = address(feed).staticcall(abi.encodeCall(AggregatorV3Interface.latestRoundData, ()));
        if (!ok || ret.length < 160) return 0;
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
        if (
            roundId != 0 && answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp && answeredInRound >= roundId
                && block.timestamp - updatedAt <= maxAge
        ) {
            return _scaleToWad(uint256(answer), feedDecimals);
        }
        return 0;
    }

    function getUnderlyingPrice(PToken pToken) external view override returns (uint256) {
        address asset = source.marketAsset(address(pToken));
        if (asset == address(0)) return 0;
        uint256 priceUsd = getPrice(asset);
        if (priceUsd == 0) return 0;
        uint8 decimals = source.assetDecimals(asset);
        if (decimals < 18) return priceUsd * (10 ** uint256(18 - decimals));
        if (decimals > 18) return priceUsd / (10 ** uint256(decimals - 18));
        return priceUsd;
    }

    function _scaleToWad(uint256 value, uint8 decimals) private pure returns (uint256) {
        if (decimals < 18) return value * (10 ** uint256(18 - decimals));
        if (decimals > 18) return value / (10 ** uint256(decimals - 18));
        return value;
    }
}
