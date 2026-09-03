// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {ConfigurableJumpRateModelV2} from "../contracts/ConfigurableJumpRateModelV2.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PeridottrollerAvalancheFuji} from "../contracts/PeridottrollerAvalancheFuji.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PToken} from "../contracts/PToken.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {Peridot} from "../contracts/Governance/Peridot.sol";
import {AvalancheFujiMarketBootstrapper} from "../contracts/deployment/AvalancheFujiMarketBootstrapper.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";

/**
 * @notice Deploys a fresh, seeded pWAVAX/pUSDC Peridot lending base on Avalanche Fuji.
 * @dev Markets start with zero spot collateral factors and borrowing paused. The bootstrapper
 *      makes market listing plus first mint atomic, preventing an externally accessible empty market.
 *      Use MARGIN_DEPLOYER with Forge's --account and --sender options; never export a raw private key.
 */
contract DeployAvalancheFujiLendingMarkets is Script {
    using SafeERC20 for IERC20;

    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;
    uint8 private constant PTOKEN_DECIMALS = 8;

    address public constant DEFAULT_WAVAX = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;
    address public constant DEFAULT_LFJ_USDC = 0xB6076C93701D6a07266c31066B298AeC6dd65c2d;
    address public constant DEFAULT_AVAX_USD_FEED = 0x5498BB86BC934c8D34FDA08E81D444153d0D06aD;
    address public constant DEFAULT_USDC_USD_FEED = 0x97FE42a7E96640D932bbc0e1580c73E705A8EB73;

    struct Deployment {
        Peridot peridot;
        AvalanchePriceOracle oracle;
        Unitroller unitroller;
        PeridottrollerAvalancheFuji implementation;
        Peridottroller controller;
        ConfigurableJumpRateModelV2 interestRateModel;
        AvalancheFujiMarketBootstrapper bootstrapper;
        address pTokenDelegate;
        PErc20Delegator pWavax;
        PErc20Delegator pUsdc;
    }

    function run() external returns (Deployment memory deployed) {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "DeployFujiLending: Fuji only");

        address deployer = vm.envAddress("MARGIN_DEPLOYER");
        address owner = vm.envAddress("MARGIN_OWNER");
        address pauseGuardian = vm.envOr("LENDING_PAUSE_GUARDIAN", owner);
        address wavax = vm.envOr("FUJI_WAVAX", DEFAULT_WAVAX);
        address usdc = vm.envOr("FUJI_LFJ_USDC", DEFAULT_LFJ_USDC);
        address avaxUsdFeed = vm.envOr("FUJI_AVAX_USD_FEED", DEFAULT_AVAX_USD_FEED);
        address usdcUsdFeed = vm.envOr("FUJI_USDC_USD_FEED", DEFAULT_USDC_USD_FEED);

        uint256 wavaxSeedAmount = vm.envUint("LENDING_WAVAX_SEED_AMOUNT");
        uint256 usdcSeedAmount = vm.envUint("LENDING_USDC_SEED_AMOUNT");
        uint256 wavaxBorrowCap = vm.envUint("LENDING_WAVAX_BORROW_CAP");
        uint256 usdcBorrowCap = vm.envUint("LENDING_USDC_BORROW_CAP");
        uint256 reserveFactor = vm.envOr("LENDING_RESERVE_FACTOR", uint256(0.1e18));
        uint256 closeFactor = vm.envOr("LENDING_CLOSE_FACTOR", uint256(0.5e18));
        uint256 liquidationIncentive = vm.envOr("LENDING_LIQUIDATION_INCENTIVE", uint256(1.08e18));
        uint256 avaxFeedMaxAge = vm.envOr("FUJI_AVAX_FEED_MAX_AGE", uint256(1_200));
        uint256 usdcFeedMaxAge = vm.envOr("FUJI_USDC_FEED_MAX_AGE", uint256(90_000));

        require(deployer != address(0), "DeployFujiLending: zero deployer");
        require(owner == deployer, "DeployFujiLending: owner must be deployer");
        require(pauseGuardian != address(0), "DeployFujiLending: zero guardian");
        require(wavax.code.length > 0 && usdc.code.length > 0, "DeployFujiLending: token not contract");
        require(wavax != usdc, "DeployFujiLending: duplicate token");
        require(wavaxSeedAmount > 0 && usdcSeedAmount > 0, "DeployFujiLending: zero seed");
        require(
            wavaxBorrowCap > wavaxSeedAmount && usdcBorrowCap > usdcSeedAmount, "DeployFujiLending: cap not above seed"
        );
        require(reserveFactor <= 0.5e18, "DeployFujiLending: reserve factor too high");
        require(closeFactor >= 0.05e18 && closeFactor <= 0.9e18, "DeployFujiLending: close factor");
        require(
            liquidationIncentive >= 1e18 && liquidationIncentive <= 1.2e18, "DeployFujiLending: liquidation incentive"
        );
        require(
            avaxFeedMaxAge > 0 && avaxFeedMaxAge <= type(uint32).max && usdcFeedMaxAge > 0
                && usdcFeedMaxAge <= type(uint32).max,
            "DeployFujiLending: feed age"
        );
        require(IERC20Metadata(wavax).decimals() == 18, "DeployFujiLending: WAVAX decimals");
        require(IERC20Metadata(usdc).decimals() == 6, "DeployFujiLending: USDC decimals");
        require(IERC20(wavax).balanceOf(deployer) >= wavaxSeedAmount, "DeployFujiLending: WAVAX seed balance");
        require(IERC20(usdc).balanceOf(deployer) >= usdcSeedAmount, "DeployFujiLending: USDC seed balance");
        _validateFeed(avaxUsdFeed, "AVAX / USD", avaxFeedMaxAge);
        _validateFeed(usdcUsdFeed, "USDC / USD", usdcFeedMaxAge);

        vm.startBroadcast(deployer);
        deployed.peridot = new Peridot(owner);
        deployed.oracle = new AvalanchePriceOracle(owner);
        deployed.unitroller = new Unitroller();
        deployed.implementation = new PeridottrollerAvalancheFuji(address(deployed.peridot));
        require(
            deployed.unitroller._setPendingImplementation(address(deployed.implementation)) == 0,
            "DeployFujiLending: pending implementation"
        );
        deployed.implementation._become(deployed.unitroller);
        deployed.controller = Peridottroller(address(deployed.unitroller));

        deployed.interestRateModel = _deployRateModel(owner);
        deployed.pTokenDelegate = address(new PErc20Delegate());
        require(
            deployed.controller._setPriceOracle(PriceOracle(address(deployed.oracle))) == 0,
            "DeployFujiLending: controller oracle"
        );
        require(deployed.controller._setCloseFactor(closeFactor) == 0, "DeployFujiLending: close factor");
        require(
            deployed.controller._setLiquidationIncentive(liquidationIncentive) == 0,
            "DeployFujiLending: liquidation incentive"
        );
        require(deployed.controller._setPauseGuardian(pauseGuardian) == 0, "DeployFujiLending: pause guardian");

        deployed.bootstrapper = new AvalancheFujiMarketBootstrapper(
            deployer,
            address(deployed.controller),
            address(deployed.interestRateModel),
            deployed.pTokenDelegate,
            wavax,
            usdc
        );
        deployed.pWavax = _deployMarket(
            wavax, "Peridot Wrapped AVAX", "pWAVAX", _initialExchangeRate(IERC20Metadata(wavax).decimals()), deployed
        );
        deployed.pUsdc = _deployMarket(
            usdc, "Peridot LFJ USD Coin", "pUSDC", _initialExchangeRate(IERC20Metadata(usdc).decimals()), deployed
        );
        require(
            deployed.unitroller._setPendingAdmin(address(deployed.bootstrapper)) == 0,
            "DeployFujiLending: pending bootstrap admin"
        );

        IERC20(wavax).forceApprove(address(deployed.bootstrapper), wavaxSeedAmount);
        IERC20(usdc).forceApprove(address(deployed.bootstrapper), usdcSeedAmount);
        deployed.bootstrapper
            .bootstrap(
                address(deployed.pWavax),
                address(deployed.pUsdc),
                wavaxSeedAmount,
                usdcSeedAmount,
                wavaxBorrowCap,
                usdcBorrowCap,
                reserveFactor
            );
        IERC20(wavax).forceApprove(address(deployed.bootstrapper), 0);
        IERC20(usdc).forceApprove(address(deployed.bootstrapper), 0);

        require(deployed.unitroller._acceptAdmin() == 0, "DeployFujiLending: accept controller admin");
        require(deployed.pWavax._acceptAdmin() == 0, "DeployFujiLending: accept pWAVAX admin");
        require(deployed.pUsdc._acceptAdmin() == 0, "DeployFujiLending: accept pUSDC admin");

        deployed.oracle.configureFeed(wavax, avaxUsdFeed, uint32(avaxFeedMaxAge));
        deployed.oracle.configureFeed(usdc, usdcUsdFeed, uint32(usdcFeedMaxAge));
        deployed.oracle.registerMarket(address(deployed.pWavax), wavax);
        deployed.oracle.registerMarket(address(deployed.pUsdc), usdc);
        vm.stopBroadcast();

        _validateDeployment(deployed, deployer, wavax, usdc, wavaxBorrowCap, usdcBorrowCap);
        _log(deployed);
    }

    function _deployRateModel(address owner) private returns (ConfigurableJumpRateModelV2) {
        return new ConfigurableJumpRateModelV2(
            vm.envOr("LENDING_BLOCKS_PER_YEAR", uint256(31_536_000)),
            vm.envOr("LENDING_BASE_RATE_PER_YEAR", uint256(0.02e18)),
            vm.envOr("LENDING_MULTIPLIER_PER_YEAR", uint256(0.1e18)),
            vm.envOr("LENDING_JUMP_MULTIPLIER_PER_YEAR", uint256(1e18)),
            vm.envOr("LENDING_KINK", uint256(0.8e18)),
            owner
        );
    }

    function _deployMarket(
        address underlying,
        string memory name,
        string memory symbol,
        uint256 initialExchangeRate,
        Deployment memory deployed
    ) private returns (PErc20Delegator) {
        return new PErc20Delegator(
            underlying,
            PeridottrollerInterface(address(deployed.controller)),
            deployed.interestRateModel,
            initialExchangeRate,
            name,
            symbol,
            PTOKEN_DECIMALS,
            payable(address(deployed.bootstrapper)),
            deployed.pTokenDelegate,
            ""
        );
    }

    function _initialExchangeRate(uint8 underlyingDecimals) private pure returns (uint256) {
        require(underlyingDecimals <= 18, "DeployFujiLending: unsupported decimals");
        return 2 * (10 ** uint256(underlyingDecimals + PTOKEN_DECIMALS));
    }

    function _validateFeed(address feed, string memory expectedDescription, uint256 maxAge) private view {
        require(feed.code.length > 0, "DeployFujiLending: feed not contract");
        AggregatorV3Interface aggregator = AggregatorV3Interface(feed);
        require(aggregator.decimals() == 8, "DeployFujiLending: feed decimals");
        require(
            keccak256(bytes(aggregator.description())) == keccak256(bytes(expectedDescription)),
            "DeployFujiLending: wrong feed"
        );
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = aggregator.latestRoundData();
        require(
            roundId != 0 && answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp && answeredInRound >= roundId
                && block.timestamp - updatedAt <= maxAge,
            "DeployFujiLending: stale feed"
        );
    }

    function _validateDeployment(
        Deployment memory deployed,
        address deployer,
        address wavax,
        address usdc,
        uint256 wavaxBorrowCap,
        uint256 usdcBorrowCap
    ) private view {
        require(deployed.unitroller.admin() == deployer, "DeployFujiLending: controller admin");
        require(deployed.unitroller.pendingAdmin() == address(0), "DeployFujiLending: controller pending admin");
        require(
            deployed.unitroller.peridottrollerImplementation() == address(deployed.implementation)
                && deployed.unitroller.pendingPeridottrollerImplementation() == address(0),
            "DeployFujiLending: controller implementation"
        );
        require(
            deployed.pWavax.admin() == deployer && deployed.pUsdc.admin() == deployer, "DeployFujiLending: market admin"
        );
        require(
            deployed.pWavax.pendingAdmin() == address(0) && deployed.pUsdc.pendingAdmin() == address(0),
            "DeployFujiLending: market pending admin"
        );
        require(deployed.bootstrapper.used(), "DeployFujiLending: bootstrap unused");
        require(deployed.oracle.owner() == deployer, "DeployFujiLending: oracle owner");
        require(
            deployed.controller.getPeridotAddress() == address(deployed.peridot), "DeployFujiLending: PERIDOT token"
        );
        require(PErc20(address(deployed.pWavax)).underlying() == wavax, "DeployFujiLending: pWAVAX asset");
        require(PErc20(address(deployed.pUsdc)).underlying() == usdc, "DeployFujiLending: pUSDC asset");
        require(
            deployed.pWavax.implementation() == deployed.pTokenDelegate
                && deployed.pUsdc.implementation() == deployed.pTokenDelegate,
            "DeployFujiLending: market delegate"
        );
        require(
            address(deployed.pWavax.peridottroller()) == address(deployed.controller)
                && address(deployed.pUsdc.peridottroller()) == address(deployed.controller),
            "DeployFujiLending: market controller"
        );
        require(
            address(deployed.pWavax.interestRateModel()) == address(deployed.interestRateModel)
                && address(deployed.pUsdc.interestRateModel()) == address(deployed.interestRateModel),
            "DeployFujiLending: market rate model"
        );
        require(
            deployed.pWavax.decimals() == PTOKEN_DECIMALS && deployed.pUsdc.decimals() == PTOKEN_DECIMALS,
            "DeployFujiLending: pToken decimals"
        );
        require(
            deployed.pWavax.exchangeRateStored() == 2e26 && deployed.pUsdc.exchangeRateStored() == 2e14,
            "DeployFujiLending: exchange rate"
        );
        require(
            deployed.pWavax.reserveFactorMantissa() <= 0.5e18 && deployed.pUsdc.reserveFactorMantissa() <= 0.5e18,
            "DeployFujiLending: reserve factor"
        );
        require(
            deployed.controller.oracle().getUnderlyingPrice(PToken(address(deployed.pWavax))) > 0,
            "DeployFujiLending: AVAX price"
        );
        require(
            deployed.controller.oracle().getUnderlyingPrice(PToken(address(deployed.pUsdc))) > 0,
            "DeployFujiLending: USDC price"
        );

        (bool wavaxListed, uint256 wavaxCollateralFactor,) = deployed.controller.markets(address(deployed.pWavax));
        (bool usdcListed, uint256 usdcCollateralFactor,) = deployed.controller.markets(address(deployed.pUsdc));
        require(wavaxListed && usdcListed, "DeployFujiLending: market not listed");
        require(wavaxCollateralFactor == 0 && usdcCollateralFactor == 0, "DeployFujiLending: spot collateral enabled");
        require(
            deployed.controller.borrowGuardianPaused(address(deployed.pWavax))
                && deployed.controller.borrowGuardianPaused(address(deployed.pUsdc)),
            "DeployFujiLending: borrow not paused"
        );
        require(
            deployed.controller.borrowCaps(address(deployed.pWavax)) == wavaxBorrowCap
                && deployed.controller.borrowCaps(address(deployed.pUsdc)) == usdcBorrowCap,
            "DeployFujiLending: borrow cap"
        );
        require(
            deployed.pWavax.flashLoansPaused() && deployed.pUsdc.flashLoansPaused(),
            "DeployFujiLending: pToken flash active"
        );
        require(
            deployed.pWavax.totalSupply() > 0 && deployed.pUsdc.totalSupply() > 0, "DeployFujiLending: unseeded market"
        );
    }

    function _log(Deployment memory deployed) private pure {
        console2.log("Fuji PERIDOT", address(deployed.peridot));
        console2.log("Fuji controller oracle", address(deployed.oracle));
        console2.log("Fuji Unitroller / Peridottroller", address(deployed.controller));
        console2.log("Fuji Peridottroller implementation", address(deployed.implementation));
        console2.log("Fuji interest-rate model", address(deployed.interestRateModel));
        console2.log("Fuji pToken delegate", deployed.pTokenDelegate);
        console2.log("Fuji pWAVAX", address(deployed.pWavax));
        console2.log("Fuji pUSDC", address(deployed.pUsdc));
        console2.log("Both markets are seeded; spot collateral is zero; borrowing and pToken flash loans are paused");
    }
}
