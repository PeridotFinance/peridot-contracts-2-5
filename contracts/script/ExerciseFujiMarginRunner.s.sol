// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {IsolatedMarginConfigUpgradeable as Config} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {ConfigureFujiCollateralMargin as Configure} from "./ConfigureFujiCollateralMargin.s.sol";

/// @notice One-use, fixed-address Fuji mock runner: 34 calls from a non-admin test wallet.
/// Four accruals, two approve/deposit/clear groups, twelve open/full-close pairs. No withdrawals.
/// NO feed updates, minting, governance, liquidation, native transfers or insurance draws.
contract ExerciseFujiMarginRunner is Script {
    address public constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address public constant RUNNER = 0x7Eb84484a3e05F611De42c8954D786100917E726;
    Executor public constant E = Executor(0xA1398d06Cf8d0bE8673A46C67e462718FD99Bf9C);
    address public constant USD_COLLATERAL = 0x8F2a561E459A4cc569b8e5ed21b7d4B23De33978;
    address public constant AVAX_COLLATERAL = 0xC3AF75b81037137FaE18cD1d390a5824E39FFcA8;
    FujiMockPriceFeed public constant USD_FEED = FujiMockPriceFeed(0xF7c5D63f1828699665b8f0Dfd8F28bBF0EA2c63d);
    FujiMockPriceFeed public constant AVAX_FEED = FujiMockPriceFeed(0xD1BDAf98B5e2a73Ef2381e9767fEbF5b79ccbACb);

    function run() external {
        require(vm.envOr("CONFIRM_FUJI_RUNNER_ROUNDTRIPS", false), "FujiRunner: confirmation");
        check();
        vm.startBroadcast(RUNNER);
        PErc20(E.settlement().pUsd()).exchangeRateCurrent();
        PErc20(E.settlement().pWavax()).exchangeRateCurrent();
        PErc20(USD_COLLATERAL).exchangeRateCurrent();
        PErc20(AVAX_COLLATERAL).exchangeRateCurrent();
        for (uint256 pool; pool < 2; ++pool) {
            address token = _collateral(pool);
            uint256 budget = _budget(pool);
            require(E.risk().pTokenValue(token, budget) == 60e18, "FujiRunner: changed NAV");
            require(IERC20(token).approve(address(E.vault()), budget), "FujiRunner: approve");
            E.vault().deposit(token, budget);
            require(IERC20(token).approve(address(E.vault()), 0), "FujiRunner: clear approval");
            for (uint16 leverage = 300; leverage <= 500; leverage += 100) {
                _roundTrip(pool, false, leverage);
                _roundTrip(pool, true, leverage);
            }
            uint256 free = E.vault().freeBalance(RUNNER, token);
            require(free >= budget * 90 / 100 && free <= budget, "FujiRunner: pool loss");
        }
        vm.stopBroadcast();
        verify();
        console2.log("FUJI MOCK ONLY: twelve requested3x/4x/5x round trips; verify actual receipts.");
    }

    function check() public {
        require(block.chainid == 43_113, "FujiRunner: Fuji only");
        require(E.nextPositionId() == 5, "FujiRunner: history");
        require(E.risk().owner() == OWNER && E.risk().executor() == address(E), "FujiRunner: owner/risk");
        require(
            E.executionVersion() == keccak256("collateral-preserving-executor-v1")
                && E.settlement().pUsdVault() == USD_COLLATERAL && E.settlement().pAvaxVault() == AVAX_COLLATERAL
                && E.vault().executor() == address(E),
            "FujiRunner: wiring"
        );
        require(!E.config().opensPaused(), "FujiRunner: paused");
        Config c = Config(address(E.config()));
        require(
            c.owner() == OWNER && c.actionDelay() == 1 hours && c.openFeeBps() == 10 && c.closeFeeBps() == 10
                && c.depositorShareBps() == 5000 && c.insuranceShareBps() == 5000 && c.treasuryShareBps() == 0
                && c.feeImmediateShareBps() == 0 && c.feeStreamDuration() == 7 days
                && E.risk().usdCollateralWeightBps() == 10_000 && E.risk().avaxCollateralWeightBps() == 10_000,
            "FujiRunner: policy"
        );
        Configure verifier = new Configure(); // local helper, never broadcast
        bytes32 expected = keccak256(abi.encode(verifier.pair()));
        _prices();
        _noDebt();
        for (uint256 pool; pool < 2; ++pool) {
            address token = _collateral(pool);
            require(
                IERC20(token).balanceOf(RUNNER) == _budget(pool)
                    && IERC20(token).allowance(RUNNER, address(E.vault())) == 0
                    && E.vault().freeBalance(RUNNER, token) == 0 && E.vault().lockedBalance(RUNNER, token) == 0,
                "FujiRunner: exact funding/checkpoint"
            );
            require(
                keccak256(abi.encode(c.getPairRisk(token, E.settlement().pWavax(), E.settlement().pUsd()))) == expected
                    && keccak256(abi.encode(c.getPairRisk(token, E.settlement().pUsd(), E.settlement().pWavax())))
                        == expected,
                "FujiRunner: pair policy"
            );
        }
        for (uint256 id = 1; id <= 4; ++id) {
            _closed(id, OWNER);
        }
    }

    function verify() public view {
        require(block.chainid == 43_113 && E.nextPositionId() == 17, "FujiRunner: completed history");
        for (uint256 id = 5; id <= 16; ++id) {
            _closed(id, RUNNER);
        }
        _noDebt();
        for (uint256 pool; pool < 2; ++pool) {
            address token = _collateral(pool);
            require(
                IERC20(token).allowance(RUNNER, address(E.vault())) == 0 && E.vault().lockedBalance(RUNNER, token) == 0
                    && E.vault().freeBalance(RUNNER, token) >= _budget(pool) * 90 / 100
                    && E.vault().freeBalance(RUNNER, token) <= _budget(pool) && IERC20(token).balanceOf(RUNNER) == 0,
                "FujiRunner: final balances"
            );
        }
    }

    function _roundTrip(uint256 pool, bool short, uint16 leverage) private {
        address token = _collateral(pool);
        Executor.OpenParams memory p;
        p.collateral = token;
        p.short = short;
        p.collateralShares = _budget(pool) * 5 / 12;
        p.leverageX100 = leverage;
        p.maxFeeShares = _budget(pool) / 240;
        (, p.minPositionOut) = E.risk().quoteOpen(token, short, p.collateralShares, leverage);
        p.deadline = block.timestamp + 1 hours;
        uint256 id = E.openPosition(p);
        (, address account,, address position, address debt,) = E.positions(id);
        require(IERC20(token).balanceOf(account) == p.collateralShares, "FujiRunner: original collateral");
        Risk.Snapshot memory entry = E.risk().snapshot(account, 0);
        require(
            !entry.metrics.liquidatable && entry.metrics.tradingLeverageX100 > leverage * 90 / 100
                && entry.metrics.tradingLeverageX100 <= leverage && entry.metrics.healthFactorBps >= 20_000,
            "FujiRunner: entry risk"
        );
        console2.log("Position / requested leverage", id, leverage);
        console2.log("Actual leverage / health", entry.metrics.tradingLeverageX100, entry.metrics.healthFactorBps);
        Executor.CloseParams memory cp;
        cp.id = id;
        cp.fractionBps = 10_000;
        cp.maxFeeShares = p.maxFeeShares;
        cp.maxCollateralSharesToSell = _budget(pool) / 30;
        uint256 underlying =
            Math.mulDiv(IERC20(position).balanceOf(account), PErc20(position).exchangeRateStored(), 1e18);
        cp.minTradeDebtOut =
            E.quoter().expectedOut(PErc20(position).underlying(), PErc20(debt).underlying(), underlying) * 99 / 100;
        cp.deadline = block.timestamp + 1 hours;
        E.closePosition(cp);
        _closed(id, RUNNER);
    }

    function _closed(uint256 id, address owner) private view {
        (address user, address account, address collateral, address position, address debt, uint256 locked) =
            E.positions(id);
        (,,, Types.Status status,) = E.risk().accounts(account);
        require(
            user == owner && status == Types.Status.CLOSED && locked == 0
                && PErc20(debt).borrowBalanceStored(account) == 0 && IERC20(collateral).balanceOf(account) == 0
                && IERC20(position).balanceOf(account) == 0,
            "FujiRunner: position residue"
        );
    }

    function _noDebt() private view {
        require(
            PErc20(E.settlement().pUsd()).totalBorrows() == 0 && PErc20(E.settlement().pWavax()).totalBorrows() == 0,
            "FujiRunner: debt"
        );
    }

    function _prices() private view {
        require(USD_FEED.owner() == OWNER && AVAX_FEED.owner() == OWNER, "FujiRunner: feed owners");
        require(USD_FEED.answer() == 1e8 && AVAX_FEED.answer() == 10e8, "FujiRunner: mock prices");
        uint256 a = USD_FEED.updatedAt();
        uint256 b = AVAX_FEED.updatedAt();
        // Leave substantial time for execution inside the venue's1200s freshness window.
        require(
            a <= block.timestamp && b <= block.timestamp && block.timestamp - a <= 300 && block.timestamp - b <= 300,
            "FujiRunner: refresh owner feeds"
        );
        require(
            E.quoter().oracle().getPrice(E.settlement().usd()) == 1e18
                && E.quoter().oracle().getPrice(E.settlement().wavax()) == 10e18,
            "FujiRunner: oracle prices"
        );
    }

    function _collateral(uint256 pool) private pure returns (address) {
        return pool == 0 ? USD_COLLATERAL : AVAX_COLLATERAL;
    }

    function _budget(uint256 pool) private pure returns (uint256) {
        return pool == 0 ? 3000e8 : 300e8;
    }
}
