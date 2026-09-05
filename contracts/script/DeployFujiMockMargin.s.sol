// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {FujiMockToken, FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {Peridot} from "../contracts/Governance/Peridot.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerAvalancheFuji} from "../contracts/PeridottrollerAvalancheFuji.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {ConfigurableJumpRateModelV2} from "../contracts/ConfigurableJumpRateModelV2.sol";
import {AvalancheFujiMarketBootstrapper} from "../contracts/deployment/AvalancheFujiMarketBootstrapper.sol";
import {DeployAvalancheFujiLendingMarkets} from "./DeployAvalancheFujiLendingMarkets.s.sol";
import {DeployIsolatedMarginAvalanche} from "./DeployIsolatedMarginAvalanche.s.sol";

/// @notice Separate MOCK-only Fuji environment. Does not consume any existing market/asset addresses.
/// @dev Only MOCK_MARGIN_DEPLOYER and CONFIRM_FUJI_MOCK_ONLY are inputs. All liquidity is unbacked mock tokens.
///      Existing .env values are overridden IN MEMORY for the reused margin script, never written to disk.
///      Position opening, borrowing, the test venue and flash lending remain paused after deployment.
contract DeployFujiMockMargin is Script {
    struct Environment {
        FujiMockToken avax;
        FujiMockToken usd;
        FujiMockPriceFeed avaxFeed;
        FujiMockPriceFeed usdFeed;
        FujiMockSwapAdapter adapter;
        SimpleFlashLoanVault lender;
        DeployAvalancheFujiLendingMarkets.Deployment lending;
        DeployIsolatedMarginAvalanche.Deployment margin;
    }

    function run() external returns (Environment memory e) {
        require(block.chainid == 43_113, "DeployMockMargin: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_MOCK_ONLY", false), "DeployMockMargin: confirmation required");
        address owner = vm.envAddress("MOCK_MARGIN_DEPLOYER");
        require(owner != address(0), "DeployMockMargin: zero owner");

        vm.startBroadcast(owner);
        e.avax = new FujiMockToken(owner, false);
        e.usd = new FujiMockToken(owner, true);
        e.avaxFeed = new FujiMockPriceFeed(owner, false);
        e.usdFeed = new FujiMockPriceFeed(owner, true);
        e.adapter = new FujiMockSwapAdapter(owner, e.avax, e.usd, e.avaxFeed, e.usdFeed);
        e.lender = new SimpleFlashLoanVault(owner);
        e.lender.setPaused(true);
        e.lender.setFeeBps(0);
        e.lender.setTokenAllowed(address(e.avax), true);
        e.lender.setTokenAllowed(address(e.usd), true);

        e.avax.mint(address(e.adapter), 100_000e18);
        e.usd.mint(address(e.adapter), 1_000_000e6);
        e.avax.mint(address(e.lender), 10_000e18);
        e.usd.mint(address(e.lender), 100_000e6);
        e.avax.mint(owner, 11_000e18); // 10,000 seed + 1,000 operator testing balance
        e.usd.mint(owner, 110_000e6); // 100,000 seed + 10,000 operator testing balance
        e.lending = _lending(e, owner);
        vm.stopBroadcast();

        _marginEnvironment(e, owner);
        e.margin = new DeployIsolatedMarginAvalanche().run();

        vm.startBroadcast(owner);
        e.adapter.setOperator(address(e.margin.swapModule));
        require(
            e.lending.pWavax.transfer(address(e.margin.insuranceFund), e.lending.pWavax.totalSupply() / 100),
            "Mock: AVAX insurance"
        );
        require(
            e.lending.pUsdc.transfer(address(e.margin.insuranceFund), e.lending.pUsdc.totalSupply() / 100),
            "Mock: USD insurance"
        );
        vm.stopBroadcast();

        require(e.margin.config.opensPaused() && e.adapter.paused() && e.lender.paused(), "Mock: unsafe pause state");
        require(
            e.lending.controller.borrowGuardianPaused(address(e.lending.pWavax))
                && e.lending.controller.borrowGuardianPaused(address(e.lending.pUsdc)),
            "Mock: borrowing active"
        );
        console2.log("MOCK ONLY - not real USDC, WAVAX, Chainlink or LFJ");
        console2.log("mockAVAX", address(e.avax));
        console2.log("mockUSD", address(e.usd));
        console2.log("MOCK AVAX feed", address(e.avaxFeed));
        console2.log("MOCK USD feed", address(e.usdFeed));
        console2.log("MOCK funded swap venue", address(e.adapter));
        console2.log("MOCK funded flash lender", address(e.lender));
        console2.log("MOCK controller", address(e.lending.controller));
        console2.log("pMockAVAX", address(e.lending.pWavax));
        console2.log("pMockUSD", address(e.lending.pUsdc));
        console2.log("All trading gates remain paused; configure pairs separately");
    }

    function _lending(Environment memory e, address owner)
        private
        returns (DeployAvalancheFujiLendingMarkets.Deployment memory d)
    {
        d.peridot = new Peridot(owner);
        d.oracle = new AvalanchePriceOracle(owner);
        d.unitroller = new Unitroller();
        d.implementation = new PeridottrollerAvalancheFuji(address(d.peridot));
        require(d.unitroller._setPendingImplementation(address(d.implementation)) == 0, "Mock: implementation");
        d.implementation._become(d.unitroller);
        d.controller = Peridottroller(address(d.unitroller));
        d.interestRateModel = new ConfigurableJumpRateModelV2(31_536_000, 0.02e18, 0.1e18, 1e18, 0.8e18, owner);
        d.pTokenDelegate = address(new PErc20Delegate());
        require(d.controller._setPriceOracle(PriceOracle(address(d.oracle))) == 0, "Mock: oracle");
        require(d.controller._setCloseFactor(0.5e18) == 0, "Mock: close factor");
        require(d.controller._setLiquidationIncentive(1.08e18) == 0, "Mock: liquidation incentive");
        d.controller._setPauseGuardian(owner);
        d.bootstrapper = new AvalancheFujiMarketBootstrapper(
            owner,
            address(d.controller),
            address(d.interestRateModel),
            d.pTokenDelegate,
            address(e.avax),
            address(e.usd)
        );
        d.pWavax = new PErc20Delegator(
            address(e.avax),
            PeridottrollerInterface(address(d.controller)),
            d.interestRateModel,
            2e26,
            "Peridot MOCK AVAX - Fuji only",
            "pMockAVAX",
            8,
            payable(address(d.bootstrapper)),
            d.pTokenDelegate,
            ""
        );
        d.pUsdc = new PErc20Delegator(
            address(e.usd),
            PeridottrollerInterface(address(d.controller)),
            d.interestRateModel,
            2e14,
            "Peridot MOCK USD - Fuji only",
            "pMockUSD",
            8,
            payable(address(d.bootstrapper)),
            d.pTokenDelegate,
            ""
        );
        require(d.unitroller._setPendingAdmin(address(d.bootstrapper)) == 0, "Mock: pending admin");
        e.avax.approve(address(d.bootstrapper), 10_000e18);
        e.usd.approve(address(d.bootstrapper), 100_000e6);
        d.bootstrapper
            .bootstrap(address(d.pWavax), address(d.pUsdc), 10_000e18, 100_000e6, 50_000e18, 500_000e6, 0.1e18);
        e.avax.approve(address(d.bootstrapper), 0);
        e.usd.approve(address(d.bootstrapper), 0);
        require(d.unitroller._acceptAdmin() == 0, "Mock: controller admin");
        require(d.pWavax._acceptAdmin() == 0 && d.pUsdc._acceptAdmin() == 0, "Mock: market admins");
        d.oracle.configureFeed(address(e.avax), address(e.avaxFeed), 1_200);
        d.oracle.configureFeed(address(e.usd), address(e.usdFeed), 1_200);
        d.oracle.registerMarket(address(d.pWavax), address(e.avax));
        d.oracle.registerMarket(address(d.pUsdc), address(e.usd));
    }

    function _marginEnvironment(Environment memory e, address owner) private {
        string memory operator = vm.toString(owner);
        vm.setEnv("MARGIN_DEPLOYER", operator);
        vm.setEnv("MARGIN_OWNER", operator);
        vm.setEnv("MARGIN_TREASURY", operator);
        vm.setEnv("MARGIN_ACTION_DELAY", "86400");
        vm.setEnv("PERIDOTTROLLER", vm.toString(address(e.lending.controller)));
        vm.setEnv("MARGIN_ROUTER_ADAPTER", vm.toString(address(e.adapter)));
        vm.setEnv("MARGIN_FLASH_LENDER", vm.toString(address(e.lender)));
        vm.setEnv(
            "MARGIN_PTOKENS",
            string.concat(vm.toString(address(e.lending.pWavax)), ",", vm.toString(address(e.lending.pUsdc)))
        );
        vm.setEnv("MARGIN_ASSETS", string.concat(vm.toString(address(e.avax)), ",", vm.toString(address(e.usd))));
        vm.setEnv(
            "MARGIN_CHAINLINK_FEEDS",
            string.concat(vm.toString(address(e.avaxFeed)), ",", vm.toString(address(e.usdFeed)))
        );
        vm.setEnv("MARGIN_FEED_MAX_AGES", "1200,1200");
        // Only the freshly created MOCK controller is wired; live deployment configuration is never read.
        vm.setEnv("WIRE_CONTROLLER", "true");
    }
}
