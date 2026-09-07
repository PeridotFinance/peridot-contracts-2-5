// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IsolatedMarginQuoter} from "../contracts/margin/IsolatedMarginQuoter.sol";
import {IsolatedMarginExecutorUpgradeable} from "../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginRiskEngineUpgradeable} from "../contracts/margin/IsolatedMarginRiskEngineUpgradeable.sol";
import {IsolatedMarginConfigUpgradeable} from "../contracts/margin/IsolatedMarginConfigUpgradeable.sol";
import {IsolatedMarginVaultUpgradeable} from "../contracts/margin/IsolatedMarginVaultUpgradeable.sol";
import {IsolatedMarginTypes} from "../contracts/margin/IsolatedMarginTypes.sol";
import {FujiMockPriceFeed} from "../contracts/margin/testing/FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "../contracts/margin/testing/FujiMockSwapAdapter.sol";
import {PErc20} from "../contracts/PErc20.sol";

/// @notice LOCAL CODE-SUBSTITUTION regression against activated Fuji state, NOT an upgrade rehearsal.
/// @dev Replaces executor implementation and non-upgradeable quoter runtime only in Foundry VM.
///      A real deployment needs a separately reviewed replacement/migration; vm.etch is not an on-chain option.
contract FujiMockSizingFixForkTest is Test {
    address constant OWNER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address constant USER = address(0xA11CE);
    uint256 constant MARGIN = 5000e8;
    PErc20 constant USD = PErc20(0x81BF2032e98C8F35F2336e1A68baA01B5B2030E4);
    PErc20 constant AVAX = PErc20(0x577AC6Ca3Df06D7702740A6A8c136F868f9f0195);
    FujiMockPriceFeed constant AF = FujiMockPriceFeed(0x515a87601C4515e8B42f69645E77B56110d1a9A4);
    FujiMockPriceFeed constant UF = FujiMockPriceFeed(0x4758CB877D0B1f768EdC1F374156127A1517b2eD);
    FujiMockSwapAdapter constant ADAPTER = FujiMockSwapAdapter(0xEF3F12c9D60bc86484dac6250BCC25d784Ba200B);
    IsolatedMarginExecutorUpgradeable constant EX =
        IsolatedMarginExecutorUpgradeable(0xa155ccCB986774AE818b3F10F07d01D1b7A47b26);
    IsolatedMarginRiskEngineUpgradeable constant RISK =
        IsolatedMarginRiskEngineUpgradeable(0x94DA93A26770C114FD6a59015aD462c65C7A2F8c);
    IsolatedMarginConfigUpgradeable constant CONFIG =
        IsolatedMarginConfigUpgradeable(0x6148183676E304dbe63a85C350c208DA3cEAc39C);
    IsolatedMarginVaultUpgradeable constant VAULT =
        IsolatedMarginVaultUpgradeable(0x0987154fB5676a8Ea545AAf41F8ef2492F785d22);

    function setUp() public {
        string memory rpc = vm.envOr("FUJI_MOCK_FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 58_243_366);
        assertEq(block.chainid, 43_113);
        require(!CONFIG.opensPaused(), "expected activated fork");
        IsolatedMarginQuoter fresh = new IsolatedMarginQuoter(address(CONFIG), address(RISK.oracle()));
        vm.etch(address(EX.quoter()), address(fresh).code);
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address implementation = address(uint160(uint256(vm.load(address(EX), slot))));
        require(implementation.code.length > 0, "implementation missing");
        vm.etch(implementation, address(new IsolatedMarginExecutorUpgradeable()).code);
        _refresh();
        vm.prank(OWNER);
        USD.transfer(USER, MARGIN * 10);
        vm.startPrank(USER);
        USD.approve(address(VAULT), MARGIN * 10);
        VAULT.deposit(address(USD), MARGIN * 10);
        vm.stopPrank();
    }

    function testFixedTwoXLongAndShortAtAllowedExecutionLoss() public {
        _flows(200);
    }

    function testFixedThreeXLongAndShortAtAllowedExecutionLoss() public {
        _candidate();
        _flows(300);
    }

    function testFixedFourXLongAndShortAtAllowedExecutionLoss() public {
        _candidate();
        _flows(400);
    }

    function testFixedFiveXLongAndShortAtAllowedExecutionLoss() public {
        _candidate();
        _flows(500);
    }

    function _flows(uint16 leverage) private {
        for (uint256 side; side < 2; ++side) {
            for (uint256 loss; loss <= 100; loss += 50) {
                vm.prank(OWNER);
                uint256 actualLoss = side == 1 && loss == 100 ? 99 : loss;
                ADAPTER.setExecutionBps(uint16(10_000 - actualLoss));
                address position = side == 0 ? address(AVAX) : address(USD);
                address debt = side == 0 ? address(USD) : address(AVAX);
                USD.exchangeRateCurrent();
                AVAX.exchangeRateCurrent();
                (, uint256 minimum) = EX.quoter()
                    .quoteOpen(address(USD), position, debt, MARGIN * USD.exchangeRateStored() / 1e18, leverage);
                vm.prank(USER);
                uint256 id = EX.openPosition(
                    IsolatedMarginExecutorUpgradeable.OpenParams(
                        address(USD),
                        position,
                        debt,
                        MARGIN,
                        leverage,
                        0,
                        minimum,
                        side == 0 ? IsolatedMarginTypes.Side.LONG : IsolatedMarginTypes.Side.SHORT,
                        ""
                    )
                );
                (,, address account,,,,,,,,,) = EX.positions(id);
                IsolatedMarginTypes.AccountMetrics memory m = RISK.getMetrics(account);
                assertLe(m.leverageX100, leverage);
                assertGe(uint256(m.equityUsd), m.initialRequirementUsd);
                assertFalse(RISK.isLiquidatable(account));
                uint256 boundary = _boundary(account, side == 1);
                uint256 distance = side == 1 ? (boundary - 10e8) * 10_000 / 10e8 : (10e8 - boundary) * 10_000 / 10e8;
                assertGe(distance, 1100);
                console2.log(side == 0 ? "LONG request x100" : "SHORT request x100", leverage);
                console2.log("execution loss bps / actual leverage x100", actualLoss, m.leverageX100);
                console2.log("liquidation feed price / adverse distance bps", boundary, distance);
                _refresh();
                vm.prank(OWNER);
                ADAPTER.setExecutionBps(10_000);
                vm.prank(USER);
                EX.closePosition(IsolatedMarginExecutorUpgradeable.CloseParams(id, 10_000, 0, 0, 0, "", ""));
                assertEq(PErc20(debt).borrowBalanceStored(account), 0);
                assertEq(VAULT.lockedBalance(USER, address(USD)), 0);
            }
        }
        uint256 free = VAULT.freeBalance(USER, address(USD));
        vm.prank(USER);
        VAULT.withdraw(address(USD), free);
        assertEq(USD.balanceOf(USER), free);
        assertEq(VAULT.freeBalance(USER, address(USD)), 0);
    }

    function _boundary(address account, bool short) private returns (uint256) {
        uint256 lo = short ? 10e8 : 1e8;
        uint256 hi = short ? 30e8 : 10e8;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            vm.prank(OWNER);
            AF.setAnswer(int256(mid));
            if (RISK.isLiquidatable(account) == short) hi = mid;
            else lo = mid;
        }
        vm.prank(OWNER);
        AF.setAnswer(int256(short ? lo : hi));
        assertFalse(RISK.isLiquidatable(account));
        vm.prank(OWNER);
        AF.setAnswer(int256(short ? hi : lo));
        assertTrue(RISK.isLiquidatable(account));
        return short ? hi : lo;
    }

    function _candidate() private {
        IsolatedMarginTypes.PairRiskConfig memory r = CONFIG.getPairRisk(address(USD), address(AVAX), address(USD));
        r.maxLeverageX100 = 500;
        r.initialMarginBps = 2000;
        r.maintenanceMarginBps = 1000;
        vm.startPrank(OWNER);
        CONFIG.queuePairRisk(address(USD), address(AVAX), address(USD), r);
        CONFIG.queuePairRisk(address(USD), address(USD), address(AVAX), r);
        vm.warp(block.timestamp + CONFIG.actionDelay());
        CONFIG.setPairRisk(address(USD), address(AVAX), address(USD), r);
        CONFIG.setPairRisk(address(USD), address(USD), address(AVAX), r);
        vm.stopPrank();
        _refresh();
    }

    function _refresh() private {
        vm.startPrank(OWNER);
        AF.setAnswer(10e8);
        UF.setAnswer(1e8);
        vm.stopPrank();
    }
}
