// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {RobinhoodBoostedDelegate} from "../contracts/boosted/RobinhoodBoostedDelegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../contracts/InterestRateModel.sol";

/**
 * @notice Deploys an initially unconfigured and paused Robinhood-backed pUSDG market.
 * @dev Deployment deliberately uses empty becomeImplementationData to avoid a circular
 *      dependency: governance must first register the production vault pair with the
 *      resulting delegator as USDG_SIDE_ACCOUNT, then queue setVaultConfig on the pToken.
 */
contract DeployRobinhoodBoostedDelegator is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "WRONG_CHAIN");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address underlying = vm.envAddress("UNDERLYING");
        address peridottroller = vm.envAddress("PERIDOTTROLLER");
        address interestRateModel = vm.envAddress("INTEREST_RATE_MODEL");
        address payable admin = payable(vm.envAddress("ADMIN"));
        string memory name = vm.envOr("PTOKEN_NAME", string("Peridot Robinhood Boosted USDG"));
        string memory symbol = vm.envOr("PTOKEN_SYMBOL", string("pUSDG"));
        uint8 pTokenDecimals = uint8(vm.envOr("PTOKEN_DECIMALS", uint256(8)));
        uint256 initialExchangeRate =
            vm.envOr("INITIAL_EXCHANGE_RATE", _defaultInitialExchangeRate(underlying, pTokenDecimals));

        require(underlying.code.length != 0, "UNDERLYING_NOT_CONTRACT");
        require(peridottroller.code.length != 0, "PERIDOTTROLLER_NOT_CONTRACT");
        require(interestRateModel.code.length != 0, "IRM_NOT_CONTRACT");
        require(admin != address(0), "ADMIN_ZERO");

        vm.startBroadcast(deployerKey);
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
        console2.log("pUSDG delegator", address(delegator));
        console2.log("admin / timelock", admin);
        console2.log("initially vault configured", address(0));
        console2.log("initially vault paused", true);
        console2.log("next: register NVDA/USDG with pUSDG as USDG_SIDE_ACCOUNT");
        console2.log("then: queueSetVaultConfig and queueSetVaultPaused(false)");
    }

    function _defaultInitialExchangeRate(address underlying, uint8 pTokenDecimals) internal view returns (uint256) {
        uint8 underlyingDecimals = IERC20Metadata(underlying).decimals();
        require(underlyingDecimals <= 18, "UNDERLYING_DECIMALS");
        require(pTokenDecimals <= underlyingDecimals + 16, "PTOKEN_DECIMALS");
        // 0.02 underlying per pToken, normalized for the selected decimal precisions.
        return 2 * (10 ** (underlyingDecimals + 16 - pTokenDecimals));
    }
}
