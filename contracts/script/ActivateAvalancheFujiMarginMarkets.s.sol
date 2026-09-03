// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";

import {PErc20} from "../contracts/PErc20.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PToken} from "../contracts/PToken.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";

/**
 * @notice Enables borrowing in the fresh Fuji markets only after isolated-margin wiring is live.
 * @dev Spot collateral factors remain zero, so ordinary accounts cannot use these markets to borrow.
 *      Margin position opening remains independently paused in IsolatedMarginConfig.
 */
contract ActivateAvalancheFujiMarginMarkets is Script {
    uint256 private constant AVALANCHE_FUJI_CHAIN_ID = 43_113;
    address private constant DEFAULT_WAVAX = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;
    address private constant DEFAULT_LFJ_USDC = 0xB6076C93701D6a07266c31066B298AeC6dd65c2d;

    function run() external {
        require(block.chainid == AVALANCHE_FUJI_CHAIN_ID, "ActivateFujiMarkets: Fuji only");
        require(vm.envBool("ACTIVATE_FUJI_MARGIN_BORROWS"), "ActivateFujiMarkets: confirmation required");

        address deployer = vm.envAddress("MARGIN_DEPLOYER");
        Peridottroller controller = Peridottroller(vm.envAddress("PERIDOTTROLLER"));
        PErc20 pWavax = PErc20(vm.envAddress("PWAVAX"));
        PErc20 pUsdc = PErc20(vm.envAddress("PUSDC"));
        IsolatedMarginRiskEngineUpgradeable riskEngine =
            IsolatedMarginRiskEngineUpgradeable(vm.envAddress("ISOLATED_MARGIN_RISK_ENGINE"));
        address wavax = vm.envOr("FUJI_WAVAX", DEFAULT_WAVAX);
        address usdc = vm.envOr("FUJI_LFJ_USDC", DEFAULT_LFJ_USDC);

        require(deployer != address(0), "ActivateFujiMarkets: zero deployer");
        require(address(controller).code.length > 0, "ActivateFujiMarkets: controller not contract");
        require(controller.admin() == deployer, "ActivateFujiMarkets: broadcaster not admin");
        require(
            address(pWavax).code.length > 0 && address(pUsdc).code.length > 0,
            "ActivateFujiMarkets: market not contract"
        );
        require(address(pWavax) != address(pUsdc), "ActivateFujiMarkets: duplicate market");
        require(pWavax.underlying() == wavax, "ActivateFujiMarkets: wrong pWAVAX asset");
        require(pUsdc.underlying() == usdc, "ActivateFujiMarkets: wrong pUSDC asset");
        require(address(riskEngine).code.length > 0, "ActivateFujiMarkets: risk engine not contract");
        require(riskEngine.controller() == address(controller), "ActivateFujiMarkets: wrong risk controller");
        require(controller.isolatedMarginRiskHook() == address(riskEngine), "ActivateFujiMarkets: wrong risk hook");
        require(controller.isolatedMarginRegistrar() == address(riskEngine), "ActivateFujiMarkets: wrong registrar");
        require(riskEngine.config().opensPaused(), "ActivateFujiMarkets: margin opens active");
        _validateMarket(controller, pWavax);
        _validateMarket(controller, pUsdc);

        vm.startBroadcast(deployer);
        require(
            controller._setBorrowPaused(PToken(address(pWavax)), false) == false, "ActivateFujiMarkets: pWAVAX unpause"
        );
        require(
            controller._setBorrowPaused(PToken(address(pUsdc)), false) == false, "ActivateFujiMarkets: pUSDC unpause"
        );
        vm.stopBroadcast();

        console2.log("Fuji isolated-margin borrowing enabled for pWAVAX", address(pWavax));
        console2.log("Fuji isolated-margin borrowing enabled for pUSDC", address(pUsdc));
        console2.log("Spot collateral factors remain zero and margin position opening remains paused");
    }

    function _validateMarket(Peridottroller controller, PErc20 pToken) private view {
        require(pToken.peridottroller() == controller, "ActivateFujiMarkets: wrong controller");
        (bool listed, uint256 collateralFactor,) = controller.markets(address(pToken));
        require(listed, "ActivateFujiMarkets: market not listed");
        require(collateralFactor == 0, "ActivateFujiMarkets: spot collateral enabled");
        require(controller.borrowGuardianPaused(address(pToken)), "ActivateFujiMarkets: borrow already active");
        uint256 borrowCap = controller.borrowCaps(address(pToken));
        require(borrowCap > 0 && borrowCap > pToken.totalBorrows(), "ActivateFujiMarkets: invalid borrow cap");
        require(
            controller.oracle().getUnderlyingPrice(PToken(address(pToken))) > 0,
            "ActivateFujiMarkets: price unavailable"
        );
        require(pToken.getCash() > 0, "ActivateFujiMarkets: no market cash");
        require(pToken.flashLoansPaused(), "ActivateFujiMarkets: pToken flash active");
    }
}
