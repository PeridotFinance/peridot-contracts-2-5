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
import {PeridottrollerAvalanche} from "../contracts/PeridottrollerAvalanche.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {PToken} from "../contracts/PToken.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {Unitroller} from "../contracts/Unitroller.sol";
import {AvalancheMarketBootstrapper} from "../contracts/deployment/AvalancheMarketBootstrapper.sol";
import {AvalanchePriceOracle} from "../contracts/margin/AvalanchePriceOracle.sol";
import {GuardedAvalanchePriceOracle, IAvalanchePriceOracleSource} from "../contracts/margin/GuardedAvalanchePriceOracle.sol";

/// @notice Every operator decision is an explicit input: there are NO default risk parameters, NO default PERIDOT token, and no
///         default admin. The script cannot unpause borrowing, set a collateral factor, or touch the margin stack.
struct CashOnlyParams {
    address deployer; // broadcasting account (also the initial admin/owner; hand over to governance as a SEPARATE, verified step)
    address peridotToken; // OPERATOR DECISION: production PERIDOT token (no placeholder is deployed or selected here)
    address pauseGuardian;
    uint256 wavaxSeed;
    uint256 usdcSeed;
    uint256 wavaxBorrowCap;
    uint256 usdcBorrowCap;
    uint256 reserveFactor;
    uint256 closeFactor;
    uint256 liquidationIncentive;
    uint256 blocksPerYear;
    uint256 baseRatePerYear;
    uint256 multiplierPerYear;
    uint256 jumpMultiplierPerYear;
    uint256 kink;
    uint256 avaxFeedMaxAge;
    uint256 usdcFeedMaxAge;
    uint256 wavaxBorrowCashFloor; // 0 = disabled; see PeridottrollerAvalanche.borrowCashFloor
    uint256 usdcBorrowCashFloor;
}

struct CashOnlyDeployment {
    AvalanchePriceOracle sourceOracle;
    GuardedAvalanchePriceOracle oracle;
    Unitroller unitroller;
    PeridottrollerAvalanche implementation;
    PeridottrollerAvalanche controller;
    ConfigurableJumpRateModelV2 interestRateModel;
    AvalancheMarketBootstrapper bootstrapper;
    address pTokenDelegate;
    PErc20Delegator pWavax;
    PErc20Delegator pUsdc;
}

/// @notice Read-only configuration and admin checks shared by the deploy script, the verifier script and the rehearsal tests.
abstract contract CashOnlyLendingChecks {
    uint256 internal constant AVALANCHE_CHAIN_ID = 43_114;
    uint8 internal constant PTOKEN_DECIMALS = 8;
    // Avalanche C-Chain native assets and Chainlink feeds (the ones the fork tests read at the pinned block; their code, decimals and
    // feed descriptions are re-checked on chain below, so a wrong address fails closed).
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant AVAX_USD_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant USDC_USD_FEED = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;

    function _checkParams(CashOnlyParams memory p) internal view {
        require(block.chainid == AVALANCHE_CHAIN_ID, "CashOnlyLending: Avalanche C-Chain only");
        require(p.deployer != address(0), "CashOnlyLending: zero deployer");
        require(p.peridotToken.code.length > 0, "CashOnlyLending: PERIDOT token must be an existing contract (operator decision)");
        require(p.pauseGuardian != address(0), "CashOnlyLending: zero guardian");
        require(WAVAX.code.length > 0 && USDC.code.length > 0, "CashOnlyLending: token not contract");
        require(IERC20Metadata(WAVAX).decimals() == 18, "CashOnlyLending: WAVAX decimals");
        require(IERC20Metadata(USDC).decimals() == 6, "CashOnlyLending: USDC decimals");
        require(p.wavaxSeed > 0 && p.usdcSeed > 0, "CashOnlyLending: zero seed");
        require(p.wavaxBorrowCap > p.wavaxSeed && p.usdcBorrowCap > p.usdcSeed, "CashOnlyLending: cap not above seed");
        require(p.reserveFactor <= 0.5e18, "CashOnlyLending: reserve factor too high");
        require(p.closeFactor >= 0.05e18 && p.closeFactor <= 0.9e18, "CashOnlyLending: close factor");
        require(p.liquidationIncentive >= 1e18 && p.liquidationIncentive <= 1.2e18, "CashOnlyLending: liquidation incentive");
        require(p.avaxFeedMaxAge > 0 && p.avaxFeedMaxAge <= type(uint32).max, "CashOnlyLending: AVAX feed age");
        require(p.usdcFeedMaxAge > 0 && p.usdcFeedMaxAge <= type(uint32).max, "CashOnlyLending: USDC feed age");
        _validateFeed(AVAX_USD_FEED, "AVAX / USD", p.avaxFeedMaxAge);
        _validateFeed(USDC_USD_FEED, "USDC / USD", p.usdcFeedMaxAge);
    }

    function _validateFeed(address feed, string memory expectedDescription, uint256 maxAge) internal view {
        require(feed.code.length > 0, "CashOnlyLending: feed not contract");
        AggregatorV3Interface a = AggregatorV3Interface(feed);
        require(a.decimals() == 8, "CashOnlyLending: feed decimals");
        require(keccak256(bytes(a.description())) == keccak256(bytes(expectedDescription)), "CashOnlyLending: wrong feed");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = a.latestRoundData();
        require(
            roundId != 0 && answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp && answeredInRound >= roundId
                && block.timestamp - updatedAt <= maxAge,
            "CashOnlyLending: stale feed"
        );
    }

    /// @notice Explicit configuration and admin checks. Reverts with a specific message on the first deviation.
    ///         `expectedAdmin` is who must hold controller, market and oracle administration NOW.
    function _verify(CashOnlyDeployment memory d, CashOnlyParams memory p, address expectedAdmin) internal view {
        // --- controller / admin
        require(d.unitroller.admin() == expectedAdmin, "verify: controller admin");
        require(d.unitroller.pendingAdmin() == address(0), "verify: controller pending admin");
        require(
            d.unitroller.peridottrollerImplementation() == address(d.implementation)
                && d.unitroller.pendingPeridottrollerImplementation() == address(0),
            "verify: controller implementation"
        );
        require(d.implementation.peridotToken() == p.peridotToken && d.controller.getPeridotAddress() == p.peridotToken, "verify: PERIDOT token");
        require(d.controller.pauseGuardian() == p.pauseGuardian, "verify: pause guardian");
        require(d.controller.closeFactorMantissa() == p.closeFactor, "verify: close factor");
        require(d.controller.liquidationIncentiveMantissa() == p.liquidationIncentive, "verify: liquidation incentive");
        // --- margin hooks UNSET (cash-only)
        require(d.controller.isolatedMarginRiskHook() == address(0), "verify: margin risk hook is set");
        require(d.controller.isolatedMarginRegistrar() == address(0), "verify: margin registrar is set");
        // --- oracle
        require(address(d.controller.oracle()) == address(d.oracle), "verify: controller oracle is not the guarded oracle");
        require(address(d.oracle.source()) == address(d.sourceOracle), "verify: guarded oracle source");
        require(d.sourceOracle.owner() == expectedAdmin, "verify: source oracle owner");
        {
            (AggregatorV3Interface fa, uint32 ma, , bool ea) = d.sourceOracle.feeds(WAVAX);
            (AggregatorV3Interface fu, uint32 mu, , bool eu) = d.sourceOracle.feeds(USDC);
            require(address(fa) == AVAX_USD_FEED && ma == p.avaxFeedMaxAge && ea, "verify: AVAX feed config");
            require(address(fu) == USDC_USD_FEED && mu == p.usdcFeedMaxAge && eu, "verify: USDC feed config");
        }
        require(d.oracle.getUnderlyingPrice(PToken(address(d.pWavax))) > 0, "verify: AVAX price unavailable");
        require(d.oracle.getUnderlyingPrice(PToken(address(d.pUsdc))) > 0, "verify: USDC price unavailable");
        // --- markets
        require(d.pWavax.admin() == expectedAdmin && d.pUsdc.admin() == expectedAdmin, "verify: market admin");
        require(d.pWavax.pendingAdmin() == address(0) && d.pUsdc.pendingAdmin() == address(0), "verify: market pending admin");
        require(PErc20(address(d.pWavax)).underlying() == WAVAX && PErc20(address(d.pUsdc)).underlying() == USDC, "verify: underlying");
        require(
            d.pWavax.implementation() == d.pTokenDelegate && d.pUsdc.implementation() == d.pTokenDelegate, "verify: not the plain delegate"
        );
        require(
            address(d.pWavax.peridottroller()) == address(d.controller) && address(d.pUsdc.peridottroller()) == address(d.controller),
            "verify: market controller"
        );
        require(
            address(d.pWavax.interestRateModel()) == address(d.interestRateModel)
                && address(d.pUsdc.interestRateModel()) == address(d.interestRateModel),
            "verify: rate model"
        );
        require(d.interestRateModel.owner() == expectedAdmin, "verify: rate model owner");
        require(d.pWavax.decimals() == PTOKEN_DECIMALS && d.pUsdc.decimals() == PTOKEN_DECIMALS, "verify: pToken decimals");
        require(d.pWavax.reserveFactorMantissa() == p.reserveFactor && d.pUsdc.reserveFactorMantissa() == p.reserveFactor, "verify: reserve factor");
        require(d.pWavax.totalSupply() > 0 && d.pUsdc.totalSupply() > 0, "verify: unseeded market");
        require(d.pWavax.totalBorrows() == 0 && d.pUsdc.totalBorrows() == 0, "verify: borrows exist");
        // --- listing, borrowing PAUSED, collateral factors ZERO, caps, floors, flash loans paused
        (bool lw, uint256 cfw,) = d.controller.markets(address(d.pWavax));
        (bool lu, uint256 cfu,) = d.controller.markets(address(d.pUsdc));
        require(lw && lu, "verify: market not listed");
        require(cfw == 0 && cfu == 0, "verify: a collateral factor is enabled (parameter step is separate)");
        require(
            d.controller.borrowGuardianPaused(address(d.pWavax)) && d.controller.borrowGuardianPaused(address(d.pUsdc)),
            "verify: BORROWING IS NOT PAUSED"
        );
        require(d.pWavax.flashLoansPaused() && d.pUsdc.flashLoansPaused(), "verify: pToken flash loans active");
        require(
            d.controller.borrowCaps(address(d.pWavax)) == p.wavaxBorrowCap && d.controller.borrowCaps(address(d.pUsdc)) == p.usdcBorrowCap,
            "verify: borrow caps"
        );
        require(
            d.controller.borrowCashFloor(address(d.pWavax)) == p.wavaxBorrowCashFloor
                && d.controller.borrowCashFloor(address(d.pUsdc)) == p.usdcBorrowCashFloor,
            "verify: borrow cash floors"
        );
    }
}

/**
 * @notice Deploys the CASH-ONLY USDC/WAVAX lending base on Avalanche C-Chain: guarded oracle, Unitroller + `PeridottrollerAvalanche`
 *         (borrow cash floor), two PLAIN `PErc20Delegate` markets seeded atomically by a single-use bootstrapper, borrowing paused,
 *         pToken flash loans paused, collateral factors ZERO, margin hooks UNSET.
 *
 * NOT a deployment authorization. Rehearse on a local fork only (`AvalancheCashOnlyDeployRehearsalFork.t.sol`); the operator signs any
 * real transaction with their own keystore (`--account`/`--sender`, never a raw private key), after the PERIDOT-token decision and
 * after choosing every parameter below, none of which has a default. Collateral factors, unpausing borrowing and the admin handover to
 * governance are SEPARATE steps outside this script.
 */
contract DeployAvalancheCashOnlyLending is Script, CashOnlyLendingChecks {
    using SafeERC20 for IERC20;

    function readParams() public view returns (CashOnlyParams memory p) {
        p.deployer = vm.envAddress("DEPLOYER");
        p.peridotToken = vm.envAddress("PERIDOT_TOKEN"); // required: unset reverts; no placeholder is chosen
        p.pauseGuardian = vm.envAddress("PAUSE_GUARDIAN");
        p.wavaxSeed = vm.envUint("LENDING_WAVAX_SEED_AMOUNT");
        p.usdcSeed = vm.envUint("LENDING_USDC_SEED_AMOUNT");
        p.wavaxBorrowCap = vm.envUint("LENDING_WAVAX_BORROW_CAP");
        p.usdcBorrowCap = vm.envUint("LENDING_USDC_BORROW_CAP");
        p.reserveFactor = vm.envUint("LENDING_RESERVE_FACTOR");
        p.closeFactor = vm.envUint("LENDING_CLOSE_FACTOR");
        p.liquidationIncentive = vm.envUint("LENDING_LIQUIDATION_INCENTIVE");
        p.blocksPerYear = vm.envUint("LENDING_BLOCKS_PER_YEAR");
        p.baseRatePerYear = vm.envUint("LENDING_BASE_RATE_PER_YEAR");
        p.multiplierPerYear = vm.envUint("LENDING_MULTIPLIER_PER_YEAR");
        p.jumpMultiplierPerYear = vm.envUint("LENDING_JUMP_MULTIPLIER_PER_YEAR");
        p.kink = vm.envUint("LENDING_KINK");
        p.avaxFeedMaxAge = vm.envUint("AVAX_FEED_MAX_AGE");
        p.usdcFeedMaxAge = vm.envUint("USDC_FEED_MAX_AGE");
        p.wavaxBorrowCashFloor = vm.envUint("LENDING_WAVAX_BORROW_CASH_FLOOR");
        p.usdcBorrowCashFloor = vm.envUint("LENDING_USDC_BORROW_CASH_FLOOR");
    }

    function run() external returns (CashOnlyDeployment memory d) {
        return deploy(readParams());
    }

    function deploy(CashOnlyParams memory p) public returns (CashOnlyDeployment memory d) {
        _checkParams(p);
        require(IERC20(WAVAX).balanceOf(p.deployer) >= p.wavaxSeed, "CashOnlyLending: WAVAX seed balance");
        require(IERC20(USDC).balanceOf(p.deployer) >= p.usdcSeed, "CashOnlyLending: USDC seed balance");

        vm.startBroadcast(p.deployer);
        d.sourceOracle = new AvalanchePriceOracle(p.deployer);
        d.oracle = new GuardedAvalanchePriceOracle(IAvalanchePriceOracleSource(address(d.sourceOracle)));
        d.unitroller = new Unitroller();
        d.implementation = new PeridottrollerAvalanche(p.peridotToken);
        require(d.unitroller._setPendingImplementation(address(d.implementation)) == 0, "CashOnlyLending: pending implementation");
        d.implementation._become(d.unitroller);
        d.controller = PeridottrollerAvalanche(address(d.unitroller));

        d.interestRateModel = new ConfigurableJumpRateModelV2(
            p.blocksPerYear, p.baseRatePerYear, p.multiplierPerYear, p.jumpMultiplierPerYear, p.kink, p.deployer
        );
        d.pTokenDelegate = address(new PErc20Delegate());
        require(d.controller._setPriceOracle(PriceOracle(address(d.oracle))) == 0, "CashOnlyLending: controller oracle");
        require(d.controller._setCloseFactor(p.closeFactor) == 0, "CashOnlyLending: close factor");
        require(d.controller._setLiquidationIncentive(p.liquidationIncentive) == 0, "CashOnlyLending: liquidation incentive");
        require(d.controller._setPauseGuardian(p.pauseGuardian) == 0, "CashOnlyLending: pause guardian");

        d.bootstrapper = new AvalancheMarketBootstrapper(
            p.deployer, address(d.controller), address(d.interestRateModel), d.pTokenDelegate, WAVAX, USDC
        );
        d.pWavax = _deployMarket(WAVAX, "Peridot Wrapped AVAX", "pWAVAX", d);
        d.pUsdc = _deployMarket(USDC, "Peridot USD Coin", "pUSDC", d);
        require(d.unitroller._setPendingAdmin(address(d.bootstrapper)) == 0, "CashOnlyLending: pending bootstrap admin");

        IERC20(WAVAX).forceApprove(address(d.bootstrapper), p.wavaxSeed);
        IERC20(USDC).forceApprove(address(d.bootstrapper), p.usdcSeed);
        d.bootstrapper.bootstrap(address(d.pWavax), address(d.pUsdc), p.wavaxSeed, p.usdcSeed, p.wavaxBorrowCap, p.usdcBorrowCap, p.reserveFactor);
        IERC20(WAVAX).forceApprove(address(d.bootstrapper), 0);
        IERC20(USDC).forceApprove(address(d.bootstrapper), 0);

        require(d.unitroller._acceptAdmin() == 0, "CashOnlyLending: accept controller admin");
        require(d.pWavax._acceptAdmin() == 0, "CashOnlyLending: accept pWAVAX admin");
        require(d.pUsdc._acceptAdmin() == 0, "CashOnlyLending: accept pUSDC admin");

        d.sourceOracle.configureFeed(WAVAX, AVAX_USD_FEED, uint32(p.avaxFeedMaxAge));
        d.sourceOracle.configureFeed(USDC, USDC_USD_FEED, uint32(p.usdcFeedMaxAge));
        d.sourceOracle.registerMarket(address(d.pWavax), WAVAX);
        d.sourceOracle.registerMarket(address(d.pUsdc), USDC);
        // The borrow cash floor (0 = disabled) is set from the explicit inputs; borrowing stays paused regardless.
        require(d.controller._setBorrowCashFloor(PToken(address(d.pWavax)), p.wavaxBorrowCashFloor) == 0, "CashOnlyLending: WAVAX cash floor");
        require(d.controller._setBorrowCashFloor(PToken(address(d.pUsdc)), p.usdcBorrowCashFloor) == 0, "CashOnlyLending: USDC cash floor");
        vm.stopBroadcast();

        _verify(d, p, p.deployer);
        console2.log("Cash-only lending: Unitroller/controller", address(d.controller));
        console2.log("  implementation", address(d.implementation));
        console2.log("  guarded oracle", address(d.oracle));
        console2.log("  pWAVAX", address(d.pWavax));
        console2.log("  pUSDC", address(d.pUsdc));
        console2.log("Borrowing is PAUSED, collateral factors are ZERO, margin hooks are UNSET. Admin = deployer until a separate verified handover.");
    }

    function _deployMarket(address underlying, string memory name, string memory symbol, CashOnlyDeployment memory d)
        private
        returns (PErc20Delegator)
    {
        uint8 dec = IERC20Metadata(underlying).decimals();
        return new PErc20Delegator(
            underlying,
            PeridottrollerInterface(address(d.controller)),
            d.interestRateModel,
            2 * (10 ** uint256(dec + PTOKEN_DECIMALS)),
            name,
            symbol,
            PTOKEN_DECIMALS,
            payable(address(d.bootstrapper)),
            d.pTokenDelegate,
            ""
        );
    }
}

/// @notice Read-only verifier for an existing deployment (also usable after the governance handover with EXPECTED_ADMIN).
contract VerifyAvalancheCashOnlyLending is Script, CashOnlyLendingChecks {
    /// @notice Struct entry point (the env-driven `run()` below is a thin wrapper); used by the rehearsal tests.
    function verify(CashOnlyDeployment memory d, CashOnlyParams memory p, address expectedAdmin) external view {
        _verify(d, p, expectedAdmin);
    }

    function run() external {
        CashOnlyDeployment memory d;
        CashOnlyParams memory p = new DeployAvalancheCashOnlyLending().readParams();
        d.unitroller = Unitroller(payable(vm.envAddress("CONTROLLER")));
        d.controller = PeridottrollerAvalanche(address(d.unitroller));
        d.implementation = PeridottrollerAvalanche(d.unitroller.peridottrollerImplementation());
        d.oracle = GuardedAvalanchePriceOracle(address(d.controller.oracle()));
        d.sourceOracle = AvalanchePriceOracle(address(d.oracle.source()));
        d.pWavax = PErc20Delegator(payable(vm.envAddress("PWAVAX")));
        d.pUsdc = PErc20Delegator(payable(vm.envAddress("PUSDC")));
        d.interestRateModel = ConfigurableJumpRateModelV2(address(d.pWavax.interestRateModel()));
        d.pTokenDelegate = d.pWavax.implementation();
        _verify(d, p, vm.envAddress("EXPECTED_ADMIN"));
    }
}
