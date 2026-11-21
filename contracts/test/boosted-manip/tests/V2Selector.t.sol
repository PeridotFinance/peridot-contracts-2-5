// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";

import {V2Base} from "./V2Base.sol";
import {PharaohDlmmShareOracle as SelOracle} from "./v2sel/PharaohDlmmShareOracle.sol";
import {PriceOracle} from "../../../contracts/PriceOracle.sol";
import {PToken} from "../../../contracts/PToken.sol";

/// @notice OPTIONAL variant (patch `patches/dlmm-oracle-fallback-feedinvalid-only.patch`, NOT applied to the frozen wrapper): fall back ONLY when the vault reverts with its own
///         `FeedInvalid(uint8)`; every other revert (failed pair read `ExitFailed`, out of gas = empty data) and a zero answer is a BROKEN vault: price 0. Shows the variant keeps the feed
///         outage behaviour and removes the non-feed fallback of V2Fallback D5/D6.
contract V2SelectorTest is V2Base {
    SelOracle internal s2;

    function setUp() public {
        _setUpV2();
        s2 = new SelOracle(PriceOracle(address(guarded)), address(pS2));
    }

    function _sp() internal view returns (uint256) {
        return s2.getUnderlyingPrice(PToken(address(pS2)));
    }

    function _sUsing() internal view returns (bool u) {
        (,,, u,) = s2.shareState();
    }

    function test_S1_a_stale_usdt_feed_still_gets_the_97_percent_fallback_and_the_same_timeline() public {
        for (uint256 k = 1; k <= 26; ++k) {
            _tick(3_600);
            _freshUsdc();
            assertTrue(s2.poke());
        }
        _tick(1);
        _freshUsdc();
        assertTrue(_sUsing(), "FeedInvalid: fallback");
        assertEq(_sp(), (uint256(s2.lastGoodAssetsPerShare()) * 9_700 / 10_000) * 1e24);
    }

    function test_S2_feed_side_bad_answers_still_fall_back_at_once() public {
        _tick(3_600);
        _freshBoth();
        assertTrue(s2.poke());
        uint256 fb = (uint256(s2.lastGoodAssetsPerShare()) * 9_700 / 10_000) * 1e24;
        feedUsdt.setAnswer(0);
        assertEq(_sp(), fb);
        feedUsdt.setAnswer(1e8);
        feedUsdt.setRevertLatest(true);
        assertEq(_sp(), fb);
        feedUsdt.setRevertLatest(false);
        feedUsdt.setIncompleteRound();
        assertEq(_sp(), fb);
        feedUsdt.setAnswer(1e8);
        feedUsdt.setUpdatedAt(clock + 1);
        assertEq(_sp(), fb);
    }

    function test_S3_a_failing_pair_read_is_price_0_not_a_fallback() public {
        _tick(3_600);
        _freshBoth();
        assertTrue(s2.poke());
        assertGt(_sp(), 0);
        vm.mockCallRevert(address(pair), abi.encodeWithSelector(pair.getBin.selector), "pair down");
        assertEq(_sp(), 0, "ExitFailed is not FeedInvalid: BROKEN");
        assertFalse(_sUsing());
        assertFalse(s2.poke());
        // the frozen wrapper serves 97 % in the same state
        assertGt(_p(), 0);
    }

    function test_S4_a_vault_whose_nav_rounds_to_zero_is_price_0() public {
        _tick(3_600);
        _freshBoth();
        assertTrue(s2.poke());
        vm.mockCall(address(pair), abi.encodeWithSelector(pair.getBin.selector), abi.encode(uint128(0), uint128(0)));
        assertEq(v.convertToAssets(1e6), 0);
        assertEq(_sp(), 0);
        assertFalse(_sUsing());
        assertGt(_p(), 0, "frozen wrapper: 97 %");
    }

    function test_S5_gas_sweep_still_never_a_fallback_or_zero_for_a_healthy_vault() public {
        feedUsdt.setAnswer(3e8);
        _tick(3_600);
        _freshBoth();
        feedUsdt.setAnswer(3e8);
        s2.poke();
        _tick(3_600);
        _freshBoth();
        feedUsdt.setAnswer(3e8);
        s2.poke();
        feedUsdt.setAnswer(1e8);
        uint256 live = _sp();
        assertEq(live, _live() * 1e24);
        assertGt(uint256(s2.lastGoodAssetsPerShare()) * 9_700 / 10_000, _live(), "setup: stored x 0.97 above live");
        uint256 reverts;
        uint256 equalLive;
        uint256 zeros;
        uint256 other;
        for (uint256 g = 4_000; g <= 400_000; g += 250) {
            vm.cool(address(s2));
            vm.cool(proxyAddr);
            vm.cool(address(guarded));
            vm.cool(address(src));
            vm.cool(address(feedUsdc));
            vm.cool(address(feedUsdt));
            vm.cool(address(pair));
            (bool ok, bytes memory ret) = address(s2).staticcall{gas: g}(abi.encodeWithSignature("getUnderlyingPrice(address)", address(pS2)));
            if (!ok || ret.length < 32) ++reverts;
            else if (abi.decode(ret, (uint256)) == live) ++equalLive;
            else if (abi.decode(ret, (uint256)) == 0) ++zeros; // vault call ran out of gas -> BROKEN -> price 0 (fail closed; the caller only blinds his own transaction)
            else ++other;
        }
        console2.log("variant sweep: reverts / equals live / price 0 / other (the fallback price would be other):", reverts);
        console2.log(equalLive, zeros, other);
        assertEq(other, 0, "never the fallback price");
    }
}
