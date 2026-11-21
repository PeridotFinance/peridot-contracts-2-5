// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {RobinhoodSpyCollateralDelegate} from "../../contracts/margin/spy/RobinhoodSpyCollateralDelegate.sol";
import {SpyCollateralLiquidator} from "../../contracts/margin/spy/SpyCollateralLiquidator.sol";
import {SpyMarginParams as P} from "./SpyMarginParams.sol";
import {SpyCollateralParams as C} from "./SpyCollateralParams.sol";

/// @notice Creates the two pSPY-collateral contracts (both immutable, no admin). Everything else is a Ledger call.
///
///   simulate:  FOUNDRY_PROFILE=robinhood_spy forge script script/spy/DeploySpyCollateral.s.sol --rpc-url $RPC --sender $DEPLOYER
///   broadcast: add --broadcast --account <throwaway> (never the Ledger, never the old deployer)
///   verify:    SPY_COLLATERAL_ACTION=verify ... (reads deployments/spy-collateral/<SPY_COLLATERAL_JOURNAL>.json)
/// Inputs: SPY_MARGIN_JOURNAL (default spy-margin-mainnet) for the deployed pSPY and SPY session source.
contract DeploySpyCollateral is Script {
    struct Deployed {
        address delegate;
        address liquidator;
    }

    function deployAll(address pSpy, address spySource) public returns (Deployed memory c) {
        c.delegate = address(new RobinhoodSpyCollateralDelegate(spySource));
        c.liquidator = address(
            new SpyCollateralLiquidator(
                P.PUSDG,
                pSpy,
                P.PNVDA,
                P.NVDA_GUARDED_SOURCE,
                P.FLASH_VAULT,
                P.ROUTER_ADAPTER,
                spySource,
                P.LEDGER,
                C.LIQUIDATOR_MAX_SLIPPAGE_BPS,
                C.USDG_DECIMALS
            )
        );
    }

    /// @notice Read-only identity checks against the live system.
    function verify(Deployed memory c, address pSpy, address spySource) public view {
        RobinhoodSpyCollateralDelegate dlg = RobinhoodSpyCollateralDelegate(c.delegate);
        require(address(dlg.spySource()) == spySource, "DELEGATE_SOURCE");
        require(dlg.SOURCE_UNREADABLE() == 255, "DELEGATE_CODE");
        SpyCollateralLiquidator l = SpyCollateralLiquidator(c.liquidator);
        require(
            address(l.debtMarket()) == P.PUSDG && address(l.collateralMarket()) == pSpy && address(l.usdg()) == P.USDG
                && address(l.spy()) == P.SPY && address(l.flashLender()) == P.FLASH_VAULT
                && address(l.nvdaDebtMarket()) == P.PNVDA && address(l.nvda()) == P.NVDA
                && address(l.nvdaPriceSource()) == P.NVDA_GUARDED_SOURCE
                && address(l.router()) == P.ROUTER_ADAPTER && address(l.spySource()) == spySource
                && l.beneficiary() == P.LEDGER && l.maxSlippageBps() == C.LIQUIDATOR_MAX_SLIPPAGE_BPS,
            "LIQUIDATOR"
        );
    }

    function run() external {
        require(block.chainid == P.CHAIN_ID, "CHAIN");
        string memory root = vm.projectRoot();
        string memory mj = vm.readFile(
            string.concat(root, "/deployments/spy-margin/", vm.envOr("SPY_MARGIN_JOURNAL", string("spy-margin-mainnet")), ".json")
        );
        address pSpy = vm.parseJsonAddress(mj, ".pSpy");
        address spySource = vm.parseJsonAddress(mj, ".spySource");
        string memory path = string.concat(
            root, "/deployments/spy-collateral/", vm.envOr("SPY_COLLATERAL_JOURNAL", string("spy-collateral-mainnet")), ".json"
        );
        string memory action = vm.envOr("SPY_COLLATERAL_ACTION", string("deploy"));
        if (keccak256(bytes(action)) == keccak256("verify")) {
            string memory j = vm.readFile(path);
            verify(
                Deployed(vm.parseJsonAddress(j, ".delegate"), vm.parseJsonAddress(j, ".liquidator")), pSpy, spySource
            );
            return;
        }
        require(keccak256(bytes(action)) == keccak256("deploy"), "ACTION");
        vm.startBroadcast();
        Deployed memory c = deployAll(pSpy, spySource);
        vm.stopBroadcast();
        verify(c, pSpy, spySource);
        string memory k = "spyc";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", msg.sender);
        vm.serializeAddress(k, "pSpy", pSpy);
        vm.serializeAddress(k, "spySource", spySource);
        vm.serializeUint(k, "lendingSupplyCapDefault", C.DEFAULT_LENDING_SUPPLY_CAP);
        vm.serializeUint(k, "collateralFactor", C.COLLATERAL_FACTOR);
        vm.serializeAddress(k, "delegate", c.delegate);
        string memory out = vm.serializeAddress(k, "liquidator", c.liquidator);
        vm.writeJson(out, path);
    }
}
