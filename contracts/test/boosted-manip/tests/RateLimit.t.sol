// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {console2} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

import {ManipBase, MockBaseOracle} from "./ManipBase.sol";
import {PToken} from "../../../contracts/PToken.sol";
// the OPTIONAL rate-limited wrapper: the patched copy (the same bytes `patches/oracle-rate-limit.patch` produces from PharaohVaultShareOracle.sol, import paths aside)
import {PharaohVaultShareOracle as ShareOracleRL} from "./rl/PharaohVaultShareOracle.sol";

contract RateLimitTest is ManipBase {
    ShareOracleRL internal rl;

    function setUp() public {
        _setUpManip();
        rl = new ShareOracleRL(SAFE, new MockBaseOracle(AggregatorV3Interface(address(feedUsdc))));
        vm.prank(SAFE);
        rl.registerVault(IERC4626(proxyAddr), AggregatorV3Interface(address(feedUsdc)), 90_000);
    }

    function _p() internal view returns (uint256) {
        return rl.getUnderlyingPrice(PToken(address(pShare)));
    }

    function _raw() internal view returns (uint256) {
        return rl.getRawShareUsdPrice(proxyAddr) * 1e12; // same mantissa scale as getUnderlyingPrice for a 6-decimal share
    }

    /// USDC borrow power of `shares` through the limited wrapper (same arithmetic as ManipBase._borrowPower)
    function _bpRL(uint256 shares) internal view returns (uint256) {
        return shares * _p() / 1e18 * CF_BPS / 10_000 * 1e6 / _usdcUsd18();
    }

    function _hourly(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _refreshFeeds();
            rl.poke(proxyAddr);
        }
    }

    function test_RL1_registration_checkpoints_assets_per_share() public view {
        assertEq(_p(), _raw(), "no spike: limited == spot");
        (uint128 ca, uint64 at) = rl.checkpoints(proxyAddr);
        assertEq(uint256(at), block.timestamp);
        assertEq(uint256(ca), v.convertToAssets(1e6), "checkpoint = assets per whole share");
    }

    function test_RL2_donation_spike_is_capped_and_released_at_1pct_per_hour_with_hourly_pokes() public {
        // the A1 scenario: the attacker holds 91.5 %, then donates 10 USDC: spot about +46 %
        uint256 D = v.maxDeposit(address(this));
        _dep(address(this), D);
        rl.poke(proxyAddr);
        uint256 base = _p();
        usdc.mint(proxyAddr, 100e6);
        uint256 raw = _raw();
        assertGt(raw, base * 14 / 10, "spot jumped by more than 40 %");
        assertEq(_p(), base, "same block: price held at the checkpoint");
        uint256 shares = sh.balanceOf(address(this));
        console2.log("borrow power (USDC-6) at the raw spot / at the limited price, same block:", shares * raw / 1e18 / 2 / 1e12, _bpRL(shares));
        _hourly(1);
        assertApproxEqRel(_p(), base * 101 / 100, 1e12, "+1 % after one hour");
        _hourly(23);
        assertApproxEqRel(_p(), base * 12_697 / 10_000, 1e14, "+26.97 % after 24 hourly pokes (re-based each poke: 1.01^24)");
        _hourly(30);
        assertEq(_p(), raw, "after about 40 hours of hourly pokes the cap passes the real (backed) value: nothing legitimate is lost, only delayed");
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
        (uint128 c0,) = rl.checkpoints(proxyAddr);
        for (uint256 i; i < 60; ++i) {
            vm.warp(block.timestamp + 1 minutes);
            _refreshFeeds();
            rl.poke(proxyAddr);
        }
        (uint128 c1,) = rl.checkpoints(proxyAddr);
        assertLe(uint256(c1), uint256(c0) * 10_101 / 10_000 + 1, "60 pokes in one hour raise the checkpoint by <= ~1.01 %");
        assertGe(uint256(c1), uint256(c0), "never lowered by a poke while spot is above");
    }

    function test_RL5_stale_checkpoint_keeps_binding_at_plus_24pct() public {
        usdc.mint(proxyAddr, 10e6); // spot about x1.59
        (uint128 c0,) = rl.checkpoints(proxyAddr);
        uint256 raw = _raw();
        vm.warp(block.timestamp + 100 hours);
        _refreshFeeds();
        uint256 lim = _p();
        assertLt(lim, raw, "un-poked for 100 h: still capped (elapsed is clamped to 24 h)");
        // price = assets per share x USDC/USD x scale: the cap allows c0 x 1.24 assets per share
        assertApproxEqRel(lim, uint256(c0) * 124 / 100 * 1e30 / 1e6, 1e13, "about +24 % over the registration checkpoint");
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

    function test_RL7_legit_income_and_a_recentre_pass_unchanged() public {
        // 20 wash round trips (fee income) and a forced re-centre with a real swap and band re-add; then one hour and one poke: price within the allowance, limited == spot
        address who = address(0xA77AC);
        for (uint256 i; i < 20; ++i) {
            uint256 o1 = _swapAs(who, true, 5_000e6);
            _swapAs(who, false, o1);
        }
        _pushOut(true);
        _warpFresh(200);
        _rebalance();
        _hourly(1);
        assertEq(_p(), _raw(), "income and re-centre cost move the price by ppm: limited == spot");
        (uint128 c,) = rl.checkpoints(proxyAddr);
        assertApproxEqAbs(uint256(c), v.convertToAssets(1e6), 1, "checkpoint follows");
    }

    function test_RL8_feed_glitch_3x_on_usdt_is_held_to_the_cap() public {
        uint256 base = _p();
        feedUsdt.setAnswer(300_000_000);
        assertGt(_raw(), base, "raw spot rises with the glitch");
        assertEq(_p(), base, "limited price unchanged in the block of the glitch");
        // the glitch lasts 3 hours (hourly pokes) then reverts: the limiter let the price rise by <= 3.04 %
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 1 hours);
            _refreshFeeds();
            feedUsdt.setAnswer(300_000_000);
            rl.poke(proxyAddr);
        }
        assertLe(_p(), base * 10_304 / 10_000 + 1, "a 3 h glitch moves the price <= 3.04 %");
        feedUsdt.setAnswer(100_000_000);
        assertApproxEqRel(_p(), base, 4e16, "back to par within the 3 % the limiter had released");
        rl.poke(proxyAddr);
        assertEq(_p(), _raw(), "and the checkpoint follows the fall");
    }

    function test_RL9_low_usdc_feed_glitch_binds_because_the_checkpoint_is_in_asset_units() public {
        uint256 shares = 16e6;
        uint256 bp0 = _bpRL(shares);
        feedUsdc.setAnswer(50_000_000); // USDC/USD 0.50: assets per share rise (USDt leg valued pp/pa), USD price falls
        uint256 bpRaw = shares * _raw() / 1e18 * CF_BPS / 10_000 * 1e6 / _usdcUsd18();
        uint256 bpLim = _bpRL(shares);
        console2.log("USDC borrow power of 16 shares: before / raw after the 0.50 USDC feed / limited:", bp0, bpRaw, bpLim);
        assertGt(bpRaw, bp0 * 14 / 10, "unlimited: USDC borrow power rises about 50 %");
        assertApproxEqRel(bpLim, bp0, 1e13, "limited: unchanged in the block of the glitch");
    }
}
