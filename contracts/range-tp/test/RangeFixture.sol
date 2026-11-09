// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {PErc20} from "@peridot/PErc20.sol";
import {PErc20Delegator} from "@peridot/PErc20Delegator.sol";
import {IsolatedMarginTypes} from "@peridot/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginConfigUpgradeable} from "@peridot/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginQuoter} from "@peridot/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginVaultUpgradeable} from "@peridot/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginOrderRegistry} from "@peridot/margin/orders/MarginOrderRegistry.sol";
import {
    DeployAvalancheMarginMainnet,
    OperateAvalancheMarginMainnet,
    MarginParams,
    MarginDeployment
} from "@script/DeployAvalancheMarginMainnet.s.sol";

// the PATCHED engine copies (src/engine): PR #7's hooks applied to the Avalanche sources, under their own names here
import {IsolatedMarginExecutorUpgradeable as RExecutor} from "../src/engine/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable as RRiskEngine} from "../src/engine/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable as RLiquidator} from "../src/engine/IsolatedMarginLiquidatorUpgradeable.sol";
import {AvalancheMarginCloseAdapter as RAdapter} from "../src/engine/AvalancheMarginCloseAdapter.sol";
import {RangeTakeProfit} from "../src/RangeTakeProfit.sol";
import {TickMath} from "../src/vendor/TickMath.sol";

interface IPoolView {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint24, bool);
    function liquidity() external view returns (uint128);
}

interface IPharaohRouterLike {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

interface INfpView {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice The shared fixture of the range take-profit fork tests, at ONE PINNED BLOCK (`RANGE_FORK_BLOCK`).
///
///  Live at the pin: the PW30 lending markets (pWAVAX, pUSDC, controller, guarded oracle), the Pharaoh WAVAX/USDC pool, router and
///  position manager, the real USDC and WAVAX. NOT live (the margin ceremony is not run): the margin stack. The fixture runs the real
///  four-stage margin script on the fork, then upgrades its executor, risk engine and liquidator proxies to the range-aware copies
///  (`src/engine/`) through their own ProxyAdmins as the Ledger (the timelock's role), and puts the custodian behind a transparent proxy.
///  Chainlink feeds are MOCKED (a fork cannot move them): pool swaps are real, the oracle follows them by `_syncOracleToPool`.
abstract contract RangeFixture is Test {
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant AVAX_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant USDC_FEED = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;
    address internal constant PHARAOH_ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    address internal constant PHARAOH_POOL = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534;
    address internal constant PHARAOH_NFPM = 0x0B4478e810D48B5882D4019D435A2f864Bab4F39;
    address internal constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
    address internal constant XPHAR = 0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A;
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    // live PW30 (docs/deployment-handoffs/avalanche-pilot-addresses.json)
    address internal constant CONTROLLER = 0xbE938cD7C25E0E4d0604Fa3F9f0a8b5b67b3D51A;
    address internal constant PWAVAX = 0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1;
    address internal constant PUSDC = 0x0f7849CD9E54ffb027aacaEec82007cca9470098;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address internal constant THROWAWAY = address(0xDE17);
    address internal constant OP1 = address(0x0A01);
    address internal constant OP2 = address(0x0A02);
    address internal constant ALICE = address(0xA11CE);
    address internal constant KEEPER = address(0x4B33);
    address internal constant PROTOCOL = address(0x9001);
    address internal constant RESERVE = address(0x9002);
    address internal constant STRANGER = address(0xBAD1);
    address internal constant WHALE = address(0xDEAD0001);

    uint256 internal constant CAP_USD = 200; // the pilot's one sizing number
    uint256 internal constant FLASH_SEED = 100e6;
    uint256 internal constant INS_SEED = 10e6;

    MarginParams internal mp;
    MarginDeployment internal md;
    DeployAvalancheMarginMainnet internal deployScript;
    OperateAvalancheMarginMainnet internal operate;
    RExecutor internal executor;
    RRiskEngine internal riskEngine;
    RLiquidator internal liquidator;
    RAdapter internal adapter2; // adapter v2 (knows the custodian); its `registry` is THIS contract so that tests can call closeFor
    IsolatedMarginConfigUpgradeable internal mConfig;
    IsolatedMarginVaultUpgradeable internal mVault;
    IsolatedMarginQuoter internal quoter;
    MarginOrderRegistry internal registry;
    RangeTakeProfit internal rtp;
    PErc20Delegator internal pWavax = PErc20Delegator(payable(PWAVAX));
    PErc20Delegator internal pUsdc = PErc20Delegator(payable(PUSDC));

    int256 internal realAvax;
    int256 internal realUsdc;
    int256 internal avaxAnswer;
    int256 internal usdcAnswer;
    uint256 internal forkBlock;

    // ===================================================================== set-up
    function setUp() public virtual {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = vm.envUint("RANGE_FORK_BLOCK"); // a pinned block is REQUIRED: the pool depth changes between heads
        vm.createSelectFork(rpc, pin);
        forkBlock = block.number;
        require(block.chainid == 43_114, "not Avalanche C-Chain");
        (, realAvax,,,) = AggregatorV3Interface(AVAX_FEED).latestRoundData();
        (, realUsdc,,,) = AggregatorV3Interface(USDC_FEED).latestRoundData();
        _setPrices(realAvax, realUsdc);

        // ---- the margin script, stages 1 and 2 (3 and 4 below), against the LIVE PW30 markets
        deal(USDC, LEDGER, FLASH_SEED + INS_SEED);
        vm.deal(LEDGER, 100 ether);
        vm.deal(THROWAWAY, 100 ether);
        mp.deployer = THROWAWAY;
        mp.ledger = LEDGER;
        mp.controller = CONTROLLER;
        mp.pWavax = PWAVAX;
        mp.pUsdc = PUSDC;
        mp.actionDelay = 24 hours;
        mp.capUsd = CAP_USD;
        mp.treasury = LEDGER;
        mp.flashSeedUsdc = FLASH_SEED;
        mp.insuranceSeedUsdc = INS_SEED;
        mp.funders = new address[](2);
        mp.funders[0] = OP1;
        mp.funders[1] = OP2;
        deployScript = new DeployAvalancheMarginMainnet();
        operate = new OperateAvalancheMarginMainnet();
        md = deployScript.deploy(mp);
        operate.wire(mp, md);
        vm.warp(block.timestamp + mp.actionDelay + 1);
        _refreshFeeds();
        operate.execute(mp, md);
        operate.enable(mp, md);

        mConfig = IsolatedMarginConfigUpgradeable(md.config);
        mVault = IsolatedMarginVaultUpgradeable(md.vault);
        quoter = IsolatedMarginQuoter(md.quoter);
        registry = MarginOrderRegistry(md.registry);

        // ---- the range upgrade: custodian behind a transparent proxy, then the three engine proxies and adapter v2
        _upgradeToRangeAware();
    }

    function _upgradeToRangeAware() internal {
        RangeTakeProfit impl = new RangeTakeProfit();
        address[] memory rewards = new address[](2);
        rewards[0] = PHAR;
        rewards[1] = XPHAR;
        RangeTakeProfit.InitParams memory ip = RangeTakeProfit.InitParams({
            executor: md.executor,
            riskEngine: md.riskEngine,
            positionManager: PHARAOH_NFPM,
            pool: PHARAOH_POOL,
            oracle: md.oracle,
            config: md.config,
            registry: md.registry,
            collateral: WAVAX,
            quote: USDC,
            admin: LEDGER,
            rewardTokens: rewards,
            xPhar: XPHAR
        });
        rtp = RangeTakeProfit(address(new TransparentUpgradeableProxy(address(impl), LEDGER, abi.encodeCall(RangeTakeProfit.initialize, (ip)))));
        adapter2 = new RAdapter(md.executor, address(this), md.oracle, md.quoter, md.config, address(rtp));

        _upgrade(md.executor, address(new RExecutor()), abi.encodeCall(RExecutor.initializeRange, (address(rtp), address(adapter2))));
        _upgrade(md.riskEngine, address(new RRiskEngine()), abi.encodeCall(RRiskEngine.initializeRangeCustodian, (address(rtp))));
        _upgrade(md.liquidator, address(new RLiquidator()), abi.encodeCall(RLiquidator.initializeRangeCustodian, (address(rtp))));
        executor = RExecutor(md.executor);
        riskEngine = RRiskEngine(md.riskEngine);
        liquidator = RLiquidator(md.liquidator);
        vm.startPrank(LEDGER);
        rtp.setUnwinders(md.liquidator, address(adapter2));
        vm.stopPrank();
    }

    function _upgrade(address proxy, address newImpl, bytes memory data) internal {
        address admin = address(uint160(uint256(vm.load(proxy, ADMIN_SLOT))));
        vm.prank(LEDGER);
        (bool ok, bytes memory ret) =
            admin.call(abi.encodeWithSignature("upgradeAndCall(address,address,bytes)", proxy, newImpl, data));
        require(ok, string(abi.encodePacked("upgrade failed: ", vm.toString(ret))));
    }

    // ===================================================================== oracle and pool
    function _mockFeed(address feed, int256 answer) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1000), answer, block.timestamp, block.timestamp, uint80(1000))
        );
    }

    function _setPrices(int256 avax8, int256 usdc8) internal {
        avaxAnswer = avax8;
        usdcAnswer = usdc8;
        _mockFeed(AVAX_FEED, avax8);
        _mockFeed(USDC_FEED, usdc8);
    }

    function _refreshFeeds() internal {
        _setPrices(avaxAnswer, usdcAnswer);
    }

    function _slot0() internal view returns (uint160 sqrtP, int24 tick) {
        (sqrtP, tick,,,,,) = IPoolView(PHARAOH_POOL).slot0();
    }

    /// Chainlink AVAX/USD (8 decimals) that equals the pool's price: pool price is raw USDC per raw WAVAX.
    function _syncOracleToPool() internal {
        (uint160 s,) = _slot0();
        uint256 x = Math.mulDiv(uint256(s), uint256(s), 1 << 64);
        uint256 avax8 = Math.mulDiv(x, 1e12 * uint256(usdcAnswer), 1 << 128);
        _setPrices(int256(avax8), usdcAnswer);
    }

    /// Moves the pool to `targetTick` by swapping (real swaps against the real pool), stopping exactly at the tick's price.
    function _moveTo(int24 targetTick) internal {
        (, int24 tick) = _slot0();
        if (targetTick == tick) return;
        bool up = targetTick > tick;
        address tokenIn = up ? USDC : WAVAX;
        address tokenOut = up ? WAVAX : USDC;
        uint256 amountIn = up ? 20_000_000e6 : 2_000_000e18;
        deal(tokenIn, WHALE, amountIn);
        vm.startPrank(WHALE);
        IERC20(tokenIn).approve(PHARAOH_ROUTER, amountIn);
        IPharaohRouterLike(PHARAOH_ROUTER).exactInputSingle(
            IPharaohRouterLike.ExactInputSingleParams(
                tokenIn, tokenOut, 10, WHALE, block.timestamp, amountIn, 0, TickMath.getSqrtPriceAtTick(targetTick)
            )
        );
        vm.stopPrank();
        (, int24 after_) = _slot0();
        if (up) require(after_ >= targetTick - 1, "moveTo: did not reach the target (pool depth)");
        else require(after_ <= targetTick, "moveTo: did not reach the target (pool depth)");
    }

    function _liveFeeProtocol() internal view returns (uint24 fp) {
        (bool ok, bytes memory r) = PHARAOH_POOL.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok, "slot0 unreadable");
        (,,,,, fp,) = abi.decode(r, (uint160, int24, uint16, uint16, uint16, uint24, bool));
    }

    /// Moves the pool and the oracle together, as a real market move would.
    function _market(int24 targetTick) internal {
        _moveTo(targetTick);
        _syncOracleToPool();
    }

    // ===================================================================== margin helpers
    function _mintP(address who, uint256 amount) internal returns (uint256 minted) {
        deal(USDC, who, IERC20(USDC).balanceOf(who) + amount);
        uint256 before = pUsdc.balanceOf(who);
        vm.startPrank(who);
        IERC20(USDC).approve(PUSDC, amount);
        require(pUsdc.mint(amount) == 0, "mint failed");
        vm.stopPrank();
        minted = pUsdc.balanceOf(who) - before;
    }

    function _pos(uint256 id) internal view returns (IsolatedMarginTypes.Position memory p) {
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

    /// One 2x long for `user` with `marginUsdc` of margin through the real vault and executor.
    function _open(address user, uint256 marginUsdc) internal returns (uint256 id) {
        uint256 shares = _mintP(user, marginUsdc);
        vm.startPrank(user);
        pUsdc.approve(address(mVault), shares);
        mVault.deposit(PUSDC, shares);
        vm.stopPrank();
        (, uint256 minPosition) = quoter.quoteOpen(PUSDC, PWAVAX, PUSDC, Math.mulDiv(shares, pUsdc.exchangeRateStored(), 1e18), 200);
        RExecutor.OpenParams memory p =
            RExecutor.OpenParams(PUSDC, PWAVAX, PUSDC, shares, 200, 0, minPosition, IsolatedMarginTypes.Side.LONG, "");
        id = executor.nextPositionId();
        vm.prank(user);
        executor.openPosition(p);
    }

    function _health(uint256 id) internal view returns (uint256) {
        return riskEngine.getMetrics(_pos(id).account).healthFactorBps;
    }

    function _debt(uint256 id) internal returns (uint256) {
        return pUsdc.borrowBalanceCurrent(_pos(id).account);
    }

    function _collateral(uint256 id) internal returns (uint256 underlying) {
        address acct = _pos(id).account;
        return Math.mulDiv(pWavax.balanceOf(acct), pWavax.exchangeRateCurrent(), 1e18);
    }

    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) assembly { s := mload(add(ret, 32)) }
    }

    function _fee(address who) internal view returns (uint256) {
        return IERC20(USDC).balanceOf(who);
    }
}
