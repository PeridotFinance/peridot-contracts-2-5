// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IsolatedMarginExecutorUpgradeable} from "../../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {RobinhoodMarginCloseAdapter, IRobinhoodOrderExecutor} from "../../contracts/margin/orders/RobinhoodMarginCloseAdapter.sol";

interface IOrdersProxyAdmin {
    function upgradeAndCall(address proxy, address implementation, bytes memory data) external payable;
    function owner() external view returns (address);
}

interface IOrdersMarket {
    function borrowBalanceStored(address) external view returns (uint256);
    function borrowBalanceCurrent(address) external returns (uint256);
}

interface IOrdersVault {
    function freeBalance(address, address) external view returns (uint256);
    function lockedBalance(address, address) external view returns (uint256);
}

interface IOrdersLiquidator {
    struct LiquidationParams {
        uint256 positionId;
        address recipient;
        uint256 minDebtUnderlying;
        uint256 minMarginUnderlying;
        bytes collateralToDebtSwapData;
        bytes debtToMarginSwapData;
    }

    function liquidate(LiquidationParams calldata params) external;
}

/// @notice The TP/SL close path against the DEPLOYED Robinhood margin stack at a fresh pin: the executor is upgraded on
/// the fork exactly as the timelock would (ProxyAdmin.upgradeAndCall with initializeOrderExecutor), the test contract
/// plays the registry, and the two live NVDA positions are closed through the adapter. Nothing is sent anywhere.
contract RobinhoodOrderCloseForkTest is Test {
    address constant EXECUTOR = 0x6A45Ae86bD992d250580d08D340A06A04D478977;
    address constant PROXY_ADMIN = 0x561fa1749F4B58A70d0d7d67e74e6fBeEba6F9B8;
    address constant TIMELOCK = 0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498;
    address constant ORACLE = 0x63150Eb3DDf71420dA0b09b66838aab398f7dEdD;
    address constant QUOTER = 0xeD3c353Ab237329BD53CC7eB24E66B370155FE6e;
    address constant CONFIG = 0x09F94fe0B79E000c8a26617c63E3427fdECB528b;
    address constant VAULT = 0x04D4A5555b7a37017A67B4D21A1Da5838de28B9e;
    address constant LIQUIDATOR = 0x1434CDa56d0Aeac4d5abC16F91ca76a8A989083c;
    address constant FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15; // RHNVDA / USD
    address constant PUSD = 0x55aEd0569c8f0D166D71facE57B57C2f2624a563;

    IsolatedMarginExecutorUpgradeable ex = IsolatedMarginExecutorUpgradeable(EXECUTOR);
    RobinhoodMarginCloseAdapter adapter;
    uint256[] active;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ORDERS_FORK_BLOCK"));
        vm.roll(vm.envUint("ORDERS_NATIVE_BLOCK")); // interest accrues on the native (L1-derived) block number
        assertEq(IOrdersProxyAdmin(PROXY_ADMIN).owner(), TIMELOCK);
        for (uint256 id = 1; id < ex.nextPositionId(); id++) {
            if (_pos(id).status == IsolatedMarginTypes.Status.ACTIVE) active.push(id);
        }
        emit log_named_uint("active positions", active.length);
    }

    function _pos(uint256 id) internal view returns (IsolatedMarginTypes.Position memory) {
        return IRobinhoodOrderExecutor(EXECUTOR).positions(id);
    }

    function _upgrade() internal {
        IsolatedMarginExecutorUpgradeable impl = new IsolatedMarginExecutorUpgradeable();
        adapter = new RobinhoodMarginCloseAdapter(EXECUTOR, address(this), ORACLE, QUOTER, CONFIG);
        vm.prank(TIMELOCK);
        IOrdersProxyAdmin(PROXY_ADMIN).upgradeAndCall(
            EXECUTOR, address(impl), abi.encodeCall(IsolatedMarginExecutorUpgradeable.initializeOrderExecutor, (address(adapter)))
        );
    }

    function _close(uint256 id, uint16 bps, uint16 slip) internal returns (uint256) {
        IsolatedMarginTypes.Position memory p = _pos(id);
        (uint256 price, bool ok) = adapter.oraclePriceE18(id);
        assertTrue(ok, "fresh oracle price");
        return adapter.closeFor(id, p.owner, bps, price, slip, "");
    }

    function _stampFeed() internal {
        (bool okc, bytes memory r) = FEED.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(okc);
        (, int256 answer,,,) = abi.decode(r, (uint80, int256, uint256, uint256, uint80));
        uint256 t = block.timestamp;
        vm.mockCall(FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(9), answer, t, t, uint80(9)));
    }

    // ------------------------------------------------------------------ upgrade
    function testUpgradePreservesEveryPositionAndSetsOnlyTheOrderExecutor() public {
        uint256 next = ex.nextPositionId();
        bytes32[] memory before = new bytes32[](next);
        for (uint256 id = 1; id < next; id++) before[id] = keccak256(abi.encode(_pos(id)));
        _upgrade();
        assertEq(ex.nextPositionId(), next);
        for (uint256 id = 1; id < next; id++) assertEq(keccak256(abi.encode(_pos(id))), before[id], "position unchanged");
        assertEq(ex.orderExecutor(), address(adapter));
        assertGt(active.length, 0, "a live position to test with");
    }

    function testOrderExecutorCanBeSetOnlyInsideTheUpgradeAndOnlyOnce() public {
        _upgrade();
        vm.expectRevert(); // not the proxy admin, and already initialized
        ex.initializeOrderExecutor(address(this));
        IsolatedMarginExecutorUpgradeable impl2 = new IsolatedMarginExecutorUpgradeable();
        vm.prank(TIMELOCK);
        vm.expectRevert(); // reinitializer(2) is spent
        IOrdersProxyAdmin(PROXY_ADMIN).upgradeAndCall(
            EXECUTOR, address(impl2), abi.encodeCall(IsolatedMarginExecutorUpgradeable.initializeOrderExecutor, (address(this)))
        );
        assertEq(ex.orderExecutor(), address(adapter));
    }

    // ------------------------------------------------------------------ authorization
    function testOnlyTheAdapterMayCloseForAnOwnerAndOnlyForTheRealOwner() public {
        _upgrade();
        uint256 id = active[0];
        IsolatedMarginTypes.Position memory p = _pos(id);
        IRobinhoodOrderExecutor.CloseParams memory cp = IRobinhoodOrderExecutor.CloseParams(id, 10_000, type(uint256).max, 0, 0, "", "");
        vm.expectRevert(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.ExecutorError.selector, uint8(60)));
        IRobinhoodOrderExecutor(EXECUTOR).closePositionFor(p.owner, cp);
        (uint256 price,) = adapter.oraclePriceE18(id);
        vm.prank(address(0xbad));
        vm.expectRevert(RobinhoodMarginCloseAdapter.NotRegistry.selector);
        adapter.closeFor(id, p.owner, 10_000, price, 100, "");
        vm.expectRevert(abi.encodeWithSelector(RobinhoodMarginCloseAdapter.InvalidClose.selector, uint8(3)));
        adapter.closeFor(id, address(0xbad), 10_000, price, 100, "");
        vm.expectRevert(RobinhoodMarginCloseAdapter.AdapterDataNotSupported.selector);
        adapter.closeFor(id, p.owner, 10_000, price, 100, hex"01");
        vm.expectRevert(abi.encodeWithSelector(RobinhoodMarginCloseAdapter.InvalidClose.selector, uint8(2)));
        adapter.closeFor(id, p.owner, 10_000, price, 301, "");
    }

    // ------------------------------------------------------------------ closes on the live positions
    function testFullCloseOfEachLivePositionReturnsMarginToTheOwnerAndRepaysAllDebt() public {
        _upgrade();
        for (uint256 i; i < active.length; i++) {
            uint256 id = active[i];
            IsolatedMarginTypes.Position memory p = _pos(id);
            uint256 free0 = IOrdersVault(VAULT).freeBalance(p.owner, p.marginPToken);
            uint256 returned = _close(id, 10_000, 100);
            assertEq(uint8(_pos(id).status), uint8(IsolatedMarginTypes.Status.CLOSED), "closed");
            assertEq(IOrdersMarket(p.debtPToken).borrowBalanceStored(p.account), 0, "all debt repaid, interest included");
            assertEq(IOrdersVault(VAULT).freeBalance(p.owner, p.marginPToken), free0 + returned, "proceeds to the owner");
            assertEq(IOrdersVault(VAULT).freeBalance(address(adapter), p.marginPToken), 0, "adapter holds nothing");
            assertEq(IOrdersVault(VAULT).freeBalance(address(this), p.marginPToken), 0, "registry holds nothing");
            emit log_named_uint("position", id);
            emit log_named_uint("  returned margin pTokens", returned);
        }
    }

    function testPartialCloseUsesTheClosePathsOwnPartialSupport() public {
        _upgrade();
        uint256 id = active[active.length - 1];
        IsolatedMarginTypes.Position memory p = _pos(id);
        uint256 debt0 = IOrdersMarket(p.debtPToken).borrowBalanceCurrent(p.account);
        uint256 locked0 = p.lockedMarginPTokens;
        _close(id, 5_000, 100);
        IsolatedMarginTypes.Position memory q = _pos(id);
        assertEq(uint8(q.status), uint8(IsolatedMarginTypes.Status.ACTIVE), "still open");
        uint256 debt1 = IOrdersMarket(p.debtPToken).borrowBalanceStored(p.account);
        if (debt0 > 0) assertApproxEqRel(debt1, debt0 / 2, 0.02e18, "about half the debt repaid");
        assertApproxEqRel(q.lockedMarginPTokens, locked0 / 2, 0.02e18, "about half the margin released");
    }

    function testAccruedInterestIsIncludedAfterAMonth() public {
        _upgrade();
        uint256 id = active[0];
        IsolatedMarginTypes.Position memory p = _pos(id);
        uint256 debt0 = IOrdersMarket(p.debtPToken).borrowBalanceStored(p.account);
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + 216_000); // about 30 days of native blocks at 12 s
        _stampFeed();
        uint256 debt1 = IOrdersMarket(p.debtPToken).borrowBalanceCurrent(p.account);
        if (debt0 > 0) assertGt(debt1, debt0, "interest accrued");
        _close(id, 10_000, 300);
        assertEq(IOrdersMarket(p.debtPToken).borrowBalanceStored(p.account), 0, "repaid including the accrued interest");
    }

    // ------------------------------------------------------------------ bounds and refusals
    function testSlippageFloorIsEnforcedByTheClosePathAndThePositionStays() public {
        _upgrade();
        uint256 id = active[0];
        bytes32 h = keccak256(abi.encode(_pos(id)));
        // Make the quoter promise twice the achievable output: the derived minimum cannot be met, so the swap must refuse.
        vm.mockCall(QUOTER, abi.encodeWithSignature("expectedOut(address,address,uint256)"), abi.encode(type(uint128).max));
        (uint256 price,) = adapter.oraclePriceE18(id);
        IsolatedMarginTypes.Position memory p = _pos(id);
        vm.expectRevert();
        adapter.closeFor(id, p.owner, 10_000, price, 100, "");
        assertEq(keccak256(abi.encode(_pos(id))), h, "position untouched");
    }

    function testStaleFeedRefusesAndThePositionStays() public {
        _upgrade();
        uint256 id = active[0];
        (uint256 price,) = adapter.oraclePriceE18(id);
        bytes32 h = keccak256(abi.encode(_pos(id)));
        vm.warp(block.timestamp + 13 hours); // beyond the guard's 12 h freshness bound, no new feed answer
        (uint256 stalePrice, bool ok) = adapter.oraclePriceE18(id);
        assertFalse(ok, "stale feed reported as unavailable");
        assertEq(stalePrice, 0);
        IsolatedMarginTypes.Position memory p = _pos(id);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodMarginCloseAdapter.InvalidClose.selector, uint8(6)));
        adapter.closeFor(id, p.owner, 10_000, price, 100, "");
        assertEq(keccak256(abi.encode(_pos(id))), h, "position untouched");
    }

    function testOracleRefusalOnAnyGuardFailureRefusesTheClose() public {
        _upgrade();
        uint256 id = active[0];
        (uint256 price,) = adapter.oraclePriceE18(id);
        // Any failure inside the guarded source (pause, incomplete round, disagreement) reaches the margin oracle as 0.
        vm.mockCallRevert(FEED, abi.encodeWithSignature("latestRoundData()"), "FEED_DOWN");
        (, bool ok) = adapter.oraclePriceE18(id);
        assertFalse(ok);
        IsolatedMarginTypes.Position memory p = _pos(id);
        vm.expectRevert(abi.encodeWithSelector(RobinhoodMarginCloseAdapter.InvalidClose.selector, uint8(6)));
        adapter.closeFor(id, p.owner, 10_000, price, 100, "");
    }

    // ------------------------------------------------------------------ liquidation independence
    function testLiquidationBehavesIdenticallyBeforeAndAfterTheUpgrade() public {
        uint256 id = active[0];
        IOrdersLiquidator.LiquidationParams memory lp = IOrdersLiquidator.LiquidationParams(id, address(this), 0, 0, "", "");
        uint256 snap = vm.snapshotState();
        (bool okBefore, bytes memory before) = LIQUIDATOR.call(abi.encodeCall(IOrdersLiquidator.liquidate, (lp)));
        vm.revertToState(snap);
        _upgrade();
        (bool okAfter, bytes memory afterRet) = LIQUIDATOR.call(abi.encodeCall(IOrdersLiquidator.liquidate, (lp)));
        assertEq(okAfter, okBefore, "same outcome");
        assertEq(keccak256(afterRet), keccak256(before), "same return or revert data");
        emit log_named_uint("healthy position: liquidation succeeded", okAfter ? 1 : 0);
    }
}
