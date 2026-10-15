// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {IsolatedMarginConfigUpgradeable as Config} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";
import {ConfigureFujiCollateralMargin as Configure} from "./ConfigureFujiCollateralMargin.s.sol";
import {ExerciseFujiMarginRunner as Pins} from "./ExerciseFujiMarginRunner.s.sol";

/// @notice Eight sequential, fixed-size Fuji MOCK liquidation scenarios after IDs1–16.
/// This generates MULTI-SENDER calls: OWNER controls feeds/acts as keeper; RUNNER owns trades.
/// Never broadcast through the old one-use runner or with only one of these signers.
/// No deposits, withdrawals, new permissions, minting or production configuration changes.
contract LiquidateFujiMarginRunner is Pins {
    uint256 public constant FIRST_ID = 17;
    uint256 public constant CASES = 8;

    function runScenario(uint8 scenario) external {
        require(block.chainid == 43_113, "FujiLiq: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_RUNNER_LIQUIDATION", false), "FujiLiq: confirmation");
        require(scenario < CASES, "FujiLiq: scenario");
        _checkpoint(scenario);
        address token = collateral(scenario);
        uint256 shares = marginShares(scenario); // $10 at the unchanged baseline NAV
        bool short = scenario % 2 == 1;
        bool full = scenario % 4 >= 2;
        vm.startBroadcast(OWNER);
        USD_FEED.setAnswer(1e8);
        AVAX_FEED.setAnswer(10e8);
        vm.stopBroadcast();

        vm.startBroadcast(RUNNER);
        require(PErc20(E.settlement().pUsd()).exchangeRateCurrent() > 0, "FujiLiq: accrue USD");
        require(PErc20(E.settlement().pWavax()).exchangeRateCurrent() > 0, "FujiLiq: accrue AVAX");
        require(PErc20(USD_COLLATERAL).exchangeRateCurrent() > 0, "FujiLiq: accrue USD collateral");
        require(PErc20(AVAX_COLLATERAL).exchangeRateCurrent() > 0, "FujiLiq: accrue AVAX collateral");
        require(E.risk().pTokenValue(token, shares) == 10e18, "FujiLiq: baseline NAV");
        Executor.OpenParams memory op;
        op.collateral = token;
        op.short = short;
        op.collateralShares = shares;
        op.leverageX100 = 500;
        op.maxFeeShares = shares / 100; // $0.10 maximum opening fee
        (, op.minPositionOut) = E.risk().quoteOpen(token, short, shares, 500);
        op.deadline = block.timestamp + 1 hours;
        uint256 id = E.openPosition(op);
        require(id == FIRST_ID + scenario, "FujiLiq: new id");
        vm.stopBroadcast();
        (, address account,,, address debt,) = E.positions(id);
        Risk.Snapshot memory entry = E.risk().snapshot(account, 0);
        require(!entry.metrics.liquidatable && entry.metrics.healthFactorBps >= 20_000, "FujiLiq: healthy entry");
        require(IERC20(token).balanceOf(account) == shares, "FujiLiq: collateral retained");
        _healthyReject(id); // local-only probe, NEVER a transaction in the broadcast list

        address asset = PErc20(debt).underlying();
        address insurance = E.config().insuranceFund();
        uint256 cashBefore = IERC20(asset).balanceOf(insurance);
        uint256 cap = coverageCap(scenario);
        require(cashBefore >= cap, "FujiLiq: insurance cash");
        uint256 debtBefore = PErc20(debt).borrowBalanceStored(account);
        vm.startBroadcast(OWNER);
        AVAX_FEED.setAnswer(int256(stressPrice(scenario)));
        Risk.Snapshot memory stress = E.risk().snapshot(account, 0);
        require(stress.metrics.liquidatable, "FujiLiq: stress not liquidatable");
        if (full) require(stress.metrics.equityUsd < 0, "FujiLiq: full must exercise insolvency");
        Executor.CloseParams memory lp = _exit(id, full ? 10_000 : 5000);
        E.liquidate(lp, cap);
        uint256 cashAfter = IERC20(asset).balanceOf(insurance);
        uint256 used = cashBefore > cashAfter ? cashBefore - cashAfter : 0;
        if (full) {
            require(used > 0 && used <= cap, "FujiLiq: coverage usage");
            _finished(id, Types.Status.LIQUIDATED);
        } else {
            require(cashAfter == cashBefore, "FujiLiq: partial insurance forbidden");
            Risk.Snapshot memory afterLiq = E.risk().snapshot(account, 0);
            require(afterLiq.metrics.healthFactorBps > stress.metrics.healthFactorBps, "FujiLiq: no health improvement");
            uint256 remaining = PErc20(debt).borrowBalanceStored(account);
            require(remaining > 0 && remaining < debtBefore, "FujiLiq: partial debt");
        }
        AVAX_FEED.setAnswer(10e8); // owner-signed restoration is part of EVERY case
        vm.stopBroadcast();
        if (!full) {
            Executor.CloseParams memory cp = _exit(id, 10_000);
            cp.maxFeeShares = shares / 100;
            cp.maxCollateralSharesToSell = shares / 5; // $2 voluntary close only; NOT a liquidation-loss limit
            vm.startBroadcast(RUNNER);
            E.closePosition(cp);
            vm.stopBroadcast();
            _finished(id, Types.Status.CLOSED);
        }
        _noDebtOrLocks();
        require(USD_FEED.answer() == 1e8 && AVAX_FEED.answer() == 10e8, "FujiLiq: prices not restored");
        console2.log("MOCK scenario / id", scenario, id);
        console2.log("MOCK raw insurance consumed", used);
    }

    function collateral(uint8 scenario) public pure returns (address) {
        return scenario < 4 ? USD_COLLATERAL : AVAX_COLLATERAL;
    }

    function marginShares(uint8 scenario) public pure returns (uint256) {
        return scenario < 4 ? 500e8 : 50e8;
    }

    function coverageCap(uint8 scenario) public pure returns (uint256) {
        if (scenario % 4 < 2) return 0;
        return scenario % 2 == 0 ? 50e6 : 5e18;
    }

    function stressPrice(uint8 scenario) public pure returns (uint256) {
        if (scenario % 4 >= 2) return scenario % 2 == 0 ? 5e8 : 20e8;
        if (scenario < 4) return scenario % 2 == 0 ? 870_000_000 : 1_130_000_000;
        return scenario % 2 == 0 ? 880_000_000 : 1_160_000_000;
    }

    function _checkpoint(uint8 scenario) private {
        require(E.nextPositionId() == FIRST_ID + scenario, "FujiLiq: history/replay");
        require(USD_FEED.owner() == OWNER && AVAX_FEED.owner() == OWNER, "FujiLiq: feed owners");
        require(USD_FEED.answer() == 1e8 && AVAX_FEED.answer() == 10e8, "FujiLiq: baseline prices");
        require(E.risk().owner() == OWNER && E.risk().executor() == address(E), "FujiLiq: risk owner");
        require(
            E.executionVersion() == keccak256("collateral-preserving-executor-v1")
                && E.settlement().pUsdVault() == USD_COLLATERAL && E.settlement().pAvaxVault() == AVAX_COLLATERAL
                && E.vault().executor() == address(E),
            "FujiLiq: wiring"
        );
        Config c = Config(address(E.config()));
        require(
            !c.opensPaused() && c.owner() == OWNER && c.actionDelay() == 1 hours && c.openFeeBps() == 10
                && c.closeFeeBps() == 10 && c.depositorShareBps() == 5000 && c.insuranceShareBps() == 5000
                && c.treasuryShareBps() == 0 && c.feeImmediateShareBps() == 0 && c.feeStreamDuration() == 7 days
                && E.risk().usdCollateralWeightBps() == 10_000 && E.risk().avaxCollateralWeightBps() == 10_000,
            "FujiLiq: policy"
        );
        Configure verifier = new Configure(); // local helper, never broadcast
        bytes32 expected = keccak256(abi.encode(verifier.pair()));
        for (uint256 pool; pool < 2; ++pool) {
            address token = pool == 0 ? USD_COLLATERAL : AVAX_COLLATERAL;
            require(
                keccak256(abi.encode(c.getPairRisk(token, E.settlement().pWavax(), E.settlement().pUsd()))) == expected
                    && keccak256(abi.encode(c.getPairRisk(token, E.settlement().pUsd(), E.settlement().pWavax())))
                        == expected,
                "FujiLiq: pair policy"
            );
            require(IERC20(token).allowance(RUNNER, address(E.vault())) == 0, "FujiLiq: approval");
        }
        _noDebtOrLocks();
        address debtAsset = scenario % 2 == 0 ? E.settlement().usd() : E.settlement().wavax();
        require(IERC20(debtAsset).balanceOf(c.insuranceFund()) >= coverageCap(scenario), "FujiLiq: insurance cash");
        require(
            E.vault().freeBalance(RUNNER, collateral(scenario)) >= marginShares(scenario) * 101 / 100,
            "FujiLiq: insufficient existing margin"
        );
        for (uint256 id = 5; id < FIRST_ID; ++id) {
            _finished(id, Types.Status.CLOSED);
        }
        for (uint256 previous; previous < scenario; ++previous) {
            _finished(FIRST_ID + previous, previous % 4 >= 2 ? Types.Status.LIQUIDATED : Types.Status.CLOSED);
        }
    }

    function _healthyReject(uint256 id) private {
        Executor.CloseParams memory p = _exit(id, 5000);
        vm.prank(OWNER);
        (bool ok, bytes memory reason) = address(E).call(abi.encodeCall(Executor.liquidate, (p, 0)));
        require(
            !ok && reason.length == 4 && bytes4(reason) == Risk.UnsafePosition.selector,
            "FujiLiq: healthy liquidation did not reject"
        );
    }

    function _exit(uint256 id, uint16 fraction) private view returns (Executor.CloseParams memory p) {
        p.id = id;
        p.fractionBps = fraction;
        p.deadline = block.timestamp + 1 hours;
        (, address account,, address position, address debt,) = E.positions(id);
        uint256 shares = Math.mulDiv(IERC20(position).balanceOf(account), fraction, 10_000);
        uint256 amount = Math.mulDiv(shares, PErc20(position).exchangeRateStored(), 1e18);
        p.minTradeDebtOut =
            E.quoter().expectedOut(PErc20(position).underlying(), PErc20(debt).underlying(), amount) * 99 / 100;
    }

    function _finished(uint256 id, Types.Status expected) private view {
        (address owner, address account, address c, address position, address debt, uint256 locked) = E.positions(id);
        (,,, Types.Status status,) = E.risk().accounts(account);
        require(
            owner == RUNNER && status == expected && locked == 0 && PErc20(debt).borrowBalanceStored(account) == 0
                && IERC20(c).balanceOf(account) == 0 && IERC20(position).balanceOf(account) == 0,
            "FujiLiq: residue/status"
        );
    }

    function _noDebtOrLocks() private view {
        require(
            PErc20(E.settlement().pUsd()).totalBorrows() == 0 && PErc20(E.settlement().pWavax()).totalBorrows() == 0
                && E.vault().lockedBalance(RUNNER, USD_COLLATERAL) == 0
                && E.vault().lockedBalance(RUNNER, AVAX_COLLATERAL) == 0,
            "FujiLiq: outstanding debt/locks"
        );
    }
}
