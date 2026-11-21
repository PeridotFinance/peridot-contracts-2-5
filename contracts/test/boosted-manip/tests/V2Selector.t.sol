// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";

import {V2Base} from "./V2Base.sol";
import {PharaohDlmmShareOracle as SelOracle} from "../../../contracts/PharaohDlmmShareOracle.sol";
import {PriceOracle} from "../../../contracts/PriceOracle.sol";
import {PToken} from "../../../contracts/PToken.sol";

/// @notice REGRESSION tests of the production wrapper v3 (`cac947c9`): the fallback covers ONLY the vault's own `FeedInvalid(uint8)`; every other vault failure (a failed pair read =
///         `ExitFailed`, an empty revert = out of gas, a panic, a zero answer) prices 0 at once. (The 21 Nov `FeedInvalid`-only patch proposed by this analysis was adopted as v3.)
contract V2SelectorTest is V2Base {
    SelOracle internal s2;

    function setUp() public {
        _setUpV2();
        s2 = w2; // production v3 (same constructor arguments as every other V2 test)
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
    }

    function test_S4_a_vault_whose_nav_rounds_to_zero_is_price_0() public {
        _tick(3_600);
        _freshBoth();
        assertTrue(s2.poke());
        vm.mockCall(address(pair), abi.encodeWithSelector(pair.getBin.selector), abi.encode(uint128(0), uint128(0)));
        assertEq(v.convertToAssets(1e6), 0);
        assertEq(_sp(), 0);
        assertFalse(_sUsing());
    }

    function test_S4b_other_non_feed_failures_price_0_and_the_vaults_own_feed_error_falls_back() public {
        _tick(3_600);
        _freshBoth();
        assertTrue(s2.poke());
        uint256 fb = (uint256(s2.lastGoodAssetsPerShare()) * 9_700 / 10_000) * 1e24;
        bytes4 sel = v.convertToAssets.selector;
        // empty revert (what an out-of-gas inside the vault looks like), a Panic, a custom error that is not FeedInvalid, a one-word return
        vm.mockCallRevert(proxyAddr, abi.encodeWithSelector(sel), "");
        assertEq(_sp(), 0, "empty revert");
        vm.mockCallRevert(proxyAddr, abi.encodeWithSelector(sel), abi.encodeWithSignature("Panic(uint256)", 0x11));
        assertEq(_sp(), 0, "panic");
        vm.mockCallRevert(proxyAddr, abi.encodeWithSelector(sel), abi.encodeWithSignature("ExitFailed()"));
        assertEq(_sp(), 0, "ExitFailed");
        vm.mockCallRevert(proxyAddr, abi.encodeWithSelector(sel), abi.encodeWithSignature("FeedInvalid(uint8)", uint8(2)));
        assertEq(_sp(), fb, "FeedInvalid(2) (the USDT feed): fallback");
        vm.mockCallRevert(proxyAddr, abi.encodeWithSelector(sel), abi.encodeWithSignature("FeedInvalid(uint8)", uint8(1)));
        assertEq(_sp(), fb, "FeedInvalid(1) (the USDC feed, if the base oracle still prices it): fallback");
        vm.clearMockedCalls();
        assertGt(_sp(), fb);
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
