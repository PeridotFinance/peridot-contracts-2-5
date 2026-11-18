// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console2} from "forge-std/Test.sol";
import {ManipBase} from "./ManipBase.sol";

contract SmokeTest is ManipBase {
    function setUp() public {
        _setUpManip();
    }

    function test_smoke_rig_behaves() public view {
        assertEq(_supply(), 17e6, "supply 17 shares");
        assertApproxEqAbs(_ta(), 17e6, 1_000, "TA 17 USDC");
        assertEq(sh.balanceOf(DEAD), 1e6, "dead seed");
        assertApproxEqAbs(v.convertToAssets(1e6), 1e6, 20, "1 share = 0.99999 USDC (band-open swap cost 13 ppm)");
        assertApproxEqAbs(_shareMantissa(), 1e30, 2e25, "oracle: 1 share = $1 -> 10^(36-6)");
        (, , , bool has,) = v.bandState();
        assertTrue(has, "band open");
        assertApproxEqAbs(_borrowPower(16e6), 8e6, 1_000, "16 shares at CF 50% borrow 8 USDC");
    }
}
