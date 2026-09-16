// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BorrowAccounting} from "../contracts/BorrowAccounting.sol";
import {BorrowAccountingModule} from "../contracts/BorrowAccountingModule.sol";
import {PToken} from "../contracts/PToken.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {MockErc20} from "./MockErc20.sol";
import {RoundingFixedRate} from "./BorrowRoundingRegression.t.sol";

contract RoundingFeeToken is ERC20 {
    constructor() ERC20("Fee test", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 fee = from != address(0) && to != address(0) ? amount / 100 : 0;
        if (fee != 0) super._update(from, address(0), fee);
        super._update(from, to, amount - fee);
    }
}

contract BorrowAccountingFixTest is Test {
    MockErc20 token;
    PErc20Delegator market;
    PToken accounting;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    function setUp() public {
        _deploy(18);
    }

    function _deploy(uint8 decimals) private {
        token = new MockErc20("Debt units test", "DEBT", decimals);
        market = new PErc20Delegator(
            address(token),
            new MockPeridottroller(),
            new RoundingFixedRate(),
            2 * 10 ** (uint256(decimals) + 8),
            "Debt units pToken",
            "pDEBT",
            8,
            payable(address(this)),
            address(new PErc20Delegate()),
            ""
        );
        accounting = PToken(address(market));
        token.mint(address(this), 10_000 * 10 ** uint256(decimals));
        token.approve(address(market), type(uint256).max);
        assertEq(market.mint(token.balanceOf(address(this))), 0);
        vm.roll(vm.getBlockNumber() + 17);
        assertEq(market.accrueInterest(), 0);
        assertTrue(accounting.borrowAccountingEnabled());
    }

    function _borrow(address user, uint256 amount) private {
        vm.startPrank(user);
        token.approve(address(market), type(uint256).max);
        assertEq(market.borrow(amount), 0);
        vm.stopPrank();
    }

    function _repay(address user, uint256 amount) private {
        uint256 debt = market.borrowBalanceStored(user);
        uint256 payment = amount == type(uint256).max ? debt : amount;
        token.mint(user, payment); // Test funding, not debt forgiveness.
        vm.prank(user);
        assertEq(market.repayBorrow(amount), 0);
        assertEq(market.borrowBalanceStored(user), debt - payment);
    }

    function _step(uint256 blocks) private {
        vm.roll(vm.getBlockNumber() + blocks);
        assertEq(market.accrueInterest(), 0);
    }

    function _invariants() private view {
        uint256 a = market.borrowBalanceStored(ALICE);
        uint256 b = market.borrowBalanceStored(BOB);
        uint256 shares = accounting.borrowShares(ALICE) + accounting.borrowShares(BOB);
        assertEq(accounting.totalBorrowShares(), shares);
        assertEq(market.totalBorrows(), Math.mulDiv(shares, market.borrowIndex(), 1e36));
        assertGe(market.totalBorrows(), a + b);
        assertLe(market.totalBorrows() - a - b, 1); // At most one fractional carry for two accounts.
        assertLe(market.totalReserves(), market.getCash() + market.totalBorrows());
    }

    function testFrequentSixDecimalAccrualRepaysWithoutUnderflow() public {
        _deploy(6);
        _borrow(ALICE, 100e6);
        for (uint256 i; i < 64; ++i) {
            _step(1);
        }
        assertGt(market.borrowBalanceStored(ALICE), 100e6);
        _invariants();
        _repay(ALICE, type(uint256).max);
        assertEq(market.totalBorrows(), 0);
        assertEq(accounting.totalBorrowShares(), 0);
    }

    function testHelperCannotBeCalledDirectlyOrViaAnUnexposedProxySelector() public {
        BorrowAccountingModule module = BorrowAccountingModule(accounting.borrowAccountingModule());
        vm.expectRevert(BorrowAccountingModule.BorrowAccountingDirectCall.selector);
        module.setShares(ALICE, 1e18, 0, 0);
        vm.expectRevert(BorrowAccountingModule.BorrowAccountingDirectCall.selector);
        module.activate(new address[](0), 0, 0);
        (bool success,) = address(market).call(abi.encodeCall(BorrowAccountingModule.setShares, (ALICE, 1e18, 0, 0)));
        assertFalse(success);
        assertEq(accounting.totalBorrowShares(), 0);
    }

    function testRepeatedBorrowRepayHasNoResidualAndLastSupplierCanRedeem() public {
        for (uint256 i; i < 64; ++i) {
            _borrow(ALICE, 10e18 + i);
            _step(2 + i % 7);
            _repay(ALICE, type(uint256).max);
            assertEq(market.totalBorrows(), 0);
        }
        uint256 shares = market.balanceOf(address(this));
        uint256 underlying = Math.mulDiv(shares, market.exchangeRateStored(), 1e18);
        uint256 before = token.balanceOf(address(this));
        assertEq(market.redeem(shares), 0);
        assertEq(token.balanceOf(address(this)) - before, underlying);
        assertEq(market.totalSupply(), 0);
        _step(1_000_000);
        assertEq(market.totalBorrows(), 0);
    }

    function testOtherBorrowerAndPartialRepaymentPreserved() public {
        _borrow(ALICE, 10e18);
        _step(13);
        _borrow(BOB, 20e18);
        _step(31);
        uint256 bobDebt = market.borrowBalanceStored(BOB);
        _repay(ALICE, 3e18);
        assertEq(market.borrowBalanceStored(BOB), bobDebt);
        _invariants();
        _repay(ALICE, type(uint256).max);
        assertEq(market.totalBorrows(), bobDebt);
        _step(100);
        assertGt(market.borrowBalanceStored(BOB), bobDebt);
        _repay(BOB, type(uint256).max);
        assertEq(market.totalBorrows(), 0);
    }

    function testFullReserveFactorDoesNotLeaveUnbackedReserveAfterAllRepay() public {
        assertEq(market._setReserveFactor(1e18), 0);
        _borrow(ALICE, 10e18 + 123);
        _borrow(BOB, 20e18 + 456);
        for (uint256 i; i < 32; ++i) {
            _step(1);
        }
        _repay(ALICE, type(uint256).max);
        _repay(BOB, type(uint256).max);
        _invariants();
        assertEq(market.totalBorrows(), 0);
        assertEq(market.redeem(market.balanceOf(address(this))), 0);
        assertGe(market.getCash(), market.totalReserves());
    }

    function testOverpaymentRemainsAtomicAndCannotEraseDebt() public {
        _borrow(ALICE, 10e18);
        _borrow(BOB, 20e18);
        token.mint(ALICE, 1e18);
        uint256 cash = market.getCash();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", uint256(0x11)));
        market.repayBorrow(11e18);
        assertEq(market.getCash(), cash);
        assertEq(market.borrowBalanceStored(ALICE), 10e18);
        _invariants();
    }

    function testFeeOnTransferRepaymentOnlyBurnsDebtForCashActuallyReceived() public {
        RoundingFeeToken feeToken = new RoundingFeeToken();
        PErc20Delegator feeMarket = new PErc20Delegator(
            address(feeToken),
            new MockPeridottroller(),
            new RoundingFixedRate(),
            2e26,
            "Fee pToken",
            "pFEE",
            8,
            payable(address(this)),
            address(new PErc20Delegate()),
            ""
        );
        feeToken.mint(address(this), 10_000e18);
        feeToken.approve(address(feeMarket), type(uint256).max);
        assertEq(feeMarket.mint(10_000e18), 0);
        vm.prank(ALICE);
        assertEq(feeMarket.borrow(100e18), 0);
        vm.startPrank(ALICE);
        feeToken.approve(address(feeMarket), type(uint256).max);
        for (uint256 i; i < 12; ++i) {
            uint256 owed = feeMarket.borrowBalanceStored(ALICE);
            if (owed == 0) break;
            feeToken.mint(ALICE, owed);
            uint256 cash = feeMarket.getCash();
            assertEq(feeMarket.repayBorrow(type(uint256).max), 0);
            uint256 received = feeMarket.getCash() - cash;
            assertEq(feeMarket.borrowBalanceStored(ALICE), owed - received);
            assertEq(feeMarket.totalBorrows(), owed - received);
        }
        vm.stopPrank();
        assertEq(feeMarket.borrowBalanceStored(ALICE), 0);
        assertEq(feeMarket.totalBorrows(), 0);
    }

    function testFuzzInterleavedBorrowRepayConservesDebt(uint96 a, uint96 b, uint32 elapsed, uint16 repayBps) public {
        a = uint96(bound(a, 1, 1000e18));
        b = uint96(bound(b, 1, 1000e18));
        elapsed = uint32(bound(elapsed, 1, 100_000));
        repayBps = uint16(bound(repayBps, 0, 10_000));
        _borrow(ALICE, a);
        _step(elapsed);
        _borrow(BOB, b);
        _step(elapsed);
        _invariants();
        _repay(ALICE, market.borrowBalanceStored(ALICE) * repayBps / 10_000);
        _invariants();
        _borrow(ALICE, a / 2);
        _invariants();
        _step(elapsed);
        _repay(BOB, type(uint256).max);
        _invariants();
        _repay(ALICE, type(uint256).max);
        _invariants();
        assertEq(market.totalBorrows(), 0);
    }

    function testFuzzMultiBorrowerLifecycleAndSupplierExit(uint256 seed, bool sixDecimals, uint16 reserveBps) public {
        if (sixDecimals) _deploy(6);
        uint256 unit = sixDecimals ? 1e6 : 1e18;
        assertEq(market._setReserveFactor(bound(reserveBps, 0, 10_000) * 1e14), 0);
        address[4] memory users = [ALICE, BOB, address(0xCAFE), address(0xD00D)];
        uint256 expectedCash = market.getCash();
        for (uint256 i; i < 32; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            address user = users[seed % 4];
            _step(1 + (seed >> 8) % 16);
            if ((seed >> 16) % 2 == 0) {
                uint256 amount = (seed >> 32) % (10 * unit);
                _borrow(user, amount);
                expectedCash -= amount;
            } else {
                uint256 owed = market.borrowBalanceStored(user);
                uint256 amount = Math.mulDiv(owed, (seed >> 32) % 10_001, 10_000);
                _repay(user, amount);
                expectedCash += amount;
            }
            uint256 shares;
            uint256 debts;
            for (uint256 j; j < users.length; ++j) {
                shares += accounting.borrowShares(users[j]);
                debts += market.borrowBalanceStored(users[j]);
            }
            assertEq(accounting.totalBorrowShares(), shares);
            assertEq(market.totalBorrows(), Math.mulDiv(shares, market.borrowIndex(), 1e36));
            assertGe(market.totalBorrows(), debts);
            assertLe(market.totalBorrows() - debts, 3);
            assertEq(market.getCash(), expectedCash);
            assertLe(market.totalReserves(), market.getCash() + market.totalBorrows());
        }
        for (uint256 j; j < users.length; ++j) {
            _repay(users[j], type(uint256).max);
        }
        assertEq(accounting.totalBorrowShares(), 0);
        assertEq(market.totalBorrows(), 0);
        assertEq(market.redeem(market.balanceOf(address(this))), 0);
        assertGe(market.getCash(), market.totalReserves());
    }

    function _legacy() private {
        // Test-only mode selection; lets this suite construct a pre-migration state naturally.
        vm.store(address(market), BorrowAccounting.SLOT, bytes32(0));
    }

    function testMigrateNegativeRoundingAndPreserveBothBorrowers() public {
        _deploy(6);
        _legacy();
        _borrow(ALICE, 100e6);
        _borrow(BOB, 200e6);
        for (uint256 i; i < 64; ++i) {
            _step(1);
        }
        uint256 a = market.borrowBalanceStored(ALICE);
        uint256 b = market.borrowBalanceStored(BOB);
        assertGt(a + b, market.totalBorrows());
        address[] memory borrowers = new address[](2);
        borrowers[0] = BOB;
        borrowers[1] = ALICE;
        uint256 legacyTotal = market.totalBorrows();
        accounting.activateBorrowAccounting(borrowers, legacyTotal, a + b - legacyTotal + 1);
        assertEq(market.borrowBalanceStored(ALICE), a);
        assertEq(market.borrowBalanceStored(BOB), b);
        _invariants();
        _repay(ALICE, type(uint256).max);
        _repay(BOB, type(uint256).max);
        assertEq(market.totalBorrows(), 0);
    }

    function testMigrationRejectsUnauthorizedDuplicateStaleAndExcessiveWriteDown() public {
        _legacy();
        _borrow(ALICE, 10e18);
        address[] memory borrowers = new address[](1);
        borrowers[0] = ALICE;
        vm.prank(BOB);
        vm.expectRevert("only admin may migrate borrows");
        accounting.activateBorrowAccounting(borrowers, 10e18, 0);
        vm.expectRevert(PToken.BorrowAccountingSnapshotChanged.selector);
        accounting.activateBorrowAccounting(borrowers, 0, 0);
        vm.expectRevert(PToken.BorrowAccountingAdjustmentExceeded.selector);
        accounting.activateBorrowAccounting(new address[](0), 10e18, 1);
        assertFalse(accounting.borrowAccountingEnabled());
        address[] memory duplicate = new address[](2);
        duplicate[0] = ALICE;
        duplicate[1] = ALICE;
        vm.expectRevert(PToken.BorrowAccountingInvalidBorrowerList.selector);
        accounting.activateBorrowAccounting(duplicate, 10e18, 0);
        accounting.activateBorrowAccounting(borrowers, 10e18, 0);
        vm.expectRevert(PToken.BorrowAccountingAlreadyEnabled.selector);
        accounting.activateBorrowAccounting(borrowers, 10e18, 0);
    }

    function testBadAdminMigrationListNeverMakesOmittedBorrowerAppearDebtFree() public {
        _legacy();
        _borrow(ALICE, 1);
        // The on-chain list is not enumerable: deliberately demonstrate the admin-review obligation.
        accounting.activateBorrowAccounting(new address[](0), 1, 1);
        vm.expectRevert(abi.encodeWithSelector(PToken.BorrowAccountingMissingBorrower.selector, ALICE));
        market.borrowBalanceStored(ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PToken.BorrowAccountingMissingBorrower.selector, ALICE));
        market.borrow(1);
    }
}
