// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;


import {PToken} from "../../contracts/PToken.sol";
import {PriceOracle} from "../../contracts/PriceOracle.sol";
import {PErc20Delegator} from "../../contracts/PErc20Delegator.sol";
import {PeridottrollerInterface} from "../../contracts/PeridottrollerInterface.sol";
import {InterestRateModel} from "../../contracts/InterestRateModel.sol";
import {PharaohDlmmShareOracle} from "../../contracts/PharaohDlmmShareOracle.sol";
import {PharaohBoostedDelegate} from "../../contracts/boosted/PharaohBoostedDelegate.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {IsolatedMarginExecutorUpgradeable} from "../../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {PErc20} from "../../contracts/PErc20.sol";
import {IsolatedMarginV2IntegrationTest} from "../IsolatedMarginV2.t.sol";
import {BpDlmmVaultMock} from "./BpBase.sol";

/// @notice LOCAL isolated-margin stack (the repo's existing `IsolatedMarginV2IntegrationTest` fixture: Peridottroller,
///         unguarded `AvalanchePriceOracle`, mock router/flash vault, the real risk engine, quoter, executor, liquidator,
///         config, vault) with the controller oracle swapped to the wrapper INSIDE each test. Whole scenarios (open, partial
///         liquidation, full close, normal-account borrow check) are run twice from the same snapshot, once with the old
///         oracle and once with the wrapper in front of it, and a digest of every number that matters must be identical.
///
///         RUN WITH `--match-test test_margin`: this contract inherits (and would otherwise re-run) the ~40 original tests.
///
///         WHAT THIS LOCAL STACK CANNOT PROVE (must be covered by the fork harness, subagent B2):
///           - the LIVE risk engine 0xE022.., quoter 0x0663.., liquidator 0xaB9B.. and order close adapter hold their own
///             oracle pointer (the guarded oracle) and ignore `controller.oracle()`: only a read of those addresses on the
///             fork proves it for the deployed bytecode (the local fixture shows it for the repo source);
///           - the 2 live open positions and 4 live orders: `canExecute`/`getMetrics`/`isLiquidatable`/close before and after
///             `_setPriceOracle(wrapper)` on the fork, and after the rollback;
///           - the live Guarded oracle + the real AVAX/USDC Chainlink feeds + real maxAge behaviour;
///           - the live controller storage layout / PeridottrollerAvalanche borrow cash floor behind the real Unitroller;
///           - the live pToken delegates (0xAB5a..) and rate model (0xe5a8..) with real interest accrual;
///           - end-to-end margin open that BORROWS through the live pUSDC (cap 200 USDC, floor 50 USDC) with the wrapper installed.
contract BpMarginLocalTest is IsolatedMarginV2IntegrationTest {
    PharaohDlmmShareOracle internal bpWrapper;
    BpDlmmVaultMock internal bpVault;
    PErc20Delegator internal bpMarket;

    function _bpInstallWrapper() internal {
        bpVault = new BpDlmmVaultMock(address(usd));
        bpVault.mintShares(address(0xB0B0), 17_000_000);
        PharaohBoostedDelegate delegate = new PharaohBoostedDelegate();
        bpMarket = new PErc20Delegator(
            address(bpVault),
            PeridottrollerInterface(address(controller)),
            InterestRateModel(address(interestRateModel)),
            2e14,
            "bp",
            "bpPHAR-USDC",
            8,
            payable(address(this)),
            address(delegate),
            abi.encode(address(bpVault), uint256(1_000_000))
        );
        bpWrapper = new PharaohDlmmShareOracle(PriceOracle(address(oracle)), address(bpMarket));
        require(controller._setPriceOracle(PriceOracle(address(bpWrapper))) == 0, "swap"); // T1
        PToken[] memory ps = new PToken[](1);
        ps[0] = PToken(address(bpMarket));
        uint256[] memory caps = new uint256[](1);
        caps[0] = 1;
        controller._setMarketBorrowCaps(ps, caps); // T2
        require(controller._supportMarket(PToken(address(bpMarket))) == 0, "support"); // T3
        controller._setBorrowPaused(PToken(address(bpMarket)), true); // T4
    }

    function _bpScenarioLongOpenAndPartialLiquidation(bool swap) internal returns (bytes32) {
        if (swap) _bpInstallWrapper();
        uint256 positionId = _openLong(500);
        IsolatedMarginTypes.Position memory p0 = _position(positionId);
        IsolatedMarginTypes.AccountMetrics memory m0 = riskEngine.getMetrics(p0.account);
        _setAvaxPriceAndRates(87e6);
        bool liquidatable = riskEngine.isLiquidatable(p0.account);
        liquidator.liquidate(_liquidationParams(positionId));
        IsolatedMarginTypes.Position memory p1 = _position(positionId);
        IsolatedMarginTypes.AccountMetrics memory m1 = riskEngine.getMetrics(p1.account);
        return keccak256(
            abi.encode(
                p0.lockedMarginPTokens,
                p0.borrowedPrincipal,
                m0.leverageX100,
                m0.healthFactorBps,
                m0.grossAssetValueUsd,
                liquidatable,
                p1.lockedMarginPTokens,
                m1.healthFactorBps,
                pUsd.borrowBalanceStored(p1.account),
                pAvax.balanceOf(p1.account),
                usd.balanceOf(LIQUIDATION_RECIPIENT),
                uint256(p1.status)
            )
        );
    }

    function _bpScenarioShortOpenAndFullClose(bool swap) internal returns (bytes32) {
        if (swap) _bpInstallWrapper();
        uint256 positionId = _openShort(500);
        IsolatedMarginTypes.Position memory p = _position(positionId);
        IsolatedMarginExecutorUpgradeable.CloseParams memory closeParams = IsolatedMarginExecutorUpgradeable.CloseParams({
            positionId: positionId,
            closeBps: uint16(BPS),
            maxClosingFeePToken: 0,
            minDebtUnderlying: 0,
            minMarginUnderlying: 0,
            positionToDebtSwapData: bytes(""),
            debtToMarginSwapData: bytes("")
        });
        vm.prank(USER);
        uint256 returned = executor.closePosition(closeParams);
        IsolatedMarginTypes.Position memory q = _position(positionId);
        return keccak256(
            abi.encode(
                p.lockedMarginPTokens,
                p.borrowedPrincipal,
                returned,
                uint256(q.status),
                pAvax.borrowBalanceStored(p.account),
                marginVault.freeBalance(USER, address(pUsd))
            )
        );
    }

    function _bpScenarioNormalAccountAndControllerChecks(bool swap) internal returns (bytes32) {
        if (swap) _bpInstallWrapper();
        uint256 positionId = _openLong(500);
        IsolatedMarginTypes.Position memory position = _position(positionId);
        avax.mint(NORMAL_USER, 100e18);
        vm.startPrank(NORMAL_USER);
        avax.approve(address(pAvax), type(uint256).max);
        pAvax.mint(100e18);
        address[] memory markets = new address[](1);
        markets[0] = address(pAvax);
        controller.enterMarkets(markets);
        vm.stopPrank();
        vm.prank(address(pUsd));
        uint256 borrowTooMuch = controller.borrowAllowed(address(pUsd), NORMAL_USER, 20e18);
        vm.prank(address(pUsd));
        uint256 borrowOk = controller.borrowAllowed(address(pUsd), NORMAL_USER, 5e18);
        (uint256 err, uint256 liq, uint256 sf) = controller.getAccountLiquidity(NORMAL_USER);
        _setAvaxPriceAndRates(75e6);
        uint256 nativeLiq =
            controller.liquidateBorrowAllowed(address(pUsd), address(pAvax), address(this), position.account, 1e18);
        uint256 seize = controller.seizeAllowed(address(pAvax), address(pUsd), address(this), position.account, 1e18);
        (uint256 seizeErr, uint256 seizeTokens) = controller.liquidateCalculateSeizeTokens(address(pUsd), address(pAvax), 3e18);
        return keccak256(abi.encode(borrowTooMuch, borrowOk, err, liq, sf, nativeLiq, seize, seizeErr, seizeTokens));
    }

    function _bpCompare(uint256 which) internal {
        uint256 snap = vm.snapshotState();
        bytes32 before = which == 0
            ? _bpScenarioLongOpenAndPartialLiquidation(false)
            : which == 1 ? _bpScenarioShortOpenAndFullClose(false) : _bpScenarioNormalAccountAndControllerChecks(false);
        vm.revertToState(snap);
        bytes32 afterSwap = which == 0
            ? _bpScenarioLongOpenAndPartialLiquidation(true)
            : which == 1 ? _bpScenarioShortOpenAndFullClose(true) : _bpScenarioNormalAccountAndControllerChecks(true);
        assertEq(address(controller.oracle()), address(bpWrapper), "controller points at the wrapper in the second run");
        assertEq(afterSwap, before, "digest with the wrapper must equal the digest with the old oracle");
    }

    function test_margin_longOpenAndPartialLiquidation_identicalWithWrapperInFront() external {
        _bpCompare(0);
    }

    function test_margin_shortOpenAndFullClose_identicalWithWrapperInFront() external {
        _bpCompare(1);
    }

    function test_margin_normalAccountAndControllerHooks_identicalWithWrapperInFront() external {
        _bpCompare(2);
    }

    /// @dev Positions opened BEFORE the swap keep working AFTER it (the live situation: 2 open positions, 4 orders).
    function test_margin_positionOpenedBeforeTheSwap_liquidatesAfterIt() external {
        uint256 positionId = _openLong(500);
        IsolatedMarginTypes.Position memory p0 = _position(positionId);
        _bpInstallWrapper();
        _setAvaxPriceAndRates(87e6);
        assertTrue(riskEngine.isLiquidatable(p0.account), "liquidatable after the swap");
        liquidator.liquidate(_liquidationParams(positionId));
        IsolatedMarginTypes.Position memory p1 = _position(positionId);
        assertLt(pUsd.borrowBalanceStored(p1.account), p0.borrowedPrincipal, "debt reduced");
        assertEq(uint256(p1.status), uint256(IsolatedMarginTypes.Status.ACTIVE));
    }

    /// @dev The swap, then rollback to the unguarded oracle, mid-life of a position: nothing changes for the position.
    function test_margin_swapThenRollback_positionUntouched() external {
        uint256 positionId = _openLong(500);
        IsolatedMarginTypes.Position memory p0 = _position(positionId);
        uint256 healthBefore = riskEngine.getMetrics(p0.account).healthFactorBps;
        _bpInstallWrapper();
        assertEq(riskEngine.getMetrics(p0.account).healthFactorBps, healthBefore);
        assertEq(controller._setPriceOracle(PriceOracle(address(oracle))), 0, "rollback");
        assertEq(riskEngine.getMetrics(p0.account).healthFactorBps, healthBefore);
        _setAvaxPriceAndRates(87e6);
        liquidator.liquidate(_liquidationParams(positionId));
    }

    /// @dev The margin risk engine's own oracle pointer is independent of the controller's: swapping the controller oracle
    ///      does not change it. (Pointer identity only; the live pointers must be read on the fork.)
    function test_margin_riskEngineKeepsItsOwnOraclePointer() external {
        address before = address(riskEngine.oracle());
        _bpInstallWrapper();
        assertEq(address(riskEngine.oracle()), before);
        assertEq(before, address(oracle));
        assertTrue(address(controller.oracle()) != address(riskEngine.oracle()));
    }
}
