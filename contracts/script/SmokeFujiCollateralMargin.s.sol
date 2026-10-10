// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {CollateralPreservingExecutor as Executor} from "../contracts/margin/CollateralPreservingExecutor.sol";
import {CollateralPreservingRiskEngine as Risk} from "../contracts/margin/CollateralPreservingRiskEngine.sol";
import {
    CollateralPreservingSettlementModule as Settlement
} from "../contracts/margin/CollateralPreservingSettlementModule.sol";
import {IsolatedMarginTypes as Types} from "../contracts/margin/IsolatedMarginTypes.sol";
import {ActivateFujiCollateralMargin as Activate} from "./ActivateFujiCollateralMargin.s.sol";
import {PharaohMarginRouterAdapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";
import {PharaohCLRouterAdapter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {FujiMockPharaohRouter} from "../contracts/margin/testing/FujiMockPharaoh.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";

/// @notice Fresh Fuji mock stack's FIRST four 2x round trips. Never use the legacy executor.
/// @dev run(): exactly 20 transactions, no withdrawal. withdraw(): separately approved two calls.
/// continueFromUsdDeposit(): exactly 17 freshly simulated calls, skips only the USD approve/deposit/clear.
/// Batches are NOT atomic: stop/reconcile partial execution, never blindly rerun or resume.
contract SmokeFujiCollateralMargin is Script {
    uint256 public constant USD_DEPOSIT_SHARES = 3000e8; // $60 at the verified mock seed rate.
    uint256 public constant AVAX_DEPOSIT_SHARES = 300e8; // 6 mockAVAX, also $60.

    function run() external {
        _run(false);
    }

    /// @notice Only for a reverted first open after the full USD deposit and approval clearance.
    /// Not a generic resume: existing positions, other deposits or missing collateral fail closed.
    function continueFromUsdDeposit() external {
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_CONTINUATION", false), "CollateralSmoke: continuation confirmation");
        _run(true);
    }

    function _run(bool reuseUsdDeposit) private {
        (Executor e, address owner) = _identity();
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_SMOKE", false), "CollateralSmoke: confirmation");
        Activate verifier = new Activate();
        // Both paths check full policy before any broadcast. Only the exact USD deposit is exempted.
        if (reuseUsdDeposit) verifier.verifySmokeContinuation(address(e), owner, false);
        else verifier.verifyPolicy(address(e), owner);
        Settlement s = e.settlement();
        address[2] memory collateral = [s.pUsdVault(), s.pAvaxVault()];
        for (uint256 i; i < 2; ++i) {
            require(
                (reuseUsdDeposit && i == 0 || IERC20(collateral[i]).balanceOf(owner) >= _deposit(i))
                    && IERC20(collateral[i]).allowance(owner, address(e.vault())) == 0,
                "CollateralSmoke: wallet budget/approval"
            );
        }
        FujiMockSwapAdapter venue = _venue(e);
        vm.startBroadcast(owner);
        venue.usdFeed().setAnswer(1e8);
        venue.avaxFeed().setAnswer(10e8);
        vm.stopBroadcast();
        // Local verifier is never a broadcast target.
        if (reuseUsdDeposit) verifier.verifySmokeContinuation(address(e), owner, true);
        else verifier.verify(address(e), owner);

        vm.startBroadcast(owner);
        PErc20(s.pUsd()).exchangeRateCurrent();
        PErc20(s.pWavax()).exchangeRateCurrent();
        PErc20(collateral[0]).exchangeRateCurrent();
        PErc20(collateral[1]).exchangeRateCurrent();
        for (uint256 i; i < 2; ++i) {
            // Fixed raw pToken budgets; fail rather than silently resize for changed mock NAV.
            require(e.risk().pTokenValue(collateral[i], _deposit(i)) == 60e18, "CollateralSmoke: changed NAV");
            if (!reuseUsdDeposit || i != 0) {
                require(IERC20(collateral[i]).approve(address(e.vault()), _deposit(i)), "CollateralSmoke: approve");
                e.vault().deposit(collateral[i], _deposit(i));
                require(IERC20(collateral[i]).approve(address(e.vault()), 0), "CollateralSmoke: clear approval");
            }
            _roundTrip(e, owner, i, false);
            _roundTrip(e, owner, i, true);
            require(
                e.vault().freeBalance(owner, collateral[i]) >= _deposit(i) * 95 / 100,
                "CollateralSmoke: excessive pool loss"
            );
        }
        vm.stopBroadcast();
        _completed(e, owner);
        console2.log("FUJI MOCK ONLY: four requested-2x round trips simulated; verify live receipts.");
        console2.log("Free pUSD-vault shares", e.vault().freeBalance(owner, collateral[0]));
        console2.log("Free pAVAX-vault shares", e.vault().freeBalance(owner, collateral[1]));
        console2.log("No withdrawal performed. Withdraw only after receipt review and separate approval.");
    }

    /// @notice Separate two-call pToken withdrawal; no prices, redemption or reward claim transaction.
    /// Newly settled streamed rewards can leave a small free balance; do not blindly sweep again.
    function withdraw() external {
        (Executor e, address owner) = _identity();
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_WITHDRAW", false), "CollateralSmoke: withdrawal confirmation");
        _completed(e, owner);
        address[2] memory collateral = [e.settlement().pUsdVault(), e.settlement().pAvaxVault()];
        uint256[2] memory amounts;
        for (uint256 i; i < 2; ++i) {
            amounts[i] = e.vault().freeBalance(owner, collateral[i]);
            require(
                amounts[i] >= _deposit(i) * 95 / 100 && amounts[i] <= _deposit(i) + _deposit(i) / 100,
                "CollateralSmoke: withdrawal budget"
            );
        }
        vm.startBroadcast(owner);
        for (uint256 i; i < 2; ++i) {
            uint256 beforeWallet = IERC20(collateral[i]).balanceOf(owner);
            uint256 supply = PErc20(collateral[i]).totalSupply();
            e.vault().withdraw(collateral[i], amounts[i]);
            require(
                IERC20(collateral[i]).balanceOf(owner) == beforeWallet + amounts[i]
                    && PErc20(collateral[i]).totalSupply() == supply
                    && e.vault().freeBalance(owner, collateral[i]) <= _deposit(i) / 100,
                "CollateralSmoke: pToken return"
            );
        }
        vm.stopBroadcast();
        console2.log("FUJI MOCK ONLY: pToken withdrawals simulated; verify receipts and any reward remainder.");
    }

    function verify(address executor, address owner) external view {
        require(block.chainid == 43_113 && owner != address(0), "CollateralSmoke: identity");
        _completed(Executor(executor), owner);
    }

    function _identity() private view returns (Executor e, address owner) {
        require(block.chainid == 43_113, "CollateralSmoke: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_COLLATERAL_MOCK_ONLY", false), "CollateralSmoke: mock confirmation");
        owner = vm.envAddress("CP_FUJI_DEPLOYER");
        e = Executor(vm.envAddress("CP_FUJI_EXECUTOR"));
        require(
            owner != address(0) && e.executionVersion() == keccak256("collateral-preserving-executor-v1")
                && e.risk().owner() == owner && e.risk().executor() == address(e) && e.vault().executor() == address(e),
            "CollateralSmoke: identity"
        );
    }

    function _roundTrip(Executor e, address owner, uint256 pool, bool short) private {
        Settlement s = e.settlement();
        address collateral = pool == 0 ? s.pUsdVault() : s.pAvaxVault();
        address other = pool == 0 ? s.pAvaxVault() : s.pUsdVault();
        address insurance = e.config().insuranceFund();
        uint256 insuranceBefore = IERC20(collateral).balanceOf(insurance);
        uint256 otherInsurance = IERC20(other).balanceOf(insurance);
        uint256 shares = _deposit(pool) * 5 / 12; // $25 margin.
        uint256 feeCap = _deposit(pool) / 600; // $0.10 per open or close.
        (, uint256 minimum) = e.risk().quoteOpen(collateral, short, shares, 200);
        Executor.OpenParams memory op;
        op.collateral = collateral;
        op.short = short;
        op.collateralShares = shares;
        op.leverageX100 = 200;
        op.maxFeeShares = feeCap;
        op.minPositionOut = minimum;
        op.deadline = block.timestamp + 15 minutes;
        uint256 id = e.openPosition(op);
        (, address account,, address position, address debt,) = e.positions(id);
        require(IERC20(collateral).balanceOf(account) == shares, "CollateralSmoke: collateral not retained");
        Risk.Snapshot memory entry = e.risk().snapshot(account, 0);
        require(
            !entry.metrics.liquidatable && entry.metrics.tradingLeverageX100 >= 180
                && entry.metrics.tradingLeverageX100 <= 200 && entry.metrics.healthFactorBps >= 40_000,
            "CollateralSmoke: entry risk"
        );
        console2.log(short ? "SHORT position" : "LONG position", id);
        console2.log("Entry trade leverage x100", entry.metrics.tradingLeverageX100);
        console2.log("Entry health factor bps", entry.metrics.healthFactorBps);
        Executor.CloseParams memory cp;
        cp.id = id;
        cp.fractionBps = 10_000;
        cp.maxFeeShares = feeCap;
        cp.maxCollateralSharesToSell = _deposit(pool) / 60; // At most $1 collateral sold for repayment.
        uint256 tradeUnderlying =
            Math.mulDiv(IERC20(position).balanceOf(account), PErc20(position).exchangeRateStored(), 1e18);
        cp.minTradeDebtOut = e.quoter()
                .expectedOut(PErc20(position).underlying(), PErc20(debt).underlying(), tradeUnderlying) * 99 / 100;
        cp.deadline = block.timestamp + 15 minutes;
        e.closePosition(cp);
        _closed(e, owner, id, collateral);
        uint256 insuranceDelta = IERC20(collateral).balanceOf(insurance) - insuranceBefore;
        require(
            insuranceDelta > 0 && insuranceDelta <= feeCap && IERC20(other).balanceOf(insurance) == otherInsurance,
            "CollateralSmoke: same-pool insurance fees"
        );
        (, uint256 eligible, uint256 reserve,,,) = s.feeDistributor().pools(collateral);
        (uint256 userShares,,) = s.feeDistributor().userRewards(collateral, owner);
        require(
            reserve > 0 && eligible == userShares && userShares == e.vault().freeBalance(owner, collateral),
            "CollateralSmoke: same-pool rewards"
        );
    }

    function _completed(Executor e, address owner) private view {
        require(e.nextPositionId() == 5 && e.risk().owner() == owner, "CollateralSmoke: unexpected history");
        Settlement s = e.settlement();
        for (uint256 i; i < 2; ++i) {
            address collateral = i == 0 ? s.pUsdVault() : s.pAvaxVault();
            _closed(e, owner, i * 2 + 1, collateral);
            _closed(e, owner, i * 2 + 2, collateral);
            require(
                e.vault().lockedBalance(owner, collateral) == 0
                    && IERC20(collateral).allowance(owner, address(e.vault())) == 0,
                "CollateralSmoke: lock/approval residue"
            );
        }
        require(
            PErc20(s.pUsd()).totalBorrows() == 0 && PErc20(s.pWavax()).totalBorrows() == 0,
            "CollateralSmoke: aggregate debt"
        );
    }

    function _closed(Executor e, address owner, uint256 id, address expectedCollateral) private view {
        (address user, address account, address collateral, address position, address debt, uint256 locked) =
            e.positions(id);
        (,,, Types.Status status,) = e.risk().accounts(account);
        require(
            user == owner && collateral == expectedCollateral && locked == 0 && status == Types.Status.CLOSED
                && PErc20(debt).borrowBalanceStored(account) == 0 && IERC20(collateral).balanceOf(account) == 0
                && IERC20(position).balanceOf(account) == 0,
            "CollateralSmoke: position residue"
        );
    }

    function _deposit(uint256 pool) private pure returns (uint256) {
        return pool == 0 ? USD_DEPOSIT_SHARES : AVAX_DEPOSIT_SHARES;
    }

    function _venue(Executor e) private view returns (FujiMockSwapAdapter) {
        PharaohMarginRouterAdapter a = PharaohMarginRouterAdapter(e.config().routerAdapter());
        return FujiMockPharaohRouter(address(PharaohCLRouterAdapter(address(a.baseRouter())).router())).venue();
    }
}
