// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {PharaohVaultShareOracle} from "../contracts/PharaohVaultShareOracle.sol";
import {PToken} from "../contracts/PToken.sol";
import {PharaohBoostedDelegate} from "../contracts/boosted/PharaohBoostedDelegate.sol";
import {MockInterestRateModel} from "./MockInterestRateModel.sol";
import {MockPeridottroller} from "./MockPeridottroller.sol";
import {
    PharaohTestAsset,
    PharaohTestBaseOracle,
    PharaohTestFeed,
    PharaohTestMarket,
    PharaohTestVault
} from "./mocks/PharaohBoostedMocks.sol";

contract PharaohBoostedAvalancheTest is Test {
    PharaohTestAsset private asset;
    PharaohTestVault private vault;
    PharaohTestFeed private feed;
    PharaohTestBaseOracle private baseOracle;
    PharaohVaultShareOracle private oracle;
    MockPeridottroller private controller;
    MockInterestRateModel private interestRateModel;
    PharaohBoostedDelegate private implementation;
    PErc20Delegator private market;

    function setUp() external {
        vm.warp(10 days);
        asset = new PharaohTestAsset("USD Coin", "USDC", 6);
        vault = new PharaohTestVault(IERC20(address(asset)), "Pharaoh USDC Vault", "pPHAR-USDC");
        feed = new PharaohTestFeed(8, 99_900_000);
        baseOracle = new PharaohTestBaseOracle();
        oracle = new PharaohVaultShareOracle(address(this), baseOracle);
        controller = new MockPeridottroller();
        interestRateModel = new MockInterestRateModel();

        asset.mint(address(this), 1_000e6);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(1_000e6, address(this));

        implementation = new PharaohBoostedDelegate();
        market = _deployMarket(vault, 1);
        oracle.registerVault(vault, feed, 1 hours);
    }

    function testDelegatePinsTheVaultShareAsUnderlying() external view {
        PharaohBoostedDelegate delegate = PharaohBoostedDelegate(address(market));
        assertEq(market.underlying(), address(vault));
        assertEq(address(delegate.pharaohVault()), address(vault));
        assertEq(delegate.vaultAsset(), address(asset));
        assertEq(delegate.minimumVaultSupplyAtListing(), 1);
        assertEq(delegate.vaultAssetsPerWholeShare(), 1e6);
    }

    function testMarketMintsAndRedeemsVaultSharesWithoutEnteringTheStrategy() external {
        uint256 suppliedShares = 100e6;
        uint256 vaultSupplyBefore = vault.totalSupply();
        uint256 vaultAssetsBefore = vault.totalAssets();

        vault.approve(address(market), suppliedShares);
        assertEq(market.mint(suppliedShares), 0);
        assertEq(vault.balanceOf(address(market)), suppliedShares);
        assertEq(vault.totalSupply(), vaultSupplyBefore);
        assertEq(vault.totalAssets(), vaultAssetsBefore);

        assertEq(market.redeemUnderlying(suppliedShares), 0);
        assertEq(vault.balanceOf(address(market)), 0);
        assertEq(vault.totalSupply(), vaultSupplyBefore);
        assertEq(vault.totalAssets(), vaultAssetsBefore);
    }

    function testOracleUsesCompoundScalingForSixDecimalShares() external view {
        uint256 wholeShareUsd18 = 999e15;
        assertEq(oracle.getShareUsdPrice(address(vault)), wholeShareUsd18);
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), wholeShareUsd18 * 1e12);
    }

    function testOracleDelegatesUnknownMarketsToBaseOracle() external {
        PharaohTestMarket unknown = new PharaohTestMarket(address(asset));
        baseOracle.setPrice(address(unknown), 123e18);
        assertEq(oracle.getUnderlyingPrice(PToken(address(unknown))), 123e18);
    }

    function testOracleFailsClosedOnStaleFeed() external {
        feed.setRound(1e8, block.timestamp - 2 hours, 2, 2);
        assertEq(oracle.getShareUsdPrice(address(vault)), 0);
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), 0);
    }

    function testOracleFailsClosedOnInvalidRoundOrFeedRevert() external {
        feed.setRound(1e8, block.timestamp, 2, 1);
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), 0);

        feed.setRound(1e8, block.timestamp, 3, 3);
        feed.setReadReverts(true);
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), 0);
    }

    function testOracleFailsClosedOnOversizedValuation() external {
        feed.setRound(type(int256).max, block.timestamp, 2, 2);
        assertEq(oracle.getShareUsdPrice(address(vault)), 0);
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), 0);
    }

    function testOracleFailsClosedOnVaultValuationOutage() external {
        vault.setConversionReverts(true);
        assertEq(oracle.getShareUsdPrice(address(vault)), 0);
        assertEq(oracle.getUnderlyingPrice(PToken(address(market))), 0);
    }

    function testDelegateRejectsDifferentVaultThanMarketUnderlying() external {
        PharaohTestVault otherVault = new PharaohTestVault(IERC20(address(asset)), "Other", "OTHER");
        asset.mint(address(this), 1e6);
        asset.approve(address(otherVault), 1e6);
        otherVault.deposit(1e6, address(this));

        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InvalidConfiguration.selector);
        new PErc20Delegator(
            address(vault),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(interestRateModel)),
            2e14,
            "Invalid Pharaoh Market",
            "invalidPHAR",
            8,
            payable(address(this)),
            address(implementation),
            abi.encode(address(otherVault), uint256(1))
        );
    }

    function testDelegateRejectsInsufficientSeedSupply() external {
        uint256 requiredSupply = vault.totalSupply() + 1;
        vm.expectRevert(PharaohBoostedDelegate.PharaohBoosted__InsufficientVaultSeed.selector);
        _deployMarket(vault, requiredSupply);
    }

    function _deployMarket(IERC4626 targetVault, uint256 minimumSupply) private returns (PErc20Delegator) {
        return new PErc20Delegator(
            address(targetVault),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(interestRateModel)),
            2e14,
            "Peridot Boosted Pharaoh USDC",
            "bpPHAR-USDC",
            8,
            payable(address(this)),
            address(implementation),
            abi.encode(address(targetVault), minimumSupply)
        );
    }
}

contract PharaohBoostedAvalancheForkTest is Test {
    uint256 private constant PINNED_FORK_BLOCK = 93_558_215;
    address private constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    IERC4626 private constant USDC_VAULT = IERC4626(0x855bF832f26a294d28500db59eE941dE3d654129);
    IERC4626 private constant WAVAX_VAULT = IERC4626(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);
    AggregatorV3Interface private constant USDC_USD_FEED =
        AggregatorV3Interface(0xF096872672F44d6EBA71458D74fe67F9a77a23B9);
    AggregatorV3Interface private constant AVAX_USD_FEED =
        AggregatorV3Interface(0x0A77230d17318075983913bC2145DB16C7366156);

    bool private forkConfigured;

    function setUp() external {
        if (block.chainid == 43_114) {
            forkConfigured = true;
            return;
        }
        string memory rpcUrl = vm.envOr("AVAX_MAINNET_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl, vm.envOr("AVAX_FORK_BLOCK", PINNED_FORK_BLOCK));
        forkConfigured = block.chainid == 43_114;
    }

    function testLiveVaultsDeployPriceAndRoundTripThroughMarkets() external {
        _requireFork();

        PharaohTestBaseOracle baseOracle = new PharaohTestBaseOracle();
        PharaohVaultShareOracle oracle = new PharaohVaultShareOracle(address(this), baseOracle);
        oracle.registerVault(USDC_VAULT, USDC_USD_FEED, 26 hours);
        oracle.registerVault(WAVAX_VAULT, AVAX_USD_FEED, 26 hours);

        MockPeridottroller controller = new MockPeridottroller();
        MockInterestRateModel interestRateModel = new MockInterestRateModel();
        PharaohBoostedDelegate implementation = new PharaohBoostedDelegate();
        PErc20Delegator usdcMarket = _deployLiveMarket(
            USDC_VAULT,
            2e14,
            "Peridot Boosted Pharaoh USDC/USDt",
            "bpPHAR-USDC",
            controller,
            interestRateModel,
            implementation
        );
        PErc20Delegator wavaxMarket = _deployLiveMarket(
            WAVAX_VAULT,
            2e26,
            "Peridot Boosted Pharaoh sAVAX/WAVAX",
            "bpPHAR-WAVAX",
            controller,
            interestRateModel,
            implementation
        );

        assertGt(oracle.getUnderlyingPrice(PToken(address(usdcMarket))), 95e28);
        assertLt(oracle.getUnderlyingPrice(PToken(address(usdcMarket))), 105e28);
        assertGt(oracle.getUnderlyingPrice(PToken(address(wavaxMarket))), 0);

        uint256 shares = USDC_VAULT.balanceOf(SAFE) / 10;
        vm.startPrank(SAFE);
        USDC_VAULT.approve(address(usdcMarket), shares);
        assertEq(usdcMarket.mint(shares), 0);
        assertEq(usdcMarket.redeemUnderlying(shares), 0);
        vm.stopPrank();
        assertEq(USDC_VAULT.balanceOf(address(usdcMarket)), 0);
    }

    function _deployLiveMarket(
        IERC4626 vault,
        uint256 initialExchangeRate,
        string memory name,
        string memory symbol,
        MockPeridottroller controller,
        MockInterestRateModel interestRateModel,
        PharaohBoostedDelegate implementation
    ) private returns (PErc20Delegator) {
        return new PErc20Delegator(
            address(vault),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(interestRateModel)),
            initialExchangeRate,
            name,
            symbol,
            8,
            payable(address(this)),
            address(implementation),
            abi.encode(address(vault), uint256(1))
        );
    }

    function _requireFork() private {
        if (!forkConfigured) {
            emit log("Skipping Avalanche fork test: set AVAX_MAINNET_RPC_URL");
            vm.skip(true);
        }
    }
}
