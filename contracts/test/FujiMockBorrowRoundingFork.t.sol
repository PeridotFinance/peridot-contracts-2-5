// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";

/// @notice Actual migrated code on pinned Fuji state. No etch, storage injection or live writes.
contract FujiMockBorrowRoundingForkTest is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant USER = address(0xA11CE);
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    uint256 constant MARGIN = 5000e8;

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_388_595); // After the verified smoke withdrawal.
        assertEq(block.chainid, 43_113);
        assertEq(address(EX.quoter()), 0xA73180B7Fdc50e061e32205f3b01e0be952d280b);
        assertEq(EX.nextPositionId(), 3);
        assertEq(AVAX.totalBorrows(), 8);
        assertEq(USD.totalBorrows(), 0);
        _refresh();
    }

    function testReplayActualShortCloseProducesExactlyEightUnits() public {
        vm.createSelectFork(vm.envString("FUJI_MOCK_FORK_RPC_URL"), 58_345_305);
        address account = _account(2);
        assertEq(AVAX.borrowBalanceStored(account), 9_900_990_150_000_000_000);
        assertEq(AVAX.borrowIndex(), 1_000_088_535_642_048_798);
        vm.roll(58_345_307); // Actual close block; interest is block-number based.
        vm.prank(OWNER);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(2, 10_000, 0, 0, 0, "", ""));
        assertEq(AVAX.borrowIndex(), 1_000_088_536_918_402_426);
        assertEq(AVAX.borrowBalanceStored(account), 0);
        assertEq(AVAX.totalBorrows(), 8);
        _assertClosed(2);
    }

    function testRepeatedTwoXLongAndShortAfterRealWithdrawal() public {
        _cycles(200);
    }

    function testFrequentAccrualCanBlockActualTwoXLongClose() public {
        vm.prank(OWNER);
        assertTrue(USD.transfer(USER, MARGIN));
        vm.startPrank(USER);
        USD.approve(address(EX.vault()), MARGIN);
        EX.vault().deposit(address(USD), MARGIN);
        vm.stopPrank();
        USD.exchangeRateCurrent();
        AVAX.exchangeRateCurrent();
        (, uint256 minimum) = EX.quoter()
            .quoteOpen(address(USD), address(AVAX), address(USD), MARGIN * USD.exchangeRateStored() / 1e18, 200);
        vm.prank(USER);
        uint256 id = EX.openPosition(
            IsolatedMarginExecutorUpgradeable.OpenParams(
                address(USD), address(AVAX), address(USD), MARGIN, 200, 0, minimum, IsolatedMarginTypes.Side.LONG, ""
            )
        );
        uint256 firstBlock = vm.getBlockNumber();
        for (uint256 i; i < 64; ++i) {
            vm.roll(firstBlock + i + 1);
            assertEq(USD.accrueInterest(), 0);
        }
        address account = _account(id);
        uint256 debt = USD.borrowBalanceStored(account);
        uint256 aggregate = USD.totalBorrows();
        assertGt(debt, aggregate);
        assertFalse(EX.riskEngine().isLiquidatable(account));
        console2.log("frequent-accrual USD account debt / aggregate", debt, aggregate);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        (,,,,,,,,,,, IsolatedMarginTypes.Status status) = EX.positions(id);
        assertEq(uint256(status), uint256(IsolatedMarginTypes.Status.ACTIVE));
        assertEq(USD.borrowBalanceStored(account), debt);
        assertEq(USD.totalBorrows(), aggregate);
        assertEq(EX.vault().lockedBalance(USER, address(USD)), MARGIN);
    }

    function testRepeatedFiveXLongAndShortWithAccruedInterest() public {
        // Timelocked candidate configuration in LOCAL VM ONLY.
        IsolatedMarginTypes.PairRiskConfig memory r = EX.config().getPairRisk(address(USD), address(AVAX), address(USD));
        r.maxLeverageX100 = 500;
        r.initialMarginBps = 2000;
        r.maintenanceMarginBps = 1000;
        vm.startPrank(OWNER);
        EX.config().queuePairRisk(address(USD), address(AVAX), address(USD), r);
        EX.config().queuePairRisk(address(USD), address(USD), address(AVAX), r);
        vm.warp(block.timestamp + EX.config().actionDelay());
        EX.config().setPairRisk(address(USD), address(AVAX), address(USD), r);
        EX.config().setPairRisk(address(USD), address(USD), address(AVAX), r);
        vm.stopPrank();
        _refresh();
        _cycles(500);
    }

    function _cycles(uint16 leverage) private {
        vm.prank(OWNER);
        assertTrue(USD.transfer(USER, MARGIN * 10));
        vm.startPrank(USER);
        USD.approve(address(EX.vault()), MARGIN * 10);
        EX.vault().deposit(address(USD), MARGIN * 10);
        vm.stopPrank();
        for (uint256 i; i < 32; ++i) {
            for (uint256 side; side < 2; ++side) {
                PErc20 debt = side == 0 ? USD : AVAX;
                address position = side == 0 ? address(AVAX) : address(USD);
                USD.exchangeRateCurrent();
                AVAX.exchangeRateCurrent();
                uint256 previousAggregate = debt.totalBorrows();
                (, uint256 minimum) = EX.quoter()
                    .quoteOpen(
                        address(USD), position, address(debt), MARGIN * USD.exchangeRateStored() / 1e18, leverage
                    );
                vm.prank(USER);
                uint256 id = EX.openPosition(
                    IsolatedMarginExecutorUpgradeable.OpenParams(
                        address(USD),
                        position,
                        address(debt),
                        MARGIN,
                        leverage,
                        0,
                        minimum,
                        side == 0 ? IsolatedMarginTypes.Side.LONG : IsolatedMarginTypes.Side.SHORT,
                        ""
                    )
                );
                address account = _account(id);
                uint256 principal = debt.borrowBalanceStored(account);
                assertFalse(EX.riskEngine().isLiquidatable(account));
                vm.roll(vm.getBlockNumber() + 100 + i);
                vm.warp(vm.getBlockTimestamp() + 10);
                _refresh();
                uint256 accruedDebt = debt.borrowBalanceCurrent(account);
                assertGt(accruedDebt, principal);
                uint256 totalBeforeClose = debt.totalBorrows();
                vm.prank(USER);
                EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
                _assertClosed(id);
                assertEq(debt.totalBorrows(), totalBeforeClose - accruedDebt);
                assertGe(debt.totalBorrows(), previousAggregate);
                assertEq(EX.vault().lockedBalance(USER, address(USD)), 0);
            }
        }
        console2.log("request leverage x100", leverage);
        console2.log("32 long/short cycles USD / AVAX residue raw", USD.totalBorrows(), AVAX.totalBorrows());
        assertGt(AVAX.totalBorrows(), 8);
        uint256 free = EX.vault().freeBalance(USER, address(USD));
        assertGe(free, MARGIN * 99 / 10); // At most 1% of initial test deposit spent in this scenario.
        vm.startPrank(USER);
        EX.vault().withdraw(address(USD), free);
        vm.stopPrank();
        assertEq(USD.balanceOf(USER), free);
        assertEq(EX.vault().freeBalance(USER, address(USD)), 0);
        assertEq(EX.vault().lockedBalance(USER, address(USD)), 0);
        // Original owner balances remain fully withdrawn; no cross-account custody changes.
        assertEq(EX.vault().freeBalance(OWNER, address(USD)), 0);
        assertEq(EX.vault().lockedBalance(OWNER, address(USD)), 0);
    }

    function _account(uint256 id) private view returns (address account) {
        (,, account,,,,,,,,,) = EX.positions(id);
    }

    function _assertClosed(uint256 id) private view {
        (,,,,,,,,,,, IsolatedMarginTypes.Status status) = EX.positions(id);
        assertEq(uint256(status), uint256(IsolatedMarginTypes.Status.CLOSED));
        assertEq(USD.borrowBalanceStored(_account(id)), 0);
        assertEq(AVAX.borrowBalanceStored(_account(id)), 0);
    }

    function _refresh() private {
        vm.startPrank(OWNER);
        AF.setAnswer(10e8);
        UF.setAnswer(1e8);
        vm.stopPrank();
    }
}
