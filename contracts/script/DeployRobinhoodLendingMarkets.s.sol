// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ConfigurableJumpRateModelV2} from "../contracts/ConfigurableJumpRateModelV2.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerRobinhood} from "../contracts/PeridottrollerRobinhood.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {Peridot} from "../contracts/Governance/Peridot.sol";
import {StockSimplePriceOracle} from "../contracts/StockSimplePriceOracle.sol";
import {RobinhoodBoostedDelegate} from "../contracts/boosted/RobinhoodBoostedDelegate.sol";
import {RobinhoodMarketBootstrapper} from "../contracts/deployment/RobinhoodMarketBootstrapper.sol";

/**
 * @notice Deploys a fresh, seeded boosted lending base on Robinhood Chain.
 * @dev Two markets only, both boosted: one per side of the paired vault. There is no plain
 *      market for either asset, so LP exposure is bounded by each market's vault buffer rather
 *      than by asking depositors to choose a market.
 *
 *      Markets start with zero collateral factor and borrowing paused. The bootstrapper makes
 *      listing and first mint atomic, so no externally reachable empty market ever exists.
 *
 *      Use DEPLOYER with Forge's --account and --sender; this script accepts no private key.
 */
contract DeployRobinhoodLendingMarkets is Script {
    using SafeERC20 for IERC20;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    uint8 private constant PTOKEN_DECIMALS = 8;

    address public constant DEFAULT_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address public constant DEFAULT_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address public constant DEFAULT_NVDA_USD_FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    /**
     * @dev Interest accrues per `block.number`. On this Orbit chain `block.number` is
     *      L1-derived and advances roughly every 11-12 seconds, NOT once per ~0.1s L2 block
     *      that `eth_blockNumber` reports. Measured against the deployed Multicall3:
     *      `getBlockNumber()` returned 25,909,774 while the RPC reported 54,959,398.
     *      Carrying a per-second default across would misprice every borrow rate by an order
     *      of magnitude, so the value is range-asserted rather than trusted.
     */
    uint256 private constant MIN_SANE_BLOCKS_PER_YEAR = 2_000_000;
    uint256 private constant MAX_SANE_BLOCKS_PER_YEAR = 4_000_000;

    struct Deployment {
        Peridot peridot;
        StockSimplePriceOracle oracle;
        Unitroller unitroller;
        PeridottrollerRobinhood implementation;
        Peridottroller controller;
        ConfigurableJumpRateModelV2 interestRateModel;
        RobinhoodMarketBootstrapper bootstrapper;
        address pTokenDelegate;
        PErc20Delegator pNvda;
        PErc20Delegator pUsdg;
    }

    function run() external returns (Deployment memory deployed) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "DeployRobinhoodLending: Robinhood only");

        address deployer = vm.envAddress("DEPLOYER");
        address owner = vm.envAddress("LENDING_OWNER");
        address pauseGuardian = vm.envOr("LENDING_PAUSE_GUARDIAN", owner);
        address nvda = vm.envOr("ROBINHOOD_NVDA", DEFAULT_NVDA);
        address usdg = vm.envOr("ROBINHOOD_USDG", DEFAULT_USDG);
        address nvdaFeed = vm.envOr("ROBINHOOD_NVDA_USD_FEED", DEFAULT_NVDA_USD_FEED);

        require(deployer != address(0) && owner != address(0), "DeployRobinhoodLending: zero actor");
        require(nvda.code.length > 0 && usdg.code.length > 0, "DeployRobinhoodLending: token not contract");
        require(nvdaFeed.code.length > 0, "DeployRobinhoodLending: feed not contract");

        uint256 nvdaSeed = vm.envUint("LENDING_NVDA_SEED_AMOUNT");
        uint256 usdgSeed = vm.envUint("LENDING_USDG_SEED_AMOUNT");
        uint256 nvdaBorrowCap = vm.envUint("LENDING_NVDA_BORROW_CAP");
        uint256 usdgBorrowCap = vm.envUint("LENDING_USDG_BORROW_CAP");
        uint256 reserveFactor = vm.envOr("LENDING_RESERVE_FACTOR", uint256(0.1e18));
        uint256 closeFactor = vm.envOr("LENDING_CLOSE_FACTOR", uint256(0.5e18));
        uint256 liquidationIncentive = vm.envOr("LENDING_LIQUIDATION_INCENTIVE", uint256(1.1e18));

        // The stock feed only updates while its market is open, so it needs a far longer
        // staleness bound than USDG. Measured: the RHNVDA feed sits stale beyond 12h for about
        // a quarter of wall-clock time, with ~52h weekend gaps.
        uint256 usdgFeedMaxAge = vm.envOr("ROBINHOOD_USDG_FEED_MAX_AGE", uint256(90_000));
        uint256 stockFeedMaxAge = vm.envOr("ROBINHOOD_STOCK_FEED_MAX_AGE", uint256(259_200));

        require(IERC20(nvda).balanceOf(deployer) >= nvdaSeed, "DeployRobinhoodLending: NVDA seed balance");
        require(IERC20(usdg).balanceOf(deployer) >= usdgSeed, "DeployRobinhoodLending: USDG seed balance");

        vm.startBroadcast(deployer);

        // Deployed only because PeridottrollerRobinhood pins a token address in its constructor.
        // It is not distributed, seeded into any market, or used for rewards.
        deployed.peridot = new Peridot(owner);
        deployed.oracle = new StockSimplePriceOracle(usdgFeedMaxAge, stockFeedMaxAge);
        deployed.unitroller = new Unitroller();
        deployed.implementation = new PeridottrollerRobinhood(address(deployed.peridot));

        require(
            deployed.unitroller._setPendingImplementation(address(deployed.implementation)) == 0,
            "DeployRobinhoodLending: pending implementation"
        );
        deployed.implementation._become(deployed.unitroller);
        deployed.controller = Peridottroller(address(deployed.unitroller));

        deployed.interestRateModel = _deployRateModel(owner);
        // Both markets run the same side-neutral boosted delegate.
        deployed.pTokenDelegate = address(new RobinhoodBoostedDelegate());

        require(
            deployed.controller._setPriceOracle(PriceOracle(address(deployed.oracle))) == 0,
            "DeployRobinhoodLending: price oracle"
        );
        require(deployed.controller._setCloseFactor(closeFactor) == 0, "DeployRobinhoodLending: close factor");
        require(
            deployed.controller._setLiquidationIncentive(liquidationIncentive) == 0,
            "DeployRobinhoodLending: liquidation incentive"
        );
        require(
            deployed.controller._setPauseGuardian(pauseGuardian) == 0, "DeployRobinhoodLending: pause guardian"
        );

        deployed.bootstrapper = new RobinhoodMarketBootstrapper(
            deployer,
            address(deployed.controller),
            address(deployed.interestRateModel),
            deployed.pTokenDelegate,
            nvda,
            usdg
        );

        deployed.pNvda = _deployMarket(nvda, deployed);
        deployed.pUsdg = _deployMarket(usdg, deployed);

        require(
            deployed.unitroller._setPendingAdmin(address(deployed.bootstrapper)) == 0,
            "DeployRobinhoodLending: pending bootstrap admin"
        );

        IERC20(nvda).forceApprove(address(deployed.bootstrapper), nvdaSeed);
        IERC20(usdg).forceApprove(address(deployed.bootstrapper), usdgSeed);
        deployed.bootstrapper.bootstrap(
            address(deployed.pNvda),
            address(deployed.pUsdg),
            nvdaSeed,
            usdgSeed,
            nvdaBorrowCap,
            usdgBorrowCap,
            reserveFactor
        );
        IERC20(nvda).forceApprove(address(deployed.bootstrapper), 0);
        IERC20(usdg).forceApprove(address(deployed.bootstrapper), 0);

        require(deployed.unitroller._acceptAdmin() == 0, "DeployRobinhoodLending: accept controller admin");
        require(deployed.pNvda._acceptAdmin() == 0, "DeployRobinhoodLending: accept pNVDA admin");
        require(deployed.pUsdg._acceptAdmin() == 0, "DeployRobinhoodLending: accept pUSDG admin");

        deployed.oracle.registerChainlinkFeed(nvda, nvdaFeed);
        // NVDA prices off a market-hours feed and must use the longer staleness bound.
        deployed.oracle.setStockAsset(nvda, true);
        // USDG has no Chainlink feed on this chain; it is pinned to one dollar. Revisit if a
        // USDG/USD feed is deployed, since a depeg would otherwise go unpriced.
        deployed.oracle.setDirectPrice(usdg, 1e18);

        vm.stopBroadcast();

        _validate(deployed, deployer, nvda, usdg, nvdaBorrowCap, usdgBorrowCap);
        _log(deployed, nvda, usdg);
    }

    function _deployRateModel(address owner) private returns (ConfigurableJumpRateModelV2) {
        uint256 blocksPerYear = vm.envUint("LENDING_BLOCKS_PER_YEAR");
        require(
            blocksPerYear >= MIN_SANE_BLOCKS_PER_YEAR && blocksPerYear <= MAX_SANE_BLOCKS_PER_YEAR,
            "DeployRobinhoodLending: blocks per year off L1 cadence"
        );
        return new ConfigurableJumpRateModelV2(
            blocksPerYear,
            vm.envOr("LENDING_BASE_RATE_PER_YEAR", uint256(0.02e18)),
            vm.envOr("LENDING_MULTIPLIER_PER_YEAR", uint256(0.1e18)),
            vm.envOr("LENDING_JUMP_MULTIPLIER_PER_YEAR", uint256(1e18)),
            vm.envOr("LENDING_KINK", uint256(0.8e18)),
            owner
        );
    }

    function _deployMarket(address underlying, Deployment memory deployed) private returns (PErc20Delegator) {
        string memory underlyingSymbol = IERC20Metadata(underlying).symbol();
        uint8 underlyingDecimals = IERC20Metadata(underlying).decimals();
        require(underlyingDecimals <= 18, "DeployRobinhoodLending: underlying decimals");

        return new PErc20Delegator(
            underlying,
            PeridottrollerInterface(address(deployed.controller)),
            InterestRateModel(address(deployed.interestRateModel)),
            2 * (10 ** uint256(underlyingDecimals + 16 - PTOKEN_DECIMALS)),
            string.concat("Peridot Robinhood Boosted ", underlyingSymbol),
            string.concat("bp", underlyingSymbol),
            PTOKEN_DECIMALS,
            payable(address(deployed.bootstrapper)),
            deployed.pTokenDelegate,
            bytes("")
        );
    }

    function _validate(
        Deployment memory d,
        address deployer,
        address nvda,
        address usdg,
        uint256 nvdaBorrowCap,
        uint256 usdgBorrowCap
    ) private view {
        require(d.unitroller.admin() == deployer, "DeployRobinhoodLending: controller admin");
        require(d.pNvda.admin() == deployer, "DeployRobinhoodLending: pNVDA admin");
        require(d.pUsdg.admin() == deployer, "DeployRobinhoodLending: pUSDG admin");
        require(d.bootstrapper.used(), "DeployRobinhoodLending: bootstrap not used");

        (bool nvdaListed,,) = d.controller.markets(address(d.pNvda));
        (bool usdgListed,,) = d.controller.markets(address(d.pUsdg));
        require(nvdaListed && usdgListed, "DeployRobinhoodLending: market not listed");

        require(d.controller.borrowGuardianPaused(address(d.pNvda)), "DeployRobinhoodLending: pNVDA borrow live");
        require(d.controller.borrowGuardianPaused(address(d.pUsdg)), "DeployRobinhoodLending: pUSDG borrow live");
        require(
            d.controller.borrowCaps(address(d.pNvda)) == nvdaBorrowCap
                && d.controller.borrowCaps(address(d.pUsdg)) == usdgBorrowCap,
            "DeployRobinhoodLending: borrow caps"
        );

        // Seeded, so no market is externally reachable while empty.
        require(d.pNvda.totalSupply() > 0 && d.pUsdg.totalSupply() > 0, "DeployRobinhoodLending: unseeded market");
        require(PErc20(address(d.pNvda)).getCash() > 0, "DeployRobinhoodLending: pNVDA cash");
        require(PErc20(address(d.pUsdg)).getCash() > 0, "DeployRobinhoodLending: pUSDG cash");

        // Collateral factors stay zero until governance sets them after the vault pair is live.
        (, uint256 nvdaCf,) = d.controller.markets(address(d.pNvda));
        (, uint256 usdgCf,) = d.controller.markets(address(d.pUsdg));
        require(nvdaCf == 0 && usdgCf == 0, "DeployRobinhoodLending: collateral factor set too early");

        require(d.oracle.getUnderlyingPrice(PErc20(address(d.pNvda))) > 0, "DeployRobinhoodLending: NVDA price");
        require(d.oracle.getUnderlyingPrice(PErc20(address(d.pUsdg))) > 0, "DeployRobinhoodLending: USDG price");
        nvda;
        usdg;
    }

    function _log(Deployment memory d, address nvda, address usdg) private view {
        console2.log("PERIDOT token (controller pin only)", address(d.peridot));
        console2.log("StockSimplePriceOracle", address(d.oracle));
        console2.log("Unitroller / PERIDOTTROLLER", address(d.unitroller));
        console2.log("PeridottrollerRobinhood impl", address(d.implementation));
        console2.log("InterestRateModel", address(d.interestRateModel));
        console2.log("RobinhoodBoostedDelegate", d.pTokenDelegate);
        console2.log("bootstrapper (single use, spent)", address(d.bootstrapper));
        console2.log("bpNVDA", address(d.pNvda));
        console2.log("bpUSDG", address(d.pUsdg));
        console2.log("NVDA underlying", nvda);
        console2.log("USDG underlying", usdg);
        console2.log("");
        console2.log("borrowing paused, collateral factors zero, seed pTokens held by deployer");
        console2.log("do NOT redeem the whole seed: totalSupply must never return to zero");
        console2.log("next: deploy nothing further, register the vault pair with these as side accounts");
    }
}
