// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {SmokeFujiMockMargin} from "../script/SmokeFujiMockMargin.s.sol";

/// @notice Post-activation deployed-code tests. All feed/risk changes are LOCAL FORK ONLY.
/// @dev 3x-5x use a candidate 5x cap / 20% initial / 10% maintenance, NOT current live risk.
contract FujiMockLeverageDistanceForkTest is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant USER = address(0xA11CE);
    uint256 constant ENTRY = 10e8;
    uint256 constant SHARES = 5000e8; // $100 mockUSD margin.
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    FujiMockSwapAdapter constant ADAPTER = FujiMockSwapAdapter(0xEF3F12c9D60bc86484dac6250BCC25d784Ba200B);
    IsolatedMarginConfigUpgradeable constant CONFIG =
        IsolatedMarginConfigUpgradeable(0x6148183676E304dbe63a85C350c208DA3cEAc39C);
    IsolatedMarginVaultUpgradeable constant VAULT =
        IsolatedMarginVaultUpgradeable(0x0987154fB5676a8Ea545AAf41F8ef2492F785d22);
    IsolatedMarginRiskEngineUpgradeable constant RISK =
        IsolatedMarginRiskEngineUpgradeable(0x94DA93A26770C114FD6a59015aD462c65C7A2F8c);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_243_366);
        assertEq(block.chainid, 43_113);
        assertFalse(CONFIG.opensPaused());
        assertEq(EX.nextPositionId(), 1);
        assertEq(CONFIG.getPairRisk(address(USD), address(AVAX), address(USD)).maxLeverageX100, 200);
        _refresh();
        vm.prank(OWNER);
        assertTrue(USD.transfer(USER, SHARES * 10));
        vm.startPrank(USER);
        USD.approve(address(VAULT), SHARES * 10);
        VAULT.deposit(address(USD), SHARES * 10);
        vm.stopPrank();
    }

    function testUpdatedSmokeRejectsOldStackBeforeAnyTransfers() public {
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "true");
        uint256 before = USD.balanceOf(OWNER);
        SmokeFujiMockMargin script = new SmokeFujiMockMargin();
        vm.expectRevert("Smoke: migrate quoter first");
        script.run();
        assertEq(USD.allowance(OWNER, address(VAULT)), 0);
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
        assertEq(VAULT.freeBalance(OWNER, address(USD)), 0);
        assertEq(USD.balanceOf(OWNER), before);
    }

    function testLiveTwoXLongFlowAndBoundary() public {
        _flow(false, 200, 3500);
    }

    function testLiveTwoXShortFlowAndBoundary() public {
        _flow(true, 200, 3500);
    }

    function testCandidateThreeXLongFlowAndBoundary() public {
        _candidate(1000);
        _flow(false, 300, 1000);
    }

    function testCandidateThreeXShortFlowAndBoundary() public {
        _candidate(1000);
        _flow(true, 300, 1000);
    }

    function testCandidateFourXLongFlowAndBoundary() public {
        _candidate(1000);
        _flow(false, 400, 1000);
    }

    function testCandidateFourXShortFlowAndBoundary() public {
        _candidate(1000);
        _flow(true, 400, 1000);
    }

    function testCandidateFiveXLongFlowAndBoundary() public {
        _candidate(1000);
        _flow(false, 500, 1000);
    }

    function testCandidateFiveXShortFlowAndBoundary() public {
        _candidate(1000);
        _flow(true, 500, 1000);
    }

    function testFiveXTooHighMaintenanceReproducesNarrowBuffer() public {
        _candidate(1900); // Valid but dangerous proximity to 20% initial margin.
        uint256 id = _open(false, 500);
        uint256 boundary = _boundary(_position(id).account, false);
        uint256 distanceBps = (ENTRY - boundary) * 10_000 / ENTRY;
        console2.log("5x long with 19% maintenance: distance bps", distanceBps);
        assertLt(distanceBps, 130);
        assertGt(distanceBps, 120);
    }

    function testExactFiveXWithHalfPercentExecutionLossRejectsAtomically() public {
        _candidate(1000);
        vm.prank(OWNER);
        ADAPTER.setExecutionBps(9950); // Within 1% DEX bound, but consumes initial-equity headroom.
        uint256 free = VAULT.freeBalance(USER, address(USD));
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(false, 500);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("BorrowPeridottrollerRejection(uint256)", uint256(4)));
        EX.openPosition(params);
        assertEq(VAULT.freeBalance(USER, address(USD)), free);
        assertEq(VAULT.lockedBalance(USER, address(USD)), 0);
        assertEq(USD.totalBorrows(), 0);
        uint256 id = _open(false, 490);
        assertFalse(RISK.isLiquidatable(_position(id).account));
        console2.log(
            "4.9x request with 0.5% execution loss: actual leverage x100",
            RISK.getMetrics(_position(id).account).leverageX100
        );
    }

    function testFreeVaultCollateralDoesNotProtectAnIsolatedPosition() public {
        _candidate(1000);
        uint256 id = _open(false, 500);
        address account = _position(id).account;
        uint256 before = RISK.getMetrics(account).healthFactorBps;
        vm.prank(OWNER);
        assertTrue(USD.transfer(USER, SHARES));
        vm.startPrank(USER);
        USD.approve(address(VAULT), SHARES);
        VAULT.deposit(address(USD), SHARES);
        vm.stopPrank();
        assertEq(RISK.getMetrics(account).healthFactorBps, before);
        assertGt(VAULT.freeBalance(USER, address(USD)), SHARES);
        vm.prank(USER);
        EX.addCollateral(id, SHARES);
        assertGt(RISK.getMetrics(account).healthFactorBps, before);
        uint256 boundary = _boundary(account, false);
        assertApproxEqAbs(boundary, 688_888_888, 100);
        console2.log("5x long plus $100 assigned collateral: liquidation feed price", boundary);
    }

    function testExactFiveXShortWithHalfPercentExecutionLossRejectsAtomically() public {
        _candidate(1000);
        vm.prank(OWNER);
        ADAPTER.setExecutionBps(9950);
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(true, 500);
        // 100 collateral + 400 borrow proceeds * 99%; this is a bound on the swapped leg only.
        params.minPositionUnderlying = 496e6;
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("BorrowPeridottrollerRejection(uint256)", uint256(4)));
        EX.openPosition(params);
        assertEq(VAULT.lockedBalance(USER, address(USD)), 0);
        assertEq(AVAX.totalBorrows(), 0);
        params.leverageX100 = 490;
        params.minPositionUnderlying = 486_100_000;
        vm.prank(USER);
        uint256 id = EX.openPosition(params);
        assertFalse(RISK.isLiquidatable(_position(id).account));
    }

    function testSmokeScriptRequiresConfirmationAndFuji() public {
        SmokeFujiMockMargin script = new SmokeFujiMockMargin();
        vm.setEnv("CONFIRM_FUJI_MOCK_ONLY", "false");
        vm.expectRevert("Smoke: confirmation required");
        script.run();
        vm.chainId(43_114);
        vm.expectRevert("Smoke: Fuji only");
        script.run();
    }

    function testAccruedDebtMovesFiveXLongLiquidationCloser() public {
        _candidate(1000);
        uint256 id = _open(false, 500);
        address account = _position(id).account;
        uint256 before = _boundary(account, false);
        _refresh();
        uint256 debt = USD.borrowBalanceStored(account);
        // This rate model accrues per block. Roll blocks, and independently advance/refresh time.
        vm.roll(block.number + 1_000_000);
        vm.warp(block.timestamp + 1_000_000);
        _refresh();
        USD.accrueInterest();
        AVAX.accrueInterest();
        assertGt(USD.borrowBalanceStored(account), debt);
        uint256 afterPrice = _boundary(account, false);
        assertGt(afterPrice, before);
        console2.log("5x long liquidation before/after 1m blocks (feed 8 decimals)", before, afterPrice);
    }

    function _flow(bool short, uint16 leverage, uint16 maintenance) private {
        uint256 id = _open(short, leverage);
        IsolatedMarginTypes.Position memory p = _position(id);
        IsolatedMarginTypes.AccountMetrics memory m = RISK.getMetrics(p.account);
        assertGe(m.leverageX100, leverage - 1);
        assertLe(m.leverageX100, leverage);
        assertFalse(RISK.isLiquidatable(p.account));
        assertGt(m.healthFactorBps, 10_000);
        uint256 boundary = _boundary(p.account, short);
        // Independent idealized formula: long Pliq/P0=(1-1/L)/(1-m);
        // short Pliq/P0=(1-m)/(1-1/L). Actual engine binary-search must match within 0.000001 USD.
        uint256 formula = short
            ? ENTRY * (10_000 - maintenance) * leverage / (uint256(10_000) * (leverage - 100))
            : ENTRY * (leverage - 100) * 10_000 / (uint256(leverage) * (10_000 - maintenance));
        assertApproxEqAbs(boundary, formula, 100);
        uint256 distance = short ? (boundary - ENTRY) * 10_000 / ENTRY : (ENTRY - boundary) * 10_000 / ENTRY;
        assertGe(distance, 1100); // Candidate 5x must retain >=11% adverse move room at unchanged costs.
        console2.log(short ? "SHORT leverage x100" : "LONG leverage x100", leverage);
        console2.log("entry health factor bps", m.healthFactorBps);
        console2.log("liquidation boundary (USD feed 8 decimals)", boundary);
        console2.log("adverse price distance bps", distance);
        _refresh();
        vm.prank(USER);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        assertEq(uint256(_position(id).status), uint256(IsolatedMarginTypes.Status.CLOSED));
        assertEq(PErc20(p.debtPToken).borrowBalanceStored(p.account), 0);
        assertEq(VAULT.lockedBalance(USER, address(USD)), 0);
        uint256 free = VAULT.freeBalance(USER, address(USD));
        vm.prank(USER);
        VAULT.withdraw(address(USD), free);
        assertEq(VAULT.freeBalance(USER, address(USD)), 0);
        assertApproxEqAbs(USD.balanceOf(USER), SHARES * 10, 50_000);
    }

    function _boundary(address account, bool short) private returns (uint256) {
        uint256 lo = short ? ENTRY : 1e8;
        uint256 hi = short ? 30e8 : ENTRY;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            vm.prank(OWNER);
            AF.setAnswer(int256(mid));
            if (RISK.isLiquidatable(account) == short) hi = mid;
            else lo = mid;
        }
        vm.prank(OWNER);
        AF.setAnswer(int256(short ? lo : hi));
        assertFalse(RISK.isLiquidatable(account));
        vm.prank(OWNER);
        AF.setAnswer(int256(short ? hi : lo));
        assertTrue(RISK.isLiquidatable(account));
        return short ? hi : lo;
    }

    function _candidate(uint16 maintenance) private {
        IsolatedMarginTypes.PairRiskConfig memory r = CONFIG.getPairRisk(address(USD), address(AVAX), address(USD));
        r.maxLeverageX100 = 500;
        r.initialMarginBps = 2000;
        r.maintenanceMarginBps = maintenance;
        vm.startPrank(OWNER);
        CONFIG.queuePairRisk(address(USD), address(AVAX), address(USD), r);
        CONFIG.queuePairRisk(address(USD), address(USD), address(AVAX), r);
        vm.warp(block.timestamp + CONFIG.actionDelay());
        CONFIG.setPairRisk(address(USD), address(AVAX), address(USD), r);
        CONFIG.setPairRisk(address(USD), address(USD), address(AVAX), r);
        vm.stopPrank();
        _refresh();
    }

    function _refresh() private {
        vm.startPrank(OWNER);
        AF.setAnswer(int256(ENTRY));
        UF.setAnswer(1e8);
        vm.stopPrank();
    }

    function _open(bool short, uint16 leverage) private returns (uint256) {
        IsolatedMarginExecutorUpgradeable.OpenParams memory params = _params(short, leverage);
        vm.prank(USER);
        return EX.openPosition(params);
    }

    function _params(bool short, uint16 leverage)
        private
        pure
        returns (IsolatedMarginExecutorUpgradeable.OpenParams memory)
    {
        return IsolatedMarginExecutorUpgradeable.OpenParams(
            address(USD),
            short ? address(USD) : address(AVAX),
            short ? address(AVAX) : address(USD),
            SHARES,
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
        ) = EX.positions(id);
    }
}
