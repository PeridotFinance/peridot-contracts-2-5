// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PToken} from "../contracts/PToken.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockMigratedSizingForkTest} from "./FujiMockQuoterMigrationFork.t.sol";

/// @notice Real proxy upgrade and debt migration in pinned LOCAL Fuji forks, never live writes.
contract FujiBorrowAccountingFixForkTest is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_388_595);
        assertEq(block.chainid, 43_113);
    }

    function _upgrade(PErc20 market, address[] memory borrowers, uint256 allowance) private {
        PErc20Delegate implementation = new PErc20Delegate();
        market.accrueInterest();
        uint256 expected = market.totalBorrows();
        uint256 cash = market.getCash();
        uint256 supply = market.totalSupply();
        uint256 ownerShares = market.balanceOf(OWNER);
        address underlying = market.underlying();
        vm.prank(OWNER);
        PErc20Delegator(payable(address(market)))
            ._setImplementation(address(implementation), false, abi.encode(borrowers, expected, allowance));
        assertTrue(market.borrowAccountingEnabled());
        assertEq(market.getCash(), cash);
        assertEq(market.totalSupply(), supply);
        assertEq(market.balanceOf(OWNER), ownerShares);
        assertEq(market.underlying(), underlying);
        assertEq(market.admin(), OWNER);
    }

    function testEmptyLegacyMarketsMigrateDustWithoutTouchingCustody() public {
        assertEq(AVAX.totalBorrows(), 8);
        uint256 avaxReserves = AVAX.totalReserves();
        uint256 nav = AVAX.getCash() + AVAX.totalBorrows() - avaxReserves;
        _upgrade(USD, new address[](0), 0);
        _upgrade(AVAX, new address[](0), 8);
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
        assertEq(AVAX.totalReserves(), avaxReserves - 8);
        assertEq(AVAX.getCash() + AVAX.totalBorrows() - AVAX.totalReserves(), nav);
        assertEq(EX.vault().freeBalance(OWNER, address(USD)), 0);
        assertEq(EX.vault().lockedBalance(OWNER, address(USD)), 0);
    }

    function testActualShortSurvivesMigrationAndClosesWithoutEightUnitResidue() public {
        vm.createSelectFork(vm.envString("FUJI_MOCK_FORK_RPC_URL"), 58_345_305);
        address account = _account(2);
        uint256 principal = AVAX.borrowBalanceStored(account);
        address[] memory borrowers = new address[](1);
        borrowers[0] = account;
        _upgrade(AVAX, borrowers, 0);
        assertEq(AVAX.borrowBalanceStored(account), principal);
        vm.roll(58_345_307);
        vm.prank(OWNER);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(2, 10_000, 0, 0, 0, "", ""));
        _closed(2);
        assertEq(AVAX.totalBorrows(), 0);
    }

    function testExistingUnderflowingLongMigratesAndFullyCloses() public {
        uint256 id = _openLong();
        address account = _account(id);
        for (uint256 i; i < 64; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            USD.accrueInterest();
        }
        uint256 debt = USD.borrowBalanceStored(account);
        assertGt(debt, USD.totalBorrows());
        address[] memory borrowers = new address[](1);
        borrowers[0] = account;
        _upgrade(USD, borrowers, debt - USD.totalBorrows());
        assertEq(USD.borrowBalanceStored(account), debt);
        vm.prank(OWNER);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        _closed(id);
        assertEq(USD.totalBorrows(), 0);
        uint256 free = EX.vault().freeBalance(OWNER, address(USD));
        uint256 before = USD.balanceOf(OWNER);
        vm.startPrank(OWNER);
        EX.vault().withdraw(address(USD), free);
        vm.stopPrank();
        assertEq(USD.balanceOf(OWNER), before + free);
    }

    function testNewLongOnUpgradedMarketClosesAfterFrequentAccrual() public {
        _upgrade(USD, new address[](0), 0);
        _upgrade(AVAX, new address[](0), 8);
        uint256 id = _openLong();
        for (uint256 i; i < 64; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            USD.accrueInterest();
        }
        assertEq(USD.totalBorrows(), USD.borrowBalanceStored(_account(id)));
        vm.prank(OWNER);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        _closed(id);
        assertEq(USD.totalBorrows(), 0);
    }

    function testRejectedMigrationRollsBackImplementationAndDebtState() public {
        PErc20Delegator proxy = PErc20Delegator(payable(address(AVAX)));
        address oldImplementation = proxy.implementation();
        PErc20Delegate next = new PErc20Delegate();
        vm.prank(OWNER);
        vm.expectRevert(PToken.BorrowAccountingAdjustmentExceeded.selector);
        proxy._setImplementation(address(next), false, abi.encode(new address[](0), uint256(8), uint256(0)));
        assertEq(proxy.implementation(), oldImplementation);
        assertEq(AVAX.totalBorrows(), 8);
    }

    function _openLong() private returns (uint256 id) {
        vm.startPrank(OWNER);
        AF.setAnswer(10e8);
        UF.setAnswer(1e8);
        USD.approve(address(EX.vault()), 5000e8);
        EX.vault().deposit(address(USD), 5000e8);
        USD.exchangeRateCurrent();
        AVAX.exchangeRateCurrent();
        (, uint256 minimum) = EX.quoter()
            .quoteOpen(address(USD), address(AVAX), address(USD), 5000e8 * USD.exchangeRateStored() / 1e18, 200);
        id = EX.openPosition(
            IsolatedMarginExecutorUpgradeable.OpenParams(
                address(USD), address(AVAX), address(USD), 5000e8, 200, 0, minimum, IsolatedMarginTypes.Side.LONG, ""
            )
        );
        vm.stopPrank();
    }

    function _account(uint256 id) private view returns (address account) {
        (,, account,,,,,,,,,) = EX.positions(id);
    }

    function _closed(uint256 id) private view {
        (,,,,,,,,,,, IsolatedMarginTypes.Status status) = EX.positions(id);
        assertEq(uint256(status), uint256(IsolatedMarginTypes.Status.CLOSED));
        assertEq(USD.borrowBalanceStored(_account(id)), 0);
        assertEq(AVAX.borrowBalanceStored(_account(id)), 0);
        assertEq(EX.vault().lockedBalance(OWNER, address(USD)), 0);
    }
}

/// @notice Reuses all 24 long/short/cost/boundary scenarios with both lending markets migrated.
contract FujiBorrowAccountingSizingForkTest is FujiMockMigratedSizingForkTest {
    function _installOpeningCode() internal override {
        super._installOpeningCode();
        PErc20Delegate implementation = new PErc20Delegate();
        vm.startPrank(OWNER);
        PErc20Delegator(payable(address(USD)))
            ._setImplementation(address(implementation), false, abi.encode(new address[](0), uint256(0), uint256(0)));
        PErc20Delegator(payable(address(AVAX)))
            ._setImplementation(address(implementation), false, abi.encode(new address[](0), uint256(0), uint256(0)));
        vm.stopPrank();
        assertTrue(USD.borrowAccountingEnabled());
        assertTrue(AVAX.borrowAccountingEnabled());
    }
}
