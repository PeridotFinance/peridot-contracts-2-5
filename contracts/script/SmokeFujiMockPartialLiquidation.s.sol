// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {IsolatedMarginExecutorUpgradeable as Executor} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {
    IsolatedMarginLiquidatorUpgradeable as Liquidator
} from "../contracts/margin/IsolatedMarginLiquidatorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable as Risk} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginConfigUpgradeable as Config} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable as Vault} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginTypes as T} from "../contracts/margin/IsolatedMarginTypes.sol";

/// @notice One-shot Fuji MOCK partial-liquidation canary. NOT authorized merely by compiling it.
/// @dev Twelve non-atomic transactions. $200-equivalent existing wallet pUSD deposit, $100 margin
/// 5x-request long, mock AVAX $10 -> $8.70 -> $10, partial liquidation then full close.
/// Keeper reward goes to OWNER. No planned insurance consumption or withdrawal. Requires separate
/// explicit signing approval. Stop/reconcile partial failure, especially an unrestored mock price.
contract SmokeFujiMockPartialLiquidation is Script {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant INS = 0xbD6f340277235483c881E79205E76bb62A9A548C;
    uint256 constant MARGIN = 5000e8;
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    Executor constant EX = Executor(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    Liquidator constant LIQ = Liquidator(0xb344A644Dcf2176f50292ABDD6acDfdfea3F525d);
    Risk constant RISK = Risk(0x94DA93A26770C114FD6a59015aD462c65C7A2F8c);
    Config constant CONFIG = Config(0x6148183676E304dbe63a85C350c208DA3cEAc39C);
    Vault constant VAULT = Vault(0x0987154fB5676a8Ea545AAf41F8ef2492F785d22);

    function run() external {
        require(block.chainid == 43_113, "PartialSmoke: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_MOCK_ONLY", false), "PartialSmoke: mock confirmation");
        require(vm.envOr("CONFIRM_FUJI_PARTIAL_LIQUIDATION", false), "PartialSmoke: liquidation confirmation");
        require(EX.nextPositionId() == 7, "PartialSmoke: inspect history");
        require(address(EX.quoter()) == 0xA73180B7Fdc50e061e32205f3b01e0be952d280b, "PartialSmoke: quoter");
        require(!CONFIG.opensPaused(), "PartialSmoke: paused");
        require(CONFIG.openFeeBps() == 0 && CONFIG.closeFeeBps() == 0, "PartialSmoke: fees");
        require(AF.owner() == OWNER && UF.owner() == OWNER, "PartialSmoke: feed ownership");
        require(AF.answer() == 10e8 && UF.answer() == 1e8, "PartialSmoke: scenario");
        require(USD.borrowAccountingEnabled() && AVAX.borrowAccountingEnabled(), "PartialSmoke: accounting");
        _zeroDebt();
        require(
            VAULT.freeBalance(OWNER, address(USD)) == 0 && VAULT.lockedBalance(OWNER, address(USD)) == 0,
            "PartialSmoke: existing margin"
        );
        require(USD.allowance(OWNER, address(VAULT)) == 0, "PartialSmoke: approval");
        require(USD.balanceOf(OWNER) >= MARGIN * 2, "PartialSmoke: wallet budget");
        T.PairRiskConfig memory expected =
            T.PairRiskConfig(true, 500, 2000, 1000, 12500, 5000, 5000, 500, 100, 100, 10_000e18, 5000e18);
        require(
            keccak256(abi.encode(CONFIG.getPairRisk(address(USD), address(AVAX), address(USD))))
                == keccak256(abi.encode(expected)),
            "PartialSmoke: risk"
        );
        uint256 insuranceUsd = USD.balanceOf(INS);
        uint256 insuranceAvax = AVAX.balanceOf(INS);
        vm.startBroadcast(OWNER);
        AF.setAnswer(10e8);
        UF.setAnswer(1e8);
        require(USD.approve(address(VAULT), MARGIN * 2), "PartialSmoke: approve");
        VAULT.deposit(address(USD), MARGIN * 2);
        require(USD.approve(address(VAULT), 0), "PartialSmoke: clear approval");
        uint256 rate = USD.exchangeRateCurrent();
        require(AVAX.accrueInterest() == 0, "PartialSmoke: accrue");
        uint256 marginUnderlying = MARGIN * rate / 1e18;
        require(marginUnderlying >= 99e6 && marginUnderlying <= 101e6, "PartialSmoke: margin budget");
        (, uint256 minimum) = EX.quoter().quoteOpen(address(USD), address(AVAX), address(USD), marginUnderlying, 500);
        uint256 id = EX.openPosition(
            Executor.OpenParams(address(USD), address(AVAX), address(USD), MARGIN, 500, 0, minimum, T.Side.LONG, "")
        );
        (,, address account,,,,,,,,,) = EX.positions(id);
        require(!RISK.isLiquidatable(account), "PartialSmoke: unhealthy entry");
        AF.setAnswer(8.7e8);
        require(RISK.isLiquidatable(account), "PartialSmoke: expected liquidation");
        uint256 healthBefore = RISK.getMetrics(account).healthFactorBps;
        uint256 debtBefore = USD.borrowBalanceStored(account);
        LIQ.liquidate(Liquidator.LiquidationParams(id, OWNER, 0, 0, "", ""));
        (,,,,,,,,,,, T.Status status) = EX.positions(id);
        require(status == T.Status.ACTIVE, "PartialSmoke: not partial");
        require(RISK.getMetrics(account).healthFactorBps > healthBefore, "PartialSmoke: health not improved");
        require(
            USD.borrowBalanceStored(account) > 0 && USD.borrowBalanceStored(account) < debtBefore,
            "PartialSmoke: debt not reduced"
        );
        console2.log("Partial-liquidation health before/after", healthBefore, RISK.getMetrics(account).healthFactorBps);
        AF.setAnswer(10e8);
        EX.closePosition(Executor.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        vm.stopBroadcast();
        (,,,,,,,,,,, status) = EX.positions(id);
        require(status == T.Status.CLOSED, "PartialSmoke: not closed");
        require(
            USD.borrowBalanceStored(account) == 0 && AVAX.borrowBalanceStored(account) == 0,
            "PartialSmoke: account debt"
        );
        _zeroDebt();
        require(
            USD.balanceOf(INS) == insuranceUsd && AVAX.balanceOf(INS) == insuranceAvax,
            "PartialSmoke: insurance consumed"
        );
        require(
            VAULT.lockedBalance(OWNER, address(USD)) == 0 && USD.allowance(OWNER, address(VAULT)) == 0,
            "PartialSmoke: residue"
        );
        require(VAULT.freeBalance(OWNER, address(USD)) >= MARGIN, "PartialSmoke: loss budget");
        console2.log("MOCK ONLY partial liquidation and full close simulated; verify receipts", id);
        console2.log("Free pMockUSD shares", VAULT.freeBalance(OWNER, address(USD)));
    }

    function _zeroDebt() private view {
        require(USD.totalBorrows() == 0 && AVAX.totalBorrows() == 0, "PartialSmoke: debt");
        require(USD.totalBorrowShares() == 0 && AVAX.totalBorrowShares() == 0, "PartialSmoke: shares");
    }
}
