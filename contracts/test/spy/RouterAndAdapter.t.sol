// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MarginPriceSourceRouter} from "../../contracts/margin/spy/MarginPriceSourceRouter.sol";
import {RobinhoodLendingPriceAdapter3} from "../../contracts/margin/spy/RobinhoodLendingPriceAdapter3.sol";
import {MockPriceSource, MockMarket, MockDecimalsToken} from "./SpyMocks.sol";

contract MarginPriceSourceRouterTest is Test {
    address constant NVDA = address(0x1111);
    address constant SPY = address(0x2222);
    address constant USDG = address(0x3333);
    MockPriceSource primary;
    MockPriceSource secondary;
    MarginPriceSourceRouter router;

    function setUp() public {
        primary = new MockPriceSource();
        secondary = new MockPriceSource();
        router = new MarginPriceSourceRouter(address(primary), address(secondary), SPY, USDG);
        primary.set(NVDA, 160e18);
        primary.set(USDG, 1e18);
        secondary.set(SPY, 748e18);
        secondary.set(USDG, 1e18);
    }

    function testEachAssetReadsItsOwnSource() public view {
        assertEq(router.assetPrices(NVDA), 160e18);
        assertEq(router.assetPrices(SPY), 748e18);
        assertEq(router.assetPrices(USDG), 1e18);
    }

    function testSecondaryAssetNeverReadsPrimary() public {
        primary.set(SPY, 1);
        secondary.set(SPY, 0);
        assertEq(router.assetPrices(SPY), 0);
        secondary.setReverts(SPY, true);
        assertEq(router.assetPrices(SPY), 0);
    }

    function testPrimaryAssetsNeverFallBack() public {
        primary.set(NVDA, 0);
        secondary.set(NVDA, 999e18);
        assertEq(router.assetPrices(NVDA), 0, "stale NVDA must stay unpriced");
        primary.setReverts(NVDA, true);
        assertEq(router.assetPrices(NVDA), 0);
    }

    function testSharedAssetPrefersPrimaryAndFallsBackOnlyOnZeroOrRevert() public {
        primary.set(USDG, 2e18);
        secondary.set(USDG, 3e18);
        assertEq(router.assetPrices(USDG), 2e18);
        primary.set(USDG, 0);
        assertEq(router.assetPrices(USDG), 3e18);
        primary.set(USDG, 2e18);
        primary.setReverts(USDG, true);
        assertEq(router.assetPrices(USDG), 3e18);
        secondary.setReverts(USDG, true);
        assertEq(router.assetPrices(USDG), 0);
    }

    function testFuzzNonSecondaryNonSharedAssetEqualsPrimary(address asset, uint256 p, uint256 q) public {
        vm.assume(asset != SPY && asset != USDG);
        primary.set(asset, p);
        secondary.set(asset, q);
        assertEq(router.assetPrices(asset), p);
    }

    function testConstructorRejectsBadConfiguration() public {
        vm.expectRevert(MarginPriceSourceRouter.InvalidConfiguration.selector);
        new MarginPriceSourceRouter(address(0x99), address(secondary), SPY, USDG);
        vm.expectRevert(MarginPriceSourceRouter.InvalidConfiguration.selector);
        new MarginPriceSourceRouter(address(primary), address(0x99), SPY, USDG);
        vm.expectRevert(MarginPriceSourceRouter.InvalidConfiguration.selector);
        new MarginPriceSourceRouter(address(primary), address(primary), SPY, USDG);
        vm.expectRevert(MarginPriceSourceRouter.InvalidConfiguration.selector);
        new MarginPriceSourceRouter(address(primary), address(secondary), address(0), USDG);
        vm.expectRevert(MarginPriceSourceRouter.InvalidConfiguration.selector);
        new MarginPriceSourceRouter(address(primary), address(secondary), SPY, address(0));
        vm.expectRevert(MarginPriceSourceRouter.InvalidConfiguration.selector);
        new MarginPriceSourceRouter(address(primary), address(secondary), SPY, SPY);
    }
}

contract RobinhoodLendingPriceAdapter3Test is Test {
    MockPriceSource source;
    MockDecimalsToken nvda;
    MockDecimalsToken spy;
    MockDecimalsToken usdg;
    MockMarket pNvda;
    MockMarket pSpy;
    MockMarket pUsdg;
    RobinhoodLendingPriceAdapter3 adapter;

    function setUp() public {
        source = new MockPriceSource();
        nvda = new MockDecimalsToken(18);
        spy = new MockDecimalsToken(18);
        usdg = new MockDecimalsToken(6);
        pNvda = new MockMarket(address(nvda));
        pSpy = new MockMarket(address(spy));
        pUsdg = new MockMarket(address(usdg));
        adapter = new RobinhoodLendingPriceAdapter3(address(source), address(pNvda), address(pUsdg), address(pSpy));
        source.set(address(nvda), 160e18);
        source.set(address(spy), 748e18);
        source.set(address(usdg), 1e18);
    }

    function testCompoundScaleForEachMarket() public view {
        assertEq(adapter.getUnderlyingPrice(address(pNvda)), 160e18);
        assertEq(adapter.getUnderlyingPrice(address(pSpy)), 748e18);
        assertEq(adapter.getUnderlyingPrice(address(pUsdg)), 1e30);
        assertEq(adapter.assetPrices(address(nvda)), 160e18);
        assertEq(adapter.assetPrices(address(spy)), 748e18);
        assertEq(adapter.assetPrices(address(usdg)), 1e18);
        assertTrue(adapter.isPriceOracle());
    }

    function testUnknownMarketAndAssetRevert() public {
        vm.expectRevert(RobinhoodLendingPriceAdapter3.UnsupportedMarket.selector);
        adapter.getUnderlyingPrice(address(0x1234));
        vm.expectRevert(RobinhoodLendingPriceAdapter3.UnsupportedAsset.selector);
        adapter.assetPrices(address(0x1234));
    }

    function testZeroSourcePricePassesThroughAsZero() public {
        source.set(address(spy), 0);
        assertEq(adapter.getUnderlyingPrice(address(pSpy)), 0);
    }

    function testOverflowingDollarPriceReverts() public {
        source.set(address(usdg), type(uint256).max / 1e11);
        vm.expectRevert();
        adapter.getUnderlyingPrice(address(pUsdg));
    }

    function testFuzzPricesPassThrough(uint128 a, uint128 b, uint128 c) public {
        source.set(address(nvda), a);
        source.set(address(spy), b);
        source.set(address(usdg), c);
        assertEq(adapter.getUnderlyingPrice(address(pNvda)), a);
        assertEq(adapter.getUnderlyingPrice(address(pSpy)), b);
        assertEq(adapter.getUnderlyingPrice(address(pUsdg)), uint256(c) * 1e12);
    }

    function testConstructorRejectsBadConfiguration() public {
        address s = address(source);
        vm.expectRevert(RobinhoodLendingPriceAdapter3.InvalidConfiguration.selector);
        new RobinhoodLendingPriceAdapter3(address(0x99), address(pNvda), address(pUsdg), address(pSpy));
        vm.expectRevert(RobinhoodLendingPriceAdapter3.InvalidConfiguration.selector);
        new RobinhoodLendingPriceAdapter3(s, address(pNvda), address(pNvda), address(pSpy));
        vm.expectRevert(RobinhoodLendingPriceAdapter3.InvalidConfiguration.selector);
        new RobinhoodLendingPriceAdapter3(s, address(pNvda), address(pUsdg), address(pUsdg));
        vm.expectRevert(RobinhoodLendingPriceAdapter3.InvalidConfiguration.selector);
        new RobinhoodLendingPriceAdapter3(s, address(pNvda), address(pUsdg), address(pNvda));
        MockMarket pSpy2 = new MockMarket(address(nvda)); // same underlying as the first stock
        vm.expectRevert(RobinhoodLendingPriceAdapter3.InvalidConfiguration.selector);
        new RobinhoodLendingPriceAdapter3(s, address(pNvda), address(pUsdg), address(pSpy2));
        MockMarket p6 = new MockMarket(address(new MockDecimalsToken(6)));
        vm.expectRevert(RobinhoodLendingPriceAdapter3.InvalidConfiguration.selector);
        new RobinhoodLendingPriceAdapter3(s, address(pNvda), address(pUsdg), address(p6));
        MockMarket pd18 = new MockMarket(address(new MockDecimalsToken(18)));
        vm.expectRevert(RobinhoodLendingPriceAdapter3.InvalidConfiguration.selector);
        new RobinhoodLendingPriceAdapter3(s, address(pNvda), address(pd18), address(pSpy));
    }
}
