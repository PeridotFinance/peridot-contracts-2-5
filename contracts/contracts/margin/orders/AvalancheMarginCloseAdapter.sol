// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC3156FlashLender} from "../../PTokenInterfaces.sol";
import {IsolatedMarginTypes} from "../IsolatedMarginTypes.sol";
import {IMarginCloseAdapter} from "./IMarginOrderRegistry.sol";

interface IAvalancheOrderExecutor {
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

interface IAvalancheOrderMarket {
    function underlying() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
}

interface IAvalancheOrderQuoter {
    function expectedOut(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256);
}

interface IAvalancheOrderOracle {
    function getPrice(address asset) external view returns (uint256);
}

interface IAvalancheOrderConfig {
    function flashLoanProvider() external view returns (address);
    function closeFeeBps() external view returns (uint16);
    function getPairRisk(address marginPToken, address positionPToken, address debtPToken)
        external
        view
        returns (IsolatedMarginTypes.PairRiskConfig memory);
}

/// @title Avalanche close path for the chain-agnostic TP/SL registry (long WAVAX / USDC only).
/// @notice Turns an executed order into `IsolatedMarginExecutorUpgradeable.closePositionFor`. It holds no funds and no
/// approvals. The minimums it passes are derived from the margin engine's own (guarded) oracle and quoter, so a keeper
/// can choose neither the price nor the route: `adapterData` must be empty, and the swap module uses its one pinned pool.
/// Same construction as the Robinhood adapter, with one addition: SHORT positions are refused everywhere (PW30 keeps WAVAX
/// borrowing paused, so none can exist; this makes the guarantee local to the adapter).
contract AvalancheMarginCloseAdapter is IMarginCloseAdapter {
    uint256 private constant BPS = 10_000;
    uint16 public constant MAX_SLIPPAGE_BPS = 300;
    uint16 public constant MAX_CLOSE_FEE_BPS = 100; // refuses to execute if governance ever raises the close fee above 1 %

    IAvalancheOrderExecutor public immutable executor;
    address public immutable registry;
    IAvalancheOrderOracle public immutable oracle;
    IAvalancheOrderQuoter public immutable quoter;
    IAvalancheOrderConfig public immutable config;

    error NotRegistry();
    error AdapterDataNotSupported();
    error InvalidClose(uint8 code); // 1 closeBps, 2 slippage, 3 owner, 4 inactive, 5 close fee too high, 6 price moved, 7 not a long

    constructor(address executor_, address registry_, address oracle_, address quoter_, address config_) {
        require(
            executor_.code.length > 0 && registry_ != address(0) && oracle_.code.length > 0 && quoter_.code.length > 0
                && config_.code.length > 0,
            "ADAPTER_CONFIG"
        );
        executor = IAvalancheOrderExecutor(executor_);
        registry = registry_;
        oracle = IAvalancheOrderOracle(oracle_);
        quoter = IAvalancheOrderQuoter(quoter_);
        config = IAvalancheOrderConfig(config_);
    }

    function positionOwner(uint256 positionId) external view returns (address) {
        return executor.positions(positionId).owner;
    }

    /// @dev A SHORT is reported as inactive, so the registry can neither create nor execute an order on it.
    function isActive(uint256 positionId) external view returns (bool) {
        IsolatedMarginTypes.Position memory p = executor.positions(positionId);
        return p.status == IsolatedMarginTypes.Status.ACTIVE && p.side == IsolatedMarginTypes.Side.LONG;
    }

    function isLong(uint256 positionId) external view returns (bool) {
        return executor.positions(positionId).side == IsolatedMarginTypes.Side.LONG;
    }

    /// @notice WAVAX price in USD (18 decimals) from the margin oracle; 0 (so `ok` false) for a stale, zero or invalid feed.
    function oraclePriceE18(uint256 positionId) public view returns (uint256 priceE18, bool ok) {
        IsolatedMarginTypes.Position memory p = executor.positions(positionId);
        if (p.side != IsolatedMarginTypes.Side.LONG || p.positionPToken == address(0)) return (0, false);
        priceE18 = oracle.getPrice(IAvalancheOrderMarket(p.positionPToken).underlying());
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
        if (p.side != IsolatedMarginTypes.Side.LONG) revert InvalidClose(7);
        if (config.closeFeeBps() > MAX_CLOSE_FEE_BPS) revert InvalidClose(5);
        (uint256 price, bool ok) = oraclePriceE18(positionId);
        if (!ok || price != oraclePriceE18_) revert InvalidClose(6); // the registry's trigger check used this exact price

        uint256 minDebt = _minimumDebt(p, closeBps, maxSlippageBps);
        // Second leg: zero selects the close path's runtime protocol floor; the first-leg minimum already bounds the result.
        returnedMargin = executor.closePositionFor(
            owner, IAvalancheOrderExecutor.CloseParams(positionId, closeBps, type(uint256).max, minDebt, 0, "", "")
        );
    }

    /// @dev The oracle-quoted value of the closed position assets less the tighter of the order's slippage and the pair's
    /// own limit (the swap module refuses a looser minimum, SwapError 5), and never less than the debt being repaid plus
    /// the flash fee. Debt is accrued first, so interest is included.
    function _minimumDebt(IsolatedMarginTypes.Position memory p, uint16 closeBps, uint16 maxSlippageBps)
        private
        returns (uint256)
    {
        IAvalancheOrderMarket positionMarket = IAvalancheOrderMarket(p.positionPToken);
        IAvalancheOrderMarket debtMarket = IAvalancheOrderMarket(p.debtPToken);
        uint256 rate = positionMarket.exchangeRateCurrent();
        uint256 assets = Math.mulDiv(positionMarket.balanceOf(p.account), rate, 1e18);
        uint256 debt = debtMarket.borrowBalanceCurrent(p.account);
        if (closeBps != BPS) {
            assets = Math.mulDiv(assets, closeBps, BPS);
            debt = Math.mulDiv(debt, closeBps, BPS, Math.Rounding.Ceil);
        }
        address debtAsset = debtMarket.underlying();
        uint256 quoted = quoter.expectedOut(positionMarket.underlying(), debtAsset, assets);
        uint16 pairMax = config.getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken).maxSlippageBps;
        uint16 effective = maxSlippageBps < pairMax ? maxSlippageBps : pairMax;
        uint256 floorBySlippage = Math.mulDiv(quoted, BPS - effective, BPS);
        uint256 flashFee = debt == 0 ? 0 : IERC3156FlashLender(config.flashLoanProvider()).flashFee(debtAsset, debt);
        return Math.max(floorBySlippage, debt + flashFee);
    }
}
