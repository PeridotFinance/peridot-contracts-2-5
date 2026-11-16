// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {DeploySpyMargin} from "../../script/spy/DeploySpyMargin.s.sol";
import {SpyMarginParams as P} from "../../script/spy/SpyMarginParams.sol";

interface IController {
    function oracle() external view returns (address);
    function admin() external view returns (address);
    function _setPriceOracle(address) external returns (uint256);
    function _supportMarket(address) external returns (uint256);
    function _setBorrowPaused(address, bool) external returns (bool);
    function borrowGuardianPaused(address) external view returns (bool);
    function markets(address) external view returns (bool, uint256, bool);
    function enterMarkets(address[] memory) external returns (uint256[] memory);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}

interface IPSpyAdmin {
    function activateBorrowAccounting(address[] memory, uint256, uint256) external;
    function borrowAccountingEnabled() external view returns (bool);
}

interface ILendingOracle {
    function registerChainlinkFeed(address, address) external;
    function setStockAsset(address, bool) external;
    function updateChainlinkPrices(address[] calldata) external;
    function assetPrices(address) external view returns (uint256);
}

interface IPriceOracleLike {
    function getUnderlyingPrice(address) external view returns (uint256);
}

interface IMarginOracle {
    function registerMarket(address, address, bool) external;
    function setAssetSource(address) external;
    function assetSource() external view returns (address);
    function getPrice(address) external view returns (uint256);
    function marketAsset(address) external view returns (address);
    function marketPriceable(address) external view returns (bool);
}

interface IConfig {
    function queuePairRisk(address, address, address, IsolatedMarginTypes.PairRiskConfig calldata) external returns (bytes32);
    function setPairRisk(address, address, address, IsolatedMarginTypes.PairRiskConfig calldata) external;
    function getPairRisk(address, address, address) external view returns (IsolatedMarginTypes.PairRiskConfig memory);
    function disablePair(address, address, address) external;
    function flashLoanProvider() external view returns (address);
}

interface IRouterAdapter {
    function registerPool(address, address, uint24, int24) external;
    function pairRegistered(bytes32) external view returns (bool);
}

interface IMarket {
    function mint(uint256) external returns (uint256);
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function getCash() external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function borrowBalanceCurrent(address) external returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function underlying() external view returns (address);
}

interface IExecutor {
    struct OpenParams {
        address marginPToken;
        address positionPToken;
        address debtPToken;
        uint256 marginPTokenAmount;
        uint16 leverageX100;
        uint256 maxOpeningFeePToken;
        uint256 minPositionUnderlying;
        IsolatedMarginTypes.Side side;
        bytes swapData;
    }

    struct CloseParams {
        uint256 positionId;
        uint16 closeBps;
        uint256 maxClosingFeePToken;
        uint256 minDebtUnderlying;
        uint256 minMarginUnderlying;
        bytes positionToDebtSwapData;
        bytes debtToMarginSwapData;
    }

    function openPosition(OpenParams calldata) external returns (uint256);
    function closePosition(CloseParams calldata) external returns (uint256);
    function addCollateral(uint256, uint256) external;
    function repayWithUnderlying(uint256, uint256) external returns (uint256);
    function repayWithPToken(uint256, uint256) external returns (uint256);
    function exitDebtFreeToPTokens(uint256, uint16) external returns (uint256, uint256, uint256);
    function positions(uint256) external view returns (IsolatedMarginTypes.Position memory);
    function nextPositionId() external view returns (uint256);
}

interface IVault {
    function deposit(address, uint256) external;
    function withdraw(address, uint256) external;
    function freeBalance(address, address) external view returns (uint256);
}

interface IQuoter {
    function quoteOpen(address, address, address, uint256, uint16) external view returns (uint256, uint256);
    function expectedOut(address, address, uint256) external view returns (uint256);
}

interface IRisk {
    function getMetrics(address) external view returns (IsolatedMarginTypes.AccountMetrics memory);
    function isLiquidatable(address) external view returns (bool);
}

interface IRegistry {
    enum OrderKind {
        TAKE_PROFIT,
        STOP_LOSS
    }

    function createOrder(uint256, OrderKind, bool, uint256, uint16, uint16, uint64) external returns (uint256);
    function executeOrder(uint256, bytes calldata) external returns (bool);
    function cancelOrder(uint256) external;
    function canExecute(uint256) external view returns (bool, uint256, uint8);
}

interface ILiquidator {
    struct LiquidationParams {
        uint256 positionId;
        address recipient;
        uint256 minDebtUnderlying;
        uint256 minMarginUnderlying;
        bytes collateralToDebtSwapData;
        bytes debtToMarginSwapData;
    }

    function liquidate(LiquidationParams calldata) external;
}

interface IFlash {
    function flashFee(address, uint256) external view returns (uint256);
}

interface IFeedRead {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @notice Shared fork setup: the exact command-list ceremony applied to the live Robinhood state (Ledger pranked),
/// plus helpers for a SPY long. Pin with SPY_FORK_BLOCK (a weekday block with a fresh SPY feed) and SPY_NATIVE_BLOCK
/// (its l1BlockNumber; interest accrues on the native block number). Nothing is sent anywhere.
abstract contract SpyMarginForkBase is Test {
    address constant WHALE = 0x8366a39CC670B4001A1121B8F6A443A643e40951; // Uniswap v4 PoolManager (USDG and SPY)
    address constant NVDA_POSITION6_ACCOUNT = 0x8039391D9a706dB3FdD46602f735fB097E5D464B;
    uint256 constant LEDGER_LIQUIDITY_USDG = 80e6; // command list steps 15-16

    DeploySpyMargin.Deployed d;
    address user = makeAddr("spy-demo-user");
    uint256 forkBlock;

    function _fork() internal {
        forkBlock = vm.envUint("SPY_FORK_BLOCK");
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), forkBlock);
        vm.roll(vm.envUint("SPY_NATIVE_BLOCK"));
    }

    function _deploy() internal {
        DeploySpyMargin s = new DeploySpyMargin();
        d = s.deployAll(
            DeploySpyMargin.Params(P.DEFAULT_MAX_STALENESS, P.DEFAULT_CLOSED_FROM, P.DEFAULT_CLOSED_UNTIL)
        );
    }

    /// @dev Command-list steps 1-13 at T0. Returns nothing; asserts the state each Compound error-code call must leave.
    function _ceremonyT0(IsolatedMarginTypes.PairRiskConfig memory risk) internal {
        vm.startPrank(P.LEDGER);
        IConfig(P.CONFIG).queuePairRisk(P.PUSDG, d.pSpy, P.PUSDG, risk); // 1
        ILendingOracle(P.LENDING_ORACLE).registerChainlinkFeed(P.SPY, P.SPY_FEED); // 2
        ILendingOracle(P.LENDING_ORACLE).setStockAsset(P.SPY, true); // 3
        address[] memory a = new address[](1);
        a[0] = P.SPY;
        ILendingOracle(P.LENDING_ORACLE).updateChainlinkPrices(a); // 4
        assertEq(IController(P.CONTROLLER)._setPriceOracle(d.lendingAdapter), 0); // 5
        assertEq(IController(P.CONTROLLER).oracle(), d.lendingAdapter);
        assertEq(IController(P.CONTROLLER)._supportMarket(d.pSpy), 0); // 6
        (bool listed, uint256 cf,) = IController(P.CONTROLLER).markets(d.pSpy);
        assertTrue(listed);
        assertEq(cf, 0);
        IController(P.CONTROLLER)._setBorrowPaused(d.pSpy, true); // 7
        assertTrue(IController(P.CONTROLLER).borrowGuardianPaused(d.pSpy));
        // 8-9: seed from the Ledger's own SPY, minted and sent to a dead address.
        uint256 seed = IERC20(P.SPY).balanceOf(P.LEDGER);
        require(seed > 0, "LEDGER_HAS_NO_SPY");
        IERC20(P.SPY).approve(d.pSpy, seed);
        IMarket(d.pSpy).mint(seed);
        IMarket(d.pSpy).transfer(P.SEED_SINK, IMarket(d.pSpy).balanceOf(P.LEDGER));
        assertTrue(IPSpyAdmin(d.pSpy).borrowAccountingEnabled()); // enabled by PToken.initialize; no step 10
        IMarginOracle(P.MARGIN_ORACLE).registerMarket(d.pSpy, P.SPY, false); // 11
        IMarginOracle(P.MARGIN_ORACLE).setAssetSource(d.router); // 12
        IRouterAdapter(P.ROUTER_ADAPTER).registerPool(P.SPY, P.USDG, P.SPY_POOL_FEE, P.SPY_POOL_TICK_SPACING); // 13
        vm.stopPrank();
    }

    /// @dev Command-list step 14 (T0 + 1 h) and 15-16 (Ledger liquidity), with the seed front-run gate first.
    function _ceremonyT1(IsolatedMarginTypes.PairRiskConfig memory risk, uint256 seedShares) internal {
        assertEq(IMarket(d.pSpy).totalSupply(), seedShares, "seed front-run gate: supply");
        assertEq(IMarket(d.pSpy).balanceOf(P.SEED_SINK), seedShares, "seed front-run gate: sink");
        vm.warp(block.timestamp + 3601);
        _freshSpyFeed(); // the rehearsal advances time; keep the feed's real answer at the new time
        vm.startPrank(P.LEDGER);
        IConfig(P.CONFIG).setPairRisk(P.PUSDG, d.pSpy, P.PUSDG, risk);
        IERC20(P.USDG).approve(P.PUSDG, LEDGER_LIQUIDITY_USDG);
        IMarket(P.PUSDG).mint(LEDGER_LIQUIDITY_USDG);
        vm.stopPrank();
    }

    function _fullCeremony() internal {
        IsolatedMarginTypes.PairRiskConfig memory risk = P.longRisk(P.DEFAULT_MAX_POSITION_USD, P.DEFAULT_MAX_DEBT_USD);
        _ceremonyT0(risk);
        _ceremonyT1(risk, IMarket(d.pSpy).totalSupply());
    }

    // ------------------------------------------------------------------ feed control
    int256 spyAnswer;

    /// @dev Re-stamps the real SPY answer at the current time (lending oracle and SPY source both read this feed).
    function _freshSpyFeed() internal {
        if (spyAnswer == 0) {
            (, int256 a,,,) = IFeedRead(P.SPY_FEED).latestRoundData();
            spyAnswer = a;
        }
        _setSpy(spyAnswer);
    }

    function _setSpy(int256 answer) internal {
        uint256 t = block.timestamp;
        vm.mockCall(
            P.SPY_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1000), answer, t, t, uint80(1000))
        );
    }

    function _setSpyAt(int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            P.SPY_FEED,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1000), answer, updatedAt, updatedAt, uint80(1000))
        );
    }

    /// @dev Scales the base answer by bps (10_000 = unchanged).
    function _moveSpy(uint256 bps) internal {
        if (spyAnswer == 0) _freshSpyFeed();
        _setSpy(int256(uint256(spyAnswer) * bps / 10_000));
    }

    // ------------------------------------------------------------------ position helpers
    function _fund(address who, uint256 usdg) internal {
        vm.prank(WHALE);
        IERC20(P.USDG).transfer(who, usdg);
    }

    /// @dev Fresh USDG margin minted into pUSDG and deposited (cash-neutral for pUSDG), then a 2x long.
    function _openLong(uint256 marginUsdg, uint16 leverageX100) internal returns (uint256 id) {
        _fund(user, marginUsdg);
        vm.startPrank(user);
        IERC20(P.USDG).approve(P.PUSDG, marginUsdg);
        IMarket(P.PUSDG).mint(marginUsdg);
        uint256 shares = IMarket(P.PUSDG).balanceOf(user);
        IMarket(P.PUSDG).approve(P.MARGIN_VAULT, shares);
        IVault(P.MARGIN_VAULT).deposit(P.PUSDG, shares);
        uint256 marginUnderlying = Math.mulDiv(shares, IMarket(P.PUSDG).exchangeRateCurrent(), 1e18);
        (, uint256 minimum) = IQuoter(P.QUOTER).quoteOpen(P.PUSDG, d.pSpy, P.PUSDG, marginUnderlying, leverageX100);
        id = IExecutor(P.EXECUTOR).openPosition(
            IExecutor.OpenParams(
                P.PUSDG, d.pSpy, P.PUSDG, shares, leverageX100, 0, minimum, IsolatedMarginTypes.Side.LONG, ""
            )
        );
        vm.stopPrank();
    }

    function _pos(uint256 id) internal view returns (IsolatedMarginTypes.Position memory) {
        return IExecutor(P.EXECUTOR).positions(id);
    }

    /// @dev The live operator-close minimum: oracle-quoted proceeds less 1%, never below debt plus flash fee.
    function _minDebt(uint256 id, uint16 closeBps) internal returns (uint256) {
        IsolatedMarginTypes.Position memory p = _pos(id);
        uint256 assets = Math.mulDiv(
            IMarket(d.pSpy).balanceOf(p.account), IMarket(d.pSpy).exchangeRateCurrent(), 1e18
        );
        uint256 debt = IMarket(P.PUSDG).borrowBalanceCurrent(p.account);
        assets = Math.mulDiv(assets, closeBps, 10_000);
        debt = Math.mulDiv(debt, closeBps, 10_000, Math.Rounding.Ceil);
        uint256 quoted = IQuoter(P.QUOTER).expectedOut(P.SPY, P.USDG, assets);
        uint256 fee = IFlash(P.FLASH_VAULT).flashFee(P.USDG, debt);
        return Math.max(quoted * 9900 / 10_000, debt + fee);
    }

    function _close(uint256 id, uint16 closeBps) internal returns (uint256 returned) {
        uint256 minDebt = _minDebt(id, closeBps);
        vm.prank(user);
        returned = IExecutor(P.EXECUTOR).closePosition(
            IExecutor.CloseParams(id, closeBps, type(uint256).max, minDebt, 0, "", "")
        );
    }

    function _metrics(uint256 id) internal view returns (IsolatedMarginTypes.AccountMetrics memory) {
        return IRisk(P.RISK_ENGINE).getMetrics(_pos(id).account);
    }
}
