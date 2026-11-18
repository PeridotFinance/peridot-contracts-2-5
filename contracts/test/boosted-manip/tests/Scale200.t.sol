// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {console2} from "forge-std/Test.sol";
import {ManipBase} from "./ManipBase.sol";

/// @notice the same vectors at the USD 200 cap (operator holds 199 of the 200 shares; everything in the band): numbers for the table of the doc
contract Scale200Test is ManipBase {
    function _extraLedger() internal pure override returns (uint256) {
        return 183e6;
    }

    function setUp() public {
        _setUpManip();
    }

    function test_S200_fixture() public view {
        assertApproxEqAbs(_ta(), 200e6, 5_000, "TA about 200");
        assertEq(v.maxDeposit(ATTACKER) < 10_000, true, "cap reached");
    }

    function test_S200_swap_table() public {
        uint256[4] memory sizes = [uint256(1_000e6), 60_000e6, 150_000e6, 400_000e6];
        for (uint256 dir; dir < 2; ++dir) {
            for (uint256 i; i < sizes.length; ++i) {
                uint256 snap = vm.snapshotState();
                uint256 ta0 = _ta();
                uint256 outAmt = _swapAs(address(0xA77AC), dir == 0, sizes[i]);
                int256 dNav = int256(_ta()) - int256(ta0);
                console2.log(dir == 0 ? "T200 SELL USDC size / navDelta(wei) / attackerLoss(wei)" : "T200 SELL USDt size / navDelta(wei) / attackerLoss(wei)", sizes[i]);
                console2.logInt(dNav);
                console2.log(sizes[i] - outAmt);
                if (dNav > 0) assertLe(uint256(dNav), sizes[i] - outAmt);
                assertLe(dNav, int256(ta0 / 2_000), "NAV rise <= 5 bp");
                vm.revertToState(snap);
            }
        }
    }

    function test_S200_forced_recentre_loss_and_sandwich() public {
        uint256 ta0 = _ta();
        address who = address(0xA77AC);
        usdc.mint(who, 5_000_000e6);
        uint256 start = usdc.balanceOf(who) + usdt.balanceOf(who);
        (uint24 lo, uint24 hi,,,) = v.bandState();
        uint256 guard;
        while (guard++ < 60) {
            uint24 act = pair.getActiveId();
            if (act > hi || act < lo) break;
            _swapAs(who, true, 40_000e6);
        }
        _warpFresh(200);
        _rebalance();
        if (usdt.balanceOf(who) != 0) _swapAs(who, false, usdt.balanceOf(who));
        uint256 end_ = usdc.balanceOf(who) + usdt.balanceOf(who);
        console2.log("T200 sandwich: attacker value before / after; vault TA before / after:", start, end_);
        console2.log(ta0, _ta());
        assertLe(end_, start, "attacker loses");
        assertLe((ta0 - _ta()) * 10_000 / ta0, 50, "vault loss <= 50 bp");
    }

    function test_S200_feed_glitch_3x_doubles_the_price_at_w_half() public {
        uint256 p0 = _shareMantissa();
        feedUsdt.setAnswer(300_000_000);
        uint256 p1 = _shareMantissa();
        console2.log("T200 price before / after USDT feed 3.00:", p0, p1);
        assertApproxEqRel(p1, 2 * p0, 1e15, "w = 1/2: price x2 at g = 3 (break-even for an attacker is V_o = 2 V_r)");
    }
}
