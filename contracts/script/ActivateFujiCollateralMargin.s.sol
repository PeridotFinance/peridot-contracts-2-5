// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ConfigureFujiCollateralMargin as Configure} from "./ConfigureFujiCollateralMargin.s.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {
    CollateralPreservingSettlementModule as Settlement
} from "../contracts/margin/CollateralPreservingSettlementModule.sol";
import {IsolatedMarginConfigUpgradeable as Config} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {PharaohMarginRouterAdapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";
import {PharaohCLRouterAdapter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {FujiMockPharaohRouter} from "../contracts/margin/testing/FujiMockPharaoh.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {SimpleFlashLoanVault} from "../contracts/margin/SimpleFlashLoanVault.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {PToken} from "../contracts/PToken.sol";
import {PErc20} from "../contracts/PErc20.sol";

/// @notice First activation of the fresh, configured Fuji mock stack only. No deposits or trades.
/// @dev Seven transactions, opens unpaused LAST. This multi-transaction batch is NOT atomic.
/// Stop/reconcile any partial broadcast; do not blindly rerun or resume it.
contract ActivateFujiCollateralMargin is Script {
    function run() external {
        require(block.chainid == 43_113, "CollateralFuji: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", false), "CollateralFuji: confirmation required");
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_ACTIVATION", false), "CollateralFuji: activation confirmation");
        address owner = vm.envAddress("CP_FUJI_DEPLOYER");
        Executor e = Executor(vm.envAddress("CP_FUJI_EXECUTOR"));
        Configure verifier = new Configure();
        verifier.verifyDelayTransition(address(e), owner);
        _policy(e, verifier);
        Config c = Config(address(e.config()));
        uint256 eta = c.queuedActions(keccak256("unpauseOpens"));
        require(eta != 0 && block.timestamp >= eta, "CollateralFuji: unpause not ready");
        Settlement s = e.settlement();
        Peridottroller controller = Peridottroller(s.controller());
        FujiMockSwapAdapter venue = _venue(e);
        SimpleFlashLoanVault lender = SimpleFlashLoanVault(c.flashLoanProvider());

        vm.startBroadcast(owner);
        venue.usdFeed().setAnswer(1e8);
        venue.avaxFeed().setAnswer(10e8);
        _prices(e, venue); // Read-only checks; no additional transactions.
        venue.setPaused(false);
        lender.setPaused(false);
        controller._setBorrowPaused(PToken(s.pUsd()), false);
        controller._setBorrowPaused(PToken(s.pWavax()), false);
        c.unpauseOpens();
        vm.stopBroadcast();

        verifier.verifyActivated(address(e), owner);
        _policy(e, verifier);
        _prices(e, venue);
        console2.log("FUJI MOCK ONLY: fresh margin stack activated. No deposits or positions opened.");
        console2.log("Boosted collateral borrowing and native pToken flash loans remain paused.");
        console2.log("Verify all seven receipts and fresh state before separately approved smoke trades.");
    }

    /// @notice Read-only initial post-activation verification; not a general live-position monitor.
    function verify(address executor, address owner) external {
        Configure verifier = new Configure();
        verifier.verifyActivated(executor, owner);
        Executor e = Executor(executor);
        _policy(e, verifier);
        _prices(e, _venue(e));
    }

    function _policy(Executor e, Configure verifier) private view {
        Config c = Config(address(e.config()));
        Settlement s = e.settlement();
        require(c.actionDelay() == 1 hours, "CollateralFuji: one-hour policy required");
        require(
            c.openFeeBps() == 10 && c.closeFeeBps() == 10 && c.depositorShareBps() == 5000
                && c.insuranceShareBps() == 5000 && c.treasuryShareBps() == 0,
            "CollateralFuji: activation fees"
        );
        bytes32 expected = keccak256(abi.encode(verifier.pair()));
        address[2] memory collateral = [s.pUsdVault(), s.pAvaxVault()];
        for (uint256 i; i < 2; ++i) {
            require(
                keccak256(abi.encode(c.getPairRisk(collateral[i], s.pWavax(), s.pUsd()))) == expected
                    && keccak256(abi.encode(c.getPairRisk(collateral[i], s.pUsd(), s.pWavax()))) == expected,
                "CollateralFuji: activation pairs"
            );
        }
        bytes32[5] memory ids = verifier.actionIds(address(e));
        for (uint256 i; i < ids.length; ++i) {
            require(c.queuedActions(ids[i]) == 0, "CollateralFuji: pending configuration");
        }
        require(
            c.queuedActions(keccak256(abi.encode("actionDelay", uint256(1 hours)))) == 0,
            "CollateralFuji: pending delay change"
        );
        Peridottroller controller = Peridottroller(s.controller());
        address[4] memory markets = [s.pUsd(), s.pWavax(), s.pUsdVault(), s.pAvaxVault()];
        uint256[4] memory seeds = [uint256(100_000e6), 10_000e18, 10_000e6, 1000e18];
        for (uint256 i; i < 4; ++i) {
            require(
                controller.borrowCaps(markets[i]) == 5 * seeds[i] && PErc20(markets[i]).getCash() >= seeds[i]
                    && PErc20(markets[i]).reserveFactorMantissa() == 0.1e18,
                "CollateralFuji: activation liquidity policy"
            );
        }
    }

    function _venue(Executor e) private view returns (FujiMockSwapAdapter) {
        PharaohMarginRouterAdapter a = PharaohMarginRouterAdapter(e.config().routerAdapter());
        PharaohCLRouterAdapter cl = PharaohCLRouterAdapter(address(a.baseRouter()));
        return FujiMockPharaohRouter(address(cl.router())).venue();
    }

    function _prices(Executor e, FujiMockSwapAdapter venue) private view {
        Settlement s = e.settlement();
        FujiMockPriceFeed[2] memory feeds = [venue.usdFeed(), venue.avaxFeed()];
        for (uint256 i; i < 2; ++i) {
            uint256 updated = feeds[i].updatedAt();
            require(
                feeds[i].IS_FUJI_MOCK() && updated != 0 && updated <= block.timestamp
                    && block.timestamp - updated <= 1200,
                "CollateralFuji: fresh mock feeds required"
            );
        }
        require(
            e.quoter().oracle().getPrice(s.usd()) == 1e18 && e.quoter().oracle().getPrice(s.wavax()) == 10e18
                && e.quoter().oracle().getPrice(s.usdVault()) == 1e18
                && e.quoter().oracle().getPrice(s.avaxVault()) == 10e18,
            "CollateralFuji: activation oracle prices"
        );
    }
}
