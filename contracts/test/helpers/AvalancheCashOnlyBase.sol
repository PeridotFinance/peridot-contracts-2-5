// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {Peridot} from "../../contracts/Governance/Peridot.sol";
import {Unitroller} from "../../contracts/Unitroller.sol";
import {Peridottroller} from "../../contracts/Peridottroller.sol";
import {PeridottrollerAvalanche} from "../../contracts/PeridottrollerAvalanche.sol";
import {PeridottrollerInterface} from "../../contracts/PeridottrollerInterface.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {PToken} from "../../contracts/PToken.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {PErc20Delegate} from "../../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../../contracts/PErc20Delegator.sol";
import {ConfigurableJumpRateModelV2} from "../../contracts/ConfigurableJumpRateModelV2.sol";
import {AvalanchePriceOracle} from "../../contracts/margin/AvalanchePriceOracle.sol";
import {GuardedAvalanchePriceOracle, IAvalanchePriceOracleSource} from "../../contracts/margin/GuardedAvalanchePriceOracle.sol";

/**
 * @notice HARNESS for the CASH-ONLY lending fixture (cash-only USDC/WAVAX lending, no margin).
 *
 * This is a SEPARATE fixture from `AvalancheSection5Base`: it deploys ONLY the controller (Unitroller +
 * `PeridottrollerAvalanche`), the two plain `PErc20Delegate` markets (pUSDC, pWAVAX), the interest rate model and the
 * `GuardedAvalanchePriceOracle` over `AvalanchePriceOracle`. It does NOT import or deploy the isolated-margin stack, the Pharaoh
 * adapter, the flash vault or the insurance fund, and BOTH controller margin hooks (`isolatedMarginRiskHook`,
 * `isolatedMarginRegistrar`) stay at address(0), which is the state a cash-only deployment would have.
 *
 * Same pinned fork as the other Avalanche suites (block 99,200,000, real tokens and Chainlink feeds; feeds are mocked only to
 * move or age prices). All lending parameters are PLACEHOLDERS used to measure, not recommendations (operator decision 3).
 * Nothing here signs or broadcasts. Without AVALANCHE_MAINNET_RPC_URL every test is skipped (setUp).
 */
abstract contract AvalancheCashOnlyBase is Test {
    uint256 internal constant PIN_BLOCK = 99_200_000;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant AVAX_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant USDC_FEED = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;
    uint32 internal constant AVAX_MAX_AGE = 1_200;
    uint32 internal constant USDC_MAX_AGE = 90_000;

    // PARAM (operator decisions): placeholders
    uint256 internal constant CF_WAVAX = 0.60e18;
    uint256 internal constant CF_USDC = 0.75e18;
    uint256 internal constant RESERVE_FACTOR = 0.10e18;
    uint256 internal constant WAVAX_BORROW_CAP = 20_000e18;
    uint256 internal constant USDC_BORROW_CAP = 500_000e6;
    uint256 internal constant PRICE_ERROR_CODE = 13;
    uint256 internal constant INSUFFICIENT_SHORTFALL_CODE = 3;
    uint256 internal constant TOO_MUCH_REPAY_CODE = 17;

    address internal constant LP = address(0x1001);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201); // liquidator
    address internal constant DAVE = address(0xDA7E);

    Peridot internal peridot;
    AvalanchePriceOracle internal inner;
    GuardedAvalanchePriceOracle internal oracle;
    Unitroller internal unitroller;
    Peridottroller internal controller;
    ConfigurableJumpRateModelV2 internal irm;
    PErc20Delegator internal pWavax;
    PErc20Delegator internal pUsdc;

    int256 internal avaxAnswer;
    int256 internal realAvaxAnswer;
    int256 internal usdcAnswer;
    bytes internal lastRevert;

    function setUp() public virtual {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PIN_BLOCK);
        require(block.chainid == 43_114, "not Avalanche C-Chain");
        (, int256 a,,,) = AggregatorV3Interface(AVAX_FEED).latestRoundData();
        (, int256 u,,,) = AggregatorV3Interface(USDC_FEED).latestRoundData();
        avaxAnswer = a;
        realAvaxAnswer = a;
        usdcAnswer = u;

        inner = new AvalanchePriceOracle(address(this));
        inner.configureFeed(WAVAX, AVAX_FEED, AVAX_MAX_AGE);
        inner.configureFeed(USDC, USDC_FEED, USDC_MAX_AGE);
        oracle = new GuardedAvalanchePriceOracle(IAvalanchePriceOracleSource(address(inner)));

        peridot = new Peridot(address(this));
        unitroller = new Unitroller();
        PeridottrollerAvalanche impl = new PeridottrollerAvalanche(address(peridot));
        require(unitroller._setPendingImplementation(address(impl)) == 0, "impl");
        impl._become(unitroller);
        controller = Peridottroller(address(unitroller));

        irm = new ConfigurableJumpRateModelV2(31_536_000, 0.02e18, 0.1e18, 1e18, 0.8e18, address(this)); // PARAM
        address delegate = address(new PErc20Delegate());
        require(controller._setPriceOracle(PriceOracle(address(oracle))) == 0, "oracle");
        require(controller._setCloseFactor(0.5e18) == 0, "close factor");
        require(controller._setLiquidationIncentive(1.08e18) == 0, "incentive");
        require(controller._setPauseGuardian(address(this)) == 0, "guardian");
        pWavax = _market(WAVAX, 2e26, "Peridot Wrapped AVAX", "pWAVAX", delegate);
        pUsdc = _market(USDC, 2e14, "Peridot USD Coin", "pUSDC", delegate);
        require(controller._supportMarket(PErc20(address(pWavax))) == 0, "list pWAVAX");
        require(controller._supportMarket(PErc20(address(pUsdc))) == 0, "list pUSDC");
        require(controller._setBorrowPaused(PErc20(address(pWavax)), true), "pause w");
        require(controller._setBorrowPaused(PErc20(address(pUsdc)), true), "pause u");
        require(PErc20(address(pWavax))._setFlashLoansPaused(true), "flash w");
        require(PErc20(address(pUsdc))._setFlashLoansPaused(true), "flash u");
        require(PErc20(address(pWavax))._setReserveFactor(RESERVE_FACTOR) == 0, "rf w");
        require(PErc20(address(pUsdc))._setReserveFactor(RESERVE_FACTOR) == 0, "rf u");
        PToken[] memory ps = new PToken[](2);
        ps[0] = PToken(address(pWavax));
        ps[1] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](2);
        caps[0] = WAVAX_BORROW_CAP;
        caps[1] = USDC_BORROW_CAP;
        controller._setMarketBorrowCaps(ps, caps);
        inner.registerMarket(address(pWavax), WAVAX);
        inner.registerMarket(address(pUsdc), USDC);
        require(oracle.getUnderlyingPrice(PToken(address(pWavax))) > 0, "AVAX price at pin");
        require(oracle.getUnderlyingPrice(PToken(address(pUsdc))) > 0, "USDC price at pin");
        require(controller._setCollateralFactor(PToken(address(pWavax)), CF_WAVAX) == 0, "cf w");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), CF_USDC) == 0, "cf u");

        _mintP(pUsdc, LP, 400_000e6);
        _mintP(pWavax, LP, 12_000e18);
    }

    function _market(address underlying, uint256 initialRate, string memory name, string memory symbol, address delegate)
        internal
        returns (PErc20Delegator)
    {
        return new PErc20Delegator(
            underlying, PeridottrollerInterface(address(controller)), irm, initialRate, name, symbol, 8, payable(address(this)), delegate, ""
        );
    }

    // ----------------------------------------------------------------- helpers
    function _unpauseBorrows() internal {
        controller._setBorrowPaused(PErc20(address(pWavax)), false);
        controller._setBorrowPaused(PErc20(address(pUsdc)), false);
    }

    function _setPrices(int256 avax8, int256 usdc8) internal {
        avaxAnswer = avax8;
        usdcAnswer = usdc8;
        _mockFeed(AVAX_FEED, avax8);
        _mockFeed(USDC_FEED, usdc8);
    }

    function _setAvaxBps(uint256 bps) internal {
        _setPrices(int256((uint256(realAvaxAnswer) * bps) / 10_000), usdcAnswer);
    }

    function _mockFeed(address feed, int256 answer) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1000), answer, block.timestamp, block.timestamp, uint80(1000))
        );
    }

    function _mintP(PErc20Delegator p, address who, uint256 amount) internal returns (uint256 minted) {
        address asset = PErc20(address(p)).underlying();
        deal(asset, who, IERC20(asset).balanceOf(who) + amount);
        uint256 before = p.balanceOf(who);
        vm.startPrank(who);
        IERC20(asset).approve(address(p), amount);
        require(p.mint(amount) == 0, "mint failed");
        vm.stopPrank();
        minted = p.balanceOf(who) - before;
    }

    function _enter(address who) internal {
        address[] memory ms = new address[](2);
        ms[0] = address(pWavax);
        ms[1] = address(pUsdc);
        vm.prank(who);
        controller.enterMarkets(ms);
    }

    /// @dev Low-level call as `who`; returns whether it did not revert and the uint error code it returned (0 = success).
    function _try(address who, address target, bytes memory data) internal returns (bool ok, uint256 code) {
        vm.prank(who);
        (bool success, bytes memory ret) = target.call(data);
        lastRevert = success ? bytes("") : ret;
        if (success && ret.length == 32) code = abi.decode(ret, (uint256));
        ok = success && code == 0;
    }

    function _borrow(PErc20Delegator p, address who, uint256 amount) internal returns (bool ok, uint256 code) {
        address asset = PErc20(address(p)).underlying();
        uint256 bal = IERC20(asset).balanceOf(who);
        (, code) = _try(who, address(p), abi.encodeWithSelector(PErc20.borrow.selector, amount));
        ok = code == 0 && lastRevert.length == 0 && IERC20(asset).balanceOf(who) == bal + amount;
    }

    function _repay(PErc20Delegator p, address who, uint256 amount) internal returns (bool ok, uint256 code) {
        address asset = PErc20(address(p)).underlying();
        deal(asset, who, IERC20(asset).balanceOf(who) + (amount == type(uint256).max ? p.borrowBalanceCurrent(who) + 1 : amount));
        vm.prank(who);
        IERC20(asset).approve(address(p), type(uint256).max);
        (ok, code) = _try(who, address(p), abi.encodeWithSelector(PErc20.repayBorrow.selector, amount));
    }

    function _redeemUnderlying(PErc20Delegator p, address who, uint256 amount) internal returns (bool ok, uint256 code) {
        address asset = PErc20(address(p)).underlying();
        uint256 bal = IERC20(asset).balanceOf(who);
        (, code) = _try(who, address(p), abi.encodeWithSelector(PErc20.redeemUnderlying.selector, amount));
        ok = code == 0 && lastRevert.length == 0 && IERC20(asset).balanceOf(who) == bal + amount;
    }

    function _liquidate(PErc20Delegator borrowedMarket, PErc20Delegator collateralMarket, address borrower, uint256 repay)
        internal
        returns (bool ok, uint256 code, uint256 seized)
    {
        address asset = PErc20(address(borrowedMarket)).underlying();
        deal(asset, CAROL, IERC20(asset).balanceOf(CAROL) + repay);
        uint256 before = collateralMarket.balanceOf(CAROL);
        vm.prank(CAROL);
        IERC20(asset).approve(address(borrowedMarket), repay);
        (, code) = _try(
            CAROL,
            address(borrowedMarket),
            abi.encodeWithSelector(PErc20.liquidateBorrow.selector, borrower, repay, address(collateralMarket))
        );
        // The market reverts with LiquidateBorrowPeridottrollerRejection(code) on a controller denial: report that code.
        if (lastRevert.length >= 36) code = _revertCode(lastRevert);
        seized = collateralMarket.balanceOf(CAROL) - before;
        ok = code == 0 && lastRevert.length == 0 && seized > 0;
    }

    function _debt(PErc20Delegator p, address who) internal returns (uint256) {
        return p.borrowBalanceCurrent(who);
    }

    function _selector(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) assembly { s := mload(add(ret, 32)) }
    }

    function _revertCode(bytes memory ret) internal pure returns (uint256 code) {
        if (ret.length >= 36) assembly { code := mload(add(ret, 36)) }
    }
}
