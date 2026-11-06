// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {StdAssertions} from "forge-std/StdAssertions.sol";
import {IsolatedMarginExecutorUpgradeable} from "../../contracts/margin/IsolatedMarginExecutorUpgradeable.sol";
import {IsolatedMarginTypes} from "../../contracts/margin/IsolatedMarginTypes.sol";
import {IRobinhoodOrderExecutor} from "../../contracts/margin/orders/RobinhoodMarginCloseAdapter.sol";
import {DeployRobinhoodOrders} from "../../script/orders/DeployRobinhoodOrders.s.sol";
import {RehearsalRegistryStub} from "./RehearsalRegistryStub.sol";

interface IDeployForkTimelock {
    function isOperationReady(bytes32 id) external view returns (bool);
}

interface IDeployForkVault {
    function freeBalance(address, address) external view returns (uint256);
}

/// @notice The prepared deployment path against the LIVE Robinhood margin stack at a fresh pin: the script's own deploy
/// (with the rehearsal registry stub standing in for the real registry), the Ledger's timelock schedule and execute
/// through the real timelock and ProxyAdmin, the script's verify, then an order-shaped close through stub, adapter and
/// closePositionFor on a live position when one exists. Nothing is sent anywhere.
contract RobinhoodOrdersDeployForkTest is DeployRobinhoodOrders, StdAssertions {
    address constant VAULT = 0x04D4A5555b7a37017A67B4D21A1Da5838de28B9e;
    address constant FEED = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    string constant JOURNAL = "deployments/orders-fork-test-journal.json";
    Deployment d;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ORDERS_FORK_BLOCK"));
        vm.roll(vm.envUint("ORDERS_NATIVE_BLOCK"));
        _preconditions();
        d = _deploy(address(this), type(RehearsalRegistryStub).creationCode);
        _postconditions(d, address(this));
    }

    function _schedule() internal {
        vm.prank(LEDGER);
        (bool ok,) = TIMELOCK.call(scheduleCalldata(d));
        assertTrue(ok, "Ledger schedules");
    }

    function _execute() internal {
        vm.warp(block.timestamp + DELAY);
        vm.prank(LEDGER);
        (bool ok,) = TIMELOCK.call(executeCalldata(d));
        assertTrue(ok, "Ledger executes");
    }

    function testTimelockPairUpgradesTheExecutorAndVerifyPasses() public {
        uint256 next = IsolatedMarginExecutorUpgradeable(EXECUTOR).nextPositionId();
        bytes32[] memory before = new bytes32[](next);
        for (uint256 id = 1; id < next; id++) before[id] = keccak256(abi.encode(IRobinhoodOrderExecutor(EXECUTOR).positions(id)));
        if (vm.exists(JOURNAL)) vm.removeFile(JOURNAL);
        _writeJournal(JOURNAL, d, "RehearsalRegistryStub");
        this.check(JOURNAL);
        _schedule();
        this.check(JOURNAL);
        assertFalse(IDeployForkTimelock(TIMELOCK).isOperationReady(operationId(d)));
        vm.prank(LEDGER);
        (bool early,) = TIMELOCK.call(executeCalldata(d));
        assertFalse(early, "execute before the delay is refused");
        _execute();
        this.verify(JOURNAL);
        for (uint256 id = 1; id < next; id++) {
            assertEq(keccak256(abi.encode(IRobinhoodOrderExecutor(EXECUTOR).positions(id))), before[id], "position unchanged");
        }
        vm.prank(LEDGER);
        (bool again,) = TIMELOCK.call(executeCalldata(d));
        assertFalse(again, "the operation runs once");
        vm.removeFile(JOURNAL);
    }

    function testOnlyTheLedgerCanSchedule() public {
        vm.prank(address(0xbad));
        (bool ok,) = TIMELOCK.call(scheduleCalldata(d));
        assertFalse(ok);
    }

    function testOrderShapedCloseOfALivePositionAfterTheUpgrade() public {
        _schedule();
        _execute();
        uint256 id;
        for (uint256 i = 1; i < IsolatedMarginExecutorUpgradeable(EXECUTOR).nextPositionId(); i++) {
            if (IRobinhoodOrderExecutor(EXECUTOR).positions(i).status == IsolatedMarginTypes.Status.ACTIVE) id = i;
        }
        if (id == 0) {
            emit log("no active position at this pin: deploy path verified, close demo skipped");
            return;
        }
        IsolatedMarginTypes.Position memory p = IRobinhoodOrderExecutor(EXECUTOR).positions(id);
        (bool okc, bytes memory r) = FEED.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(okc);
        (, int256 answer,,,) = abi.decode(r, (uint80, int256, uint256, uint256, uint80));
        vm.mockCall(
            FEED, abi.encodeWithSignature("latestRoundData()"), abi.encode(uint80(9), answer, block.timestamp, block.timestamp, uint80(9))
        );
        uint256 freeBefore = IDeployForkVault(VAULT).freeBalance(p.owner, p.marginPToken);
        vm.prank(address(0xbeef)); // anyone may trigger the registry; the stub has no auth, the adapter checks the registry
        uint256 returned = RehearsalRegistryStub(d.registry).closeAtOracle(id, 100);
        emit log_named_uint("closed position", id);
        emit log_named_uint("margin returned to the owner (pToken units)", returned);
        assertTrue(IRobinhoodOrderExecutor(EXECUTOR).positions(id).status != IsolatedMarginTypes.Status.ACTIVE, "closed");
        assertEq(IDeployForkVault(VAULT).freeBalance(p.owner, p.marginPToken), freeBefore + returned, "credited to the owner");
    }
}
