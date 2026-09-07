// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ConfigureFujiMockMargin} from "../script/ConfigureFujiMockMargin.s.sol";
import {FujiMockToken, FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {MarginFeeDistributorUpgradeable} from "../contracts/margin/MarginFeeDistributorUpgradeable.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";

/// @notice LOCAL FORK ONLY: attaches to the verified mock deployment without redeploying or replacing code.
/// @dev Run serially with FUJI_MOCK_FORK_RPC_URL. Governance impersonation and time travel affect only
///      the test VM. This proves deployed mock-stack behavior, not LFJ liquidity or a live Fuji lifecycle.
contract FujiMockDeployedForkTest is Test {
    uint256 constant FORK_BLOCK = 58_206_160;
    uint256 constant PAIR_ETA = 1_788_705_833;
    bytes32 constant LONG_ACTION = 0x56d55a32d1635cf6169712e0f8040637e3c45394f49f0dd56a252ef5aa3ff650;
    bytes32 constant SHORT_ACTION = 0xe73e01ec56ed915bc06519f35083558da455297653440406945be2d92f75a680;
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant USER = address(0xA11CE);
    uint256 constant MARGIN = 5000e8; // 100 mockUSD at the seeded exchange rate.

    PErc20 constant PUSD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant PAVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockToken constant USD = FujiMockToken(0x145700AA1575E7Fb84162D2c8C5201cf683df335);
    FujiMockPriceFeed constant AVAX_FEED = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant USD_FEED = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    FujiMockSwapAdapter constant ADAPTER = FujiMockSwapAdapter(0xEF3F12c9D60bc86484dac6250BCC25d784Ba200B);
    SimpleFlashLoanVault constant LENDER = SimpleFlashLoanVault(0xC857ECa06c694df21671e23188A724907c7f6F53);
    Peridottroller constant CONTROLLER = Peridottroller(0x0020998Ef0f159cf225e183BefF212b5dBA8285a);
    IsolatedMarginConfigUpgradeable constant CONFIG =
        IsolatedMarginConfigUpgradeable(0x6148183676E304dbe63a85C350c208DA3cEAc39C);
    IsolatedMarginVaultUpgradeable constant VAULT =
        IsolatedMarginVaultUpgradeable(0x0987154fB5676a8Ea545AAf41F8ef2492F785d22);
    IsolatedMarginRiskEngineUpgradeable constant RISK =
        IsolatedMarginRiskEngineUpgradeable(0x94DA93A26770C114FD6a59015aD462c65C7A2F8c);
    IsolatedMarginExecutorUpgradeable constant EXECUTOR =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    IsolatedMarginLiquidatorUpgradeable constant LIQUIDATOR =
        IsolatedMarginLiquidatorUpgradeable(0xb344A644Dcf2176f50292ABDD6acDfdfea3F525d);
    MarginFeeDistributorUpgradeable constant FEES =
        MarginFeeDistributorUpgradeable(0x74ce8DAb244831F01700838e72ddFdDeAA19DF98);

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true); // Explicit SKIP, never counted as successful fork evidence.
            return;
        }
        vm.createSelectFork(rpc, FORK_BLOCK);
        assertEq(block.chainid, 43_113);
        assertEq(CONFIG.owner(), OWNER);
        assertEq(CONFIG.queuedActions(LONG_ACTION), PAIR_ETA);
        assertEq(CONFIG.queuedActions(SHORT_ACTION), PAIR_ETA);
        assertEq(CONFIG.queuedActions(keccak256("unpauseOpens")), 0);
        _assertPaused();
        vm.prank(OWNER);
        assertTrue(PUSD.transfer(USER, MARGIN * 10));
        vm.startPrank(USER);
        PUSD.approve(address(VAULT), MARGIN * 10);
        VAULT.deposit(address(PUSD), MARGIN * 10);
        vm.stopPrank();
    }

    function testRecordedPairActionsRespectExactDeadlineAndDoNotActivate() public {
        vm.warp(PAIR_ETA - 1);
        vm.expectRevert("MarginConfig: not ready");
        vm.prank(OWNER);
        CONFIG.setPairRisk(address(PUSD), address(PAVAX), address(PUSD), _risk(200));
        vm.warp(PAIR_ETA);
        _executeScript(false);
        assertEq(CONFIG.queuedActions(LONG_ACTION), 0);
        assertEq(CONFIG.queuedActions(SHORT_ACTION), 0);
        _assertPaused();
        vm.prank(OWNER);
        vm.expectRevert("MarginConfig: not queued");
        CONFIG.unpauseOpens();
    }

    function testDuplicateQueueCannotResetDeadline() public {
        vm.prank(OWNER);
        vm.expectRevert("MarginConfig: already queued");
        CONFIG.queuePairRisk(address(PUSD), address(PAVAX), address(PUSD), _risk(200));
        assertEq(CONFIG.queuedActions(LONG_ACTION), PAIR_ETA);
    }

    function testPausedDepositWithdrawKeepsPTokens() public {
        vm.prank(USER);
        VAULT.withdraw(address(PUSD), MARGIN * 10);
        assertEq(PUSD.balanceOf(USER), MARGIN * 10);
        assertEq(VAULT.freeBalance(USER, address(PUSD)), 0);
        assertEq(USD.balanceOf(USER), 0);
    }

    function testTwoXLongAndShortReturnPTokens() public {
        _activate(200);
        _roundTrip(false, 200);
        _roundTrip(true, 200);
        uint256 free = VAULT.freeBalance(USER, address(PUSD));
        vm.prank(USER);
        VAULT.withdraw(address(PUSD), free);
        assertEq(PUSD.balanceOf(USER), free);
        assertEq(USD.balanceOf(USER), 0);
    }

    function testTwoXPolicyRejectsFiveXWithoutLockingFunds() public {
        _activate(200);
        uint256 free = VAULT.freeBalance(USER, address(PUSD));
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(false, 500);
        vm.prank(USER);
        vm.expectRevert();
        EXECUTOR.openPosition(params);
        assertEq(VAULT.freeBalance(USER, address(PUSD)), free);
        assertEq(VAULT.lockedBalance(USER, address(PUSD)), 0);
        assertEq(PUSD.totalBorrows(), 0);
    }

    function testFiveXLocalRiskChangeLongAndShortHealthyWithZeroSpotCF() public {
        _activate(500); // A separate LOCAL-ONLY, fully timelocked risk change, never a Fuji change.
        _roundTrip(false, 500);
        _roundTrip(true, 500);
    }

    function testBorrowInterestAndSupplyYieldAccrueOnDeployedMarkets() public {
        _activate(200);
        uint256 id = _open(false, 200);
        address account = _position(id).account;
        uint256 debt = PUSD.borrowBalanceStored(account);
        uint256 exchange = PUSD.exchangeRateStored();
        vm.roll(block.number + 100_000);
        assertGt(PUSD.borrowBalanceCurrent(account), debt);
        assertGt(PUSD.exchangeRateStored(), exchange);
        assertEq(VAULT.lockedBalance(USER, address(PUSD)), MARGIN);
    }

    function testSlippageFailureIsAtomicAndSpotBorrowStillBlocked() public {
        _activate(200);
        vm.prank(OWNER);
        ADAPTER.setExecutionBps(9800);
        uint256 free = VAULT.freeBalance(USER, address(PUSD));
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(false, 200);
        vm.prank(USER);
        vm.expectRevert("FujiMock: minimum output");
        EXECUTOR.openPosition(params);
        assertEq(VAULT.freeBalance(USER, address(PUSD)), free);
        assertEq(VAULT.lockedBalance(USER, address(PUSD)), 0);
        assertEq(PUSD.totalBorrows(), 0);
        vm.prank(USER);
        vm.expectRevert();
        PUSD.borrow(1e6);
    }

    function testDebtFreeExitWorksWithStalePrices() public {
        _activate(200);
        uint256 id = _open(false, 200);
        vm.prank(OWNER);
        USD.transfer(USER, 200e6);
        vm.startPrank(USER);
        USD.approve(address(EXECUTOR), type(uint256).max);
        EXECUTOR.repayWithUnderlying(id, type(uint256).max);
        vm.stopPrank();
        vm.warp(block.timestamp + 1201);
        assertEq(RISK.oracle().getPrice(PAVAX.underlying()), 0);
        vm.prank(USER);
        EXECUTOR.exitDebtFreeToPTokens(id, 0);
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.CLOSED));
        assertEq(PUSD.borrowBalanceStored(_position(id).account), 0);
        assertGt(PAVAX.balanceOf(USER), 0);
    }

    function testTwoXPartialLiquidationImprovesHealth() public {
        _activate(200);
        uint256 id = _open(false, 200);
        address account = _position(id).account;
        vm.prank(OWNER);
        AVAX_FEED.setAnswer(7.5e8);
        uint256 health = RISK.getMetrics(account).healthFactorBps;
        assertTrue(RISK.isLiquidatable(account));
        _liquidate(id);
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.ACTIVE));
        assertGt(RISK.getMetrics(account).healthFactorBps, health);
    }

    function testTwoXCrashAndSqueezeInsuranceClearRawDebt() public {
        _activate(200);
        uint256 id = _open(false, 200);
        vm.prank(OWNER);
        AVAX_FEED.setAnswer(4e8);
        _assertFullLiquidation(id);
        vm.prank(OWNER);
        AVAX_FEED.setAnswer(10e8);
        id = _open(true, 200);
        vm.prank(OWNER);
        AVAX_FEED.setAnswer(25e8);
        _assertFullLiquidation(id);
    }

    function testFiveXPartialLiquidationImprovesHealth() public {
        _activate(500);
        uint256 id = _open(false, 500);
        address account = _position(id).account;
        vm.prank(OWNER);
        AVAX_FEED.setAnswer(8.8e8);
        uint256 health = RISK.getMetrics(account).healthFactorBps;
        assertTrue(RISK.isLiquidatable(account));
        _liquidate(id);
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.ACTIVE));
        assertGt(RISK.getMetrics(account).healthFactorBps, health);
    }

    function testFiveXCrashAndSqueezeInsuranceClearRawDebt() public {
        _activate(500);
        uint256 id = _open(false, 500);
        vm.prank(OWNER);
        AVAX_FEED.setAnswer(7.5e8);
        _assertFullLiquidation(id);
        vm.prank(OWNER);
        AVAX_FEED.setAnswer(10e8);
        id = _open(true, 500);
        vm.prank(OWNER);
        AVAX_FEED.setAnswer(15e8);
        _assertFullLiquidation(id);
    }

    function testLocalFeeConfigurationStreamsSameCollateralPTokens() public {
        vm.prank(OWNER);
        CONFIG.queueFees(10, 10, 5000, 5000, 0);
        _activate(200);
        vm.prank(OWNER);
        CONFIG.setFees(10, 10, 5000, 5000, 0);
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(false, 200);
        params.maxOpeningFeePToken = MARGIN / 100;
        vm.prank(USER);
        EXECUTOR.openPosition(params);
        assertLt(FEES.pendingRewards(USER, address(PUSD)), CONFIG.feeStreamDuration());
        vm.warp(block.timestamp + 7 days);
        uint256 reward = FEES.pendingRewards(USER, address(PUSD));
        assertGt(reward, 0);
        uint256 free = VAULT.freeBalance(USER, address(PUSD));
        vm.prank(USER);
        VAULT.settle(address(PUSD));
        assertEq(VAULT.freeBalance(USER, address(PUSD)), free + reward);
    }

    function _activate(uint16 leverage) private {
        // Existing on-chain pair actions are consumed, not requeued. Unpause needs its OWN local queue.
        vm.prank(OWNER);
        CONFIG.queueUnpauseOpens();
        vm.warp(block.timestamp + CONFIG.actionDelay());
        _executeScript(true);
        if (leverage == 500) {
            vm.startPrank(OWNER);
            CONFIG.queuePairRisk(address(PUSD), address(PAVAX), address(PUSD), _risk(500));
            CONFIG.queuePairRisk(address(PUSD), address(PUSD), address(PAVAX), _risk(500));
            vm.warp(block.timestamp + CONFIG.actionDelay());
            AVAX_FEED.setAnswer(10e8);
            USD_FEED.setAnswer(1e8);
            CONFIG.setPairRisk(address(PUSD), address(PAVAX), address(PUSD), _risk(500));
            CONFIG.setPairRisk(address(PUSD), address(PUSD), address(PAVAX), _risk(500));
            vm.stopPrank();
        }
    }

    function _executeScript(bool enable) private {
        vm.setEnv("MOCK_MARGIN_DEPLOYER", vm.toString(OWNER));
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        vm.setEnv("MOCK_RISK_ENGINE", vm.toString(address(RISK)));
        vm.setEnv("MOCK_PAVAX", vm.toString(address(PAVAX)));
        vm.setEnv("MOCK_PUSD", vm.toString(address(PUSD)));
        vm.setEnv("MOCK_EXECUTE", "true");
        vm.setEnv("MOCK_ENABLE_TRADING", enable ? "true" : "false");
        new ConfigureFujiMockMargin().run(); // Forge test only: never invokes network transaction submission.
    }

    function _assertPaused() private view {
        assertTrue(CONFIG.opensPaused() && ADAPTER.paused() && LENDER.paused());
        assertTrue(CONTROLLER.borrowGuardianPaused(address(PUSD)));
        assertTrue(CONTROLLER.borrowGuardianPaused(address(PAVAX)));
        assertTrue(PUSD.flashLoansPaused() && PAVAX.flashLoansPaused());
    }

    function _risk(uint16 leverage) private pure returns (IsolatedMarginTypes.PairRiskConfig memory) {
        return IsolatedMarginTypes.PairRiskConfig(
            true,
            leverage,
            leverage == 500 ? 2000 : 5000,
            leverage == 500 ? 1000 : 3500,
            12_500,
            5000,
            5000,
            500,
            100,
            100,
            10_000e18,
            5000e18
        );
    }

    function _roundTrip(bool short, uint16 leverage) private {
        uint256 free = VAULT.freeBalance(USER, address(PUSD));
        uint256 id = _open(short, leverage);
        IsolatedMarginTypes.Position memory p = _position(id);
        IsolatedMarginTypes.AccountMetrics memory m = RISK.getMetrics(p.account);
        assertGe(m.leverageX100, leverage - 1);
        assertLe(m.leverageX100, leverage);
        assertGt(m.healthFactorBps, 10_000);
        (, uint256 cf,) = CONTROLLER.markets(p.positionPToken);
        assertEq(cf, 0);
        vm.prank(USER);
        EXECUTOR.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.CLOSED));
        assertEq(PToken(p.debtPToken).borrowBalanceStored(p.account), 0);
        assertEq(VAULT.lockedBalance(USER, address(PUSD)), 0);
        assertApproxEqAbs(VAULT.freeBalance(USER, address(PUSD)), free, 50_000);
    }

    function _open(bool short, uint16 leverage) private returns (uint256) {
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(short, leverage);
        vm.prank(USER);
        return EXECUTOR.openPosition(params);
    }

    function _params(bool short, uint16 leverage)
        private
        pure
        returns (IsolatedMarginExecutorUpgradeable.OpenParams memory)
    {
        return IsolatedMarginExecutorUpgradeable.OpenParams(
            address(PUSD),
            short ? address(PUSD) : address(PAVAX),
            short ? address(PAVAX) : address(PUSD),
            MARGIN,
            leverage,
            0,
            short ? uint256(leverage) * 1e6 * 999 / 1000 : uint256(leverage) * 1e17 * 99 / 100,
            short ? IsolatedMarginTypes.Side.SHORT : IsolatedMarginTypes.Side.LONG,
            ""
        );
    }

    function _position(uint256 id) private view returns (IsolatedMarginTypes.Position memory p) {
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
        ) = EXECUTOR.positions(id);
    }

    function _liquidate(uint256 id) private {
        LIQUIDATOR.liquidate(IsolatedMarginLiquidatorUpgradeable.LiquidationParams(id, address(0xBEEF), 0, 0, "", ""));
    }

    function _assertFullLiquidation(uint256 id) private {
        IsolatedMarginTypes.Position memory p = _position(id);
        assertTrue(RISK.isLiquidatable(p.account));
        uint256 insuranceBefore = PUSD.balanceOf(CONFIG.insuranceFund());
        _liquidate(id);
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.LIQUIDATED));
        assertEq(PToken(p.debtPToken).borrowBalanceStored(p.account), 0);
        assertEq(VAULT.lockedBalance(USER, address(PUSD)), 0);
        assertLt(PUSD.balanceOf(CONFIG.insuranceFund()), insuranceBefore);
    }
}
