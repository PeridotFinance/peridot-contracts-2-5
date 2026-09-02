// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IERC3156FlashLender} from "../contracts/PTokenInterfaces.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginMath} from "../contracts/margin/IsolatedMarginMath.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {IMarginPriceOracle} from "../contracts/margin/interfaces/IMarginPriceOracle.sol";

/**
 * @notice Queues or executes one Avalanche Fuji isolated-margin pair configuration.
 * @dev Run once with EXECUTE=false, wait config.actionDelay(), then rerun with EXECUTE=true.
 *      Use MARGIN_DEPLOYER with Forge's --account and --sender options; never export a raw private key.
 *      Mainnet is intentionally rejected. Set UNPAUSE_OPENS=true only after every explicit Fuji gate passes.
 */
contract ConfigureIsolatedMarginPairAvalanche is Script {
    using SafeCast for uint256;

    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;

    function run() external returns (bytes32 actionId) {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "ConfigureMargin: Fuji only");
        address deployer = vm.envAddress("MARGIN_DEPLOYER");
        IsolatedMarginConfigUpgradeable config =
            IsolatedMarginConfigUpgradeable(vm.envAddress("ISOLATED_MARGIN_CONFIG"));
        address marginPToken = vm.envAddress("MARGIN_PTOKEN");
        address positionPToken = vm.envAddress("POSITION_PTOKEN");
        address debtPToken = vm.envAddress("DEBT_PTOKEN");

        require(deployer != address(0), "ConfigureMargin: zero deployer");
        require(address(config).code.length > 0, "ConfigureMargin: config not contract");
        require(config.owner() == deployer, "ConfigureMargin: broadcaster not owner");
        address pairController = _validatePairMarkets(marginPToken, positionPToken, debtPToken);

        IsolatedMarginTypes.PairRiskConfig memory risk = riskFromEnvironment();
        validateFujiRiskConfig(risk);

        bool unpauseOpens = vm.envOr("UNPAUSE_OPENS", false);
        if (unpauseOpens) {
            _requireFujiUnpauseGates(config, marginPToken, positionPToken, debtPToken, pairController);
        }

        vm.startBroadcast(deployer);
        if (vm.envOr("EXECUTE", false)) {
            config.setPairRisk(marginPToken, positionPToken, debtPToken, risk);
            if (unpauseOpens) config.unpauseOpens();
            actionId = keccak256(abi.encode("pairRisk", config.pairKey(marginPToken, positionPToken, debtPToken), risk));
            console2.log("Executed pair risk action");
        } else {
            actionId = config.queuePairRisk(marginPToken, positionPToken, debtPToken, risk);
            if (unpauseOpens) {
                bytes32 unpauseActionId = config.queueUnpauseOpens();
                console2.log("Queued unpause action");
                console2.logBytes32(unpauseActionId);
            }
            console2.log("Queued pair risk action");
            console2.log("Execute after", config.queuedActions(actionId));
        }
        vm.stopBroadcast();
        console2.logBytes32(actionId);
    }

    function fujiRiskDefaults() public pure returns (IsolatedMarginTypes.PairRiskConfig memory) {
        return IsolatedMarginTypes.PairRiskConfig({
            enabled: true,
            maxLeverageX100: 200,
            initialMarginBps: 5_000,
            maintenanceMarginBps: 3_500,
            liquidationTargetBps: 12_500,
            fullLiquidationHealthBps: 5_000,
            maxLiquidationBps: 5_000,
            liquidationBonusBps: 500,
            maxSlippageBps: 100,
            oracleDeviationBps: 100,
            maxPositionValueUsd: uint128(10_000e18),
            maxDebtValueUsd: uint128(5_000e18)
        });
    }

    function validateFujiRiskConfig(IsolatedMarginTypes.PairRiskConfig memory risk) public pure {
        IsolatedMarginMath.validateRiskConfig(risk);
        require(
            risk.maxPositionValueUsd > 0 && risk.maxDebtValueUsd > 0 && risk.maxDebtValueUsd < risk.maxPositionValueUsd,
            "ConfigureMargin: finite caps required"
        );
    }

    function riskFromEnvironment() public view returns (IsolatedMarginTypes.PairRiskConfig memory risk) {
        IsolatedMarginTypes.PairRiskConfig memory defaults = fujiRiskDefaults();
        risk = IsolatedMarginTypes.PairRiskConfig({
            enabled: true,
            maxLeverageX100: vm.envOr("MAX_LEVERAGE_X100", uint256(defaults.maxLeverageX100)).toUint16(),
            initialMarginBps: vm.envOr("INITIAL_MARGIN_BPS", uint256(defaults.initialMarginBps)).toUint16(),
            maintenanceMarginBps: vm.envOr("MAINTENANCE_MARGIN_BPS", uint256(defaults.maintenanceMarginBps)).toUint16(),
            liquidationTargetBps: vm.envOr("LIQUIDATION_TARGET_BPS", uint256(defaults.liquidationTargetBps)).toUint16(),
            fullLiquidationHealthBps: vm.envOr(
                    "FULL_LIQUIDATION_HEALTH_BPS", uint256(defaults.fullLiquidationHealthBps)
                ).toUint16(),
            maxLiquidationBps: vm.envOr("MAX_LIQUIDATION_BPS", uint256(defaults.maxLiquidationBps)).toUint16(),
            liquidationBonusBps: vm.envOr("LIQUIDATION_BONUS_BPS", uint256(defaults.liquidationBonusBps)).toUint16(),
            maxSlippageBps: vm.envOr("MAX_SLIPPAGE_BPS", uint256(defaults.maxSlippageBps)).toUint16(),
            oracleDeviationBps: vm.envOr("ORACLE_DEVIATION_BPS", uint256(defaults.oracleDeviationBps)).toUint16(),
            maxPositionValueUsd: vm.envOr("MAX_POSITION_VALUE_USD", uint256(defaults.maxPositionValueUsd)).toUint128(),
            maxDebtValueUsd: vm.envOr("MAX_DEBT_VALUE_USD", uint256(defaults.maxDebtValueUsd)).toUint128()
        });
    }

    function _requireFujiUnpauseGates(
        IsolatedMarginConfigUpgradeable config,
        address marginPToken,
        address positionPToken,
        address debtPToken,
        address pairController
    ) internal view {
        require(vm.envOr("CONFIRM_ALL_FUJI_PAIRS_CONFIGURED", false), "ConfigureMargin: pairs not confirmed");
        require(vm.envOr("CONFIRM_FUJI_ROUTE_TESTED", false), "ConfigureMargin: route not confirmed");
        require(vm.envOr("CONFIRM_FUJI_ORACLES", false), "ConfigureMargin: oracles not confirmed");
        require(vm.envOr("CONFIRM_FUJI_LIFECYCLE_TESTS", false), "ConfigureMargin: lifecycle not confirmed");
        require(vm.envOr("CONFIRM_FUJI_LIQUIDATION_TESTED", false), "ConfigureMargin: liquidation not confirmed");

        IsolatedMarginRiskEngineUpgradeable riskEngine =
            IsolatedMarginRiskEngineUpgradeable(vm.envAddress("ISOLATED_MARGIN_RISK_ENGINE"));
        require(address(riskEngine).code.length > 0, "ConfigureMargin: risk engine not contract");
        require(address(riskEngine.config()) == address(config), "ConfigureMargin: wrong risk config");
        require(riskEngine.controller() == pairController, "ConfigureMargin: wrong risk controller");

        require(config.opensPaused(), "ConfigureMargin: opens already active");
        require(config.routerAdapter().code.length > 0, "ConfigureMargin: router not contract");
        address flashLoanProvider = config.flashLoanProvider();
        require(flashLoanProvider.code.length > 0, "ConfigureMargin: lender not contract");
        require(config.feeImmediateShareBps() == 0, "ConfigureMargin: immediate fee enabled");
        require(config.feeStreamDuration() == 7 days, "ConfigureMargin: unexpected fee stream");

        uint256 minimumInsuranceBalance = vm.envUint("MIN_INSURANCE_PTOKEN_BALANCE");
        require(minimumInsuranceBalance > 0, "ConfigureMargin: zero insurance minimum");
        require(config.insuranceFund().code.length > 0, "ConfigureMargin: insurance not contract");
        require(
            IERC20(marginPToken).balanceOf(config.insuranceFund()) >= minimumInsuranceBalance,
            "ConfigureMargin: insurance underfunded"
        );

        IMarginPriceOracle oracle = riskEngine.oracle();
        require(address(oracle).code.length > 0, "ConfigureMargin: oracle not contract");
        _requirePrice(oracle, marginPToken);
        _requirePrice(oracle, positionPToken);
        _requirePrice(oracle, debtPToken);

        address debtAsset = PErc20(debtPToken).underlying();
        uint256 minimumFlashLiquidity = vm.envUint("MIN_FLASH_LIQUIDITY_UNDERLYING");
        require(minimumFlashLiquidity > 0, "ConfigureMargin: zero flash minimum");
        require(
            IERC3156FlashLender(flashLoanProvider).maxFlashLoan(debtAsset) >= minimumFlashLiquidity,
            "ConfigureMargin: insufficient flash liquidity"
        );
    }

    function _validatePairMarkets(address marginPToken, address positionPToken, address debtPToken)
        internal
        view
        returns (address controller)
    {
        require(
            marginPToken.code.length > 0 && positionPToken.code.length > 0 && debtPToken.code.length > 0,
            "ConfigureMargin: pToken not contract"
        );

        address marginAsset = PErc20(marginPToken).underlying();
        address positionAsset = PErc20(positionPToken).underlying();
        address debtAsset = PErc20(debtPToken).underlying();
        require(
            marginAsset.code.length > 0 && positionAsset.code.length > 0 && debtAsset.code.length > 0,
            "ConfigureMargin: asset not contract"
        );
        require(positionAsset != debtAsset, "ConfigureMargin: identical position and debt");
        require(
            marginAsset == positionAsset || marginAsset == debtAsset,
            "ConfigureMargin: margin asset must match one side"
        );

        controller = address(PErc20(marginPToken).peridottroller());
        require(controller.code.length > 0, "ConfigureMargin: controller not contract");
        require(
            address(PErc20(positionPToken).peridottroller()) == controller
                && address(PErc20(debtPToken).peridottroller()) == controller,
            "ConfigureMargin: wrong pToken controller"
        );
    }

    function _requirePrice(IMarginPriceOracle oracle, address pToken) private view {
        address asset = oracle.marketAsset(pToken);
        require(asset != address(0) && oracle.getPrice(asset) > 0, "ConfigureMargin: price unavailable");
    }
}
