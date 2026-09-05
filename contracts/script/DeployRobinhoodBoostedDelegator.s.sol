// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RobinhoodBoostedDelegate} from "../contracts/boosted/RobinhoodBoostedDelegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";

/**
 * @notice Deploys an initially unconfigured and paused Robinhood-backed boosted market.
 * @dev Works for either side of a paired vault. RobinhoodBoostedDelegate routes every vault
 *      call through `underlying`, so the stock-side and USDG-side markets are two deployments
 *      of one implementation rather than two contracts. Set UNDERLYING accordingly.
 *
 *      becomeImplementationData is deliberately empty to avoid a circular dependency:
 *      governance must first register the vault pair with the resulting delegator as that
 *      side's account, then queue setVaultConfig on the pToken.
 *
 *      Broadcasts bind to the public DEPLOYER address. Sign with --account and an encrypted
 *      keystore or a hardware wallet; this script accepts no private key.
 */
contract DeployRobinhoodBoostedDelegator is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "WRONG_CHAIN");
        address deployer = vm.envAddress("DEPLOYER");
        address underlying = vm.envAddress("UNDERLYING");
        address peridottroller = vm.envAddress("PERIDOTTROLLER");
        address interestRateModel = vm.envAddress("INTEREST_RATE_MODEL");
        address payable admin = payable(vm.envAddress("ADMIN"));
        // Defaults follow the house convention for boosted markets (bpPHAR-USDC and friends)
        // and derive from the underlying, so neither side is hardcoded.
        string memory underlyingSymbol = IERC20Metadata(underlying).symbol();
        string memory name = vm.envOr("PTOKEN_NAME", string.concat("Peridot Robinhood Boosted ", underlyingSymbol));
        string memory symbol = vm.envOr("PTOKEN_SYMBOL", string.concat("bp", underlyingSymbol));
        uint8 pTokenDecimals = uint8(vm.envOr("PTOKEN_DECIMALS", uint256(8)));
        uint256 initialExchangeRate =
            vm.envOr("INITIAL_EXCHANGE_RATE", _defaultInitialExchangeRate(underlying, pTokenDecimals));

        require(deployer != address(0), "ZERO_DEPLOYER");
        require(underlying.code.length != 0, "UNDERLYING_NOT_CONTRACT");
        require(peridottroller.code.length != 0, "PERIDOTTROLLER_NOT_CONTRACT");
        require(interestRateModel.code.length != 0, "IRM_NOT_CONTRACT");
        require(admin != address(0), "ADMIN_ZERO");

        vm.startBroadcast(deployer);
        RobinhoodBoostedDelegate implementation = new RobinhoodBoostedDelegate();
        PErc20Delegator delegator = new PErc20Delegator(
            underlying,
            PeridottrollerInterface(peridottroller),
            InterestRateModel(interestRateModel),
            initialExchangeRate,
            name,
            symbol,
            pTokenDecimals,
            admin,
            address(implementation),
            bytes("")
        );
        vm.stopBroadcast();

        console2.log("RobinhoodBoostedDelegate", address(implementation));
        console2.log("delegator", address(delegator));
        console2.log("underlying", underlying);
        console2.log("symbol", symbol);
        console2.log("admin / timelock", admin);
        console2.log("initially vault configured", address(0));
        console2.log("initially vault paused", true);
        console2.log("next: register the vault pair with this delegator as that side's account");
        console2.log("then: queue-config and queue-unpause via ConfigureRobinhoodBoostedDelegator");
    }

    function _defaultInitialExchangeRate(address underlying, uint8 pTokenDecimals) internal view returns (uint256) {
        uint8 underlyingDecimals = IERC20Metadata(underlying).decimals();
        require(underlyingDecimals <= 18, "UNDERLYING_DECIMALS");
        require(pTokenDecimals <= underlyingDecimals + 16, "PTOKEN_DECIMALS");
        // 0.02 underlying per pToken, normalized for the selected decimal precisions.
        return 2 * (10 ** (underlyingDecimals + 16 - pTokenDecimals));
    }
}
