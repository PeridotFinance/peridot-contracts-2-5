// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";

/// @notice One-shot, fixed-address Fuji MOCK 5x-request smoke using existing free pMockUSD.
/// @dev Ten transactions: two unchanged-price refreshes, then accrue/accrue/open/full-close per side.
/// No deposits, approvals, withdrawals, minting or risk changes. Transactions are NOT atomic.
/// Quotes/checks run during simulation; they do not guarantee subsequent inclusion conditions.
/// Never blindly replay after partial execution. Verify live receipts before any withdrawal.
contract SmokeFujiMockFiveX is Script {
    address internal constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    uint256 internal constant MARGIN = 5000e8; // Approximately $100 at the pinned exchange rate.
    PErc20 internal constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 internal constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockPriceFeed internal constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed internal constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    IsolatedMarginConfigUpgradeable internal constant CONFIG =
        IsolatedMarginConfigUpgradeable(0x6148183676E304dbe63a85C350c208DA3cEAc39C);
    IsolatedMarginVaultUpgradeable internal constant VAULT =
        IsolatedMarginVaultUpgradeable(0x0987154fB5676a8Ea545AAf41F8ef2492F785d22);
    IsolatedMarginExecutorUpgradeable internal constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    IsolatedMarginRiskEngineUpgradeable internal constant RISK =
        IsolatedMarginRiskEngineUpgradeable(0x94DA93A26770C114FD6a59015aD462c65C7A2F8c);

    function run() external {
        require(block.chainid == 43_113, "FiveX: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_MOCK_ONLY", false), "FiveX: mock confirmation");
        require(vm.envOr("CONFIRM_FUJI_FIVE_X_SMOKE", false), "FiveX: trade confirmation");
        require(EX.nextPositionId() == 5, "FiveX: inspect history before replay");
        require(address(EX.quoter()) == 0xA73180B7Fdc50e061e32205f3b01e0be952d280b, "FiveX: quoter changed");
        require(address(EX.vault()) == address(VAULT) && address(EX.config()) == address(CONFIG), "FiveX: wiring");
        require(!CONFIG.opensPaused(), "FiveX: opens paused");
        require(CONFIG.openFeeBps() == 0 && CONFIG.closeFeeBps() == 0, "FiveX: fees changed");
        require(AF.owner() == OWNER && UF.owner() == OWNER, "FiveX: feed ownership");
        require(AF.answer() == 10e8 && UF.answer() == 1e8, "FiveX: prices changed");
        require(USD.borrowAccountingEnabled() && AVAX.borrowAccountingEnabled(), "FiveX: accounting disabled");
        _zeroDebt();
        _risk(address(AVAX), address(USD));
        _risk(address(USD), address(AVAX));
        require(VAULT.lockedBalance(OWNER, address(USD)) == 0, "FiveX: existing lock");
        require(USD.allowance(OWNER, address(VAULT)) == 0, "FiveX: existing approval");
        uint256 freeBefore = VAULT.freeBalance(OWNER, address(USD));
        require(freeBefore == 999_999_990_000, "FiveX: collateral changed");
        uint256 walletBefore = USD.balanceOf(OWNER);
        vm.startBroadcast(OWNER);
        AF.setAnswer(10e8);
        UF.setAnswer(1e8);
        _roundTrip(false);
        _roundTrip(true);
        vm.stopBroadcast();
        _zeroDebt();
        require(EX.nextPositionId() == 7, "FiveX: unexpected positions");
        require(VAULT.lockedBalance(OWNER, address(USD)) == 0, "FiveX: locked residue");
        require(VAULT.freeBalance(OWNER, address(USD)) >= freeBefore * 99 / 100, "FiveX: excessive loss");
        require(USD.balanceOf(OWNER) == walletBefore, "FiveX: wallet shares changed");
        require(USD.allowance(OWNER, address(VAULT)) == 0, "FiveX: approval residue");
        console2.log("MOCK ONLY: both 5x-request round trips simulated; verify actual receipts");
        console2.log("Free pMockUSD shares", VAULT.freeBalance(OWNER, address(USD)));
    }

    function _risk(address position, address debt) private view {
        IsolatedMarginTypes.PairRiskConfig memory expected = IsolatedMarginTypes.PairRiskConfig(
            true, 500, 2000, 1000, 12500, 5000, 5000, 500, 100, 100, 10_000e18, 5000e18
        );
        require(
            keccak256(abi.encode(CONFIG.getPairRisk(address(USD), position, debt))) == keccak256(abi.encode(expected)),
            "FiveX: risk changed"
        );
    }

    function _zeroDebt() private view {
        require(USD.totalBorrows() == 0 && AVAX.totalBorrows() == 0, "FiveX: aggregate debt");
        require(USD.totalBorrowShares() == 0 && AVAX.totalBorrowShares() == 0, "FiveX: debt shares");
    }

    function _roundTrip(bool short) private {
        uint256 rate = USD.exchangeRateCurrent();
        require(AVAX.accrueInterest() == 0, "FiveX: accrue AVAX");
        uint256 underlyingMargin = Math.mulDiv(MARGIN, rate, 1e18);
        require(underlyingMargin >= 99e6 && underlyingMargin <= 101e6, "FiveX: margin budget changed");
        address position = short ? address(USD) : address(AVAX);
        address debt = short ? address(AVAX) : address(USD);
        (, uint256 minimum) = EX.quoter().quoteOpen(address(USD), position, debt, underlyingMargin, 500);
        uint256 id = EX.openPosition(
            IsolatedMarginExecutorUpgradeable.OpenParams(
                address(USD),
                position,
                debt,
                MARGIN,
                500,
                0,
                minimum,
                short ? IsolatedMarginTypes.Side.SHORT : IsolatedMarginTypes.Side.LONG,
                ""
            )
        );
        (,, address account,,,,,,,,,) = EX.positions(id);
        _checkEntry(account, short);
        console2.log(short ? "SHORT id" : "LONG id", id);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        require(USD.borrowBalanceStored(account) == 0 && AVAX.borrowBalanceStored(account) == 0, "FiveX: account debt");
        require(USD.borrowShares(account) == 0 && AVAX.borrowShares(account) == 0, "FiveX: account shares");
        (,,,,,,,,,,, IsolatedMarginTypes.Status status) = EX.positions(id);
        require(status == IsolatedMarginTypes.Status.CLOSED, "FiveX: not closed");
        _zeroDebt();
    }

    function _checkEntry(address account, bool short) internal virtual {
        IsolatedMarginTypes.AccountMetrics memory m = RISK.getMetrics(account);
        require(!RISK.isLiquidatable(account) && m.healthFactorBps > 10_000, "FiveX: unhealthy entry");
        require(m.leverageX100 >= 475 && m.leverageX100 <= 500, "FiveX: unexpected leverage");
        // Scenario-specific estimate: all long assets move with AVAX, all short debt moves with AVAX.
        // Assumes USD stays $1, maintenance stays 10%, and no future interest/execution costs.
        // This calculation changes no prices. Fork tests independently search the actual risk-engine boundary.
        uint256 boundary = short
            ? Math.mulDiv(10e8, m.grossAssetValueUsd * 9000, m.debtValueUsd * 10_000)
            : Math.mulDiv(10e8, m.debtValueUsd * 10_000, m.grossAssetValueUsd * 9000);
        uint256 distance = short ? (boundary - 10e8) * 10_000 / 10e8 : (10e8 - boundary) * 10_000 / 10e8;
        require(distance >= 1100, "FiveX: narrow liquidation buffer");
        console2.log("Actual entry leverage x100", m.leverageX100);
        console2.log("Entry health factor bps", m.healthFactorBps);
        console2.log("Estimated AVAX liquidation price (8 decimals)", boundary);
        console2.log("Adverse price distance bps", distance);
    }
}
