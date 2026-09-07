// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginLiquidatorUpgradeable} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {PErc20} from "../contracts/PErc20.sol";

/// @notice LOCAL FORK ONLY: migration feasibility and executor-only upgrade failure evidence.
/// @dev Uses the deployed ProxyAdmin call path, never vm.etch or vm.store. No migration implementation
///      or broadcast script is provided here. Successful execution of an upgrade is NOT a working migration.
abstract contract FujiMockMigrationForkFixture is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant USER = address(0xA11CE);
    uint256 constant MARGIN = 5000e8;
    bytes32 constant ADMIN_SLOT = bytes32(uint256(keccak256("eip1967.proxy.admin")) - 1);
    bytes32 constant IMPL_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    IsolatedMarginQuoter fresh;
    ProxyAdmin admin;

    function setUp() public virtual {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_244_625);
        assertEq(block.chainid, 43_113);
        admin = ProxyAdmin(_slotAddress(ADMIN_SLOT));
        fresh = new IsolatedMarginQuoter(address(EX.config()), address(EX.riskEngine().oracle()));
        vm.startPrank(OWNER);
        FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4).setAnswer(10e8);
        FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD).setAnswer(1e8);
        assertTrue(USD.transfer(USER, MARGIN * 2));
        vm.stopPrank();
        vm.startPrank(USER);
        USD.approve(address(EX.vault()), MARGIN * 2);
        EX.vault().deposit(address(USD), MARGIN * 2);
        vm.stopPrank();
    }

    function _slotAddress(bytes32 slot) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(EX), slot))));
    }
}

contract FujiMockMigrationPreflightForkTest is FujiMockMigrationForkFixture {
    function testPinnedAuthorityAndDependencyGraph() public view {
        assertEq(admin.owner(), OWNER);
        assertEq(admin.UPGRADE_INTERFACE_VERSION(), "5.0.0");
        assertEq(EX.config().owner(), OWNER);
        assertEq(EX.nextPositionId(), 1);
        assertEq(USD.totalBorrows(), 0);
        assertEq(AVAX.totalBorrows(), 0);
        assertFalse(EX.config().opensPaused());
        assertEq(address(EX.quoter()), 0x6c68ef73728337e5D8212a11CFeDDdF1B4Ff23eD);
        assertEq(address(EX.swapModule().quoter()), address(EX.quoter()));
        IsolatedMarginLiquidatorUpgradeable liq =
            IsolatedMarginLiquidatorUpgradeable(0xb344A644Dcf2176f50292ABDD6acDfdfea3F525d);
        assertEq(address(liq.quoter()), address(EX.quoter()));
        assertEq(address(liq.executor()), address(EX));
        assertEq(address(liq.swapModule()), address(EX.swapModule()));
        console2.log("Pinned Fuji block", block.number);
        console2.log("Executor ProxyAdmin", address(admin));
        console2.log("Old executor implementation", _slotAddress(IMPL_SLOT));
    }

    function testOldQuoterMissingOpeningSelectorNewQuoterSupportsIt() public view {
        bytes memory data = abi.encodeCall(
            IsolatedMarginQuoter.quoteOpen, (address(USD), address(AVAX), address(USD), 100e6, uint16(200))
        );
        (bool oldSuccess,) = address(EX.quoter()).staticcall(data);
        (bool newSuccess, bytes memory result) = address(fresh).staticcall(data);
        assertFalse(oldSuccess);
        assertTrue(newSuccess);
        (uint256 flash, uint256 minimum) = abi.decode(result, (uint256, uint256));
        assertGt(flash, 0);
        assertGt(minimum, 0);
    }

    function testFuzzLegacyHelpersRemainCompatible(uint96 raw) public view {
        uint256 amount = bound(uint256(raw), 0, 1_000_000e18);
        IsolatedMarginQuoter old = EX.quoter();
        address a = AVAX.underlying();
        address u = USD.underlying();
        assertEq(address(old.config()), address(fresh.config()));
        assertEq(address(old.oracle()), address(fresh.oracle()));
        assertEq(address(old.flashLender()), address(fresh.flashLender()));
        for (uint256 i; i < 2; ++i) {
            address asset = i == 0 ? a : u;
            address market = i == 0 ? address(AVAX) : address(USD);
            assertEq(old.assetForMarket(market), fresh.assetForMarket(market));
            assertEq(old.price(asset), fresh.price(asset));
            assertEq(old.underlyingValueUsd(asset, amount), fresh.underlyingValueUsd(asset, amount));
            assertEq(old.expectedOut(asset, i == 0 ? u : a, amount), fresh.expectedOut(asset, i == 0 ? u : a, amount));
            assertEq(old.feePToken(market, amount), fresh.feePToken(market, amount));
            assertEq(
                old.underlyingForUsd(asset, amount, Math.Rounding.Floor),
                fresh.underlyingForUsd(asset, amount, Math.Rounding.Floor)
            );
            assertEq(
                old.underlyingForUsd(asset, amount, Math.Rounding.Ceil),
                fresh.underlyingForUsd(asset, amount, Math.Rounding.Ceil)
            );
        }
    }

    function testUnauthorizedUpgradeRejected() public {
        address implementation = address(new IsolatedMarginExecutorUpgradeable());
        address previous = _slotAddress(IMPL_SLOT);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", USER));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(EX)), implementation, "");
        assertEq(_slotAddress(IMPL_SLOT), previous);
    }

    function testReinitializingToReplaceQuoterRevertsUpgradeAtomically() public {
        address implementation = address(new IsolatedMarginExecutorUpgradeable());
        address previous = _slotAddress(IMPL_SLOT);
        address previousQuoter = address(EX.quoter());
        bytes memory data = abi.encodeCall(
            IsolatedMarginExecutorUpgradeable.initialize,
            (
                address(EX.config()),
                address(EX.riskEngine()),
                address(EX.vault()),
                address(EX.feeDistributor()),
                address(fresh),
                address(EX.swapModule()),
                address(EX.accountFactory())
            )
        );
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(EX)), implementation, data);
        assertEq(_slotAddress(IMPL_SLOT), previous);
        assertEq(address(EX.quoter()), previousQuoter);
    }

    function testExecutorOnlyUpgradeBreaksOpenWithoutLosingDeposit() public {
        bytes32 stateBefore = _executorSlots();
        _upgradeOnly();
        assertEq(_executorSlots(), stateBefore);
        bytes memory data = abi.encodeCall(IsolatedMarginExecutorUpgradeable.openPosition, (_params()));
        vm.expectCall(address(EX.quoter()), abi.encodeWithSelector(IsolatedMarginQuoter.quoteOpen.selector));
        vm.prank(USER);
        (bool success,) = address(EX).call(data);
        assertFalse(success);
        assertEq(EX.nextPositionId(), 1);
        assertEq(EX.vault().freeBalance(USER, address(USD)), MARGIN * 2);
        assertEq(EX.vault().lockedBalance(USER, address(USD)), 0);
        assertEq(USD.totalBorrows(), 0);
    }

    function testPreUpgradePositionCanCloseWhileOpensPausedAfterUpgradeOnly() public {
        vm.prank(USER);
        uint256 id = EX.openPosition(_params());
        (,, address account,,,,,,,,,) = EX.positions(id);
        vm.startPrank(OWNER);
        EX.config().pauseOpens();
        vm.stopPrank();
        bytes32 stateBefore = _executorSlots();
        _upgradeOnly();
        assertEq(_executorSlots(), stateBefore);
        assertTrue(EX.config().opensPaused());
        vm.prank(USER);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        assertEq(USD.borrowBalanceStored(account), 0);
        assertEq(EX.vault().lockedBalance(USER, address(USD)), 0);
        uint256 free = EX.vault().freeBalance(USER, address(USD));
        assertGt(free, 0);
        vm.startPrank(USER);
        EX.vault().withdraw(address(USD), free);
        vm.stopPrank();
        assertEq(USD.balanceOf(USER), free);
        assertEq(EX.vault().freeBalance(USER, address(USD)), 0);
    }

    function _upgradeOnly() private {
        address implementation = address(new IsolatedMarginExecutorUpgradeable());
        vm.prank(OWNER);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(EX)), implementation, "");
        assertEq(_slotAddress(IMPL_SLOT), implementation);
        assertEq(_slotAddress(ADMIN_SLOT), address(admin));
    }

    function _params() private pure returns (IsolatedMarginExecutorUpgradeable.OpenParams memory) {
        return IsolatedMarginExecutorUpgradeable.OpenParams(
            address(USD), address(AVAX), address(USD), MARGIN, 200, 0, 19.8e18, IsolatedMarginTypes.Side.LONG, ""
        );
    }

    function _executorSlots() private view returns (bytes32 hash) {
        // Top-level storage preservation evidence, not a complete storage-layout compatibility proof.
        for (uint256 i; i < 40; ++i) {
            hash = keccak256(abi.encode(hash, vm.load(address(EX), bytes32(i))));
        }
    }
}
