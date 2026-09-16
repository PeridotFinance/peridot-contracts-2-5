// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console2} from "forge-std/Script.sol";
import {PErc20Delegate} from "../contracts/PErc20Delegate.sol";
import {PErc20Delegator} from "../contracts/PErc20Delegator.sol";
import {PErc20} from "../contracts/PErc20.sol";
import {PToken} from "../contracts/PToken.sol";
import {Peridottroller} from "../contracts/Peridottroller.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";

/// @notice Two separately approved stages for the existing, debt-free FUJI MOCK markets only.
/// @dev pause() = three transactions. run() = deploy delegate + two atomic market upgrades.
///      NOT a cross-market atomic batch. Never blindly replay after partial execution.
///      Re-enumerate ALL historical borrowers after pause receipts before approving run().
contract MigrateFujiMockBorrowAccounting is Script {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant LEGACY = 0x87563AAb6F1e60441D511d1512f28A0bdfA6FAf2;
    address constant LONG_ACCOUNT = 0x8280Bb4DDc57447c5a3b04177e67F7bf7C07dAE1;
    address constant SHORT_ACCOUNT = 0xBe80594d30c257f61E3C9ad7A3E189ba6f065Dd4;
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    Peridottroller constant CONTROLLER = Peridottroller(0x0020998Ef0f159cf225e183BefF212b5dBA8285a);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);

    struct Snapshot {
        uint256 cash;
        uint256 supply;
        uint256 reserves;
        uint256 ownerShares;
        uint256 vaultShares;
        uint256 exchangeRate;
    }

    function pause() external {
        _confirm();
        require(vm.envOr("CONFIRM_FUJI_DEBT_PAUSE", false), "DebtMigration: pause confirmation");
        _preflight();
        require(
            !EX.config().opensPaused() && !CONTROLLER.borrowGuardianPaused(address(USD))
                && !CONTROLLER.borrowGuardianPaused(address(AVAX)),
            "DebtMigration: reconcile partial pause"
        );
        vm.startBroadcast(OWNER);
        EX.config().pauseOpens();
        require(CONTROLLER._setBorrowPaused(PToken(address(USD)), true), "DebtMigration: USD pause");
        require(CONTROLLER._setBorrowPaused(PToken(address(AVAX)), true), "DebtMigration: AVAX pause");
        vm.stopBroadcast();
        _paused();
        console2.log("MOCK ONLY: opens and both borrowing gates paused. Verify receipts and borrower history.");
    }

    function run() external returns (PErc20Delegate replacement) {
        _confirm();
        require(vm.envOr("CONFIRM_FUJI_DEBT_MIGRATION", false), "DebtMigration: migration confirmation");
        require(vm.envOr("CONFIRM_FUJI_BORROWER_HISTORY_REVIEWED", false), "DebtMigration: history confirmation");
        _preflight();
        _paused();
        Snapshot memory usd = _snapshot(USD);
        Snapshot memory avax = _snapshot(AVAX);
        vm.startBroadcast(OWNER);
        replacement = new PErc20Delegate();
        require(address(replacement).code.length <= 24_576, "DebtMigration: delegate size");
        require(replacement.borrowAccountingModule().code.length > 0, "DebtMigration: helper missing");
        PErc20Delegator(payable(address(USD)))
            ._setImplementation(address(replacement), false, abi.encode(new address[](0), uint256(0), uint256(0)));
        PErc20Delegator(payable(address(AVAX)))
            ._setImplementation(address(replacement), false, abi.encode(new address[](0), uint256(8), uint256(8)));
        vm.stopBroadcast();
        _verify(USD, replacement, usd, 0);
        _verify(AVAX, replacement, avax, 8);
        _paused();
        console2.log("MOCK ONLY lending delegate", address(replacement));
        console2.log("Immutable debt-accounting helper", replacement.borrowAccountingModule());
        console2.log("Both markets migrated; opens and borrowing remain paused. No reopening or leverage change.");
    }

    function _confirm() private view {
        require(block.chainid == 43_113, "DebtMigration: Fuji only");
        require(vm.envOr("CONFIRM_FUJI_MOCK_ONLY", false), "DebtMigration: mock confirmation");
        require(
            keccak256(bytes(vm.envOr("FOUNDRY_PROFILE", string("")))) == keccak256("debt_accounting"),
            "DebtMigration: release profile required"
        );
    }

    function _preflight() private view {
        require(
            LEGACY.codehash == 0x38aefc43d0a808b508524223cdeef1160e05e305bf88435491cbd60ac2e4b7db,
            "DebtMigration: legacy runtime"
        );
        require(CONTROLLER.admin() == OWNER && EX.config().owner() == OWNER, "DebtMigration: owner changed");
        require(address(EX.config()) == 0x6148183676E304dbe63a85C350c208DA3cEAc39C, "DebtMigration: config");
        require(address(EX.vault()) == 0x0987154fB5676a8Ea545AAf41F8ef2492F785d22, "DebtMigration: vault");
        require(EX.config().queuedActions(keccak256("unpauseOpens")) == 0, "DebtMigration: pending unpause");
        require(EX.nextPositionId() == 3, "DebtMigration: position history changed");
        _market(USD, 0x145700AA1575E7Fb84162D2c8C5201cf683df335, 0);
        _market(AVAX, 0x614396e98a9042b2Bdc9619E6A556e132A62DC06, 8);
        _closed(1, LONG_ACCOUNT);
        _closed(2, SHORT_ACCOUNT);
        require(AVAX.totalReserves() >= 8, "DebtMigration: insufficient rounding reserve");
        require(
            EX.config().getPairRisk(address(USD), address(AVAX), address(USD)).maxLeverageX100 == 200
                && EX.config().getPairRisk(address(USD), address(USD), address(AVAX)).maxLeverageX100 == 200,
            "DebtMigration: leverage changed"
        );
    }

    function _market(PErc20 market, address asset, uint256 debt) private view {
        require(market.admin() == OWNER && market.underlying() == asset, "DebtMigration: market identity");
        require(address(market.peridottroller()) == address(CONTROLLER), "DebtMigration: controller");
        require(PErc20Delegator(payable(address(market))).implementation() == LEGACY, "DebtMigration: implementation");
        require(market.totalBorrows() == debt && market.flashLoansPaused(), "DebtMigration: debt or flash gate");
        require(EX.vault().totalLockedBalance(address(market)) == 0, "DebtMigration: locked margin");
    }

    function _closed(uint256 id, address expectedAccount) private view {
        (,, address account,,,,,,,,, IsolatedMarginTypes.Status status) = EX.positions(id);
        require(account == expectedAccount && status == IsolatedMarginTypes.Status.CLOSED, "DebtMigration: position");
        require(
            USD.borrowBalanceStored(account) == 0 && AVAX.borrowBalanceStored(account) == 0,
            "DebtMigration: active borrower"
        );
    }

    function _paused() private view {
        require(
            EX.config().opensPaused() && CONTROLLER.borrowGuardianPaused(address(USD))
                && CONTROLLER.borrowGuardianPaused(address(AVAX)),
            "DebtMigration: pause first"
        );
    }

    function _snapshot(PErc20 market) private view returns (Snapshot memory) {
        return Snapshot(
            market.getCash(),
            market.totalSupply(),
            market.totalReserves(),
            market.balanceOf(OWNER),
            market.balanceOf(address(EX.vault())),
            market.exchangeRateStored()
        );
    }

    function _verify(PErc20 market, PErc20Delegate replacement, Snapshot memory before_, uint256 writeDown)
        private
        view
    {
        require(
            PErc20Delegator(payable(address(market))).implementation() == address(replacement), "DebtMigration: pointer"
        );
        require(market.borrowAccountingEnabled() && market.totalBorrowShares() == 0, "DebtMigration: mode/shares");
        require(
            market.totalBorrows() == 0 && market.totalReserves() == before_.reserves - writeDown,
            "DebtMigration: totals"
        );
        require(market.getCash() == before_.cash && market.totalSupply() == before_.supply, "DebtMigration: custody");
        require(
            market.balanceOf(OWNER) == before_.ownerShares
                && market.balanceOf(address(EX.vault())) == before_.vaultShares
                && market.exchangeRateStored() == before_.exchangeRate,
            "DebtMigration: supply claims"
        );
        require(
            market.borrowAccountingModule() == replacement.borrowAccountingModule(), "DebtMigration: helper binding"
        );
    }
}
