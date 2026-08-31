// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {PErc20} from "../contracts/PErc20.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PharaohVaultShareOracle} from "../contracts/PharaohVaultShareOracle.sol";
import {PToken} from "../contracts/PToken.sol";

interface ILaunchPharaohVault is IERC4626 {
    function depositCap() external view returns (uint256);
}

/**
 * @notice Installs and configures deployed Pharaoh vault-share markets on Avalanche.
 * @dev The default bootstrap mode lists both markets with zero collateral factor, minting paused,
 *      borrowing paused, and one-raw-share borrow caps. Activation is separately gated and keeps
 *      borrowing paused unless ENABLE_BORROWING is explicitly set.
 *
 *      Production controller and market administration should be a multisig. In that case use these
 *      exact calls in one reviewed Safe batch rather than broadcasting an EOA private key.
 */
contract ConfigurePharaohBoostedMarketsAvalanche is Script {
    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;
    uint256 private constant MANTISSA_ONE = 1e18;

    address private constant USDC_VAULT = 0x855bF832f26a294d28500db59eE941dE3d654129;
    address private constant WAVAX_VAULT = 0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8;

    error ConfigurePharaohMarkets__WrongChain(uint256 actual);
    error ConfigurePharaohMarkets__InvalidAddress(address target);
    error ConfigurePharaohMarkets__WrongAdmin(address expected, address actual);
    error ConfigurePharaohMarkets__InvalidMarket(address market);
    error ConfigurePharaohMarkets__LaunchGate();
    error ConfigurePharaohMarkets__ControllerError(uint256 code);

    function run() external {
        if (block.chainid != AVALANCHE_CHAIN_ID) revert ConfigurePharaohMarkets__WrongChain(block.chainid);

        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address broadcaster = vm.addr(adminKey);
        Peridottroller controller = Peridottroller(vm.envAddress("PERIDOTTROLLER"));
        PharaohVaultShareOracle oracle = PharaohVaultShareOracle(vm.envAddress("PHARAOH_SHARE_ORACLE"));
        PErc20Delegator usdcMarket = PErc20Delegator(payable(vm.envAddress("PHARAOH_USDC_PTOKEN")));
        PErc20Delegator wavaxMarket = PErc20Delegator(payable(vm.envAddress("PHARAOH_WAVAX_PTOKEN")));

        _requireContract(address(controller));
        _requireContract(address(oracle));
        _validateMarket(usdcMarket, USDC_VAULT, oracle);
        _validateMarket(wavaxMarket, WAVAX_VAULT, oracle);
        if (controller.admin() != broadcaster) {
            revert ConfigurePharaohMarkets__WrongAdmin(controller.admin(), broadcaster);
        }

        bool activate = vm.envOr("ACTIVATE_MARKETS", false);
        bool enableBorrowing = vm.envOr("ENABLE_BORROWING", false);
        bool setReserveFactors = vm.envOr("SET_RESERVE_FACTORS", false);

        if (activate) _requireActivationGates(usdcMarket, wavaxMarket);
        if (enableBorrowing && !activate) revert ConfigurePharaohMarkets__LaunchGate();

        vm.startBroadcast(adminKey);
        if (address(controller.oracle()) != address(oracle)) {
            if (address(controller.oracle()) != address(oracle.baseOracle())) {
                revert ConfigurePharaohMarkets__LaunchGate();
            }
            _requireNoError(controller._setPriceOracle(oracle));
        }

        _listIfNeeded(controller, usdcMarket);
        _listIfNeeded(controller, wavaxMarket);

        if (activate) {
            _activate(controller, usdcMarket, wavaxMarket, enableBorrowing);
        } else {
            _bootstrapPaused(controller, usdcMarket, wavaxMarket);
        }

        if (setReserveFactors) {
            uint256 usdcReserveFactor = vm.envOr("USDC_RESERVE_FACTOR", uint256(1e17));
            uint256 wavaxReserveFactor = vm.envOr("WAVAX_RESERVE_FACTOR", uint256(1e17));
            if (usdcMarket.admin() != broadcaster) {
                revert ConfigurePharaohMarkets__WrongAdmin(usdcMarket.admin(), broadcaster);
            }
            if (wavaxMarket.admin() != broadcaster) {
                revert ConfigurePharaohMarkets__WrongAdmin(wavaxMarket.admin(), broadcaster);
            }
            _requireNoError(usdcMarket._setReserveFactor(usdcReserveFactor));
            _requireNoError(wavaxMarket._setReserveFactor(wavaxReserveFactor));
        }
        vm.stopBroadcast();

        console2.log(activate ? "Pharaoh markets activated" : "Pharaoh markets bootstrapped paused");
        console2.log("USDC/USDt market", address(usdcMarket));
        console2.log("sAVAX/WAVAX market", address(wavaxMarket));
        console2.log("Borrowing enabled", activate && enableBorrowing);
    }

    function _bootstrapPaused(Peridottroller controller, PErc20Delegator usdcMarket, PErc20Delegator wavaxMarket)
        private
    {
        _requireNoError(controller._setCollateralFactor(PToken(address(usdcMarket)), 0));
        _requireNoError(controller._setCollateralFactor(PToken(address(wavaxMarket)), 0));

        PToken[] memory markets = _markets(usdcMarket, wavaxMarket);
        uint256[] memory caps = new uint256[](2);
        caps[0] = 1;
        caps[1] = 1;
        controller._setMarketBorrowCaps(markets, caps);
        controller._setMintPaused(PToken(address(usdcMarket)), true);
        controller._setMintPaused(PToken(address(wavaxMarket)), true);
        controller._setBorrowPaused(PToken(address(usdcMarket)), true);
        controller._setBorrowPaused(PToken(address(wavaxMarket)), true);
    }

    function _activate(
        Peridottroller controller,
        PErc20Delegator usdcMarket,
        PErc20Delegator wavaxMarket,
        bool enableBorrowing
    ) private {
        uint256 usdcCollateralFactor = vm.envOr("USDC_COLLATERAL_FACTOR", uint256(35e16));
        uint256 wavaxCollateralFactor = vm.envOr("WAVAX_COLLATERAL_FACTOR", uint256(25e16));
        if (usdcCollateralFactor > MANTISSA_ONE || wavaxCollateralFactor > MANTISSA_ONE) {
            revert ConfigurePharaohMarkets__LaunchGate();
        }

        _requireNoError(controller._setCollateralFactor(PToken(address(usdcMarket)), usdcCollateralFactor));
        _requireNoError(controller._setCollateralFactor(PToken(address(wavaxMarket)), wavaxCollateralFactor));
        controller._setMintPaused(PToken(address(usdcMarket)), false);
        controller._setMintPaused(PToken(address(wavaxMarket)), false);

        PToken[] memory markets = _markets(usdcMarket, wavaxMarket);
        uint256[] memory caps = new uint256[](2);
        if (enableBorrowing) {
            caps[0] = vm.envUint("USDC_BORROW_CAP");
            caps[1] = vm.envUint("WAVAX_BORROW_CAP");
            if (caps[0] <= 1 || caps[1] <= 1) revert ConfigurePharaohMarkets__LaunchGate();
            controller._setMarketBorrowCaps(markets, caps);
            controller._setBorrowPaused(PToken(address(usdcMarket)), false);
            controller._setBorrowPaused(PToken(address(wavaxMarket)), false);
        } else {
            caps[0] = 1;
            caps[1] = 1;
            controller._setMarketBorrowCaps(markets, caps);
            controller._setBorrowPaused(PToken(address(usdcMarket)), true);
            controller._setBorrowPaused(PToken(address(wavaxMarket)), true);
        }
    }

    function _requireActivationGates(PErc20Delegator usdcMarket, PErc20Delegator wavaxMarket) private view {
        if (
            !vm.envOr("CONFIRM_EXTERNAL_AUDIT", false) || !vm.envOr("CONFIRM_CURRENT_FORK_TESTS", false)
                || !vm.envOr("CONFIRM_PUBLIC_REWARD_POLICY", false)
        ) revert ConfigurePharaohMarkets__LaunchGate();

        ILaunchPharaohVault usdcVault = ILaunchPharaohVault(USDC_VAULT);
        ILaunchPharaohVault wavaxVault = ILaunchPharaohVault(WAVAX_VAULT);
        if (
            usdcVault.maxDeposit(address(usdcMarket)) == 0 || wavaxVault.maxDeposit(address(wavaxMarket)) == 0
                || usdcVault.depositCap() == 1 || wavaxVault.depositCap() == 1
        ) revert ConfigurePharaohMarkets__LaunchGate();
    }

    function _validateMarket(PErc20Delegator market, address expectedVault, PharaohVaultShareOracle oracle)
        private
        view
    {
        _requireContract(address(market));
        if (market.underlying() != expectedVault || oracle.getUnderlyingPrice(PToken(address(market))) == 0) {
            revert ConfigurePharaohMarkets__InvalidMarket(address(market));
        }
    }

    function _listIfNeeded(Peridottroller controller, PErc20Delegator market) private {
        (bool isListed,,) = controller.markets(address(market));
        if (!isListed) _requireNoError(controller._supportMarket(PToken(address(market))));
    }

    function _markets(PErc20Delegator usdcMarket, PErc20Delegator wavaxMarket)
        private
        pure
        returns (PToken[] memory markets)
    {
        markets = new PToken[](2);
        markets[0] = PToken(address(usdcMarket));
        markets[1] = PToken(address(wavaxMarket));
    }

    function _requireContract(address target) private view {
        if (target == address(0) || target.code.length == 0) {
            revert ConfigurePharaohMarkets__InvalidAddress(target);
        }
    }

    function _requireNoError(uint256 code) private pure {
        if (code != 0) revert ConfigurePharaohMarkets__ControllerError(code);
    }
}
