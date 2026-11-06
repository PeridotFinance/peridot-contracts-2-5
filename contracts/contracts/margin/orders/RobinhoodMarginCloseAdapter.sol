// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC3156FlashLender} from "../../PTokenInterfaces.sol";
import {IsolatedMarginTypes} from "../IsolatedMarginTypes.sol";
import {IMarginCloseAdapter} from "./IMarginOrderRegistry.sol";

interface IRobinhoodOrderExecutor {
    struct CloseParams {
        uint256 positionId;
        uint16 closeBps;
        uint256 maxClosingFeePToken;
        uint256 minDebtUnderlying;
        uint256 minMarginUnderlying;
        bytes positionToDebtSwapData;
        bytes debtToMarginSwapData;
    }

    function positions(uint256 positionId) external view returns (IsolatedMarginTypes.Position memory);
    function closePositionFor(address owner, CloseParams calldata params) external returns (uint256 returnedMarginPTokens);
    function orderExecutor() external view returns (address);
}

interface IRobinhoodOrderMarket {
    function underlying() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
}

interface IRobinhoodOrderQuoter {
    function expectedOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
}

interface IRobinhoodOrderOracle {
    function getPrice(address asset) external view returns (uint256);
}

interface IRobinhoodOrderConfig {
    function flashLoanProvider() external view returns (address);
    function closeFeeBps() external view returns (uint16);
    function getPairRisk(address marginPToken, address positionPToken, address debtPToken)
        external
        view
        returns (IsolatedMarginTypes.PairRiskConfig memory);
}

/// @title Robinhood close path for the chain-agnostic TP/SL registry.
/// @notice Turns an executed order into `IsolatedMarginExecutorUpgradeable.closePositionFor`. It holds no funds and no
/// approvals. The minimums it passes are derived from the margin engine's own oracle and quoter, so a keeper can choose
/// neither the price nor the route: `adapterData` must be empty, and the swap module uses its registered pools.
contract RobinhoodMarginCloseAdapter is IMarginCloseAdapter {
    uint256 private constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 300;
    uint16 public constant MAX_CLOSE_FEE_BPS = 100; // refuses to execute if governance ever raises the close fee above 1 %

    IRobinhoodOrderExecutor public immutable executor;
    address public immutable registry;
    IRobinhoodOrderOracle public immutable oracle;
    IRobinhoodOrderQuoter public immutable quoter;
    IRobinhoodOrderConfig public immutable config;

    error NotRegistry();
    error AdapterDataNotSupported();
    error InvalidClose(uint8 code); // 1 closeBps, 2 slippage, 3 owner, 4 inactive, 5 close fee too high, 6 price moved

    constructor(address executor_, address registry_, address oracle_, address quoter_, address config_) {
        require(
            executor_.code.length > 0 && registry_ != address(0) && oracle_.code.length > 0 && quoter_.code.length > 0
                && config_.code.length > 0,
            "ADAPTER_CONFIG"
        );
        executor = IRobinhoodOrderExecutor(executor_);
        registry = registry_;
        oracle = IRobinhoodOrderOracle(oracle_);
        quoter = IRobinhoodOrderQuoter(quoter_);
        config = IRobinhoodOrderConfig(config_);
    }

    function positionOwner(uint256 positionId) external view returns (address) {
        return executor.positions(positionId).owner;
    }

    function isActive(uint256 positionId) external view returns (bool) {
        return executor.positions(positionId).status == IsolatedMarginTypes.Status.ACTIVE;
    }

    function isLong(uint256 positionId) external view returns (bool) {
        return executor.positions(positionId).side == IsolatedMarginTypes.Side.LONG;
    }

    /// @notice The stock leg's price from the margin oracle. That oracle returns 0 for a stale, paused or invalid price.
    function oraclePriceE18(uint256 positionId) public view returns (uint256 priceE18, bool ok) {
        IsolatedMarginTypes.Position memory p = executor.positions(positionId);
        address stockPToken = p.side == IsolatedMarginTypes.Side.LONG ? p.positionPToken : p.debtPToken;
        if (stockPToken == address(0)) return (0, false);
        priceE18 = oracle.getPrice(IRobinhoodOrderMarket(stockPToken).underlying());
        ok = priceE18 > 0;
    }

    function closeFor(
        uint256 positionId,
        address owner,
        uint16 closeBps,
        uint256 oraclePriceE18_,
        uint16 maxSlippageBps,
        bytes calldata adapterData
    ) external returns (uint256 returnedMargin) {
        if (msg.sender != registry) revert NotRegistry();
        if (adapterData.length != 0) revert AdapterDataNotSupported();
        if (closeBps == 0 || closeBps > BPS) revert InvalidClose(1);
        if (maxSlippageBps == 0 || maxSlippageBps > MAX_SLIPPAGE_BPS) revert InvalidClose(2);
        IsolatedMarginTypes.Position memory p = executor.positions(positionId);
        if (p.owner != owner) revert InvalidClose(3);
        if (p.status != IsolatedMarginTypes.Status.ACTIVE) revert InvalidClose(4);
        if (config.closeFeeBps() > MAX_CLOSE_FEE_BPS) revert InvalidClose(5);
        (uint256 price, bool ok) = oraclePriceE18(positionId);
        if (!ok || price != oraclePriceE18_) revert InvalidClose(6); // the registry's trigger check used this exact price

        uint256 minDebt = _minimumDebt(p, closeBps, maxSlippageBps);
        // Second leg: zero selects the close path's runtime protocol floor; the first-leg minimum already bounds the result.
        returnedMargin = executor.closePositionFor(
            owner, IRobinhoodOrderExecutor.CloseParams(positionId, closeBps, type(uint256).max, minDebt, 0, "", "")
        );
    }

    /// @dev Same construction as the live operator close (remediation MarginAcceptance): the oracle-quoted value of the
    /// closed position assets less the order's slippage, and never less than the debt being repaid plus the flash fee.
    /// Debt is accrued first, so interest is included.
    function _minimumDebt(IsolatedMarginTypes.Position memory p, uint16 closeBps, uint16 maxSlippageBps)
        private
        returns (uint256)
    {
        IRobinhoodOrderMarket positionMarket = IRobinhoodOrderMarket(p.positionPToken);
        IRobinhoodOrderMarket debtMarket = IRobinhoodOrderMarket(p.debtPToken);
        uint256 rate = positionMarket.exchangeRateCurrent();
        uint256 assets = Math.mulDiv(positionMarket.balanceOf(p.account), rate, 1e18);
        uint256 debt = debtMarket.borrowBalanceCurrent(p.account);
        if (closeBps != BPS) {
            assets = Math.mulDiv(assets, closeBps, BPS);
            debt = Math.mulDiv(debt, closeBps, BPS, Math.Rounding.Ceil);
        }
        address debtAsset = debtMarket.underlying();
        uint256 quoted = quoter.expectedOut(positionMarket.underlying(), debtAsset, assets);
        // The swap module refuses a minimum looser than the pair's own slippage limit (SwapError 5), so use the tighter of
        // the order's tolerance and the pair's: never worse for the owner than what the order allows.
        uint16 pairMax = config.getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken).maxSlippageBps;
        uint16 effective = maxSlippageBps < pairMax ? maxSlippageBps : pairMax;
        uint256 floorBySlippage = Math.mulDiv(quoted, BPS - effective, BPS);
        uint256 flashFee = debt == 0 ? 0 : IERC3156FlashLender(config.flashLoanProvider()).flashFee(debtAsset, debt);
        return Math.max(floorBySlippage, debt + flashFee);
    }
}
