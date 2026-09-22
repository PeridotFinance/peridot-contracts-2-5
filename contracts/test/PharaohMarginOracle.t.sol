// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PharaohMarginOracle} from "../contracts/margin/PharaohMarginOracle.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {PharaohVaultShareOracle} from "../contracts/PharaohVaultShareOracle.sol";
import {
    PharaohTestAsset,
    PharaohTestBaseOracle,
    PharaohTestFeed,
    PharaohTestMarket,
    PharaohTestVault
} from "./mocks/PharaohBoostedMocks.sol";

contract PharaohMarginOracleTest is Test {
    PharaohTestAsset internal usd;
    PharaohTestAsset internal wavax;
    PharaohTestVault internal uVault;
    PharaohTestVault internal aVault;
    PharaohTestMarket internal pUsd;
    PharaohTestMarket internal pAvax;
    PharaohTestMarket internal pUVault;
    PharaohTestMarket internal pAVault;
    PharaohTestFeed internal usdFeed;
    PharaohTestFeed internal avaxFeed;
    AvalanchePriceOracle internal base;
    PharaohVaultShareOracle internal shares;
    PharaohMarginOracle internal oracle;

    function setUp() public {
        vm.warp(10 days);
        usd = new PharaohTestAsset("USDC", "USDC", 6);
        wavax = new PharaohTestAsset("WAVAX", "WAVAX", 18);
        uVault = new PharaohTestVault(usd, "USD vault", "uv");
        aVault = new PharaohTestVault(wavax, "AVAX vault", "av");
        usd.mint(address(this), 1000e6);
        wavax.mint(address(this), 1000e18);
        usd.approve(address(uVault), 1000e6);
        wavax.approve(address(aVault), 1000e18);
        uVault.deposit(1000e6, address(this));
        aVault.deposit(1000e18, address(this));
        usdFeed = new PharaohTestFeed(8, 1e8);
        avaxFeed = new PharaohTestFeed(8, 10e8);
        base = new AvalanchePriceOracle(address(this));
        base.configureFeed(address(usd), address(usdFeed), 1 hours);
        base.configureFeed(address(wavax), address(avaxFeed), 1 hours);
        pUsd = new PharaohTestMarket(address(usd));
        pAvax = new PharaohTestMarket(address(wavax));
        pUVault = new PharaohTestMarket(address(uVault));
        pAVault = new PharaohTestMarket(address(aVault));
        base.registerMarket(address(pUsd), address(usd));
        base.registerMarket(address(pAvax), address(wavax));
        shares = new PharaohVaultShareOracle(address(this), new PharaohTestBaseOracle());
        shares.registerVault(uVault, usdFeed, 1 hours);
        shares.registerVault(aVault, avaxFeed, 1 hours);
        oracle =
            new PharaohMarginOracle(base, shares, address(pUVault), address(uVault), address(pAVault), address(aVault));
    }

    function testMapsCollateralToSharesNotBaseAssets() public view {
        assertEq(oracle.marketAsset(address(pUVault)), address(uVault));
        assertEq(oracle.marketAsset(address(pAVault)), address(aVault));
        assertEq(oracle.marketAsset(address(pUsd)), address(usd));
        assertEq(oracle.marketAsset(address(pAvax)), address(wavax));
    }

    function testPricesWholeSharesInUsdWadForBothDecimals() public view {
        assertEq(oracle.getPrice(address(uVault)), 1e18);
        assertEq(oracle.getPrice(address(aVault)), 10e18);
        assertEq(oracle.getPrice(address(usd)), 1e18);
        assertEq(oracle.getPrice(address(wavax)), 10e18);
    }

    function testShareYieldDoesNotChangeUnderlyingIdentity() public {
        usd.mint(address(uVault), 100e6);
        assertGt(oracle.getPrice(address(uVault)), 1e18);
        assertEq(oracle.getPrice(address(usd)), 1e18);
        assertEq(oracle.marketAsset(address(pUVault)), address(uVault));
    }

    function testStaleSharePriceCannotFallBackToEmergencyBasePrice() public {
        vm.warp(vm.getBlockTimestamp() + 3601);
        base.setEmergencyPrice(address(uVault), 5e18, uint64(vm.getBlockTimestamp() + 60));
        assertEq(oracle.getPrice(address(uVault)), 0);
        assertEq(oracle.getPrice(address(aVault)), 0);
    }

    function testUnavailableVaultValuationFailsClosed() public {
        uVault.setConversionReverts(true);
        assertEq(oracle.getPrice(address(uVault)), 0);
        assertEq(oracle.getPrice(address(aVault)), 10e18);
    }

    function testRemovedShareConfigDoesNotBecomePlainAssetPrice() public {
        shares.removeVault(address(uVault));
        assertEq(oracle.getPrice(address(uVault)), 0);
    }

    function testUnknownMarketAndAssetAreUnavailable() public view {
        assertEq(oracle.marketAsset(address(0xBAD)), address(0));
        assertEq(oracle.getPrice(address(0xBAD)), 0);
    }

    function testRejectsMarketWhoseUnderlyingIsNotPinnedVault() public {
        vm.expectRevert(PharaohMarginOracle.InvalidConfiguration.selector);
        new PharaohMarginOracle(base, shares, address(pUsd), address(uVault), address(pAVault), address(aVault));
    }

    function testRejectsUnpricedShareConfiguration() public {
        shares.removeVault(address(uVault));
        vm.expectRevert(PharaohMarginOracle.InvalidConfiguration.selector);
        new PharaohMarginOracle(base, shares, address(pUVault), address(uVault), address(pAVault), address(aVault));
    }
}
