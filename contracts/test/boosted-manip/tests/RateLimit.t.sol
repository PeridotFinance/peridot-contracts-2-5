// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {console2} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {ManipBase, MockBaseOracle} from "./ManipBase.sol";
import {PToken} from "../../../contracts/PToken.sol";
// the OPTIONAL rate-limited wrapper: the patched copy (the same bytes `patches/oracle-rate-limit.patch` produces from PharaohVaultShareOracle.sol)
import {PharaohVaultShareOracle as ShareOracleRL} from "./rl/PharaohVaultShareOracle.sol";

contract RateLimitTest is ManipBase {
    ShareOracleRL internal rl;

    function setUp() public {
        _setUpManip();
        rl = new ShareOracleRL(SAFE, new MockBaseOracle());
        vm.prank(SAFE);
        rl.registerVault(IERC4626(proxyAddr), AggregatorV3Interface(address(feedUsdc)), 90_000);
    }

    function _p() internal view returns (uint256) {
        return rl.getUnderlyingPrice(PToken(address(pShare)));
    }

    function _raw() internal view returns (uint256) {
        return rl.getRawShareUsdPrice(proxyAddr) * 1e12; // same mantissa scale as getUnderlyingPrice for a 6-decimal share
    }

    function test_RL1_registration_checkpoints_the_spot() public view {
        assertEq(_p(), _raw(), "no spike: limited == spot");
        (uint128 px, uint64 at) = rl.checkpoints(proxyAddr);
        assertEq(uint256(at), block.timestamp);
        assertEq(uint256(px) * 1e12, _raw());
    }

    function test_RL2_donation_spike_is_capped_and_released_at_1pct_per_hour() public {
        // the A1 scenario: the attacker holds 91.5 %, then donates 100 USDC: spot +50 %
        uint256 D = v.maxDeposit(address(this));
        _dep(address(this), D);
        rl.poke(proxyAddr); // the hourly keeper poke after the (honest) deposit
        uint256 base = _p();
        usdc.mint(proxyAddr, 100e6);
        uint256 raw = _raw();
        assertGt(raw, base * 14 / 10, "spot jumped about +46 %");
        assertEq(_p(), base, "same block: price held at the checkpoint");
        uint256 shares = sh.balanceOf(address(this));
        console2.log("borrow power (USDC-6) at raw spot / at limited price, same block:", shares * raw / 1e18 / 2 / 1e12, shares * _p() / 1e18 / 2 / 1e12);
        vm.warp(block.timestamp + 1 hours);
        _refreshFeeds();
        assertApproxEqRel(_p(), base * 101 / 100, 1e12, "+1 % after one hour");
        vm.warp(block.timestamp + 23 hours);
        _refreshFeeds();
        assertApproxEqRel(_p(), base * 124 / 100, 1e12, "+24 % after a day (linear, not compounded)");
        vm.warp(block.timestamp + 40 hours);
        _refreshFeeds();
        assertEq(_p(), raw, "after about 46 hours the cap passes the real (backed) value: nothing legitimate is lost, only delayed");
    }

    function test_RL3_drops_pass_through_at_once() public {
        uint256 before = _p();
        feedUsdt.setAnswer(98_000_000); // USDT/USD 0.98
        uint256 afterP = _p();
        assertLt(afterP, before, "a fall is never delayed");
        assertEq(afterP, _raw(), "limited == spot on the way down");
    }

    function test_RL4_poking_cannot_accelerate_the_rise() public {
        usdc.mint(proxyAddr, 1_000e6); // spot x59
        uint256 base = _p() / 59; // price before the donation, approximately
        (uint128 c0,) = rl.checkpoints(proxyAddr);
        for (uint256 i; i < 60; ++i) {
            vm.warp(block.timestamp + 1 minutes);
            _refreshFeeds();
            rl.poke(proxyAddr);
        }
        (uint128 c1,) = rl.checkpoints(proxyAddr);
        // 60 pokes over exactly one hour: <= +1 % (+ the tiny compounding of re-basing every minute)
        assertLe(uint256(c1), uint256(c0) * 10_101 / 10_000 + 1, "60 pokes in one hour raise the checkpoint by <= ~1.01 %");
        assertGe(uint256(c1), uint256(c0), "never lowered by a poke while spot is above");
        base;
    }

    function test_RL5_stale_checkpoint_only_loosens() public {
        usdc.mint(proxyAddr, 10e6); // spot about x1.59
        uint256 raw = _raw();
        vm.warp(block.timestamp + 100 hours);
        _refreshFeeds();
        // 100 hours without a poke: cap = 2.0 x checkpoint > raw: the limiter has dissolved (never worse than the unlimited wrapper); a 5.9x spike would still be held to 2.0x
        assertEq(_p(), raw, "un-poked for 100 h: the cap no longer binds (fails open to the unlimited wrapper)");
        usdc.mint(proxyAddr, 90e6);
    }

    function test_RL6_failed_feed_returns_zero_and_poke_is_a_noop() public {
        (uint128 c0, uint64 t0) = rl.checkpoints(proxyAddr);
        vm.warp(block.timestamp + 93_601); // USDt feed stale for the vault
        feedUsdc.setUpdatedAt(block.timestamp);
        assertEq(_p(), 0, "same fail-closed behaviour as the unlimited wrapper");
        rl.poke(proxyAddr);
        (uint128 c1, uint64 t1) = rl.checkpoints(proxyAddr);
        assertEq(uint256(c1), uint256(c0), "poke stores nothing on a failed read");
        assertEq(uint256(t1), uint256(t0));
    }

    function test_RL7_legit_income_and_composition_drift_pass_unchanged() public {
        // a day of 100 wash round trips (fee income) and a re-centre: price moves a few ppm, far inside 1 %/h
        address who = address(0xA77AC);
        usdc.mint(who, 1_000_000e6);
        for (uint256 i; i < 10; ++i) {
            vm.startPrank(who);
            usdc.approve(address(router), type(uint256).max);
            usdt.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
        _warpFresh(1 hours);
        assertEq(_p(), _raw(), "within the allowance: limited == spot");
    }

    function test_RL8_feed_glitch_3x_on_usdt_is_held_to_the_cap() public {
        uint256 base = _p();
        feedUsdt.setAnswer(300_000_000);
        uint256 raw = _raw();
        assertGt(raw, base, "raw spot rises with the glitch");
        assertEq(_p(), base, "limited price unchanged in the block of the glitch");
        // the glitch lasts 3 hours then reverts: the limiter let the price rise by <= 3 %
        vm.warp(block.timestamp + 3 hours);
        _refreshFeeds();
        feedUsdt.setAnswer(300_000_000);
        uint256 lim = _p();
        assertLe(lim, base * 10_300 / 10_000 + 1, "a 3 h glitch moves the price <= 3 %");
        feedUsdt.setAnswer(100_000_000);
        assertApproxEqRel(_p(), base, 1e15, "back to par: nothing was ever borrowed against the spike");
    }
}
