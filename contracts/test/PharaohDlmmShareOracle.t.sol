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

    function testShareFailsClosedWithoutRevertingWhenVaultPricingFails() external {
        PToken m = PToken(address(market));
        vault.setConversionReverts(true); // the real vault's totalAssets reverts on a stale feed
        assertEq(oracle.getUnderlyingPrice(m), 0);
        assertEq(oracle.getShareUsdPrice(), 0);
        vault.setConversionReverts(false);
        assertEq(oracle.getUnderlyingPrice(m), 1e30);

        vm.mockCall(address(vault), abi.encodeWithSignature("convertToAssets(uint256)"), abi.encode(uint256(0)));
        assertEq(oracle.getUnderlyingPrice(m), 0);
        vm.mockCall(address(vault), abi.encodeWithSignature("convertToAssets(uint256)"), hex""); // short return data
        assertEq(oracle.getUnderlyingPrice(m), 0);
        vm.mockCall(
            address(vault), abi.encodeWithSignature("convertToAssets(uint256)"), abi.encode(uint256(type(uint128).max) + 1)
        );
        assertEq(oracle.getUnderlyingPrice(m), 0);
        vm.clearMockedCalls();
        assertEq(oracle.getUnderlyingPrice(m), 1e30);
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
        // the only state-changing surface is none: every public symbol is a view / immutable
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
