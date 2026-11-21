// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PharaohDlmmShareOracle} from "../contracts/PharaohDlmmShareOracle.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {PToken} from "../contracts/PToken.sol";
import {PharaohBoostedDelegate} from "../contracts/boosted/PharaohBoostedDelegate.sol";
import {IMarginPriceOracle} from "../contracts/margin/interfaces/IMarginPriceOracle.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {PharaohTestAsset, PharaohTestVault} from "./mocks/PharaohBoostedMocks.sol";

/// @dev Stand-in for the live GuardedAvalanchePriceOracle: per-market prices, per-asset margin prices, switchable reverts.
contract DlmmTestGuardedBase is PriceOracle, IMarginPriceOracle {
    mapping(address => uint256) public underlyingPrices;
    mapping(address => uint256) public assetPrices;
    mapping(address => address) public assetOf;
    bool public revertAll;

    function setUnderlyingPrice(address pToken, uint256 p) external {
        underlyingPrices[pToken] = p;
    }

    function setAssetPrice(address asset, uint256 p) external {
        assetPrices[asset] = p;
    }

    function setMarketAsset(address pToken, address asset) external {
        assetOf[pToken] = asset;
    }

    function setRevertAll(bool v) external {
        revertAll = v;
    }

    function getUnderlyingPrice(PToken pToken) external view override returns (uint256) {
        require(!revertAll, "base reverts");
        return underlyingPrices[address(pToken)];
    }

    function getPrice(address asset) external view override returns (uint256) {
        require(!revertAll, "base reverts");
        return assetPrices[asset];
    }

    function marketAsset(address pToken) external view override returns (address) {
        require(!revertAll, "base reverts");
        return assetOf[pToken];
    }
}

contract DlmmTestController is MockPeridottroller {
    address public oracle;

    function setOracle(address o) external {
        oracle = o;
    }
}

contract PharaohDlmmShareOracleTest is Test {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant SEED_SHARES = 1_000_000; // 1 whole share (6 decimals), the same size as the vault's own dead seed

    PharaohTestAsset internal usdc;
    PharaohTestVault internal vault;
    DlmmTestGuardedBase internal base;
    DlmmTestController internal controller;
    MockInterestRateModel internal irm;
    PharaohBoostedDelegate internal implementation;
    PErc20Delegator internal market;
    PharaohDlmmShareOracle internal oracle;

    address internal constant OUTSIDER = address(0xBEEF);

    function setUp() external {
        vm.warp(10 days);
        usdc = new PharaohTestAsset("USD Coin", "USDC", 6);
        vault = new PharaohTestVault(IERC20(address(usdc)), "Peridot Pharaoh DLMM USDC/USDt", "pdlmm");
        base = new DlmmTestGuardedBase();
        controller = new DlmmTestController();
        irm = new MockInterestRateModel();

        base.setAssetPrice(address(usdc), 1e18);
        controller.setOracle(address(base));

        // the real vault is 17 USDC / 17,000,000 shares: the share price starts at exactly 1.0
        usdc.mint(address(this), 1_000e6);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, address(this));

        implementation = new PharaohBoostedDelegate();
        market = new PErc20Delegator(
            address(vault),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(irm)),
            2e14,
            "Peridot Boosted Pharaoh DLMM USDC/USDt",
            "bpPHAR-USDC",
            8,
            payable(address(this)), // the pToken admin (the Ledger on mainnet)
            address(implementation),
            abi.encode(address(vault), uint256(1_000_000))
        );
        oracle = new PharaohDlmmShareOracle(base, address(market));
    }

    // ------------------------------------------------------------------------------------------ wrapper: new market

    function testShareUsesCompoundScalingForSixDecimalShares() external view {
        // 1 share = 1.0 USDC = 1.0 USD: price mantissa 1e18 * 1e12
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), 1e30);
        assertEq(oracle.getShareUsdPrice(), 1e18);
        assertEq(oracle.vault(), address(vault));
        assertEq(oracle.vaultAsset(), address(usdc));
        assertEq(oracle.shareDecimals(), 6);
        assertEq(oracle.assetDecimals(), 6);
    }

    function testSharePriceTracksVaultNavAndBaseUsdcPrice() external {
        usdc.mint(address(vault), 100e6); // NAV +10%
        // convertToAssets floors: 1e6 * (1100e6 + 1) / (1000e6 + 1) = 1_100_000 - dust
        uint256 perShare = vault.convertToAssets(1e6);
        assertEq(oracle.getShareUsdPrice(), perShare * 1e12);
        base.setAssetPrice(address(usdc), 0.998e18); // base USDC price: 0.998
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), perShare * 0.998e18 * 1e12 / 1e6);
    }

    function testVaultReadFailureServesTheHaircutLastGoodLegNeverReverts() external {
        PToken m = PToken(address(market));
        vault.setConversionReverts(true); // the real vault's totalAssets reverts on a stale feed
        assertEq(oracle.getUnderlyingPrice(m), 0.97e30, "last good 1.000000 minus 3%");
        assertEq(oracle.getShareUsdPrice(), 0.97e18);
        vault.setConversionReverts(false);
        assertEq(oracle.getUnderlyingPrice(m), 1e30);

        // short return data, a zero answer: the vault cannot answer, same fallback
        vm.mockCall(address(vault), abi.encodeWithSignature("convertToAssets(uint256)"), abi.encode(uint256(0)));
        assertEq(oracle.getUnderlyingPrice(m), 0.97e30);
        vm.mockCall(address(vault), abi.encodeWithSignature("convertToAssets(uint256)"), hex"");
        assertEq(oracle.getUnderlyingPrice(m), 0.97e30);
        // an oversized answer is a broken vault, not an outage: no fallback
        vm.mockCall(
            address(vault), abi.encodeWithSignature("convertToAssets(uint256)"), abi.encode(uint256(type(uint128).max) + 1)
        );
        assertEq(oracle.getUnderlyingPrice(m), 0);
        vm.clearMockedCalls();
        assertEq(oracle.getUnderlyingPrice(m), 1e30);
    }

    function testFallbackUsesTheLiveUsdcPriceAndTheStoredLegOnly() external {
        PToken m = PToken(address(market));
        usdc.mint(address(vault), 100e6); // NAV +10%, then poked: stored = the live leg (within the +2% cap it is 1.02)
        vm.warp(oracle.lastGoodTime() + 1 hours);
        assertTrue(oracle.poke());
        assertEq(oracle.lastGoodAssetsPerShare(), 1_020_000, "upward step capped at 2%");
        vault.setConversionReverts(true);
        base.setAssetPrice(address(usdc), 0.998e18); // the live USDC price moved after the poke: the fallback follows it
        assertEq(oracle.getUnderlyingPrice(m), uint256(1_020_000) * 9700 / 10_000 * 0.998e18 * 1e12 / 1e6);
    }

    function testFallbackExpires24HoursAfterTheLastPokeAndPokeRenewsIt() external {
        PToken m = PToken(address(market));
        uint256 t0 = oracle.lastGoodTime(); // the constructor stored the leg at t0
        vault.setConversionReverts(true);
        vm.warp(t0 + 24 hours);
        assertEq(oracle.getUnderlyingPrice(m), 0.97e30, "still valid at exactly 24 h");
        vm.warp(t0 + 24 hours + 1);
        assertEq(oracle.getUnderlyingPrice(m), 0, "expired one second later");
        assertEq(oracle.getShareUsdPrice(), 0);

        vault.setConversionReverts(false);
        assertTrue(oracle.poke()); // stored value older than the window: replaced by the live value
        uint256 t1 = t0 + 24 hours + 1;
        assertEq(oracle.lastGoodTime(), t1);
        vault.setConversionReverts(true);
        assertEq(oracle.getUnderlyingPrice(m), 0.97e30);
        vm.warp(t1 + 24 hours);
        assertEq(oracle.getUnderlyingPrice(m), 0.97e30);
        vm.warp(t1 + 24 hours + 1);
        assertEq(oracle.getUnderlyingPrice(m), 0);
    }

    function testPokeWhileTheVaultCannotAnswerStoresNothing() external {
        vault.setConversionReverts(true);
        uint256 before_ = oracle.lastGoodTime();
        vm.warp(before_ + 5 hours);
        assertFalse(oracle.poke());
        assertEq(oracle.lastGoodTime(), before_);
        assertEq(oracle.lastGoodAssetsPerShare(), 1e6);
    }

    function testPokeBounds_downAtOnce_upOncePerHourAndCappedAt2Percent() external {
        // the vault leg falls 5%: stored at once (conservative), no waiting
        vm.prank(address(vault));
        usdc.transfer(address(0xD00D), 50e6);
        assertTrue(oracle.poke());
        uint256 down = oracle.lastGoodAssetsPerShare();
        assertLt(down, 0.96e6 + 100_000);
        assertLt(down, 1e6);

        // the leg recovers +30% (a glitch or a donation): an upward poke inside the hour is refused ...
        usdc.mint(address(vault), 300e6);
        assertFalse(oracle.poke(), "upward move inside POKE_UP_INTERVAL");
        assertEq(oracle.lastGoodAssetsPerShare(), down);
        // ... and later it is stored at most +2% per accepted poke
        vm.warp(oracle.lastGoodTime() + 1 hours);
        assertTrue(oracle.poke());
        assertEq(oracle.lastGoodAssetsPerShare(), down * 10_200 / 10_000);
        assertFalse(oracle.poke(), "a second poke in the same transaction/time cannot compound");
        assertEq(oracle.lastGoodAssetsPerShare(), down * 10_200 / 10_000);
    }

    function testPokeAfterTheWindowAcceptsTheLiveValueWhateverItIs() external {
        usdc.mint(address(vault), 1_000e6); // x2
        vm.warp(oracle.lastGoodTime() + 24 hours + 1);
        assertTrue(oracle.poke());
        assertApproxEqAbs(oracle.lastGoodAssetsPerShare(), 2e6, 1);
    }

    function testPokeIsPermissionlessAndOnlyEverStoresTheVaultsOwnAnswer() external {
        vm.prank(OUTSIDER);
        assertTrue(oracle.poke());
        // the stored leg can never exceed the live leg (the cap only lowers a live value)
        usdc.mint(address(vault), 500e6);
        vm.warp(oracle.lastGoodTime() + 2 hours);
        vm.prank(OUTSIDER);
        oracle.poke();
        assertLe(oracle.lastGoodAssetsPerShare(), vault.convertToAssets(1e6));
    }

    function testFallbackNeverCoversAnUnpricedUsdcOrABrokenVault() external {
        PToken m = PToken(address(market));
        vault.setConversionReverts(true);
        base.setAssetPrice(address(usdc), 0); // the USDC feed is stale too: pUSDC is unpriced by the base oracle as well
        assertEq(oracle.getUnderlyingPrice(m), 0);
        base.setAssetPrice(address(usdc), 1e18);
        assertEq(oracle.getUnderlyingPrice(m), 0.97e30);
        vm.mockCall(address(vault), abi.encodeWithSignature("asset()"), abi.encode(address(0x1234))); // another asset
        assertEq(oracle.getUnderlyingPrice(m), 0);
        vm.mockCallRevert(address(vault), abi.encodeWithSignature("asset()"), "x"); // unreadable asset
        assertEq(oracle.getUnderlyingPrice(m), 0);
        vm.clearMockedCalls();
        base.setRevertAll(true);
        assertEq(oracle.getUnderlyingPrice(m), 0, "the share path never reverts");
    }

    function testIdentityForOtherMarketsIsUnchangedDuringTheFallback() external {
        address other = address(0x7777);
        base.setUnderlyingPrice(other, 123e18);
        vault.setConversionReverts(true);
        assertEq(oracle.getUnderlyingPrice(PToken(other)), 123e18);
    }

    function testShareStateReportsTheFallback() external {
        uint256 t0 = oracle.lastGoodTime();
        (uint256 live, uint256 stored, uint64 at, bool fb, uint256 left) = oracle.shareState();
        assertEq(live, 1e6);
        assertEq(stored, 1e6);
        assertEq(at, t0);
        assertFalse(fb);
        assertEq(left, 24 hours);

        vault.setConversionReverts(true);
        vm.warp(t0 + 10 hours);
        (live, stored, at, fb, left) = oracle.shareState();
        assertEq(live, 0);
        assertTrue(fb);
        assertEq(left, 14 hours);
        vm.warp(t0 + 24 hours);
        (,,, fb, left) = oracle.shareState();
        assertTrue(fb, "valid at exactly 24 h, like the price");
        assertEq(left, 0);
        vm.warp(t0 + 24 hours + 1);
        (,,, fb, left) = oracle.shareState();
        assertFalse(fb);
        assertEq(left, 0);
    }

    function testConstructorSeedsTheStoredLegAndEmits() external {
        vm.recordLogs();
        PharaohDlmmShareOracle fresh = new PharaohDlmmShareOracle(base, address(market));
        assertEq(fresh.lastGoodAssetsPerShare(), 1e6);
        assertEq(fresh.lastGoodTime(), block.timestamp);
        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(fresh.FALLBACK_HAIRCUT_BPS(), 300);
        assertEq(fresh.FALLBACK_WINDOW(), 24 hours);
        assertEq(fresh.POKE_MAX_UP_BPS(), 200);
        assertEq(fresh.POKE_UP_INTERVAL(), 1 hours);
    }

    function testShareFailsClosedWhenAssetPriceOrVaultAssetChanges() external {
        PToken m = PToken(address(market));
        base.setAssetPrice(address(usdc), 0); // stale base USDC feed
        assertEq(oracle.getUnderlyingPrice(m), 0);
        base.setAssetPrice(address(usdc), 1e18);
        assertEq(oracle.getUnderlyingPrice(m), 1e30);

        base.setRevertAll(true); // the base oracle itself reverts for getPrice
        assertEq(oracle.getUnderlyingPrice(m), 0, "share path never reverts");
        base.setRevertAll(false);

        vm.mockCall(address(vault), abi.encodeWithSignature("asset()"), abi.encode(address(0x1234))); // vault upgraded to another asset
        assertEq(oracle.getUnderlyingPrice(m), 0);
        vm.mockCallRevert(address(vault), abi.encodeWithSignature("asset()"), "x");
        assertEq(oracle.getUnderlyingPrice(m), 0);
        vm.clearMockedCalls();
        assertEq(oracle.getUnderlyingPrice(m), 1e30);
    }

    function testShareFailsClosedOnOversizedBasePrice() external {
        base.setAssetPrice(address(usdc), uint256(type(uint128).max) + 1);
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), 0);
    }

    // --------------------------------------------------------------------------- wrapper: identity for other markets

    function testIdentityForExistingMarketsIncludingZeroAndRevert() external {
        address pWavax = address(0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1); // no code here: the base is a mock keyed by address
        address pUsdc = address(0x0f7849CD9E54ffb027aacaEec82007cca9470098);
        base.setUnderlyingPrice(pWavax, 21.5e18);
        base.setUnderlyingPrice(pUsdc, 1e30);
        assertEq(oracle.getUnderlyingPrice(PToken(pWavax)), 21.5e18);
        assertEq(oracle.getUnderlyingPrice(PToken(pUsdc)), 1e30);

        // zero ("price unavailable") is passed through as zero
        base.setUnderlyingPrice(pWavax, 0);
        assertEq(oracle.getUnderlyingPrice(PToken(pWavax)), 0);

        // a base revert is the wrapper's revert (same behaviour as the old oracle)
        base.setRevertAll(true);
        vm.expectRevert("base reverts");
        oracle.getUnderlyingPrice(PToken(pUsdc));
        base.setRevertAll(false);

        // a pToken address with no code is not special-cased (the old wrapper would have reverted on the underlying() probe)
        assertEq(oracle.getUnderlyingPrice(PToken(address(0xdead0001))), 0);
    }

    function testFuzzIdentityEqualsBaseForEveryOtherPToken(address pToken, uint256 price) external {
        vm.assume(pToken != address(market));
        base.setUnderlyingPrice(pToken, price);
        assertEq(oracle.getUnderlyingPrice(PToken(pToken)), price);
        assertEq(oracle.getUnderlyingPrice(PToken(pToken)), base.getUnderlyingPrice(PToken(pToken)));
    }

    function testMarginSurfaceIsForwardedVerbatim() external {
        address wavax = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
        address pWavax = address(0x12f1F4Fc057a76f473B781ce2Fa88E55ef8581B1);
        base.setAssetPrice(wavax, 21.5e18);
        base.setMarketAsset(pWavax, wavax);

        assertEq(oracle.getPrice(wavax), 21.5e18);
        assertEq(oracle.getPrice(address(usdc)), 1e18);
        assertEq(oracle.getPrice(address(vault)), 0, "the share market is not registered as a margin asset");
        assertEq(oracle.marketAsset(pWavax), wavax);
        assertEq(oracle.marketAsset(address(market)), address(0), "the share market is not a margin market");

        base.setRevertAll(true);
        vm.expectRevert("base reverts");
        oracle.getPrice(wavax);
        vm.expectRevert("base reverts");
        oracle.marketAsset(pWavax);
    }

    function testWrapperHasNoOwnerOrRegistry() external view {
        // no owner, no setter: the only state-changing function is the permissionless, bounded poke() (see the poke tests)
        assertEq(address(oracle.baseOracle()), address(base));
        assertEq(oracle.market(), address(market));
        assertTrue(oracle.isPriceOracle());
    }

    // ---------------------------------------------------------------------------------- wrapper: construction pins

    function testConstructorRejectsBadMarketOrBaseAndAllowsReplacement() external {
        // a replacement wrapper must stay deployable while the controller already points at the first wrapper
        controller.setOracle(address(oracle));
        PharaohDlmmShareOracle replacement = new PharaohDlmmShareOracle(base, address(market));
        assertEq(replacement.getUnderlyingPrice(PToken(address(market))), oracle.getUnderlyingPrice(PToken(address(market))));
        controller.setOracle(address(base));

        vm.expectRevert(); // not a pToken: the isPToken() probe has no answer
        new PharaohDlmmShareOracle(base, address(vault));
        vm.expectRevert(PharaohDlmmShareOracle.PharaohDlmmOracle__InvalidConfiguration.selector);
        new PharaohDlmmShareOracle(base, address(0xABCD)); // no code
        vm.expectRevert(PharaohDlmmShareOracle.PharaohDlmmOracle__InvalidConfiguration.selector);
        new PharaohDlmmShareOracle(PriceOracle(address(0xABCD)), address(market));
    }

    function testConstructorRejectsUnavailablePrices() external {
        base.setAssetPrice(address(usdc), 0);
        vm.expectRevert(PharaohDlmmShareOracle.PharaohDlmmOracle__InvalidConfiguration.selector);
        new PharaohDlmmShareOracle(base, address(market));
        base.setAssetPrice(address(usdc), 1e18);
        vault.setConversionReverts(true);
        vm.expectRevert(PharaohDlmmShareOracle.PharaohDlmmOracle__InvalidConfiguration.selector);
        new PharaohDlmmShareOracle(base, address(market));
    }

    // ---------------------------------------------------------------------------------------------- delegate pinning

    function testDelegatePinsVaultAndStartsWithFlashLoansPaused() external view {
        PharaohBoostedDelegate d = PharaohBoostedDelegate(address(market));
        assertEq(address(d.pharaohVault()), address(vault));
        assertEq(d.minimumVaultSupplyAtListing(), 1_000_000);
        assertEq(market.underlying(), address(vault));
        assertTrue(market.flashLoansPaused());
        assertEq(market.maxFlashLoan(address(vault)), 0);
        assertEq(market.admin(), address(this));
        assertEq(market.pendingAdmin(), address(0));
    }

    function testDelegateRejectsMismatchedOrUndersizedOrBrokenVault() external {
        // pinned vault differs from the underlying
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InvalidConfiguration.selector);
        _market(address(vault), abi.encode(address(0xCAFE), uint256(1)));
        // minimum supply above the vault's supply
        bytes memory tooBig = abi.encode(address(vault), vault.totalSupply() + 1);
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InsufficientVaultSeed.selector);
        _market(address(vault), tooBig);
        // zero minimum / empty data
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InvalidConfiguration.selector);
        _market(address(vault), abi.encode(address(vault), uint256(0)));
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InvalidConfiguration.selector);
        _market(address(vault), "");
        // the vault cannot price a share while a feed is bad: the listing build fails closed
        vault.setConversionReverts(true);
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InvalidVault.selector);
        _market(address(vault), abi.encode(address(vault), uint256(1)));
    }

    // ------------------------------------------------------------------------------------- delegate: seed-first mint

    function testOnlyAdminCanMintWhileSupplyIsZero() external {
        vault.transfer(OUTSIDER, 10e6);
        vm.startPrank(OUTSIDER);
        vault.approve(address(market), type(uint256).max);
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__SeedPending.selector);
        market.mint(1);
        vm.stopPrank();
        assertEq(market.totalSupply(), 0);

        // the admin seeds, then burns the pTokens to the dead address
        vault.approve(address(market), SEED_SHARES);
        assertEq(market.mint(SEED_SHARES), 0);
        uint256 seedPTokens = market.balanceOf(address(this));
        assertEq(seedPTokens, SEED_SHARES * 5000); // 2e14 initial rate: 1 share-wei = 5000 pToken-wei
        assertTrue(market.transfer(DEAD, seedPTokens));
        assertEq(market.balanceOf(DEAD), 5_000_000_000);
        assertEq(market.balanceOf(address(this)), 0);

        // from now on anybody can mint
        vm.prank(OUTSIDER);
        assertEq(market.mint(1e6), 0);
        assertEq(market.balanceOf(OUTSIDER), 5_000_000_000);
    }

    function testMintAndRedeemDoNotNeedTheVaultPriceOrTheVaultAtAll() external {
        vault.approve(address(market), type(uint256).max);
        market.mint(SEED_SHARES);
        market.transfer(DEAD, market.balanceOf(address(this)));
        vault.setConversionReverts(true); // the vault's NAV is unavailable (stale feed); share transfers still work
        assertEq(market.mint(50e6), 0);
        assertEq(market.redeemUnderlying(50e6), 0);
        assertEq(vault.balanceOf(address(market)), SEED_SHARES);
    }

    // ----------------------------------------------------------------------------------------- inflation / donation

    function testDonationAfterTheSeedCannotHarmALaterSupplierMaterially() external {
        vault.approve(address(market), type(uint256).max);
        market.mint(SEED_SHARES);
        market.transfer(DEAD, market.balanceOf(address(this)));

        // attacker: 1 share-wei minted, then donates 100 whole shares straight to the pToken
        address attacker = address(0xA77AC);
        vault.transfer(attacker, 150e6);
        vm.startPrank(attacker);
        vault.approve(address(market), type(uint256).max);
        market.mint(1);
        vault.transfer(address(market), 100e6);
        vm.stopPrank();
        uint256 attackerTokens = market.balanceOf(attacker);

        // victim supplies one whole share
        address victim = address(0x71C71);
        vault.transfer(victim, 5e6);
        vm.startPrank(victim);
        vault.approve(address(market), type(uint256).max);
        market.mint(1e6);
        vm.stopPrank();

        uint256 rate = market.exchangeRateStored();
        uint256 victimValue = market.balanceOf(victim) * rate / 1e18;
        // the loss is bounded by ONE pToken-wei of the (inflated) rate, never by the victim's deposit
        assertGe(victimValue + rate / 1e18 + 1, 1e6);
        // the attacker's claim is a rounding speck of what the dead seed now owns: the donation is gone
        uint256 attackerValue = attackerTokens * rate / 1e18;
        assertLt(attackerValue, 1_000);
    }

    // ------------------------------------------------------------------------------------------------------- helpers

    function _market(address underlying_, bytes memory data) private returns (PErc20Delegator) {
        return new PErc20Delegator(
            underlying_,
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(irm)),
            2e14,
            "x",
            "x",
            8,
            payable(address(this)),
            address(implementation),
            data
        );
    }
}
