// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {RangeFixture} from "./RangeFixture.sol";
import {RangeTakeProfit} from "../src/RangeTakeProfit.sol";

/// @notice Builds the state the keeper's ANVIL fork test starts from, and DUMPS it (`vm.dumpState`) with the addresses: the live pool and PW30 at
/// the pinned block, the margin stack, the range upgrade, ALICE's 2x long with the 70/20/10 ladder, and the market traded through ALL THREE
/// rungs (pool and oracle). Run by `./run-fork.sh --match-contract KeeperFixtureDump`; the TypeScript test replays it into a local anvil fork.
contract KeeperFixtureDumpTest is RangeFixture {
    function test_dump() public {
        string memory dir = "fixtures";
        vm.createDir(dir, true);
        uint256 id = _open(ALICE, 90e6);
        vm.prank(ALICE);
        rtp.createRangeOrder(id, 4, 0);
        RangeTakeProfit.Order memory o = rtp.getOrder(id);
        _market(o.rungs[2].tickUpper + 5);
        (uint8 act, uint8 ready) = rtp.finalizable(id);
        require(act == 3 && ready == 3, "fixture: three rungs must be crossed");

        string memory k = "fixture";
        vm.serializeAddress(k, "custodian", address(rtp));
        vm.serializeAddress(k, "executor", md.executor);
        vm.serializeAddress(k, "vault", md.vault);
        vm.serializeAddress(k, "pUsdc", PUSDC);
        vm.serializeAddress(k, "alice", ALICE);
        vm.serializeAddress(k, "keeper", KEEPER);
        vm.serializeAddress(k, "avaxFeed", AVAX_FEED);
        vm.serializeAddress(k, "usdcFeed", USDC_FEED);
        vm.serializeInt(k, "avaxAnswer8", avaxAnswer);
        vm.serializeInt(k, "usdcAnswer8", usdcAnswer);
        vm.serializeUint(k, "positionId", id);
        vm.serializeUint(k, "forkBlock", forkBlock);
        vm.serializeUint(k, "timestamp", vm.getBlockTimestamp());
        string memory json = vm.serializeUint(k, "chainId", block.chainid);
        vm.writeJson(json, string.concat(dir, "/fixture.json"));
        vm.dumpState(string.concat(dir, "/state.json"));
    }
}
