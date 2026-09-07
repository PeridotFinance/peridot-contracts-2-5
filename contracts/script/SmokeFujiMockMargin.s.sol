// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {PErc20} from "../contracts/PErc20.sol";

/// @notice Fixed-address, MOCK-FUJI-ONLY 2x smoke test. No risk configuration or minting.
/// @dev run(): refresh mock rounds, deposit $200-equivalent existing pTokens, round-trip $100 margin
///      long and short sequentially. AFTER receipt verification, withdraw() sweeps the resulting free
///      pTokens in a separately simulated transaction; avoids precomputing withdrawal across live accrual.
///      Broadcast transactions are NOT atomic. Never blindly rerun after partial execution.
contract SmokeFujiMockMargin is Script {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    uint256 constant MARGIN = 5000e8;
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    IsolatedMarginConfigUpgradeable constant CONFIG =
        IsolatedMarginConfigUpgradeable(0x6148183676E304dbe63a85C350c208DA3cEAc39C);
    IsolatedMarginVaultUpgradeable constant VAULT =
        IsolatedMarginVaultUpgradeable(0x0987154fB5676a8Ea545AAf41F8ef2492F785d22);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    IsolatedMarginRiskEngineUpgradeable constant RISK =
        IsolatedMarginRiskEngineUpgradeable(0x94DA93A26770C114FD6a59015aD462c65C7A2F8c);

    function run() external {
        _confirm();
        require(!CONFIG.opensPaused(), "Smoke: opens paused");
        require(AF.owner() == OWNER && UF.owner() == OWNER, "Smoke: feed ownership");
        require(AF.answer() == 10e8 && UF.answer() == 1e8, "Smoke: changed scenario");
        require(CONFIG.openFeeBps() == 0 && CONFIG.closeFeeBps() == 0, "Smoke: fee policy changed");
        require(
            CONFIG.getPairRisk(address(USD), address(AVAX), address(USD)).maxLeverageX100 == 200
                && CONFIG.getPairRisk(address(USD), address(USD), address(AVAX)).maxLeverageX100 == 200,
            "Smoke: not launch risk"
        );
        require(
            VAULT.freeBalance(OWNER, address(USD)) == 0 && VAULT.lockedBalance(OWNER, address(USD)) == 0,
            "Smoke: existing margin balance, inspect before rerun"
        );
        require(USD.balanceOf(OWNER) >= MARGIN * 2, "Smoke: pToken budget");
        require(USD.allowance(OWNER, address(VAULT)) == 0, "Smoke: existing approval");
        vm.startBroadcast(OWNER);
        AF.setAnswer(10e8);
        UF.setAnswer(1e8);
        require(USD.approve(address(VAULT), MARGIN * 2), "Smoke: approve");
        VAULT.deposit(address(USD), MARGIN * 2);
        require(USD.approve(address(VAULT), 0), "Smoke: clear approval");
        _roundTrip(false);
        _roundTrip(true);
        vm.stopBroadcast();
        require(VAULT.lockedBalance(OWNER, address(USD)) == 0, "Smoke: locked residue");
        require(VAULT.freeBalance(OWNER, address(USD)) >= MARGIN * 198 / 100, "Smoke: excessive roundtrip loss");
        console2.log("MOCK ONLY: both 2x round trips complete; verify receipts before withdraw()");
        console2.log("Free pMockUSD shares", VAULT.freeBalance(OWNER, address(USD)));
    }

    function withdraw() external {
        _confirm();
        require(CONFIG.openFeeBps() == 0 && CONFIG.closeFeeBps() == 0, "Smoke: fee policy changed");
        require(VAULT.lockedBalance(OWNER, address(USD)) == 0, "Smoke: outstanding lock");
        uint256 amount = VAULT.freeBalance(OWNER, address(USD));
        require(amount > 0 && amount <= MARGIN * 202 / 100, "Smoke: unexpected withdrawal budget");
        vm.startBroadcast(OWNER);
        VAULT.withdraw(address(USD), amount);
        vm.stopBroadcast();
        require(VAULT.freeBalance(OWNER, address(USD)) == 0, "Smoke: free residue");
        console2.log("MOCK ONLY: pMockUSD returned to wallet", amount);
    }

    function _confirm() private view {
        require(block.chainid == 43_113, "Smoke: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_MOCK_ONLY", false), "Smoke: confirmation required");
    }

    function _roundTrip(bool short) private {
        uint256 id = EX.openPosition(
            IsolatedMarginExecutorUpgradeable.OpenParams(
                address(USD),
                short ? address(USD) : address(AVAX),
                short ? address(AVAX) : address(USD),
                MARGIN,
                200,
                0,
                short ? 199_800_000 : 19.8e18,
                short ? IsolatedMarginTypes.Side.SHORT : IsolatedMarginTypes.Side.LONG,
                ""
            )
        );
        (,, address account,,,,,,,,,) = EX.positions(id);
        require(!RISK.isLiquidatable(account), "Smoke: unhealthy at entry");
        console2.log(short ? "SHORT id" : "LONG id", id);
        console2.log("Entry health factor bps", RISK.getMetrics(account).healthFactorBps);
        EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
        require((short ? AVAX : USD).borrowBalanceStored(account) == 0, "Smoke: debt residue");
        (,,,,,,,,,,, IsolatedMarginTypes.Status status) = EX.positions(id);
        require(status == IsolatedMarginTypes.Status.CLOSED, "Smoke: not closed");
    }
}
