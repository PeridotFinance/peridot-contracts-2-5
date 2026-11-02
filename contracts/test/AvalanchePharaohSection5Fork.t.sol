// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {Peridot} from "../contracts/Governance/Peridot.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {PToken} from "../contracts/PToken.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {ConfigurableJumpRateModelV2} from "../contracts/ConfigurableJumpRateModelV2.sol";
import {PeridotTransparentProxy} from "../contracts/proxy/PeridotTransparentProxy.sol";

import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {GuardedAvalanchePriceOracle, IAvalanchePriceOracleSource} from "../contracts/margin/GuardedAvalanchePriceOracle.sol";
import {PharaohCLRouterAdapter, IPharaohCLRouter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginAccountFactory} from "../contracts/margin/IsolatedMarginAccountFactory.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginSwapModule} from "../contracts/margin/IsolatedMarginSwapModule.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginFeeDistributorUpgradeable} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {MarginInsuranceFundUpgradeable} from "../contracts/margin/MarginInsuranceFundUpgradeable.sol";

interface IPharaohPoolState {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint24 feeProtocol, bool unlocked);
    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
}

/**
 * @notice Handoff 09 section 5 checkpoint: Avalanche C-Chain FORK test, local VM writes only.
 *
 * Nothing here signs or broadcasts. Everything is deployed inside the forked VM:
 *   - Track B: fresh Unitroller + Peridottroller (`PeridottrollerAvalanche`), plain `PErc20Delegate`
 *     markets pUSDC / pWAVAX over the real native USDC and WAVAX, cash only, borrowing PAUSED at deploy.
 *   - Oracle: `GuardedAvalanchePriceOracle` over `AvalanchePriceOracle` (real Chainlink feeds, no emergency price).
 *   - Track C: legacy isolated-margin stack bound to B's controller, `PharaohCLRouterAdapter` pinned to the
 *     real WAVAX/USDC Pharaoh CL pool, SimpleFlashLoanVault, insurance fund; opens PAUSED at deploy.
 *
 * Pinned block: see PIN_BLOCK. setUp reads the REAL Chainlink rounds, which must be within AVAX_MAX_AGE of the
 * pin block (changing PIN_BLOCK needs a block shortly after a Chainlink update, or setUp fails with
 * "AVAX price at pin"). Real answers cannot be moved on a fork, so after any warp, margin activation and every
 * shock use `vm.mockCall` on the aggregator (`_setPrices`, pinned answers re-served fresh): all margin and
 * liquidation tests run on MOCKED prices; only deployments, the pool, the router and token balances are real.
 * The pool stays real unless a test explicitly trades it (`_movePoolTo`).
 * Without AVALANCHE_MAINNET_RPC_URL every test is skipped (setUp), which shows as "skipped", not "passed".
 *
 * Parameters that are OPERATOR DECISIONS (handoff 09 section 8) are marked PARAM: collateral factors,
 * rate model, reserve factor, borrow caps, pair caps and flash fee here are placeholders used to measure,
 * not recommendations.
 *
 * Run (public RPC served this pin during development; a private archive RPC is preferable):
 *   AVALANCHE_MAINNET_RPC_URL=https://api.avax.network/ext/bc/C/rpc FOUNDRY_PROFILE=debt_accounting \
 *   forge test --match-contract AvalanchePharaohSection5ForkTest --threads 1 -vv \
 *     --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
 */
contract AvalanchePharaohSection5ForkTest is Test {
    // ---------------------------------------------------------------- pinned environment (handoff 09 s1/s2)
    uint256 internal constant PIN_BLOCK = 99_200_000;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant AVAX_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant USDC_FEED = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;
    address internal constant PHARAOH_ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    address internal constant PHARAOH_FACTORY = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d;
    address internal constant PHARAOH_POOL = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534;
    int24 internal constant TICK_SPACING = 10;

    uint32 internal constant AVAX_MAX_AGE = 1_200; // as AvalancheFuji deploy defaults
    uint32 internal constant USDC_MAX_AGE = 90_000;

    // ---------------------------------------------------------------- PARAM (operator decisions)
    uint256 internal constant CF_WAVAX = 0.60e18;
    uint256 internal constant CF_USDC = 0.75e18;
    uint256 internal constant RESERVE_FACTOR = 0.10e18;
    uint256 internal constant WAVAX_BORROW_CAP = 20_000e18;
    uint256 internal constant USDC_BORROW_CAP = 500_000e6;
    uint16 internal constant MAX_LEV_X100 = 200;
    uint128 internal constant POSITION_CAP_USD = 50_000e18;
    uint128 internal constant DEBT_CAP_USD = 25_000e18;
    uint256 internal constant FLASH_FEE_BPS = 0;

    address internal constant PROXY_ADMIN_OWNER = address(0xAD);
    address internal constant LP = address(0x1001);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant WHALE = address(0xDEAD0001);
    address internal constant DAVE = address(0xDA7E);
    uint256 internal constant PRICE_ERROR_CODE = 13; // ErrorReporter.Error.PRICE_ERROR
    uint16 internal maintenanceBps = 2500; // PARAM; tests that need an earlier liquidation override it
    bytes internal lastRevert;
    address internal constant KEEPER_RECIPIENT = address(0xBEEF);

    // ---------------------------------------------------------------- deployed in setUp
    Peridot internal peridot;
    AvalanchePriceOracle internal inner;
    GuardedAvalanchePriceOracle internal oracle;
    Unitroller internal unitroller;
    Peridottroller internal controller;
    ConfigurableJumpRateModelV2 internal irm;
    PErc20Delegator internal pWavax;
    PErc20Delegator internal pUsdc;

    PharaohCLRouterAdapter internal clAdapter;
    SimpleFlashLoanVault internal lender;
    MarginInsuranceFundUpgradeable internal insuranceFund;
    IsolatedMarginConfigUpgradeable internal mConfig;
    MarginFeeDistributorUpgradeable internal feeDistributor;
    IsolatedMarginVaultUpgradeable internal mVault;
    IsolatedMarginRiskEngineUpgradeable internal riskEngine;
    IsolatedMarginQuoter internal quoter;
    IsolatedMarginSwapModule internal swapModule;
    IsolatedMarginAccountFactory internal accountFactory;
    IsolatedMarginExecutorUpgradeable internal executor;
    IsolatedMarginLiquidatorUpgradeable internal liquidator;

    int256 internal avaxAnswer; // Chainlink 8-decimals, as read at the pin
    int256 internal usdcAnswer;
    int256 internal realAvaxAnswer;
    bool internal feedsMocked;

    // ================================================================= setUp
    function setUp() public {
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

        _deployOracle();
        _deployLending();
        _deployMargin();
        _fundVenuesAndLiquidity();
    }

    // ----------------------------------------------------------------- deployment
    function _deployOracle() internal {
        inner = new AvalanchePriceOracle(address(this));
        inner.configureFeed(WAVAX, AVAX_FEED, AVAX_MAX_AGE);
        inner.configureFeed(USDC, USDC_FEED, USDC_MAX_AGE);
        oracle = new GuardedAvalanchePriceOracle(IAvalanchePriceOracleSource(address(inner)));
    }

    function _deployLending() internal {
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
        // Borrowing and pToken flash loans start paused (handoff 09 s3b/s6).
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
        // Ordinary lending needs CF > 0 on both sides (PARAM). Margin accounts bypass CF via the risk hook.
        require(controller._setCollateralFactor(PToken(address(pWavax)), CF_WAVAX) == 0, "cf w");
        require(controller._setCollateralFactor(PToken(address(pUsdc)), CF_USDC) == 0, "cf u");
    }

    function _market(address underlying, uint256 initialRate, string memory name, string memory symbol, address delegate)
        internal
        returns (PErc20Delegator)
    {
        return new PErc20Delegator(
            underlying,
            PeridottrollerInterface(address(controller)),
            irm,
            initialRate,
            name,
            symbol,
            8,
            payable(address(this)),
            delegate,
            ""
        );
    }

    function _deployMargin() internal {
        clAdapter = new PharaohCLRouterAdapter(
            PHARAOH_ROUTER, PHARAOH_FACTORY, PHARAOH_POOL, WAVAX, USDC, TICK_SPACING
        );
        lender = new SimpleFlashLoanVault(address(this));
        lender.setTokenAllowed(WAVAX, true);
        lender.setTokenAllowed(USDC, true);
        lender.setFeeBps(FLASH_FEE_BPS);

        address me = address(this);
        insuranceFund = MarginInsuranceFundUpgradeable(
            _proxy(
                address(new MarginInsuranceFundUpgradeable()),
                abi.encodeWithSelector(MarginInsuranceFundUpgradeable.initialize.selector, me)
            )
        );
        mConfig = IsolatedMarginConfigUpgradeable(
            _proxy(
                address(new IsolatedMarginConfigUpgradeable()),
                abi.encodeWithSelector(
                    IsolatedMarginConfigUpgradeable.initialize.selector,
                    me,
                    1 hours,
                    address(clAdapter),
                    address(lender),
                    address(insuranceFund),
                    me
                )
            )
        );
        feeDistributor = MarginFeeDistributorUpgradeable(
            _proxy(
                address(new MarginFeeDistributorUpgradeable()),
                abi.encodeWithSelector(MarginFeeDistributorUpgradeable.initialize.selector, me, address(mConfig))
            )
        );
        mVault = IsolatedMarginVaultUpgradeable(
            _proxy(
                address(new IsolatedMarginVaultUpgradeable()),
                abi.encodeWithSelector(IsolatedMarginVaultUpgradeable.initialize.selector, me, address(feeDistributor))
            )
        );
        riskEngine = IsolatedMarginRiskEngineUpgradeable(
            _proxy(
                address(new IsolatedMarginRiskEngineUpgradeable()),
                abi.encodeWithSelector(
                    IsolatedMarginRiskEngineUpgradeable.initialize.selector,
                    me,
                    address(mConfig),
                    address(oracle), // SAME guarded oracle as the controller
                    address(controller)
                )
            )
        );
        quoter = new IsolatedMarginQuoter(address(mConfig), address(oracle));
        swapModule = new IsolatedMarginSwapModule(address(mConfig), address(quoter));
        accountFactory = new IsolatedMarginAccountFactory(me);
        executor = IsolatedMarginExecutorUpgradeable(
            _proxy(
                address(new IsolatedMarginExecutorUpgradeable()),
                abi.encodeWithSelector(
                    IsolatedMarginExecutorUpgradeable.initialize.selector,
                    address(mConfig),
                    address(riskEngine),
                    address(mVault),
                    address(feeDistributor),
                    address(quoter),
                    address(swapModule),
                    address(accountFactory)
                )
            )
        );
        liquidator = IsolatedMarginLiquidatorUpgradeable(
            _proxy(
                address(new IsolatedMarginLiquidatorUpgradeable()),
                abi.encodeWithSelector(
                    IsolatedMarginLiquidatorUpgradeable.initialize.selector,
                    address(executor),
                    address(mConfig),
                    address(riskEngine),
                    address(mVault),
                    address(insuranceFund),
                    address(quoter),
                    address(swapModule)
                )
            )
        );
        accountFactory.setExecutor(address(executor));
        riskEngine.setOperators(address(executor), address(liquidator));
        mVault.setExecutor(address(executor));
        mVault.setLiquidator(address(liquidator));
        feeDistributor.setVault(address(mVault));
        feeDistributor.setFeeCollector(address(mVault), true);
        feeDistributor.setFeeCollector(address(executor), true);
        insuranceFund.setLiquidator(address(liquidator));
        mVault.setPTokenAllowed(address(pWavax), true);
        mVault.setPTokenAllowed(address(pUsdc), true);
        require(controller._setIsolatedMarginRiskHook(address(riskEngine)) == 0, "hook");
        require(controller._setIsolatedMarginRegistrar(address(riskEngine)) == 0, "registrar");
        require(mConfig.opensPaused(), "opens must start paused");
    }

    function _proxy(address implementation, bytes memory data) internal returns (address) {
        return address(new PeridotTransparentProxy(implementation, PROXY_ADMIN_OWNER, data));
    }

    function _fundVenuesAndLiquidity() internal {
        // Supplier liquidity: PARAM sized so ordinary and margin tests have headroom.
        _mintP(pUsdc, LP, 400_000e6);
        _mintP(pWavax, LP, 12_000e18);
        // Flash vault funded to the caps (measured need is reported by the funding test).
        deal(USDC, address(this), 200_000e6);
        deal(WAVAX, address(this), 5_000e18);
        IERC20(USDC).approve(address(lender), type(uint256).max);
        IERC20(WAVAX).approve(address(lender), type(uint256).max);
        lender.depositLiquidity(USDC, 200_000e6);
        lender.depositLiquidity(WAVAX, 5_000e18);
        // Insurance fund seeded in pTokens (the liquidator draws pTokens): ~1% of each market.
        _mintP(pUsdc, address(this), 5_000e6);
        _mintP(pWavax, address(this), 150e18);
        require(pUsdc.transfer(address(insuranceFund), pUsdc.balanceOf(address(this))), "ins u");
        require(pWavax.transfer(address(insuranceFund), pWavax.balanceOf(address(this))), "ins w");
    }

    // ----------------------------------------------------------------- activation (the gates, collapsed)
    function _activate() internal {
        _activateLendingBorrows();
        _activateMargin();
    }

    function _activateLendingBorrows() internal {
        controller._setBorrowPaused(PErc20(address(pWavax)), false);
        controller._setBorrowPaused(PErc20(address(pUsdc)), false);
    }

    function _pairRisk(uint16 lev) internal view returns (IsolatedMarginTypes.PairRiskConfig memory) {
        // 2x, 50% initial / 25% maintenance (handoff 09 s3c canary profile). PARAM everything else.
        return IsolatedMarginTypes.PairRiskConfig(
            true, lev, 5000, maintenanceBps, 12_500, 5000, 5000, 500, 100, 100, POSITION_CAP_USD, DEBT_CAP_USD
        );
    }

    function _activateMargin() internal {
        IsolatedMarginTypes.PairRiskConfig memory r = _pairRisk(MAX_LEV_X100);
        // LONG: margin pUSDC, position pWAVAX, debt pUSDC. SHORT: margin pUSDC, position pUSDC, debt pWAVAX.
        mConfig.queuePairRisk(address(pUsdc), address(pWavax), address(pUsdc), r);
        mConfig.queuePairRisk(address(pUsdc), address(pUsdc), address(pWavax), r);
        mConfig.queueUnpauseOpens();
        vm.warp(block.timestamp + mConfig.actionDelay());
        _setPrices(avaxAnswer, usdcAnswer); // real feeds are stale after the delay; keep pinned answers fresh
        mConfig.setPairRisk(address(pUsdc), address(pWavax), address(pUsdc), r);
        mConfig.setPairRisk(address(pUsdc), address(pUsdc), address(pWavax), r);
        mConfig.unpauseOpens();
    }

    // ----------------------------------------------------------------- helpers
    function _setPrices(int256 avax8, int256 usdc8) internal {
        avaxAnswer = avax8;
        usdcAnswer = usdc8;
        feedsMocked = true;
        _mockFeed(AVAX_FEED, avax8);
        _mockFeed(USDC_FEED, usdc8);
    }

    /// @dev AVAX price as a percentage of the pinned real answer (bps), USDC at its pinned answer.
    function _setAvaxBps(uint256 bps) internal {
        _setPrices(int256((uint256(realAvaxAnswer) * bps) / 10_000), usdcAnswer);
    }

    function _refreshFeeds() internal {
        _setPrices(avaxAnswer, usdcAnswer);
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

    /// @dev Borrow through the market and report whether it really took effect (Compound-style
    ///      markets return an error code instead of reverting on a controller denial).
    function _borrow(PErc20Delegator p, address who, uint256 amount) internal returns (bool ok, uint256 code) {
        address asset = PErc20(address(p)).underlying();
        uint256 balBefore = IERC20(asset).balanceOf(who);
        vm.prank(who);
        (bool success, bytes memory ret) = address(p).call(abi.encodeWithSelector(PErc20.borrow.selector, amount));
        if (success && ret.length == 32) code = abi.decode(ret, (uint256));
        lastRevert = success ? bytes("") : ret;
        ok = success && code == 0 && IERC20(asset).balanceOf(who) == balBefore + amount;
    }

    function _liquidateOrdinary(PErc20Delegator borrowedMarket, PErc20Delegator collateralMarket, address borrower, uint256 repay)
        internal
        returns (bool ok, uint256 code, uint256 seized)
    {
        address asset = PErc20(address(borrowedMarket)).underlying();
        deal(asset, CAROL, IERC20(asset).balanceOf(CAROL) + repay);
        uint256 seizedBefore = collateralMarket.balanceOf(CAROL);
        vm.startPrank(CAROL);
        IERC20(asset).approve(address(borrowedMarket), repay);
        (bool success, bytes memory ret) = address(borrowedMarket)
            .call(abi.encodeWithSelector(PErc20.liquidateBorrow.selector, borrower, repay, address(collateralMarket)));
        vm.stopPrank();
        if (success && ret.length == 32) code = abi.decode(ret, (uint256));
        lastRevert = success ? bytes("") : ret;
        seized = collateralMarket.balanceOf(CAROL) - seizedBefore;
        ok = success && code == 0 && seized > 0;
    }

    function _usdPerAvax() internal view returns (uint256) {
        return uint256(avaxAnswer) / 1e8;
    }

    function _wavaxUsd(uint256 amount) internal view returns (uint256 usd6) {
        return Math.mulDiv(amount, uint256(avaxAnswer), 1e8 * 1e12); // USDC base units (6 dec)
    }

    function _poolSqrtPrice() internal view returns (uint160 s) {
        (s,,,,,,) = IPharaohPoolState(PHARAOH_POOL).slot0();
    }

    /// @dev Pool-implied USD per AVAX in Chainlink 8-decimals. price(USDC raw / WAVAX raw) = sqrt^2 / 2^192.
    function _poolAnswer8() internal view returns (int256) {
        uint256 pX128 = Math.mulDiv(uint256(_poolSqrtPrice()), uint256(_poolSqrtPrice()), 1 << 64);
        return int256(Math.mulDiv(pX128, 1e20, 1 << 128));
    }

    /// @dev Trade the REAL pool (WHALE, router, no limit) until its price reaches `targetBps` of the pinned price:
    ///      down = sell WAVAX in `chunkAvax` pieces, up = buy WAVAX with `chunkUsdc` pieces. Stops at the target, at
    ///      the price floor (<1% of pin: liquidity exhausted), or after `maxChunks`. Returns USD (1e6) traded and chunks.
    function _movePoolTo(uint256 targetBps, uint256 chunkAvax, uint256 chunkUsdc, uint256 maxChunks)
        internal
        returns (uint256 usdTraded, uint256 chunks)
    {
        int256 target = int256((uint256(realAvaxAnswer) * targetBps) / 10_000);
        bool down = targetBps < 10_000;
        while (chunks < maxChunks) {
            int256 now8 = _poolAnswer8();
            if (down ? now8 <= target : now8 >= target) break;
            if (now8 * 100 < realAvaxAnswer) break; // floor
            address tin = down ? WAVAX : USDC;
            address tout = down ? USDC : WAVAX;
            uint256 amt = down ? chunkAvax : chunkUsdc;
            deal(tin, WHALE, amt);
            vm.startPrank(WHALE);
            IERC20(tin).approve(PHARAOH_ROUTER, amt);
            (bool ok,) = PHARAOH_ROUTER.call(
                abi.encodeCall(
                    IPharaohCLRouter.exactInputSingle,
                    (IPharaohCLRouter.ExactInputSingleParams(tin, tout, TICK_SPACING, WHALE, block.timestamp + 1, amt, 0, 0))
                )
            );
            vm.stopPrank();
            if (!ok) break;
            usdTraded += down ? _wavaxUsd(amt) : amt;
            ++chunks;
        }
    }

    // ----------------------------------------------------------------- margin helpers
    function _marginPTokens(address user, uint256 usdcAmount) internal returns (uint256 shares) {
        shares = _mintP(pUsdc, user, usdcAmount);
        vm.startPrank(user);
        pUsdc.approve(address(mVault), shares);
        mVault.deposit(address(pUsdc), shares);
        vm.stopPrank();
    }

    function _openParams(bool short, uint256 shares, uint16 lev)
        internal
        view
        returns (IsolatedMarginExecutorUpgradeable.OpenParams memory p, uint256 flashAmount)
    {
        address pos = short ? address(pUsdc) : address(pWavax);
        address debt = short ? address(pWavax) : address(pUsdc);
        uint256 minPosition;
        (flashAmount, minPosition) = quoter.quoteOpen(
            address(pUsdc), pos, debt, Math.mulDiv(shares, pUsdc.exchangeRateStored(), 1e18), lev
        );
        p = IsolatedMarginExecutorUpgradeable.OpenParams(
            address(pUsdc),
            pos,
            debt,
            shares,
            lev,
            0,
            minPosition,
            short ? IsolatedMarginTypes.Side.SHORT : IsolatedMarginTypes.Side.LONG,
            ""
        );
    }

    struct OpenReport {
        uint256 id;
        uint256 flashAmount;
        uint256 gas;
        IsolatedMarginTypes.AccountMetrics m;
    }

    function _open(address user, bool short, uint256 marginUsdc, uint16 lev) internal returns (OpenReport memory r) {
        uint256 shares = _marginPTokens(user, marginUsdc);
        IsolatedMarginExecutorUpgradeable.OpenParams memory p;
        (p, r.flashAmount) = _openParams(short, shares, lev);
        vm.prank(user);
        uint256 g = gasleft();
        r.id = executor.openPosition(p);
        r.gas = g - gasleft();
        r.m = riskEngine.getMetrics(_position(r.id).account);
    }

    function _position(uint256 id) internal view returns (IsolatedMarginTypes.Position memory p) {
        (
            p.id,
            p.owner,
            p.account,
            p.marginPToken,
            p.positionPToken,
            p.debtPToken,
            p.lockedMarginPTokens,
            p.initialNotionalUsd,
            p.borrowedPrincipal,
            p.requestedLeverageX100,
            p.side,
            p.status
        ) = executor.positions(id);
    }

    function _liqParams(uint256 id) internal pure returns (IsolatedMarginLiquidatorUpgradeable.LiquidationParams memory) {
        return IsolatedMarginLiquidatorUpgradeable.LiquidationParams(id, KEEPER_RECIPIENT, 0, 0, "", "");
    }

    function _close(address user, uint256 id, uint16 bps) internal returns (bool ok, bytes memory ret) {
        vm.prank(user);
        (ok, ret) = address(executor)
            .call(
                abi.encodeWithSelector(
                    IsolatedMarginExecutorUpgradeable.closePosition.selector,
                    IsolatedMarginExecutorUpgradeable.CloseParams(id, bps, type(uint256).max, 0, 0, "", "")
                )
            );
    }

    function _logSel(string memory label, bytes4 sel) internal {
        string memory name = sel == bytes4(0x91240a1b)
            ? "RedeemTransferOutNotPossible (market cash)"
            : sel == IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector
                ? "PriceUnavailable(asset)"
                : sel == bytes4(0x08c379a0) ? "Error(string)" : "other";
        emit log_named_string(label, name);
    }

    /// @dev Assert `ret` is the market's `<name>PeridottrollerRejection(errorCode)` custom error with `code`.
    function _assertRejection(bytes memory ret, string memory sig, uint256 code, string memory why) internal pure {
        require(ret.length == 36, string.concat(why, ": revert data is not a rejection error"));
        bytes4 want = bytes4(keccak256(bytes(sig)));
        require(_selectorOf(ret) == want, string.concat(why, ": wrong error selector"));
        uint256 got;
        assembly { got := mload(add(ret, 36)) }
        require(got == code, string.concat(why, ": wrong controller error code"));
    }

    function _selectorOf(bytes memory ret) internal pure returns (bytes4 s) {
        assembly { s := mload(add(ret, 32)) }
    }

    function _reasonContains(bytes memory ret, string memory needle) internal pure returns (bool) {
        if (ret.length < 68 || _selectorOf(ret) != bytes4(0x08c379a0)) return false;
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i; i < body.length; ++i) body[i] = ret[i + 4];
        bytes memory hay = bytes(abi.decode(body, (string)));
        bytes memory nd = bytes(needle);
        if (nd.length > hay.length) return false;
        for (uint256 i; i + nd.length <= hay.length; ++i) {
            bool m = true;
            for (uint256 j; j < nd.length; ++j) if (hay[i + j] != nd[j]) { m = false; break; }
            if (m) return true;
        }
        return false;
    }

    function _selector(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) assembly { s := mload(add(ret, 32)) }
    }

    /// @dev Walk the AVAX price down (long) or up (short) in 1% steps until the account is liquidatable.
    function _thresholdBps(address account, bool short) internal returns (uint256 bps) {
        bps = 10_000;
        for (uint256 i; i < 90; ++i) {
            bps = short ? bps + 100 : bps - 100;
            _setAvaxBps(bps);
            if (riskEngine.isLiquidatable(account)) return bps;
        }
        revert("no liquidation threshold found");
    }

    // ================================================================= 0. deployment state
    function testDeploymentStateIsPausedAndWired() public view {
        assertTrue(controller.borrowGuardianPaused(address(pWavax)) && controller.borrowGuardianPaused(address(pUsdc)));
        assertTrue(mConfig.opensPaused());
        assertTrue(pWavax.flashLoansPaused() && pUsdc.flashLoansPaused());
        assertEq(address(controller.oracle()), address(oracle));
        assertEq(address(riskEngine.oracle()), address(oracle));
        assertEq(address(quoter.oracle()), address(oracle));
        assertEq(controller.isolatedMarginRiskHook(), address(riskEngine));
        assertEq(mConfig.routerAdapter(), address(clAdapter));
        // Plain delegates: no strategy delegate, one implementation, cash only.
        assertEq(pWavax.implementation(), pUsdc.implementation());
        assertEq(PErc20(address(pUsdc)).underlying(), USDC);
        assertEq(PErc20(address(pWavax)).underlying(), WAVAX);
    }

    function testPinnedPoolAndFeedFacts() public {
        IPharaohPoolState pool = IPharaohPoolState(PHARAOH_POOL);
        (uint160 sqrtP, int24 tick,,,, uint24 feeProtocol,) = pool.slot0();
        emit log_named_uint("pin block", block.number);
        emit log_named_uint("pool fee ppm", pool.fee());
        emit log_named_uint("pool feeProtocol", feeProtocol);
        emit log_named_int("pool tick", tick);
        emit log_named_uint("pool active liquidity", pool.liquidity());
        emit log_named_uint("pool sqrtPriceX96", sqrtP);
        emit log_named_int("pool-implied USD/AVAX (e8)", _poolAnswer8());
        emit log_named_int("Chainlink AVAX/USD (e8)", realAvaxAnswer);
        emit log_named_int("Chainlink USDC/USD (e8)", usdcAnswer);
        emit log_named_uint("WAVAX in pool (1e18)", IERC20(WAVAX).balanceOf(PHARAOH_POOL));
        emit log_named_uint("USDC in pool (1e6)", IERC20(USDC).balanceOf(PHARAOH_POOL));
        int256 dev = (_poolAnswer8() - realAvaxAnswer) * 10_000 / realAvaxAnswer;
        emit log_named_int("pool vs oracle deviation (bps)", dev);
        assertEq(pool.fee(), 490, "fee tier at pin (handoff 09 s2 says 490 ppm now)");
    }

    // ================================================================= 1. ordinary lending, both directions
    function testSupplyAndBorrowBothDirectionsAndRepay() public {
        _activateLendingBorrows();
        // Borrowing is paused until activation (checked in the deployment test); here it is live.
        // USDC against WAVAX (ALICE)
        _mintP(pWavax, ALICE, 100e18);
        _enter(ALICE);
        (uint256 err, uint256 liq,) = controller.getAccountLiquidity(ALICE);
        assertEq(err, 0);
        uint256 borrowUsdc = liq / 1e12 * 9 / 10; // 90% of capacity (liq is 1e18-scaled USD)
        (bool ok, uint256 code) = _borrow(pUsdc, ALICE, borrowUsdc);
        assertTrue(ok, "USDC against WAVAX");
        emit log_named_uint("ALICE borrowed USDC (1e6) against 100 WAVAX", borrowUsdc);
        // WAVAX against USDC (BOB)
        _mintP(pUsdc, BOB, 10_000e6);
        _enter(BOB);
        (, liq,) = controller.getAccountLiquidity(BOB);
        uint256 borrowAvax = Math.mulDiv(liq, 9, 10) * 1e8 / uint256(avaxAnswer) / 1e10 * 1e10 / 1; // ~90% of capacity
        borrowAvax = Math.mulDiv(liq * 9 / 10, 1e8, uint256(avaxAnswer)); // liq is USD1e18; AVAX 1e18 = usd*1e8/price8
        (ok, code) = _borrow(pWavax, BOB, borrowAvax);
        assertTrue(ok, "WAVAX against USDC");
        emit log_named_uint("BOB borrowed WAVAX (1e18) against 10k USDC", borrowAvax);
        // Over-borrow is refused (code != 0) and no tokens move.
        (ok, code) = _borrow(pUsdc, ALICE, borrowUsdc);
        assertFalse(ok, "second borrow must exceed capacity (market reverts or returns a controller error code)");
        emit log_named_uint("over-borrow error code (0 = market reverted)", code);
        // Interest accrues, then repay in full (repay always allowed).
        vm.roll(block.number + 100_000);
        vm.warp(block.timestamp + 100_000);
        _refreshFeeds();
        uint256 owed = pUsdc.borrowBalanceCurrent(ALICE);
        assertGt(owed, borrowUsdc, "interest accrued");
        deal(USDC, ALICE, owed);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(pUsdc), owed);
        assertEq(pUsdc.repayBorrow(type(uint256).max), 0);
        vm.stopPrank();
        assertEq(pUsdc.borrowBalanceStored(ALICE), 0);
    }

    function testBorrowIsRejectedWhilePausedAndAfterCap() public {
        _mintP(pWavax, ALICE, 100e18);
        _enter(ALICE);
        (bool ok,) = _borrow(pUsdc, ALICE, 100e6);
        assertFalse(ok, "borrow paused at deploy");
        _activateLendingBorrows();
        (ok,) = _borrow(pUsdc, ALICE, 100e6);
        assertTrue(ok);
        // borrow cap: a second borrower asks for more than the (lowered) cap allows
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 150e6; // total borrows incl. ALICE's 100e6
        controller._setMarketBorrowCaps(ps, caps);
        _mintP(pWavax, BOB, 100e18);
        _enter(BOB);
        (ok,) = _borrow(pUsdc, BOB, 100e6);
        assertFalse(ok, "borrow above the cap is rejected");
        (ok,) = _borrow(pUsdc, BOB, 40e6);
        assertTrue(ok, "borrow within the cap works");
    }

    function testOrdinaryLiquidationBothDirections() public {
        _activateLendingBorrows();
        // ALICE: WAVAX collateral, USDC debt  -> liquidatable when AVAX falls.
        _mintP(pWavax, ALICE, 100e18);
        _enter(ALICE);
        (, uint256 liq,) = controller.getAccountLiquidity(ALICE);
        uint256 aliceDebt = liq / 1e12 * 97 / 100;
        (bool ok,) = _borrow(pUsdc, ALICE, aliceDebt);
        assertTrue(ok);
        // BOB: USDC collateral, WAVAX debt -> liquidatable when AVAX rises.
        _mintP(pUsdc, BOB, 20_000e6);
        _enter(BOB);
        (, liq,) = controller.getAccountLiquidity(BOB);
        uint256 bobDebt = Math.mulDiv(liq * 97 / 100, 1e8, uint256(avaxAnswer));
        (ok,) = _borrow(pWavax, BOB, bobDebt);
        assertTrue(ok);

        // healthy: not liquidatable
        (bool lok, uint256 lcode,) = _liquidateOrdinary(pUsdc, pWavax, ALICE, aliceDebt / 4);
        assertFalse(lok, "healthy account must not be liquidatable (market reverts LiquidatePeridottrollerRejection)");

        // AVAX -15%: ALICE underwater (close factor 50%, incentive 8%)
        _setAvaxBps(8_500);
        (uint256 e1,, uint256 shortfall) = controller.getAccountLiquidity(ALICE);
        assertEq(e1, 0);
        assertGt(shortfall, 0, "ALICE shortfall");
        uint256 repay = aliceDebt / 2;
        uint256 debtBefore = pUsdc.borrowBalanceCurrent(ALICE);
        // close factor 50%: repaying the whole debt in one call while underwater is refused and changes nothing
        (lok, lcode,) = _liquidateOrdinary(pUsdc, pWavax, ALICE, debtBefore);
        assertFalse(lok, "repay above close factor refused");
        _assertRejection(lastRevert, "LiquidatePeridottrollerRejection(uint256)", 17, "close factor"); // TOO_MUCH_REPAY
        assertEq(pUsdc.borrowBalanceStored(ALICE), debtBefore, "debt unchanged by the refused liquidation");
        uint256 seizedP;
        (lok, lcode, seizedP) = _liquidateOrdinary(pUsdc, pWavax, ALICE, repay);
        assertTrue(lok, "liquidate USDC debt, seize pWAVAX");
        assertLt(pUsdc.borrowBalanceStored(ALICE), debtBefore);
        // incentive: liquidator receives repay * 1.08 of collateral minus the 2.8% protocol seize share (within 0.5%)
        uint256 seizedWavax = Math.mulDiv(seizedP, pWavax.exchangeRateStored(), 1e18);
        uint256 seizedUsd6 = _wavaxUsd(seizedWavax);
        assertApproxEqRel(seizedUsd6, repay * 108 / 100 * (1e18 - 2.8e16) / 1e18, 0.005e18, "seize value = repay * 1.08 * (1 - 2.8%)");
        // AVAX +25% from pin: BOB underwater
        _setAvaxBps(12_500);
        (, , shortfall) = controller.getAccountLiquidity(BOB);
        assertGt(shortfall, 0, "BOB shortfall");
        uint256 bobRepay = pWavax.borrowBalanceCurrent(BOB) / 2;
        (lok, lcode, ) = _liquidateOrdinary(pWavax, pUsdc, BOB, bobRepay);
        assertTrue(lok, "liquidate WAVAX debt, seize pUSDC");
    }

    // ================================================================= 2. margin lifecycle through PharaohCLRouterAdapter
    function testMarginLongOpenPartialCloseFullClose() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        emit log_named_uint("LONG flash USDC (1e6)", r.flashAmount);
        emit log_named_uint("LONG open gas", r.gas);
        emit log_named_uint("LONG gross USD (1e18)", r.m.grossAssetValueUsd);
        emit log_named_uint("LONG debt USD (1e18)", r.m.debtValueUsd);
        emit log_named_uint("LONG leverageX100", r.m.leverageX100);
        emit log_named_uint("LONG healthBps", r.m.healthFactorBps);
        assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertLe(r.m.leverageX100, MAX_LEV_X100);
        assertGt(r.m.healthFactorBps, 10_000);
        // Margin account is registered in the controller: ordinary CF liquidation/seizure refused.
        assertTrue(controller.isolatedMarginAccounts(p.account));

        uint256 freeBefore = mVault.freeBalance(ALICE, address(pUsdc));
        (bool ok, bytes memory ret) = _close(ALICE, r.id, 5_000);
        assertTrue(ok, "50% close");
        ret;
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        (ok, ret) = _close(ALICE, r.id, 10_000);
        assertTrue(ok, "full close");
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(pUsdc.borrowBalanceStored(p.account), 0);
        uint256 freeAfter = mVault.freeBalance(ALICE, address(pUsdc));
        // round trip returns margin minus swap costs; report cost in bps of margin
        uint256 marginShares = p.lockedMarginPTokens;
        uint256 returned = freeAfter - freeBefore;
        emit log_named_uint("LONG margin shares locked", marginShares);
        emit log_named_uint("LONG margin shares returned", returned);
        emit log_named_uint("LONG round-trip cost bps of margin", (marginShares - Math.min(returned, marginShares)) * 10_000 / marginShares);
        assertGe(returned, marginShares * 95 / 100, "round trip costs more than 5% of margin");
    }

    function testMarginShortOpenPartialCloseFullClose() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        emit log_named_uint("SHORT flash WAVAX (1e18)", r.flashAmount);
        emit log_named_uint("SHORT open gas", r.gas);
        emit log_named_uint("SHORT gross USD (1e18)", r.m.grossAssetValueUsd);
        emit log_named_uint("SHORT debt USD (1e18)", r.m.debtValueUsd);
        emit log_named_uint("SHORT leverageX100", r.m.leverageX100);
        emit log_named_uint("SHORT healthBps", r.m.healthFactorBps);
        assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertEq(p.debtPToken, address(pWavax));
        assertLe(r.m.leverageX100, MAX_LEV_X100);
        assertGt(r.m.healthFactorBps, 10_000);

        uint256 freeBefore = mVault.freeBalance(BOB, address(pUsdc));
        (bool ok,) = _close(BOB, r.id, 5_000);
        assertTrue(ok, "50% close");
        (ok,) = _close(BOB, r.id, 10_000);
        assertTrue(ok, "full close");
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(pWavax.borrowBalanceStored(p.account), 0);
        uint256 returned = mVault.freeBalance(BOB, address(pUsdc)) - freeBefore;
        emit log_named_uint("SHORT margin shares locked", p.lockedMarginPTokens);
        emit log_named_uint("SHORT margin shares returned", returned);
        assertGe(returned, p.lockedMarginPTokens * 95 / 100, "round trip costs more than 5% of margin");
    }

    function testMarginAccountCannotBeLiquidatedThroughOrdinaryPath() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _thresholdBps(account, false);
        assertTrue(riskEngine.isLiquidatable(account));
        // precondition: by ordinary collateral-factor accounting the account IS in shortfall, so only the
        // margin flag can explain the denial
        (uint256 lerr,, uint256 shortfall) = controller.getAccountLiquidity(account);
        assertEq(lerr, 0);
        assertGt(shortfall, 0, "ordinary shortfall exists");
        (bool ok,,) = _liquidateOrdinary(pUsdc, pWavax, account, 10e6);
        assertFalse(ok, "ordinary liquidateBorrow on a margin account");
        _assertRejection(lastRevert, "LiquidatePeridottrollerRejection(uint256)", 3, "margin account"); // INSUFFICIENT_SHORTFALL
        // the dedicated liquidator still works
        uint256 debtBefore = pUsdc.borrowBalanceCurrent(account);
        liquidator.liquidate(_liqParams(r.id));
        assertLt(pUsdc.borrowBalanceStored(account), debtBefore, "dedicated liquidation repaid debt");
    }

    function testMarginLongPartialAndFullLiquidation() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        uint256 threshold = _thresholdBps(account, false);
        emit log_named_uint("LONG liquidatable once AVAX <= % of pin (bps)", threshold);
        uint256 healthBefore = riskEngine.getMetrics(account).healthFactorBps;
        uint256 rewardBefore = IERC20(USDC).balanceOf(KEEPER_RECIPIENT);
        uint256 g = gasleft();
        liquidator.liquidate(_liqParams(r.id));
        emit log_named_uint("LONG liquidation gas", g - gasleft());
        emit log_named_uint("LONG keeper reward USDC (1e6)", IERC20(USDC).balanceOf(KEEPER_RECIPIENT) - rewardBefore);
        IsolatedMarginTypes.Status st = _position(r.id).status;
        emit log_named_uint("status after first liquidation (2=ACTIVE,6=LIQUIDATED)", uint8(st));
        assertEq(uint8(st), uint8(IsolatedMarginTypes.Status.ACTIVE), "first liquidation just past threshold is partial");
        assertGt(riskEngine.getMetrics(account).healthFactorBps, healthBefore, "partial liquidation improves health");
        // push deeper (oracle-only) -> full liquidation
        _setAvaxBps(threshold > 3_000 ? threshold - 3_000 : 500);
        assertTrue(riskEngine.isLiquidatable(account));
        liquidator.liquidate(_liqParams(r.id));
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.LIQUIDATED), "fully liquidated");
        assertEq(pUsdc.borrowBalanceStored(account), 0, "no debt left");
    }

    /// @dev FINDING test. The pool's buy side is also a wall: ~USD 4.9M of USDC buys the pool's WAVAX up to about
    ///      +50%, then the price jumps (to ~+115%) because no liquidity remains (see testPoolDepthCurve). The 2x/25%
    ///      short becomes liquidatable at about +51%, just beyond that wall. With the pool pumped past it and the
    ///      oracle following the pool, the liquidation swap reverts at the router. Asserts CURRENT behaviour.
    function testFinding_ShortLiquidationFailsWhenPoolBuySideIsExhausted() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        (uint256 usd, uint256 n) = _movePoolTo(15_250, 0, 25_000e6, 400);
        emit log_named_uint("USDC spent to pump the pool (1e6)", usd);
        emit log_named_uint("pump chunks (USD 25k each)", n);
        emit log_named_int("pool-implied USD/AVAX e8 after pump", _poolAnswer8());
        emit log_named_uint("pool WAVAX left (1e18)", IERC20(WAVAX).balanceOf(PHARAOH_POOL));
        _setPrices(_poolAnswer8(), usdcAnswer);
        assertTrue(riskEngine.isLiquidatable(account), "squeeze makes the short liquidatable");
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        emit log_named_uint("short liquidation succeeded against exhausted pool (0/1)", ok ? 1 : 0);
        _logSel("revert", _selector(ret));
        assertFalse(ok, "FINDING: no buy-side liquidity left for the liquidation swap");
        assertTrue(_reasonContains(ret, "Too little received"), "cause is the router minimum-output check");
    }

    /// @dev With maintenance 40% (initial 50%) the long becomes liquidatable at about -17% and the short at about
    ///      +20%. The short threshold lies inside the pool's buy wall and its liquidation EXECUTES against the moved
    ///      pool (next test). The long threshold lies where the sell side holds only a few thousand USD, so even this
    ///      earlier trigger cannot sell a USD 10k position (FINDING, asserts current behaviour).
    function testFinding_LongLiquidationFailsAtMinus17PercentEvenWithMaint4000() public {
        maintenanceBps = 4000;
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        (uint256 usd,) = _movePoolTo(8_250, 25e18, 0, 2_000);
        _setPrices(_poolAnswer8(), usdcAnswer);
        emit log_named_uint("USD sold into the pool, valued at pin price (1e6)", usd);
        emit log_named_uint("pool price (bps of pin)", uint256(_poolAnswer8() * 10_000 / realAvaxAnswer));
        emit log_named_uint("pool USDC left (1e6)", IERC20(USDC).balanceOf(PHARAOH_POOL));
        assertTrue(riskEngine.isLiquidatable(account), "liquidatable at about -17%");
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(ok, "FINDING: the sell side cannot absorb a USD 10k long liquidation");
        assertTrue(_reasonContains(ret, "Too little received"), "cause is the router minimum-output check");
    }

    function testMovedPool_ShortLiquidation_Maint4000() public {
        maintenanceBps = 4000;
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        (uint256 usd,) = _movePoolTo(12_200, 0, 25_000e6, 400);
        _setPrices(_poolAnswer8(), usdcAnswer);
        emit log_named_uint("USDC spent pumping the pool (1e6)", usd);
        emit log_named_uint("pool price (bps of pin)", uint256(_poolAnswer8() * 10_000 / realAvaxAnswer));
        assertTrue(riskEngine.isLiquidatable(account), "liquidatable at about +20%");
        uint256 debtBefore = pWavax.borrowBalanceCurrent(account);
        uint256 g = gasleft();
        liquidator.liquidate(_liqParams(r.id));
        emit log_named_uint("liquidation gas against moved pool", g - gasleft());
        emit log_named_uint("status (2=ACTIVE,6=LIQUIDATED)", uint8(_position(r.id).status));
        assertLt(pWavax.borrowBalanceStored(account), debtBefore, "debt repaid from the moved pool");
    }

    /// @dev Oracle-only +70% shock with the real pool unchanged: the debt->margin leg would sell surplus WAVAX at the
    ///      pool's old price, below the oracle floor, so the liquidation reverts. Documented as an observation: an
    ///      oracle that LEADS the pool blocks short liquidations until the pool catches up.
    function testObservation_ShortLiquidationRevertsWhenOracleLeadsPool() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _setAvaxBps(17_000);
        assertTrue(riskEngine.isLiquidatable(account));
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        emit log_named_uint("short liquidation succeeded with oracle +70% vs unchanged pool (0/1)", ok ? 1 : 0);
        assertFalse(ok);
        assertTrue(_reasonContains(ret, "Too little received"), "oracle-leads-pool: router minimum-output check");
    }

    /// @dev Gap crash (oracle only, pool unchanged): liquidation is profitable-looking against the stale pool.
    ///      A REAL crash moves the pool too -- see testFinding_LongLiquidationFailsWhenPoolSellSideIsExhausted and the _Maint4000 moved-pool tests.
    function testGapShocksAndInsuranceDraw() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        uint256 insBefore = pUsdc.balanceOf(address(insuranceFund));
        _setAvaxBps(4_000); // -60% gap: equity gone
        assertTrue(riskEngine.isLiquidatable(account));
        IsolatedMarginTypes.AccountMetrics memory m = riskEngine.getMetrics(account);
        emit log_named_int("LONG equity USD (1e18) at -60% gap", m.equityUsd);
        liquidator.liquidate(_liqParams(r.id));
        emit log_named_uint("status (6=LIQUIDATED)", uint8(_position(r.id).status));
        emit log_named_uint("insurance pUSDC drawn", insBefore - pUsdc.balanceOf(address(insuranceFund)));
        assertEq(pUsdc.borrowBalanceStored(account), 0);
    }

    /// @dev FINDING test. The pool's sell side is a wall: ~USD 98.5k of USDC in total, price -10% after ~USD 90k and
    ///      -20% after ~USD 97k, then no liquidity (see testPoolDepthCurve). The 2x/25% long only becomes liquidatable
    ///      at about -34%, which the pool cannot reach without being emptied. Here the pool is sold to its floor, the
    ///      oracle follows, and the liquidation of a USD 10k long cannot sell its collateral. Asserts the CURRENT
    ///      behaviour so a change in depth, caps or contracts shows up as a failing test to re-evaluate.
    function testFinding_LongLiquidationFailsWhenPoolSellSideIsExhausted() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        (uint256 usd, uint256 n) = _movePoolTo(6_000, 100e18, 0, 400);
        int256 pool8 = _poolAnswer8();
        emit log_named_uint("USD of WAVAX sold into the pool (1e6)", usd);
        emit log_named_uint("sell chunks (100 WAVAX each)", n);
        emit log_named_int("pool-implied USD/AVAX e8 after crash", pool8);
        emit log_named_uint("pool USDC left (1e6)", IERC20(USDC).balanceOf(PHARAOH_POOL));
        _setPrices(pool8, usdcAnswer);
        assertTrue(riskEngine.isLiquidatable(account), "crash makes the long liquidatable");
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        emit log_named_uint("long liquidation succeeded against exhausted pool (0/1)", ok ? 1 : 0);
        _logSel("revert", _selector(ret));
        assertFalse(ok, "FINDING: no sell-side liquidity left for the liquidation swap");
        assertTrue(_reasonContains(ret, "Too little received"), "cause is the router minimum-output check");
    }

    /// @dev Depth curve of the real pool: cumulative USD traded to move the price by X, both directions.
    function testPoolDepthCurve() public {
        uint256[7] memory down = [uint256(9_900), 9_800, 9_500, 9_000, 8_000, 6_500, 5_000];
        uint256[7] memory up = [uint256(10_100), 10_200, 10_500, 11_000, 12_000, 15_000, 20_000];
        uint256 snap = vm.snapshotState();
        uint256 cumulative;
        for (uint256 i; i < down.length; ++i) {
            (uint256 usd,) = _movePoolTo(down[i], 25e18, 0, 2_000);
            cumulative += usd;
            emit log_named_uint("SELL WAVAX: price at (bps of pin)", uint256(_poolAnswer8() * 10_000 / realAvaxAnswer));
            emit log_named_uint("   cumulative USD sold (1e6)", cumulative);
        }
        emit log_named_uint("pool USDC left after sells (1e6)", IERC20(USDC).balanceOf(PHARAOH_POOL));
        vm.revertToState(snap);
        cumulative = 0;
        for (uint256 i; i < up.length; ++i) {
            (uint256 usd,) = _movePoolTo(up[i], 0, 2_500e6, 4_000);
            cumulative += usd;
            emit log_named_uint("BUY WAVAX: price at (bps of pin)", uint256(_poolAnswer8() * 10_000 / realAvaxAnswer));
            emit log_named_uint("   cumulative USD bought (1e6)", cumulative);
        }
    }

    // ================================================================= 3. stale feed + emergency price
    function testStaleFeedWithEmergencyPriceStillBlocksRiskIncreaseAndLiquidation() public {
        _activate();
        // --- state built while feeds are fresh ---
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100); // margin long, healthy
        IsolatedMarginTypes.Position memory p = _position(r.id);
        // positive control for the margin open: the same kind of open works while the feed is fresh
        _open(BOB, false, 1_000e6, MAX_LEV_X100);
        // DAVE borrows close to the limit so that the emergency price below puts DAVE deep underwater
        _mintP(pWavax, DAVE, 100e18);
        _enter(DAVE);
        (bool ok,) = _borrow(pUsdc, DAVE, 480e6);
        assertTrue(ok, "pre-stale borrow works");
        uint256 daveShares = _marginPTokens(CAROL, 1_000e6); // margin for the stale open attempt below

        // --- AVAX stale (mocked feed keeps its old updatedAt), USDC still fresh (90_000 s) ---
        vm.warp(block.timestamp + AVAX_MAX_AGE + 1);
        assertEq(oracle.getPrice(WAVAX), 0, "guarded: stale AVAX -> 0");
        assertGt(oracle.getPrice(USDC), 0, "USDC feed still fresh");

        // --- owner sets an emergency price on the INNER oracle: USD 2 makes DAVE and ALICE deeply underwater ---
        inner.setEmergencyPrice(WAVAX, uint192(2e18), uint64(block.timestamp + 30 minutes));
        assertEq(inner.getPrice(WAVAX), 2e18, "inner oracle would serve the emergency price");
        assertEq(oracle.getPrice(WAVAX), 0, "guarded oracle ignores the emergency price");
        assertEq(oracle.getUnderlyingPrice(PToken(address(pWavax))), 0);

        // CONTROL: if the controller used the unguarded oracle, DAVE would be liquidatable right now and the
        // liquidation would succeed. This proves the blocks below are caused by the guard, not by account health.
        uint256 snap = vm.snapshotState();
        require(controller._setPriceOracle(PriceOracle(address(inner))) == 0, "control oracle");
        (, , uint256 controlShortfall) = controller.getAccountLiquidity(DAVE);
        assertGt(controlShortfall, 0, "control: DAVE underwater at the emergency price");
        (bool cOk,,) = _liquidateOrdinary(pUsdc, pWavax, DAVE, 100e6);
        assertTrue(cOk, "control: unguarded oracle would allow the liquidation");
        vm.revertToState(snap);

        // 1. ordinary borrows blocked, with the controller's PRICE_ERROR
        (ok,) = _borrow(pUsdc, DAVE, 1e6);
        assertFalse(ok, "stale + emergency: borrow USDC against WAVAX blocked");
        _assertRejection(lastRevert, "BorrowPeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "borrow USDC");
        (ok,) = _borrow(pWavax, DAVE, 1e18);
        assertFalse(ok, "stale + emergency: borrow WAVAX blocked");
        _assertRejection(lastRevert, "BorrowPeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "borrow WAVAX");

        // 2. margin open blocked by the missing price, not by another parameter (control above)
        (IsolatedMarginExecutorUpgradeable.OpenParams memory op,) = _openParamsFixedMin(daveShares);
        vm.prank(CAROL);
        (bool openOk, bytes memory openRet) =
            address(executor).call(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.openPosition.selector, op));
        assertFalse(openOk, "margin open blocked");
        _logSel("margin open revert", _selector(openRet));
        assertTrue(
            _selector(openRet) == IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector
                || _reasonContains(openRet, "price unavailable"),
            "margin open reverts for the missing price"
        );

        // 3. margin liquidation blocked with PriceUnavailable (ALICE's long is deeply underwater at USD 2)
        (bool lok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(lok, "margin liquidation must not run on an emergency price");
        assertEq(_selector(ret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "PriceUnavailable");

        // 4. ordinary liquidation blocked with PRICE_ERROR (DAVE is liquidatable under the control)
        (bool oOk,,) = _liquidateOrdinary(pUsdc, pWavax, DAVE, 100e6);
        assertFalse(oOk, "ordinary liquidation blocked");
        _assertRejection(lastRevert, "LiquidatePeridottrollerRejection(uint256)", PRICE_ERROR_CODE, "ordinary liquidation");

        // 5. margin close needs prices: blocked
        (bool cok, bytes memory cret) = _close(ALICE, r.id, 10_000);
        assertFalse(cok, "close needs a trustworthy price");
        assertEq(_selector(cret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "close: PriceUnavailable");

        // --- paths that MUST keep working ---
        deal(USDC, DAVE, 600e6);
        vm.startPrank(DAVE);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        assertEq(pUsdc.repayBorrow(type(uint256).max), 0, "ordinary repay works while stale");
        vm.stopPrank();
        assertEq(pUsdc.borrowBalanceStored(DAVE), 0);
        uint256 owed = pUsdc.borrowBalanceCurrent(p.account);
        deal(USDC, ALICE, owed + 10e6);
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(executor), type(uint256).max);
        executor.repayWithUnderlying(r.id, type(uint256).max);
        (uint256 retMargin, uint256 retPos,) = executor.exitDebtFreeToPTokens(r.id, 0);
        vm.stopPrank();
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertGt(retMargin + retPos, 0, "pTokens returned without a price");
        assertEq(pUsdc.borrowBalanceStored(p.account), 0);
    }

    /// @dev Open params that do not need a price to build (min output fixed), so a stale price is the only
    ///      thing that can make the open fail.
    function _openParamsFixedMin(uint256 shares)
        internal
        view
        returns (IsolatedMarginExecutorUpgradeable.OpenParams memory, uint256)
    {
        return (_paramsWithoutQuote(shares), 0);
    }

    /// @dev Guarded oracle returns 0 (never reverts, never the emergency price) for every bad round shape.
    function testGuardedOracleFailsClosedOnBadRounds() public {
        assertGt(oracle.getPrice(WAVAX), 0);
        bytes4 sel = AggregatorV3Interface.latestRoundData.selector;
        uint256 t = block.timestamp;
        // zero answer, negative answer, future updatedAt, answeredInRound < roundId, roundId 0, updatedAt 0
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(0), t, t, uint80(5)));
        assertEq(oracle.getPrice(WAVAX), 0, "zero answer");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(-1), t, t, uint80(5)));
        assertEq(oracle.getPrice(WAVAX), 0, "negative answer");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(8e8), t, t + 1, uint80(5)));
        assertEq(oracle.getPrice(WAVAX), 0, "future updatedAt");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(8e8), t, t, uint80(4)));
        assertEq(oracle.getPrice(WAVAX), 0, "answeredInRound < roundId");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(0), int256(8e8), t, t, uint80(0)));
        assertEq(oracle.getPrice(WAVAX), 0, "roundId 0");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), abi.encode(uint80(5), int256(8e8), t, uint256(0), uint80(5)));
        assertEq(oracle.getPrice(WAVAX), 0, "updatedAt 0");
        vm.mockCall(AVAX_FEED, abi.encodeWithSelector(sel), hex"1234"); // short returndata
        assertEq(oracle.getPrice(WAVAX), 0, "malformed returndata");
        vm.mockCallRevert(AVAX_FEED, abi.encodeWithSelector(sel), "boom");
        assertEq(oracle.getPrice(WAVAX), 0, "reverting feed");
        // the emergency price never leaks through, even when the inner oracle has one
        inner.setEmergencyPrice(WAVAX, uint192(9e18), uint64(block.timestamp + 10 minutes));
        assertEq(inner.getPrice(WAVAX), 9e18);
        assertEq(oracle.getPrice(WAVAX), 0, "emergency price ignored");
        // disabled feed and unregistered asset
        inner.disableFeed(WAVAX);
        assertEq(oracle.getPrice(WAVAX), 0, "disabled feed (inner still serves the emergency price)");
        assertEq(inner.getPrice(WAVAX), 9e18);
        assertEq(oracle.getPrice(address(0x1234)), 0, "unknown asset");
        assertEq(oracle.getUnderlyingPrice(PToken(address(0x1234))), 0, "unknown market");
        // a good round is returned with the same scaling as the inner oracle
        vm.clearMockedCalls();
        inner.configureFeed(WAVAX, AVAX_FEED, 1_000_000_000);
        inner.clearEmergencyPrice(WAVAX);
        assertEq(oracle.getPrice(WAVAX), inner.getPrice(WAVAX), "same scaling as the inner oracle");
        assertEq(
            oracle.getUnderlyingPrice(PToken(address(pWavax))), inner.getUnderlyingPrice(PToken(address(pWavax)))
        );
    }

    function testStaleFeedOrdinarySupplierRedeemBehaviour() public {
        _activate();
        // A: supplier with no debt who did NOT enter markets; B: entered, has no debt. Report both under stale AVAX.
        uint256 aShares = _mintP(pWavax, ALICE, 10e18);
        uint256 bShares = _mintP(pUsdc, BOB, 1_000e6);
        _enter(BOB);
        vm.warp(block.timestamp + AVAX_MAX_AGE + 1);
        inner.setEmergencyPrice(WAVAX, uint192(30e18), uint64(block.timestamp + 30 minutes));
        vm.prank(ALICE);
        uint256 aCode = pWavax.redeem(aShares);
        vm.prank(BOB);
        (bool bSuccess, bytes memory bRet) = address(pUsdc).call(abi.encodeWithSelector(PErc20.redeem.selector, bShares));
        uint256 bCode = bSuccess && bRet.length == 32 ? abi.decode(bRet, (uint256)) : type(uint256).max;
        emit log_named_uint("non-member supplier redeem code under stale AVAX", aCode);
        emit log_named_string("entered-market supplier (no debt) redeem under stale AVAX", bSuccess ? (bCode == 0 ? "succeeded" : "returned error code") : "REVERTED");
        assertEq(aCode, 0, "supplier outside the collateral set can always exit");
    }

    function _paramsWithoutQuote(uint256 shares) internal view returns (IsolatedMarginExecutorUpgradeable.OpenParams memory) {
        return IsolatedMarginExecutorUpgradeable.OpenParams(
            address(pUsdc), address(pWavax), address(pUsdc), shares, MAX_LEV_X100, 0, 1, IsolatedMarginTypes.Side.LONG, ""
        );
    }

    // ================================================================= 4. recovery paths
    /// @dev Plain delegates have no strategy and therefore no "local borrowing reserve" (handoff 09 s3b). The
    ///      reserve-consumption property reduces to: closes and liquidations redeem from market cash and keep
    ///      working while cash is nearly exhausted by ordinary borrowers, as long as the unwind itself returns cash.
    function testLongCloseWorksWhenDebtMarketCashIsExhausted() public {
        _activate();
        OpenReport memory r = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        _drainCash(pUsdc, pWavax);
        emit log_named_uint("pUSDC cash after drain (1e6)", pUsdc.getCash());
        (bool ok, bytes memory ret) = _close(ALICE, r.id, 10_000);
        emit log_named_uint("LONG close with exhausted pUSDC cash succeeded (0/1)", ok ? 1 : 0);
        _logSel("revert selector", _selector(ret));
        assertTrue(ok, "long close: repayment adds cash first, redeems pWAVAX");
    }

    function testShortCloseAgainstExhaustedCashAndVoluntaryEmergencyExit() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        IsolatedMarginTypes.Position memory p = _position(r.id);
        _drainCash(pUsdc, pWavax);
        assertLe(pUsdc.getCash(), 1, "pUSDC cash exhausted");
        (bool ok, bytes memory ret) = _close(BOB, r.id, 10_000);
        assertFalse(ok, "short close needs pUSDC cash to redeem the position");
        assertEq(_selector(ret), bytes4(0x91240a1b), "cause: RedeemTransferOutNotPossible (market cash)");
        // Voluntary emergency close (handoff 09 s3b table): owner supplies the debt asset, repays all, takes pTokens.
        uint256 owed = pWavax.borrowBalanceCurrent(p.account);
        deal(WAVAX, BOB, owed + 1e18);
        vm.startPrank(BOB);
        IERC20(WAVAX).approve(address(executor), type(uint256).max);
        executor.repayWithUnderlying(r.id, type(uint256).max);
        (uint256 a, uint256 b,) = executor.exitDebtFreeToPTokens(r.id, 0);
        vm.stopPrank();
        assertEq(uint8(_position(r.id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertGt(a + b, 0, "pTokens released although the market has no cash");
        emit log_named_uint("pTokens released via debt-free exit (margin)", a);
    }

    function testShortLiquidationWithExhaustedCash() public {
        _activate();
        OpenReport memory r = _open(BOB, true, 5_000e6, MAX_LEV_X100);
        address account = _position(r.id).account;
        _drainCash(pUsdc, pWavax);
        // oracle-only shock; the pool is untouched, so any revert is attributable to market cash
        _thresholdBps(account, true);
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(r.id)));
        assertFalse(ok, "FINDING: short liquidation cannot redeem collateral from an empty pUSDC market");
        _logSel("revert", _selector(ret));
        // The selector is the finding; if a different cause appears (oracle floor etc.) re-evaluate.
        emit log_named_uint("selector==RedeemTransferOutNotPossible (0/1)", _selector(ret) == bytes4(0x91240a1b) ? 1 : 0);
    }

    /// @dev WHALE supplies a large collateral and borrows (almost) all cash of `drain` using `collateral` market.
    function _drainCash(PErc20Delegator drain, PErc20Delegator collateral) internal {
        uint256 cash = drain.getCash();
        uint256 collateralNeeded = collateral == pWavax
            ? Math.mulDiv(cash * 1e12, 1e8, uint256(avaxAnswer)) * 3 // generous: CF .6, USDC drained
            : cash * 3;
        _mintP(collateral, WHALE, collateralNeeded);
        _enter(WHALE);
        uint256 target = drain.getCash() - 1;
        uint256 cap = controller.borrowCaps(address(drain));
        uint256 borrowed = drain.totalBorrows();
        if (cap != 0 && borrowed + target >= cap) target = cap - borrowed - 1;
        (bool ok,) = _borrow(drain, WHALE, target);
        require(ok, "drain borrow failed (raise whale collateral or caps)");
    }

    /// @dev MANDATORY, UNMET: the funded in-kind forced fallback (handoff 00 s10, 09 s3b table) does not exist yet.
    ///      This test FAILS on purpose so the section 5 launch gate cannot read green while the requirement is
    ///      open. Replace the body with the real fallback scenarios when the route is implemented.
    function testRequirement_fundedInKindForcedFallback_UNMET() public pure {
        revert("UNMET REQUIREMENT: funded in-kind forced liquidation fallback is not implemented");
    }

    // ================================================================= 5. funding and capacity measurements
    function testFundingAtCapsFlashVaultAndOpenCosts() public {
        _activate();
        // Open as large as the pair caps allow: position cap 50k USD, debt cap 25k USD -> margin ~25k USD at 2x.
        uint256 marginUsd = 24_000e6;
        OpenReport memory l = _open(ALICE, false, marginUsd, MAX_LEV_X100);
        OpenReport memory s = _open(BOB, true, marginUsd, MAX_LEV_X100);
        emit log_named_uint("margin USDC per position (1e6)", marginUsd);
        emit log_named_uint("LONG flash need (USDC 1e6)", l.flashAmount);
        emit log_named_uint("SHORT flash need (WAVAX 1e18)", s.flashAmount);
        emit log_named_uint("LONG gross USD 1e18", l.m.grossAssetValueUsd);
        emit log_named_uint("SHORT gross USD 1e18", s.m.grossAssetValueUsd);
        emit log_named_uint("LONG health bps", l.m.healthFactorBps);
        emit log_named_uint("SHORT health bps", s.m.healthFactorBps);
        emit log_named_uint("LONG leverageX100", l.m.leverageX100);
        emit log_named_uint("SHORT leverageX100", s.m.leverageX100);
        emit log_named_uint("pUSDC cash after both opens (1e6)", pUsdc.getCash());
        emit log_named_uint("pWAVAX cash after both opens (1e18)", pWavax.getCash());
        // Peak flash need must fit the funded vault, and health must hold at the caps.
        assertLe(l.flashAmount, 200_000e6, "USDC flash need within vault funding");
        assertLe(s.flashAmount, 5_000e18, "WAVAX flash need within vault funding");
        assertGt(l.m.healthFactorBps, 10_000);
        assertGt(s.m.healthFactorBps, 10_000);
        // The debt cap binds: a 26k-margin open at 2x exceeds the 25k debt cap and is refused.
        uint256 shares = _marginPTokens(CAROL, 26_000e6);
        (IsolatedMarginExecutorUpgradeable.OpenParams memory big,) = _openParams(false, shares, MAX_LEV_X100);
        vm.prank(CAROL);
        (bool capOk,) = address(executor).call(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.openPosition.selector, big));
        assertFalse(capOk, "open above the pair cap is refused");
    }

    function testFlashFeeSensitivity() public {
        _activate();
        lender.setFeeBps(9);
        OpenReport memory l = _open(ALICE, false, 5_000e6, MAX_LEV_X100);
        emit log_named_uint("LONG leverageX100 with 9 bps flash fee", l.m.leverageX100);
        emit log_named_uint("LONG health bps with 9 bps flash fee", l.m.healthFactorBps);
        assertGt(l.m.healthFactorBps, 10_000);
    }

    function _trySwap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (bool ok, uint256 out)
    {
        deal(tokenIn, address(this), amountIn);
        IERC20(tokenIn).approve(address(clAdapter), amountIn);
        try clAdapter.swap(address(this), tokenIn, tokenOut, amountIn, minOut, "") returns (uint256 o) {
            return (true, o);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Capacity ladder (both directions, one-way and round trip) through the production adapter into the
    ///      REAL pool at the pin. A size that reverts is a measured limit, not a test failure.
    function testCapacityLadderAdapterBothDirections() public {
        uint256[7] memory sizes =
            [uint256(1_000e6), 5_000e6, 25_000e6, 50_000e6, 100_000e6, 250_000e6, 500_000e6];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 usd = sizes[i];
            emit log_named_uint("== ladder notional USD (1e6)", usd);
            // buy WAVAX with USDC
            uint256 oracleAvax = Math.mulDiv(usd * 1e12, 1e8, uint256(avaxAnswer));
            (bool okBuy, uint256 avaxOut) = _trySwap(USDC, WAVAX, usd, 1);
            if (okBuy) {
                uint256 buyLoss = oracleAvax > avaxOut ? (oracleAvax - avaxOut) * 10_000 / oracleAvax : 0;
                emit log_named_uint("   buy  WAVAX loss vs oracle (bps)", buyLoss);
                // sell it straight back from the post-trade pool state
                (bool okBack, uint256 usdBack) = _trySwap(WAVAX, USDC, avaxOut, 1);
                if (okBack) {
                    emit log_named_uint("   round-trip loss (bps)", usd > usdBack ? (usd - usdBack) * 10_000 / usd : 0);
                } else {
                    emit log_string("   round-trip sell leg REVERTED");
                }
            } else {
                emit log_string("   buy  WAVAX REVERTED (beyond pool depth/price limit)");
            }
            vm.revertToState(snap);
            snap = vm.snapshotState();
            // sell WAVAX for USDC (fresh pool state)
            uint256 avaxIn = Math.mulDiv(usd * 1e12, 1e8, uint256(avaxAnswer));
            uint256 oracleUsdc = Math.mulDiv(avaxIn, uint256(avaxAnswer), 1e8 * 1e12);
            (bool okSell, uint256 usdcOut) = _trySwap(WAVAX, USDC, avaxIn, 1);
            if (okSell) {
                emit log_named_uint("   sell WAVAX loss vs oracle (bps)", oracleUsdc > usdcOut ? (oracleUsdc - usdcOut) * 10_000 / oracleUsdc : 0);
            } else {
                emit log_string("   sell WAVAX REVERTED (beyond pool depth/price limit)");
            }
            vm.revertToState(snap);
        }
    }
}
