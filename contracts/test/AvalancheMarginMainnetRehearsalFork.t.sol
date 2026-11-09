// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {MarginOrderRegistry} from "../contracts/margin/orders/MarginOrderRegistry.sol";
import {IMarginOrderRegistry} from "../contracts/margin/orders/IMarginOrderRegistry.sol";
import {AvalancheMarginCloseAdapter} from "../contracts/margin/orders/AvalancheMarginCloseAdapter.sol";
import {IPharaohCLRouter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {
    DeployAvalancheCashOnlyLending,
    CashOnlyDeployment,
    CashOnlyParams
} from "../script/DeployAvalancheCashOnlyLending.s.sol";
import {
    DeployAvalancheMarginMainnet,
    OperateAvalancheMarginMainnet,
    MarginParams,
    MarginDeployment
} from "../script/DeployAvalancheMarginMainnet.s.sol";

/**
 * @notice LOCAL-FORK REHEARSAL of the long-only 2x margin on top of PW30: the PW30 lending script, then the four margin stages
 *         (`script/DeployAvalancheMarginMainnet.s.sol`) run inside the forge VM at the CURRENT head. Nothing is signed or sent.
 *         The real Chainlink rounds are used at the start; after every warp and every shock the two aggregators are MOCKED
 *         (a fork cannot move real feeds), so liquidation tests run on mocked prices while deployments, the pool, the router
 *         and the token balances are real.
 *
 *         Run (one fork job at a time):
 *           AVALANCHE_MAINNET_RPC_URL=<in the environment> FOUNDRY_PROFILE=debt_accounting forge test \
 *             --match-contract AvalancheMarginMainnetRehearsalForkTest --threads 1 -vv --skip P_OFTAdapter.sol ...
 */
interface IPharaohPoolState2 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint24 feeProtocol, bool unlocked);
}

contract AvalancheMarginMainnetRehearsalForkTest is Test {
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant AVAX_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant PHARAOH_ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    address internal constant PHARAOH_POOL = 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534;
    int24 internal constant TICK_SPACING = 10;
    address internal constant WHALE = address(0xDEAD0001);
    address internal constant USDC_FEED = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;
    address internal constant LEDGER = 0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD;
    address internal constant THROWAWAY = address(0xDE17);
    address internal constant OP1 = address(0x0A01);
    address internal constant OP2 = address(0x0A02);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant TEAM = address(0x7EA3);
    address internal constant STRANGER = address(0xBAD1);

    // PW30 inputs (contracts/ceremony/pilot-pw30.env, public values)
    uint256 internal constant SEED_WAVAX = 12e18;
    uint256 internal constant SEED_USDC = 100e6;
    uint256 internal constant TEAM_SUPPLY = 6_250e6;
    uint256 internal constant FLASH_SEED = 2_500e6;
    uint256 internal constant INS_SEED = 250e6;

    CashOnlyDeployment internal pw;
    PeridottrollerAvalanche internal controller;
    PErc20Delegator internal pWavax;
    PErc20Delegator internal pUsdc;
    MarginParams internal mp;
    MarginDeployment internal md;
    DeployAvalancheMarginMainnet internal deployScript;
    OperateAvalancheMarginMainnet internal operate;
    IsolatedMarginExecutorUpgradeable internal executor;
    IsolatedMarginLiquidatorUpgradeable internal liquidator;
    IsolatedMarginRiskEngineUpgradeable internal riskEngine;
    IsolatedMarginConfigUpgradeable internal mConfig;
    IsolatedMarginVaultUpgradeable internal mVault;
    IsolatedMarginQuoter internal quoter;
    MarginOrderRegistry internal registry;
    AvalancheMarginCloseAdapter internal closeAdapter;

    int256 internal realAvax;
    int256 internal realUsdc;
    int256 internal avaxAnswer;
    int256 internal usdcAnswer;
    uint256 internal forkBlock;

    // ===================================================================== set-up: PW30, then the margin stages
    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = vm.envOr("MARGIN_FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        forkBlock = block.number;
        require(block.chainid == 43_114, "not Avalanche C-Chain");
        (, realAvax,,,) = AggregatorV3Interface(AVAX_FEED).latestRoundData();
        (, realUsdc,,,) = AggregatorV3Interface(USDC_FEED).latestRoundData();
        avaxAnswer = realAvax;
        usdcAnswer = realUsdc;

        // ---- PW30 exactly as the ceremony does it (Ledger as deployer and admin)
        deal(WAVAX, LEDGER, SEED_WAVAX);
        deal(USDC, LEDGER, SEED_USDC + FLASH_SEED + INS_SEED);
        vm.deal(LEDGER, 100 ether);
        DeployAvalancheCashOnlyLending s = new DeployAvalancheCashOnlyLending();
        CashOnlyParams memory c;
        c.deployer = LEDGER;
        c.peridotToken = address(0);
        c.allowNoRewardToken = true;
        c.pauseGuardian = LEDGER;
        c.wavaxSeed = SEED_WAVAX;
        c.usdcSeed = SEED_USDC;
        c.wavaxBorrowCap = 120e18;
        c.usdcBorrowCap = 5_000e6;
        c.reserveFactor = 0.1e18;
        c.closeFactor = 0.5e18;
        c.liquidationIncentive = 1.08e18;
        c.blocksPerYear = 33_500_000;
        c.baseRatePerYear = 0.02e18;
        c.multiplierPerYear = 0.1e18;
        c.jumpMultiplierPerYear = 1e18;
        c.kink = 0.8e18;
        c.avaxFeedMaxAge = 1_200;
        c.usdcFeedMaxAge = 90_000;
        c.wavaxBorrowCashFloor = 0;
        c.usdcBorrowCashFloor = 1_250e6;
        pw = s.deploy(c);
        controller = pw.controller;
        pWavax = pw.pWavax;
        pUsdc = pw.pUsdc;
        // ceremony E.1 and E.3: WAVAX collateral factor 30%, USDC borrowing enabled (WAVAX stays paused, USDC CF 0)
        vm.startPrank(LEDGER);
        require(controller._setCollateralFactor(PToken(address(pWavax)), 0.3e18) == 0, "cf");
        controller._setBorrowPaused(PErc20(address(pUsdc)), false);
        require(!controller.borrowGuardianPaused(address(pUsdc)), "unpause usdc");
        vm.stopPrank();
        _mintP(pUsdc, TEAM, TEAM_SUPPLY);

        // ---- margin stages 1 and 2 (stage 3/4 are tests' business so that they can be examined)
        mp.deployer = THROWAWAY;
        mp.ledger = LEDGER;
        mp.controller = address(controller);
        mp.pWavax = address(pWavax);
        mp.pUsdc = address(pUsdc);
        mp.actionDelay = 24 hours;
        mp.treasury = LEDGER;
        mp.flashSeedUsdc = FLASH_SEED;
        mp.insuranceSeedUsdc = INS_SEED;
        mp.funders = new address[](2);
        mp.funders[0] = OP1;
        mp.funders[1] = OP2;
        deployScript = new DeployAvalancheMarginMainnet();
        operate = new OperateAvalancheMarginMainnet();
        md = deployScript.deploy(mp);
        executor = IsolatedMarginExecutorUpgradeable(md.executor);
        liquidator = IsolatedMarginLiquidatorUpgradeable(md.liquidator);
        riskEngine = IsolatedMarginRiskEngineUpgradeable(md.riskEngine);
        mConfig = IsolatedMarginConfigUpgradeable(md.config);
        mVault = IsolatedMarginVaultUpgradeable(md.vault);
        quoter = IsolatedMarginQuoter(md.quoter);
        registry = MarginOrderRegistry(md.registry);
        closeAdapter = AvalancheMarginCloseAdapter(md.closeAdapter);
    }

    function _wire() internal {
        operate.wire(mp, md);
    }

    /// stage 3 + 4 after the delay, with fresh feeds
    function _executeAndEnable() internal {
        _wire();
        vm.warp(block.timestamp + mp.actionDelay + 1);
        _refreshFeeds();
        operate.execute(mp, md);
        operate.enable(mp, md);
    }

    // ===================================================================== helpers
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

    /// AVAX as a percentage of the head's real answer (bps)
    function _setAvaxBps(uint256 bps) internal {
        _setPrices(int256((uint256(realAvax) * bps) / 10_000), usdcAnswer);
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

    function _marginShares(address user, uint256 usdcAmount) internal returns (uint256 shares) {
        shares = _mintP(pUsdc, user, usdcAmount);
        vm.startPrank(user);
        pUsdc.approve(address(mVault), shares);
        mVault.deposit(address(pUsdc), shares);
        vm.stopPrank();
    }

    function _openParams(uint256 shares, uint16 lev) internal view returns (IsolatedMarginExecutorUpgradeable.OpenParams memory p, uint256 flash) {
        uint256 minPosition;
        (flash, minPosition) = quoter.quoteOpen(
            address(pUsdc), address(pWavax), address(pUsdc), Math.mulDiv(shares, pUsdc.exchangeRateStored(), 1e18), lev
        );
        p = IsolatedMarginExecutorUpgradeable.OpenParams(
            address(pUsdc), address(pWavax), address(pUsdc), shares, lev, 0, minPosition, IsolatedMarginTypes.Side.LONG, ""
        );
    }

    function _tryOpen(address user, uint256 marginUsdc, uint16 lev) internal returns (bool ok, bytes memory ret, uint256 id) {
        uint256 shares = _marginShares(user, marginUsdc);
        (IsolatedMarginExecutorUpgradeable.OpenParams memory p,) = _openParams(shares, lev);
        vm.prank(user);
        (ok, ret) = address(executor).call(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.openPosition.selector, p));
        if (ok) id = abi.decode(ret, (uint256));
    }

    function _open(address user, uint256 marginUsdc) internal returns (uint256 id) {
        bool ok;
        bytes memory ret;
        (ok, ret, id) = _tryOpen(user, marginUsdc, 200);
        require(ok, string(abi.encodePacked("open failed: ", vm.toString(ret))));
    }

    function _close(address user, uint256 id, uint16 bps) internal returns (bool ok, bytes memory ret) {
        vm.prank(user);
        (ok, ret) = address(executor).call(
            abi.encodeWithSelector(
                IsolatedMarginExecutorUpgradeable.closePosition.selector,
                IsolatedMarginExecutorUpgradeable.CloseParams(id, bps, type(uint256).max, 0, 0, "", "")
            )
        );
    }

    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) assembly { s := mload(add(ret, 32)) }
    }

    function _fundedCall(uint256 id, address op, uint256 maxRepay, uint256 minValueBps) internal returns (bool ok, bytes memory ret) {
        vm.prank(op);
        (ok, ret) = address(liquidator).call(
            abi.encodeWithSelector(
                IsolatedMarginLiquidatorUpgradeable.liquidateFunded.selector,
                IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, op, maxRepay, 0, 0, minValueBps)
            )
        );
    }

    function _fundOperator(address op, uint256 usdc) internal {
        deal(USDC, op, usdc);
        vm.prank(op);
        IERC20(USDC).approve(address(liquidator), usdc);
    }

    // ===================================================================== R-A 1: stage 1 and the deployer-holds-nothing rule
    function test_01_stage1_deployerHoldsNothing_andEverythingIsLedgerOwned() public {
        // deploy() already ran `_verify(stage 1)` inside setUp; spell the key facts out independently
        assertEq(mConfig.owner(), LEDGER);
        assertEq(mVault.owner(), LEDGER);
        assertEq(riskEngine.owner(), LEDGER);
        assertEq(mConfig.opensPaused() ? 1 : 0, 1, "opens start paused");
        assertEq(address(riskEngine.oracle()), address(controller.oracle()), "the PW30 guarded oracle is reused");
        assertEq(controller.isolatedMarginRiskHook(), address(0), "hooks untouched by stage 1");
        assertEq(executor.orderExecutor(), address(0));
        assertEq(address(registry.adapter()), md.closeAdapter);
        assertEq(closeAdapter.registry(), md.registry);
        // the deployer may have spent nonces only; it is nobody
        assertEq(IERC20(USDC).balanceOf(THROWAWAY), 0);
        assertEq(pUsdc.balanceOf(THROWAWAY), 0);
    }

    function test_01b_stage1_refusals() public {
        MarginParams memory q = mp;
        q.deployer = LEDGER; // the Ledger must not be the deployer
        vm.expectRevert(bytes("Margin: the deployer must not be the Ledger"));
        deployScript.deploy(q);

        q = mp;
        q.actionDelay = 10 minutes;
        vm.expectRevert(bytes("Margin: delay below the contract minimum"));
        deployScript.deploy(q);

        q = mp;
        q.funders = new address[](2);
        q.funders[0] = OP1;
        q.funders[1] = OP1;
        vm.expectRevert(bytes("Margin: duplicate funder"));
        deployScript.deploy(q);

        q = mp;
        q.funders = new address[](1);
        q.funders[0] = LEDGER; // the Ledger is not an operator
        vm.expectRevert(bytes("Margin: bad funder"));
        deployScript.deploy(q);

        // WAVAX borrowing unpaused => not long-only => refused
        vm.prank(LEDGER);
        controller._setBorrowPaused(PErc20(address(pWavax)), false);
        vm.expectRevert(bytes("Margin: WAVAX borrowing is not paused"));
        deployScript.deploy(mp);
    }

    // ===================================================================== R-A 2: wire, queue, delay, execute, enable
    function test_02_wire_queueDelayExecuteEnable() public {
        _wire();
        // stage 2 verified inside wire(); opens still paused, pair not configured, funders not added
        assertTrue(mConfig.opensPaused());
        assertFalse(mConfig.fundedLiquidators(OP1));
        // before the delay every queued action refuses
        vm.expectRevert(bytes("MarginConfig: not ready"));
        operate.execute(mp, md);
        vm.stopBroadcast();
        vm.warp(block.timestamp + mp.actionDelay - 1 hours);
        _refreshFeeds();
        vm.expectRevert(bytes("MarginConfig: not ready"));
        operate.execute(mp, md);
        vm.stopBroadcast();
        vm.warp(block.timestamp + 1 hours + 1);
        _refreshFeeds();
        // stage 4 cannot run before stage 3 (the pair risk is not in place)
        vm.expectRevert(bytes("verify: pair risk differs from the proposed constants"));
        operate.enable(mp, md);
        operate.execute(mp, md);
        assertTrue(mConfig.opensPaused(), "stage 3 leaves opens paused");
        assertTrue(mConfig.fundedLiquidators(OP1) && mConfig.fundedLiquidators(OP2));
        // opens refuse while paused
        (bool ok,,) = _tryOpen(ALICE, 1_000e6, 200);
        assertFalse(ok, "open refused while paused");
        operate.enable(mp, md);
        assertFalse(mConfig.opensPaused());
        // the queued unpause cannot be replayed
        vm.expectRevert(bytes("MarginConfig: not queued"));
        vm.prank(LEDGER);
        mConfig.unpauseOpens();
    }

    function test_02b_orderExecutor_isOneShot_andAdminOnly() public {
        _wire();
        assertEq(executor.orderExecutor(), md.closeAdapter);
        // a second initialization (even by the ProxyAdmin owner through upgradeAndCall) reverts: reinitializer(2)
        address admin = address(uint160(uint256(vm.load(md.executor, 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103))));
        vm.prank(LEDGER);
        (bool ok,) = admin.call(
            abi.encodeWithSignature(
                "upgradeAndCall(address,address,bytes)",
                md.executor,
                md.executorImpl,
                abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.initializeOrderExecutor.selector, address(0xBEEF))
            )
        );
        assertFalse(ok, "second order-executor wiring must revert");
        // a direct call by anyone is refused
        vm.prank(STRANGER);
        vm.expectRevert();
        executor.initializeOrderExecutor(STRANGER);
        assertEq(executor.orderExecutor(), md.closeAdapter);
    }

    // ===================================================================== R-A 3: lifecycle at the caps
    // The numbers below are the DECISIONS of the user (pair risk as proposed, accepted 2026-11-07), pinned as literals so that a change of the
    // script's constants cannot pass unnoticed (the script's own `verify` compares the chain with the same constants, so it cannot catch that).
    function test_02c_pairRisk_onChainEqualsTheDecisions() public {
        _executeAndEnable();
        IsolatedMarginTypes.PairRiskConfig memory r = mConfig.getPairRisk(address(pUsdc), address(pWavax), address(pUsdc));
        assertTrue(r.enabled);
        assertEq(r.maxLeverageX100, 200, "2x");
        assertEq(r.initialMarginBps, 5_000);
        assertEq(r.maintenanceMarginBps, 2_500, "25% maintenance");
        assertEq(r.liquidationTargetBps, 12_500);
        assertEq(r.fullLiquidationHealthBps, 5_000);
        assertEq(r.maxLiquidationBps, 5_000);
        assertEq(r.liquidationBonusBps, 500, "5% bonus");
        assertEq(r.maxSlippageBps, 100, "slippage floor 100 bp");
        assertEq(r.oracleDeviationBps, 100);
        assertEq(uint256(r.maxPositionValueUsd), 5_000e18, "position cap USD 5,000");
        assertEq(uint256(r.maxDebtValueUsd), 2_500e18, "debt cap USD 2,500");
        assertEq(mConfig.actionDelay(), 24 hours, "timelock 24 h");
        assertEq(mConfig.openFeeBps(), 0);
        assertEq(mConfig.closeFeeBps(), 0);
        assertTrue(mConfig.fundedLiquidators(OP1));
        assertTrue(mConfig.fundedLiquidators(OP2));
        assertFalse(mConfig.fundedLiquidators(STRANGER));
        assertFalse(mConfig.fundedLiquidators(LEDGER), "the Ledger is not an operator");
        assertTrue(controller.borrowGuardianPaused(address(pWavax)), "long only: WAVAX borrowing stays paused");
    }

    function test_03_lifecycle_open_caps_close() public {
        _executeAndEnable();
        // 2,500 margin at 2x => position about 5,000, debt about 2,450
        uint256 id = _open(ALICE, 2_500e6);
        IsolatedMarginTypes.Position memory p = _pos(id);
        assertEq(uint8(p.side), uint8(IsolatedMarginTypes.Side.LONG));
        assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        IsolatedMarginTypes.AccountMetrics memory m = riskEngine.getMetrics(p.account);
        emit log_named_uint("gross asset USD (1e18)", m.grossAssetValueUsd);
        emit log_named_uint("debt USD (1e18)", m.debtValueUsd);
        emit log_named_uint("health bps", m.healthFactorBps);
        assertLe(m.grossAssetValueUsd, 5_000e18 + 1e16, "position within the cap");
        assertLe(m.debtValueUsd, 2_500e18, "debt within the cap");
        // the account is registered with the controller hook
        assertTrue(controller.isolatedMarginAccounts(p.account));

        // above the cap: margin 2,700 => position 5,400
        (bool okCap, bytes memory retCap,) = _tryOpen(BOB, 2_700e6, 200);
        assertFalse(okCap, "position above USD 5,000 must be refused");
        assertEq(_sel(retCap), bytes4(keccak256("BorrowPeridottrollerRejection(uint256)")), "refused by the controller hook (caps)");
        // the position cap alone: margin 2,550 => debt about 2,499 (under the debt cap) but position about 5,046... still refused? record it
        (bool okPos,,) = _tryOpen(address(0xB0B2), 2_550e6, 200);
        emit log_named_uint("margin 2,550 (position over USD 5,000, debt under 2,500) opens (0/1)", okPos ? 1 : 0);
        assertFalse(okPos, "the position cap alone refuses (debt is still under its cap)");
        // leverage above 2x
        uint256 sh = _marginShares(BOB, 1_000e6);
        uint256 shUnderlying = Math.mulDiv(sh, pUsdc.exchangeRateStored(), 1e18);
        vm.expectRevert(bytes("MarginQuoter: invalid opening leverage"));
        quoter.quoteOpen(address(pUsdc), address(pWavax), address(pUsdc), shUnderlying, 250);
        // and the executor itself refuses a 2.5x request even if the quote is bypassed
        vm.prank(BOB);
        (bool okLev,) = address(executor).call(
            abi.encodeWithSelector(
                IsolatedMarginExecutorUpgradeable.openPosition.selector,
                IsolatedMarginExecutorUpgradeable.OpenParams(address(pUsdc), address(pWavax), address(pUsdc), sh, 250, 0, 1, IsolatedMarginTypes.Side.LONG, "")
            )
        );
        assertFalse(okLev, "leverage above 2x refused");

        // partial close 50%, then full
        (bool okP, bytes memory retP) = _close(ALICE, id, 5_000);
        assertTrue(okP, string(abi.encodePacked("partial close: ", vm.toString(retP))));
        (bool okF, bytes memory retF) = _close(ALICE, id, 10_000);
        assertTrue(okF, string(abi.encodePacked("full close: ", vm.toString(retF))));
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertEq(pUsdc.borrowBalanceStored(p.account), 0, "debt repaid");
        uint256 back = mVault.freeBalance(ALICE, address(pUsdc));
        uint256 backUsdc = Math.mulDiv(back, pUsdc.exchangeRateStored(), 1e18);
        emit log_named_uint("margin returned (USDC 1e6) of 2,500", backUsdc);
        assertGt(backUsdc, 2_450e6, "round trip costs well under 2% of the margin");
    }

    // ===================================================================== R-A 4: the shared USDC budget
    function test_04_sharedBudget_operatingRule() public {
        _executeAndEnable();
        // the operating rule: team lending borrows at or under 2,000 USDC. Team deposits 400 WAVAX (CF 30%) and borrows 2,000.
        _mintP(pWavax, TEAM, 1_000e18);
        address[] memory ms = new address[](1);
        ms[0] = address(pWavax);
        vm.prank(TEAM);
        controller.enterMarkets(ms);
        vm.prank(TEAM);
        require(pUsdc.borrow(2_000e6) == 0, "team borrow 2,000");
        // margin at the cap still opens (debt about 2,450): cap 5,000 and floor 1,250 respected
        uint256 id = _open(ALICE, 2_500e6);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        uint256 cash = IERC20(USDC).balanceOf(address(pUsdc));
        emit log_named_uint("pUSDC cash after team 2,000 + margin 2,450", cash);
        assertGe(cash, 1_250e6, "cash floor respected");
    }

    function test_04b_sharedBudget_teamBorrowsMoreThanTheRule_marginIsRefused() public {
        _executeAndEnable();
        _mintP(pWavax, TEAM, 1_800e18);
        address[] memory ms = new address[](1);
        ms[0] = address(pWavax);
        vm.prank(TEAM);
        controller.enterMarkets(ms);
        vm.prank(TEAM);
        require(pUsdc.borrow(4_000e6) == 0, "team borrow 4,000");
        // 4,000 + 2,450 > 5,000 cap: the margin open must fail (and nothing is left half-open)
        (bool ok,,) = _tryOpen(ALICE, 2_500e6, 200);
        assertFalse(ok, "margin refused when the shared cap is exhausted");
        // a smaller one fits: margin 500 => debt about 490, total about 4,490 < 5,000
        (bool ok2,,) = _tryOpen(BOB, 500e6, 200);
        assertTrue(ok2, "small margin position fits under the remaining headroom");
    }

    // ===================================================================== helpers for the pool
    function _poolSqrt() internal view returns (uint160 q) {
        (q,,,,,,) = IPharaohPoolState2(PHARAOH_POOL).slot0();
    }

    function _poolAnswer8() internal view returns (int256) {
        uint256 pX128 = Math.mulDiv(uint256(_poolSqrt()), uint256(_poolSqrt()), 1 << 64);
        return int256(Math.mulDiv(pX128, 1e20, 1 << 128));
    }

    function _wavaxUsd6(uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, uint256(avaxAnswer), 1e8 * 1e12);
    }

    /// trade the REAL pool until its price reaches `targetBps` of the head's real price (down: sell WAVAX, up: buy WAVAX)
    function _movePoolTo(uint256 targetBps, uint256 chunkAvax, uint256 chunkUsdc, uint256 maxChunks) internal returns (uint256 usdTraded, uint256 chunks) {
        int256 target = int256((uint256(realAvax) * targetBps) / 10_000);
        bool down = targetBps < 10_000;
        while (chunks < maxChunks) {
            int256 now8 = _poolAnswer8();
            if (down ? now8 <= target : now8 >= target) break;
            if (now8 * 100 < realAvax) break;
            address tin = down ? WAVAX : USDC;
            address tout = down ? USDC : WAVAX;
            uint256 amt = down ? chunkAvax : chunkUsdc;
            deal(tin, WHALE, amt);
            vm.startPrank(WHALE);
            IERC20(tin).approve(PHARAOH_ROUTER, amt);
            (bool ok,) = PHARAOH_ROUTER.call(
                abi.encodeCall(IPharaohCLRouter.exactInputSingle, (IPharaohCLRouter.ExactInputSingleParams(tin, tout, TICK_SPACING, WHALE, block.timestamp + 1, amt, 0, 0)))
            );
            vm.stopPrank();
            if (!ok) break;
            usdTraded += down ? _wavaxUsd6(amt) : amt;
            ++chunks;
        }
    }

    function _liqCode(bytes memory ret) internal pure returns (uint256 c) {
        require(ret.length == 36 && _sel(ret) == bytes4(keccak256("LiquidationError(uint8)")), "not a LiquidationError");
        assembly { c := mload(add(ret, 36)) }
    }

    function _usdc6OfPWavax(uint256 pTokens) internal view returns (uint256) {
        uint256 wavax = Math.mulDiv(pTokens, pWavax.exchangeRateStored(), 1e18);
        return Math.mulDiv(wavax, uint256(avaxAnswer), 1e8 * 1e12);
    }

    // ===================================================================== R-A 5: funded liquidation by the two operators
    function test_05_fundedLiquidation_partial_thenDeeper_andRedeem() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        address acct = _pos(id).account;
        _setAvaxBps(7_000); // -30%: still healthy
        assertFalse(riskEngine.isLiquidatable(acct), "healthy at -30%");
        _setAvaxBps(6_400); // -36%
        assertTrue(riskEngine.isLiquidatable(acct), "liquidatable at -36%");

        // a stranger cannot use the funded route
        _fundOperator(STRANGER, 3_750e6);
        (bool okS,) = _fundedCall(id, STRANGER, 3_750e6, 10_000);
        assertFalse(okS, "not on the allowlist");

        // operator 1: the funded route, break-even floor
        _fundOperator(OP1, 3_750e6);
        uint256 before1 = IERC20(USDC).balanceOf(OP1);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = _fundedCall(id, OP1, 3_750e6, 10_000);
        g -= gasleft();
        assertTrue(ok, string(abi.encodePacked("operator 1 funded liquidation: ", vm.toString(ret))));
        uint256 spent = before1 - IERC20(USDC).balanceOf(OP1);
        uint256 gotUsd = _usdc6OfPWavax(pWavax.balanceOf(OP1));
        emit log_named_uint("funded partial: USDC repaid by operator 1 (1e6)", spent);
        emit log_named_uint("funded partial: value of the pWAVAX received (USDC 1e6)", gotUsd);
        emit log_named_uint("funded partial: gas", g);
        assertGt(spent, 0);
        assertGe(gotUsd * 10_000 / spent, 10_000, "value received covers the repayment");
        assertLe(gotUsd * 10_000 / spent, 10_000 + 500 + 5, "bonus at most 5%");

        // F7: the operator redeems the seized pWAVAX; the WAVAX market is not borrowed, so the cash is there
        uint256 pbal = pWavax.balanceOf(OP1);
        uint256 cashBefore = IERC20(WAVAX).balanceOf(address(pWavax));
        vm.prank(OP1);
        assertEq(pWavax.redeem(pbal), 0, "redeem returns no error code");
        assertGt(IERC20(WAVAX).balanceOf(OP1), 0, "operator holds WAVAX after redeeming");
        emit log_named_uint("pWAVAX market cash before redeem (WAVAX 1e18)", cashBefore);
        emit log_named_uint("WAVAX redeemed by operator 1 (1e18)", IERC20(WAVAX).balanceOf(OP1));

        // deeper: operator 2 finishes it
        _setAvaxBps(5_200);
        _fundOperator(OP2, 3_750e6);
        if (uint8(_pos(id).status) == uint8(IsolatedMarginTypes.Status.ACTIVE) && riskEngine.isLiquidatable(acct)) {
            (bool ok2, bytes memory ret2) = _fundedCall(id, OP2, 3_750e6, 10_000);
            assertTrue(ok2, string(abi.encodePacked("operator 2 funded liquidation: ", vm.toString(ret2))));
        }
        emit log_named_uint("final status (5 = CLOSED, 6 = LIQUIDATED, 2 = ACTIVE)", uint8(_pos(id).status));
        emit log_named_uint("debt left (USDC 1e6)", pUsdc.borrowBalanceStored(acct));
    }

    function test_05b_insolvent_operatorDeclinesWithFloor_orAbsorbsWithout() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        address acct = _pos(id).account;
        _setAvaxBps(4_500); // -55%: collateral is worth less than the debt
        _fundOperator(OP1, 3_750e6);
        uint256 debt = pUsdc.borrowBalanceCurrent(acct);
        (bool declined, bytes memory ret) = _fundedCall(id, OP1, 3_750e6, 10_000);
        assertFalse(declined, "the break-even floor refuses an insolvent position");
        assertEq(_liqCode(ret), 32, "refused by the value floor (code 32)");
        assertEq(pUsdc.borrowBalanceStored(acct), debt, "debt untouched by the refusal");
        // without a floor the operator absorbs the loss
        uint256 before1 = IERC20(USDC).balanceOf(OP1);
        (bool ok,) = _fundedCall(id, OP1, 3_750e6, 0);
        assertTrue(ok, "without a floor the call succeeds");
        uint256 spent = before1 - IERC20(USDC).balanceOf(OP1);
        uint256 gotUsd = _usdc6OfPWavax(pWavax.balanceOf(OP1));
        emit log_named_uint("insolvent -55%: operator repaid (USDC 1e6)", spent);
        emit log_named_uint("insolvent -55%: operator received (USDC 1e6)", gotUsd);
        assertLt(gotUsd, spent, "the operator absorbs a loss");
        assertEq(pUsdc.borrowBalanceStored(acct), 0, "debt cleared");
    }

    function test_05c_flashRouteControl_andThePoolCliff() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        address acct = _pos(id).account;
        // A. oracle-only shock of -36%: the pool still pays the old price, so the flash route (which SELLS into the pool) is helped
        _setAvaxBps(6_400);
        assertTrue(riskEngine.isLiquidatable(acct));
        uint256 snap = vm.snapshotState();
        (bool ok,) = address(liquidator).call(
            abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, IsolatedMarginLiquidatorUpgradeable.LiquidationParams(id, address(0xBEEF), 0, 0, "", ""))
        );
        emit log_named_uint("flash route with a pool that LAGS the oracle (0/1)", ok ? 1 : 0);
        vm.revertToState(snap);
        _setAvaxBps(6_400);
        // B. the pool cannot follow the oracle that far: selling into it hits the liquidity wall long before -36%
        (uint256 usd,) = _movePoolTo(7_000, 500e18, 0, 2_000);
        int256 pool8 = _poolAnswer8();
        emit log_named_uint("pool: USD sold trying to reach 70% of the head price (1e6)", usd);
        emit log_named_int("pool answer after the attempt (1e8)", pool8);
        assertLt(pool8 * 100, realAvax * 40, "the pool collapses past the wall instead of stopping at 70%");
    }

    // ===================================================================== R-A 6: orders through the registry and the Avalanche adapter
    function _entryPrice(uint256 id) internal view returns (uint256 price) {
        bool ok;
        (price, ok) = closeAdapter.oraclePriceE18(id);
        require(ok, "no price");
    }

    function test_06_orders_takeProfit_executedByAStranger() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        uint256 entry = _entryPrice(id);
        vm.prank(ALICE);
        uint256 oid = registry.createOrder(id, IMarginOrderRegistry.OrderKind.TAKE_PROFIT, true, entry * 115 / 100, 10_000, 100, uint64(block.timestamp + 7 days));
        // wrong direction for a long is refused
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(1)));
        registry.createOrder(id, IMarginOrderRegistry.OrderKind.TAKE_PROFIT, false, entry * 85 / 100, 10_000, 100, uint64(block.timestamp + 7 days));
        // a stranger cannot create orders on Alice's position
        vm.prank(STRANGER);
        vm.expectRevert(IMarginOrderRegistry.NotPositionOwner.selector);
        registry.createOrder(id, IMarginOrderRegistry.OrderKind.STOP_LOSS, false, entry * 85 / 100, 10_000, 100, uint64(block.timestamp + 7 days));

        (bool ex,, uint8 reason) = registry.canExecute(oid);
        assertFalse(ex);
        assertEq(reason, 6, "trigger not reached");
        // the pool and the oracle move up 20%
        _movePoolTo(12_000, 0, 60_000e6, 120);
        _setPrices(_poolAnswer8(), usdcAnswer);
        (ex,, reason) = registry.canExecute(oid);
        assertTrue(ex, "executable once the price crossed");
        uint256 usdcBefore = IERC20(USDC).balanceOf(STRANGER);
        uint256 freeBefore = mVault.freeBalance(ALICE, address(pUsdc));
        uint256 g = gasleft();
        vm.prank(STRANGER);
        assertTrue(registry.executeOrder(oid, ""));
        g -= gasleft();
        emit log_named_uint("executeOrder gas (full TP close)", g);
        assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
        assertGt(mVault.freeBalance(ALICE, address(pUsdc)), freeBefore + 2_500e6 * 1e18 / pUsdc.exchangeRateStored(), "owner got margin plus profit");
        assertEq(IERC20(USDC).balanceOf(STRANGER) + pUsdc.balanceOf(STRANGER), usdcBefore, "the executor receives nothing");
        // a second execution is refused
        vm.prank(STRANGER);
        vm.expectRevert(IMarginOrderRegistry.OrderNotOpen.selector);
        registry.executeOrder(oid, "");
    }

    function test_06b_orders_stopLoss_clampAndLiquidationBackstop() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        uint256 entry = _entryPrice(id);
        vm.startPrank(ALICE);
        uint256 sl = registry.createOrder(id, IMarginOrderRegistry.OrderKind.STOP_LOSS, false, entry * 97 / 100, 10_000, 300, uint64(block.timestamp + 7 days));
        uint256 tp = registry.createOrder(id, IMarginOrderRegistry.OrderKind.TAKE_PROFIT, true, entry * 130 / 100, 10_000, 100, uint64(block.timestamp + 7 days));
        vm.stopPrank();
        (uint256 usd, uint256 chunks) = _movePoolTo(9_400, 500e18, 0, 2_000);
        emit log_named_uint("pool sold down: USD (1e6)", usd);
        emit log_named_uint("pool sold down: chunks", chunks);
        int256 pool8 = _poolAnswer8();
        emit log_named_int("pool answer (1e8) after the move", pool8);
        // the oracle lags the pool by 3%: the order's price test passes but the pool pays 3% less than the oracle value; the floor is 1% => the close reverts
        _setPrices(pool8 * 103 / 100, usdcAnswer);
        (bool ex,,) = registry.canExecute(sl);
        assertTrue(ex, "trigger crossed");
        vm.prank(STRANGER);
        (bool ok,) = address(registry).call(abi.encodeWithSelector(IMarginOrderRegistry.executeOrder.selector, sl, bytes("")));
        assertFalse(ok, "the stop-loss cannot fill with the pool 3% below the oracle: it stays open");
        assertEq(uint8(registry.getOrder(sl).status), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
        // once the oracle follows the pool the same order fills IF THE POOL CAN TAKE THE SALE. That depends on the pool's depth at the head the
        // suite runs on, which moves a lot (measured 7 Nov vs 9 Nov: USD to sell to reach -10% went from 777k to 231k): the test asserts the
        // invariant (filled and the sibling cancelled, OR still open) and logs which one happened.
        _setPrices(pool8, usdcAnswer);
        vm.prank(STRANGER);
        (bool filled,) = address(registry).call(abi.encodeWithSelector(IMarginOrderRegistry.executeOrder.selector, sl, bytes("")));
        if (filled) {
            emit log_string("stop-loss FILLED once the oracle followed the pool");
            assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED));
            // the sibling take-profit was cancelled in the same transaction
            assertEq(uint8(registry.getOrder(tp).status), uint8(IMarginOrderRegistry.OrderStatus.CANCELLED));
        } else {
            emit log_string("DEPTH WALL: the pool cannot take the stop-loss sale within the 1% floor at this head; the order stays open (liquidation is the backstop)");
            assertEq(uint8(registry.getOrder(sl).status), uint8(IMarginOrderRegistry.OrderStatus.OPEN));
            assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        }
    }

    function test_06c_orders_liquidationCancelsOrders_andOwnerCloseCancels() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        uint256 entry = _entryPrice(id);
        vm.prank(ALICE);
        uint256 oid = registry.createOrder(id, IMarginOrderRegistry.OrderKind.STOP_LOSS, false, entry * 50 / 100, 10_000, 100, uint64(block.timestamp + 7 days));
        _setAvaxBps(6_400);
        _fundOperator(OP1, 3_750e6);
        (bool ok,) = _fundedCall(id, OP1, 3_750e6, 10_000);
        assertTrue(ok);
        // finish the liquidation if partial left it active
        _setAvaxBps(5_200);
        if (uint8(_pos(id).status) == uint8(IsolatedMarginTypes.Status.ACTIVE) && riskEngine.isLiquidatable(_pos(id).account)) {
            _fundOperator(OP2, 3_750e6);
            _fundedCall(id, OP2, 3_750e6, 10_000);
        }
        if (uint8(_pos(id).status) != uint8(IsolatedMarginTypes.Status.ACTIVE)) {
            vm.prank(STRANGER);
            assertFalse(registry.executeOrder(oid, ""), "dead order: cancelled, no revert");
            assertEq(uint8(registry.getOrder(oid).status), uint8(IMarginOrderRegistry.OrderStatus.CANCELLED));
        }
        // owner close cancels another order the same way
        _setAvaxBps(10_000);
        uint256 id2 = _open(BOB, 1_000e6);
        uint256 entry2 = _entryPrice(id2);
        vm.prank(BOB);
        uint256 oid2 = registry.createOrder(id2, IMarginOrderRegistry.OrderKind.STOP_LOSS, false, entry2 * 80 / 100, 10_000, 100, uint64(block.timestamp + 7 days));
        (bool okc,) = _close(BOB, id2, 10_000);
        assertTrue(okc);
        vm.prank(STRANGER);
        assertFalse(registry.executeOrder(oid2, ""));
        assertEq(uint8(registry.getOrder(oid2).status), uint8(IMarginOrderRegistry.OrderStatus.CANCELLED));
    }

    // ===================================================================== R-C: the adapter's own guards, called DIRECTLY as the registry
    // The registry only ever passes consistent inputs, so these guards are defence in depth that no order-level test can reach. Each assertion
    // below is the one that a mutation of the matching line of AvalancheMarginCloseAdapter must break (see the R-C mutation table).
    function test_06e_adapterGuards_directCalls() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        uint256 price = _entryPrice(id);
        address reg = md.registry;
        vm.prank(STRANGER);
        vm.expectRevert(AvalancheMarginCloseAdapter.NotRegistry.selector);
        closeAdapter.closeFor(id, ALICE, 10_000, price, 100, "");
        vm.prank(reg);
        vm.expectRevert(AvalancheMarginCloseAdapter.AdapterDataNotSupported.selector);
        closeAdapter.closeFor(id, ALICE, 10_000, price, 100, hex"01");
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(1)));
        closeAdapter.closeFor(id, ALICE, 0, price, 100, "");
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(1)));
        closeAdapter.closeFor(id, ALICE, 10_001, price, 100, "");
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(2)));
        closeAdapter.closeFor(id, ALICE, 10_000, price, 0, "");
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(2)));
        closeAdapter.closeFor(id, ALICE, 10_000, price, 301, "");
        // the owner must be the position's owner
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(3)));
        closeAdapter.closeFor(id, STRANGER, 10_000, price, 100, "");
        // the price must be EXACTLY the one the registry's trigger check used
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(6)));
        closeAdapter.closeFor(id, ALICE, 10_000, price + 1, 100, "");
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(6)));
        closeAdapter.closeFor(id, ALICE, 10_000, price - 1, 100, "");

        // long only: a position that reports side SHORT is inactive, has no price and cannot be closed through the adapter
        IsolatedMarginTypes.Position memory p = _pos(id);
        p.side = IsolatedMarginTypes.Side.SHORT;
        vm.mockCall(address(executor), abi.encodeWithSelector(executor.positions.selector, id), abi.encode(p));
        assertFalse(closeAdapter.isActive(id), "a short is inactive");
        assertFalse(closeAdapter.isLong(id));
        (uint256 px, bool okPx) = closeAdapter.oraclePriceE18(id);
        assertFalse(okPx);
        assertEq(px, 0);
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(7)));
        closeAdapter.closeFor(id, ALICE, 10_000, price, 100, "");
        vm.clearMockedCalls(); // this also clears the suite's mocked Chainlink rounds: put them back
        _setPrices(avaxAnswer, usdcAnswer);
        assertTrue(closeAdapter.isActive(id), "the real position is an active long again");

        // an inactive (closed) position cannot be closed again
        (bool okClose,) = _close(ALICE, id, 10_000);
        assertTrue(okClose, "owner close");
        vm.prank(reg);
        vm.expectRevert(abi.encodeWithSelector(AvalancheMarginCloseAdapter.InvalidClose.selector, uint8(4)));
        closeAdapter.closeFor(id, ALICE, 10_000, price, 100, "");
    }

    // The minimum the adapter hands to the close path: max( oracle value x (1 - min(order slippage, pair slippage)), debt + flash fee ).
    function test_06f_adapterMinimum_clampAndDebtFloor() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        address acct = _pos(id).account;
        uint256 price = _entryPrice(id);
        address reg = md.registry;
        pUsdc.accrueInterest();
        pWavax.exchangeRateCurrent();
        uint256 assets = pWavax.balanceOf(acct) * pWavax.exchangeRateStored() / 1e18;
        uint256 debt = pUsdc.borrowBalanceStored(acct);
        uint256 quoted = quoter.expectedOut(WAVAX, USDC, assets);
        assertGt(quoted * 9_900 / 10_000, debt, "at the entry price the slippage floor is the binding one");

        // A. an order that allows 300 bp is CLAMPED to the pair's 100 bp
        uint256 want = quoted * 9_900 / 10_000;
        vm.expectCall(
            address(executor),
            abi.encodeWithSelector(
                IsolatedMarginExecutorUpgradeable.closePositionFor.selector,
                ALICE,
                IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, type(uint256).max, want, 0, "", "")
            )
        );
        vm.prank(reg);
        (bool ok,) = address(closeAdapter).call(abi.encodeWithSelector(AvalancheMarginCloseAdapter.closeFor.selector, id, ALICE, uint16(10_000), price, uint16(300), bytes("")));
        assertTrue(ok, "a 300 bp order executes with the 100 bp floor at the entry price");
    }

    function test_06g_adapterMinimum_debtFloorBinds() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        address acct = _pos(id).account;
        uint256 price = _entryPrice(id);
        address reg = md.registry;
        pUsdc.accrueInterest();
        pWavax.exchangeRateCurrent();
        uint256 debt = pUsdc.borrowBalanceStored(acct);
        // the oracle value of the assets is mocked BELOW the debt: the minimum must then be the debt (plus the flash fee, 0 in the pilot)
        vm.mockCall(address(quoter), abi.encodeWithSelector(IsolatedMarginQuoter.expectedOut.selector), abi.encode(debt / 2));
        vm.expectCall(
            address(executor),
            abi.encodeWithSelector(
                IsolatedMarginExecutorUpgradeable.closePositionFor.selector,
                ALICE,
                IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, type(uint256).max, debt, 0, "", "")
            )
        );
        vm.prank(reg);
        address(closeAdapter).call(abi.encodeWithSelector(AvalancheMarginCloseAdapter.closeFor.selector, id, ALICE, uint16(10_000), price, uint16(100), bytes("")));
    }

    function test_06d_registryPause_stopsOnlyExecution() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 1_000e6);
        uint256 entry = _entryPrice(id);
        vm.prank(ALICE);
        registry.createOrder(id, IMarginOrderRegistry.OrderKind.STOP_LOSS, false, entry * 90 / 100, 10_000, 100, uint64(block.timestamp + 7 days));
        vm.prank(LEDGER);
        registry.setPaused(true);
        // owner close and liquidation are unaffected by the pause
        (bool ok,) = _close(ALICE, id, 10_000);
        assertTrue(ok, "owner close works while the registry is paused");
    }

    // ===================================================================== R-A 8: pool cost of a round trip (open then close at once)
    function _roundTripCostBps(address user, uint256 marginUsdc) internal returns (uint256 bps, uint256 g1, uint256 g2) {
        uint256 shares = _marginShares(user, marginUsdc);
        (IsolatedMarginExecutorUpgradeable.OpenParams memory p,) = _openParams(shares, 200);
        vm.prank(user);
        g1 = gasleft();
        uint256 id = executor.openPosition(p);
        g1 -= gasleft();
        vm.prank(user);
        g2 = gasleft();
        executor.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, type(uint256).max, 0, 0, "", ""));
        g2 -= gasleft();
        uint256 back = mVault.freeBalance(user, address(pUsdc));
        bps = back >= shares ? 0 : (shares - back) * 10_000 / shares;
    }

    function test_08_roundTripCost_atThePool() public {
        _executeAndEnable();
        uint256[3] memory sizes = [uint256(500e6), 1_500e6, 2_500e6];
        for (uint256 i; i < sizes.length; ++i) {
            address u = address(uint160(0xC0DE00 + i));
            (uint256 bps, uint256 g1, uint256 g2) = _roundTripCostBps(u, sizes[i]);
            emit log_named_uint("margin (USDC 1e6)", sizes[i]);
            emit log_named_uint("  round-trip cost, bps of the margin", bps);
            emit log_named_uint("  open gas", g1);
            emit log_named_uint("  close gas", g2);
            assertLt(bps, 300, "round trip under 3% of the margin");
        }
    }

    // ===================================================================== R-A 9: lending side unaffected
    function test_09_marginAccount_isNotOrdinarilyLiquidatable_andLendingStillWorks() public {
        _executeAndEnable();
        uint256 id = _open(ALICE, 2_500e6);
        address acct = _pos(id).account;
        _setAvaxBps(6_400);
        address CAROL = address(0xCA201);
        deal(USDC, CAROL, 5_000e6);
        vm.startPrank(CAROL);
        IERC20(USDC).approve(address(pUsdc), type(uint256).max);
        (bool ok, bytes memory ret) = address(pUsdc).call(abi.encodeWithSelector(PErc20.liquidateBorrow.selector, acct, 500e6, address(pWavax)));
        vm.stopPrank();
        bool took = false;
        if (ok && ret.length == 32) took = abi.decode(ret, (uint256)) == 0;
        assertFalse(took, "ordinary seizure of a margin account must not work");
        // an ordinary borrower is unaffected: supply, borrow and repay
        _mintP(pWavax, TEAM, 1_000e18);
        address[] memory ms = new address[](1);
        ms[0] = address(pWavax);
        vm.prank(TEAM);
        controller.enterMarkets(ms);
        _refreshFeeds();
        vm.prank(TEAM);
        require(pUsdc.borrow(500e6) == 0, "ordinary borrow while a margin position is open");
    }

    // ===================================================================== R-A 7: how deep is the pool at this head (the reachability of the trigger)
    function test_07_poolDepth_milestones() public {
        _executeAndEnable();
        emit log_named_int("head: real AVAX answer (1e8)", realAvax);
        emit log_named_uint("head: block", forkBlock);
        uint256[7] memory down = [uint256(9_900), 9_500, 9_000, 8_000, 7_000, 6_400, 5_000];
        uint256 total;
        for (uint256 i; i < down.length; ++i) {
            (uint256 usd,) = _movePoolTo(down[i], 500e18, 0, 2_000);
            total += usd;
            emit log_named_uint(string.concat("SELL side: cumulative USD (1e6) to reach ", vm.toString(down[i] / 100), "% of the head price"), total);
            emit log_named_int("   pool answer now (1e8)", _poolAnswer8());
            if (_poolAnswer8() * 100 < realAvax * 50) break;
        }
    }

    function test_07b_poolDepth_buySide() public {
        _executeAndEnable();
        uint256[5] memory up = [uint256(10_100), 10_500, 11_000, 12_000, 13_000];
        uint256 total;
        for (uint256 i; i < up.length; ++i) {
            (uint256 usd,) = _movePoolTo(up[i], 0, 5_000e6, 2_000);
            total += usd;
            emit log_named_uint(string.concat("BUY side: cumulative USD (1e6) to reach ", vm.toString(up[i] / 100), "% of the head price"), total);
        }
    }
}
