// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {MarginOrderRegistry} from "../../contracts/margin/orders/MarginOrderRegistry.sol";
import {MarginOrderRegistryV2} from "../../contracts/margin/orders/MarginOrderRegistryV2.sol";
import {IMarginOrderRegistry, IMarginCloseAdapter} from "../../contracts/margin/orders/IMarginOrderRegistry.sol";
import {MockCloseAdapter} from "./MarginOrderRegistry.t.sol";

contract MockRangeActive {
    mapping(uint256 => bool) public isActive;

    function set(uint256 id, bool b) external {
        isActive[id] = b;
    }
}

/// @notice The prepared V1 -> V2 registry upgrade: V1 exactly as the ceremony deploys it, with live orders, upgraded by
/// the proxy admin (the timelock owns it) with initializeV2. Storage kept; the exclusivity rule; re-pointed adapter.
contract MarginOrderRegistryV2Test is Test {
    address timelock = address(0x71);
    address alice = address(0xA11CE);
    MockCloseAdapter ad1;
    MockCloseAdapter ad2;
    MockRangeActive range;
    MarginOrderRegistry v1;
    MarginOrderRegistryV2 reg;
    ProxyAdmin admin;
    IMarginOrderRegistry.OrderKind constant TP = IMarginOrderRegistry.OrderKind.TAKE_PROFIT;
    IMarginOrderRegistry.OrderKind constant SL = IMarginOrderRegistry.OrderKind.STOP_LOSS;

    function setUp() public {
        vm.warp(1_800_000_000);
        ad1 = new MockCloseAdapter();
        ad2 = new MockCloseAdapter();
        range = new MockRangeActive();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
            address(new MarginOrderRegistry()), timelock, abi.encodeCall(MarginOrderRegistry.initialize, (ad1, timelock))
        );
        v1 = MarginOrderRegistry(address(proxy));
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(proxy), 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103)))));
        for (uint256 i = 1; i <= 2; i++) {
            ad1.set(i, alice, true, true);
            ad2.set(i, alice, true, true);
        }
        ad1.setRegistry(address(proxy));
        ad2.setRegistry(address(proxy));
        vm.startPrank(alice);
        v1.createOrder(1, TP, true, 120e18, 10_000, 100, uint64(block.timestamp + 1 days));
        v1.createOrder(1, SL, false, 80e18, 10_000, 100, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        reg = MarginOrderRegistryV2(address(proxy));
    }

    function _upgrade() internal {
        address impl = address(new MarginOrderRegistryV2());
        vm.prank(timelock);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(reg)), impl,
            abi.encodeCall(MarginOrderRegistryV2.initializeV2, (IMarginCloseAdapter(address(ad2)), address(range)))
        );
    }

    function testUpgradeKeepsEveryOrderAndRepointsTheAdapter() public {
        bytes32 before1 = keccak256(abi.encode(v1.getOrder(1)));
        bytes32 before2 = keccak256(abi.encode(v1.getOrder(2)));
        _upgrade();
        assertEq(keccak256(abi.encode(reg.getOrder(1))), before1);
        assertEq(keccak256(abi.encode(reg.getOrder(2))), before2);
        assertEq(reg.nextOrderId(), 3);
        assertEq(reg.openOrdersOf(1).length, 2);
        assertEq(reg.admin(), timelock);
        assertEq(address(reg.adapter()), address(ad2));
        assertEq(reg.rangeOrders(), address(range));
        // an order created before the upgrade still executes, through the new adapter
        ad2.setPrice(130e18, true);
        assertTrue(reg.executeOrder(1, ""));
        assertEq(ad2.calls(), 1);
        assertEq(ad1.calls(), 0);
    }

    function testTakeProfitRefusedWhileARangeBandIsActiveStopLossStillAllowed() public {
        _upgrade();
        range.set(2, true);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IMarginOrderRegistry.InvalidOrder.selector, uint8(7)));
        reg.createOrder(2, TP, true, 120e18, 10_000, 100, uint64(block.timestamp + 1 days));
        reg.createOrder(2, SL, false, 80e18, 10_000, 100, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        range.set(2, false);
        vm.prank(alice);
        reg.createOrder(2, TP, true, 120e18, 10_000, 100, uint64(block.timestamp + 1 days));
    }

    function testInitializeV2OnlyByTheProxyAdminAndOnlyOnce() public {
        address impl = address(new MarginOrderRegistryV2());
        vm.prank(timelock);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(reg)), impl, "");
        vm.expectRevert(bytes("REGISTRY_NOT_PROXY_ADMIN"));
        reg.initializeV2(IMarginCloseAdapter(address(ad2)), address(range));
        vm.prank(timelock);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(reg)), impl,
            abi.encodeCall(MarginOrderRegistryV2.initializeV2, (IMarginCloseAdapter(address(ad2)), address(range)))
        );
        vm.prank(timelock);
        vm.expectRevert(); // reinitializer(2) spent
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(reg)), impl,
            abi.encodeCall(MarginOrderRegistryV2.initializeV2, (IMarginCloseAdapter(address(ad1)), address(range)))
        );
        assertEq(address(reg.adapter()), address(ad2));
    }

    function testInitializeV2RejectsNonContracts() public {
        address impl = address(new MarginOrderRegistryV2());
        vm.prank(timelock);
        vm.expectRevert(bytes("REGISTRY_CONFIG"));
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(reg)), impl,
            abi.encodeCall(MarginOrderRegistryV2.initializeV2, (IMarginCloseAdapter(address(ad2)), address(0xdead)))
        );
    }
}
