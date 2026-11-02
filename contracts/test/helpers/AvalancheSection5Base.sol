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
import {PeridotTransparentProxy} from "../../contracts/proxy/PeridotTransparentProxy.sol";

import {AvalanchePriceOracle} from "../../contracts/margin/AvalanchePriceOracle.sol";
import {GuardedAvalanchePriceOracle, IAvalanchePriceOracleSource} from "../../contracts/margin/GuardedAvalanchePriceOracle.sol";
import {PharaohCLRouterAdapter, IPharaohCLRouter} from "../../contracts/margin/PharaohCLRouterAdapter.sol";
import {SimpleFlashLoanVault} from "../../contracts/margin/SimpleFlashLoanVault.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginAccountFactory} from "../../contracts/margin/IsolatedMarginAccountFactory.sol";
import {IsolatedMarginConfigUpgradeable} from "../../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginQuoter} from "../../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginSwapModule} from "../../contracts/margin/IsolatedMarginSwapModule.sol";
import {IsolatedMarginVaultUpgradeable} from "../../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginFeeDistributorUpgradeable} from "../../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {MarginInsuranceFundUpgradeable} from "../../contracts/margin/MarginInsuranceFundUpgradeable.sol";

interface IPharaohPoolState {
    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint24 feeProtocol, bool unlocked);
    function liquidity() external view returns (uint128);
    function fee() external view returns (uint24);
}

/**
 * @notice SHARED HARNESS for the handoff-09 Avalanche fork tests (deployment, helpers, pool mover).
 *         Concrete suites inherit this and add tests. See AvalanchePharaohSection5Fork.t.sol for the original header.
 *
 * (original header) Handoff 09 section 5 checkpoint: Avalanche C-Chain FORK test, local VM writes only.
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
abstract contract AvalancheSection5Base is Test {
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
}
