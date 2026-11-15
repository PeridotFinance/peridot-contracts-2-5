// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {World} from "./World.sol";
import {MockLBPair} from "./mocks/MockLBPair.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// @notice Self-tests of the mocks: they must behave like the verified Pharaoh DLMM pair/router/rewarder where the vault depends on it.
contract MocksSelfTest is World {
    function setUp() public {
        _deployWorld();
    }

    function _vaultLike(address who, uint256 usdcAmt, uint256 usdtAmt, int256[] memory d, uint256[] memory dX, uint256[] memory dY) internal {
        _mintTokens(who, usdcAmt, usdtAmt);
        (uint256 aX, uint256 aY) = _split(usdcAmt, usdtAmt);
        vm.startPrank(who);
        usdc.approve(address(router), type(uint256).max);
        usdt.approve(address(router), type(uint256).max);
        router.addLiquidity(MockRouter.LiquidityParameters(pair.tokenX(), pair.tokenY(), BIN_STEP, aX, aY, 0, 0, ID0, 0, d, dX, dY, who, who, block.timestamp + 1));
        vm.stopPrank();
    }

    function _three() internal view returns (int256[] memory d, uint256[] memory dX, uint256[] memory dY) {
        d = new int256[](3);
        dX = new uint256[](3);
        dY = new uint256[](3);
        d[0] = -1;
        d[1] = 0;
        d[2] = 1;
        dY[0] = 0.5e18;
        dY[1] = 0.5e18;
        dX[1] = 0.5e18;
        dX[2] = 0.5e18;
        (pair); // silence
    }

    function test_tokenOrderAndHook() public view {
        assertEq(pair.tokenX(), usdcIsX ? address(usdc) : address(usdt));
        assertEq(pair.tokenY(), usdcIsX ? address(usdt) : address(usdc));
        assertEq(address(uint160(uint256(pair.getLBHooksParameters()))), address(rewarder));
        assertEq(uint256(pair.getLBHooksParameters()) >> 160, 0x151);
        assertTrue(rewarder.isLinked());
    }

    function test_whaleLiquidityLayout() public view {
        (uint128 bx, uint128 by) = pair.getBin(ID0 - 1);
        assertEq(bx, 0); // Y only below the active bin
        assertGt(by, 0);
        (bx, by) = pair.getBin(ID0 + 1);
        assertGt(bx, 0); // X only above
        assertEq(by, 0);
        (bx, by) = pair.getBin(ID0);
        assertGt(bx, 0);
        assertGt(by, 0);
    }

    function test_mintOneSidedRuleReverts() public {
        // USDC (Y) put into a bin ABOVE the active bin must be rejected by the pair
        int256[] memory d = new int256[](1);
        uint256[] memory dX = new uint256[](1);
        uint256[] memory dY = new uint256[](1);
        d[0] = 2;
        dY[0] = 1e18;
        // put only the Y token (USDC normally) in: above the active bin that is flawed
        uint256 cAmt = usdcIsX ? 0 : 1000e6;
        uint256 tAmt = usdcIsX ? 1000e6 : 0;
        _mintTokens(ALICE, cAmt, tAmt);
        (uint256 aX, uint256 aY) = _split(cAmt, tAmt);
        address xt = pair.tokenX();
        address yt = pair.tokenY();
        vm.startPrank(ALICE);
        usdc.approve(address(router), type(uint256).max);
        usdt.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(MockLBPair.BinHelper__CompositionFactorFlawed.selector, ID0 + 2));
        router.addLiquidity(MockRouter.LiquidityParameters(xt, yt, BIN_STEP, aX, aY, 0, 0, ID0, 0, d, dX, dY, ALICE, ALICE, block.timestamp + 1));
        vm.stopPrank();
    }

    function test_idSlippageAndDeadlineAndRecipient() public {
        (int256[] memory d, uint256[] memory dX, uint256[] memory dY) = _three();
        _mintTokens(ALICE, 1000e6, 1000e6);
        (uint256 aX, uint256 aY) = _split(1000e6, 1000e6);
        address xt = pair.tokenX();
        address yt = pair.tokenY();
        vm.startPrank(ALICE);
        usdc.approve(address(router), type(uint256).max);
        usdt.approve(address(router), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(MockRouter.LBRouter__IdSlippageCaught.selector, ID0 + 5, 1, ID0));
        router.addLiquidity(MockRouter.LiquidityParameters(xt, yt, BIN_STEP, aX, aY, 0, 0, ID0 + 5, 1, d, dX, dY, ALICE, ALICE, block.timestamp + 1));
        vm.expectRevert(abi.encodeWithSelector(MockRouter.LBRouter__DeadlineExceeded.selector, block.timestamp - 1, block.timestamp));
        router.addLiquidity(MockRouter.LiquidityParameters(xt, yt, BIN_STEP, aX, aY, 0, 0, ID0, 0, d, dX, dY, ALICE, ALICE, block.timestamp - 1));
        vm.expectRevert(abi.encodeWithSelector(MockRouter.LBRouter__UnauthorizedLiquidityRecipient.selector, ALICE, BOB));
        router.addLiquidity(MockRouter.LiquidityParameters(xt, yt, BIN_STEP, aX, aY, 0, 0, ID0, 0, d, dX, dY, BOB, ALICE, block.timestamp + 1));
        vm.stopPrank();
    }

    function test_mintBurnRoundTripAndProRata() public {
        (int256[] memory d, uint256[] memory dX, uint256[] memory dY) = _three();
        _vaultLike(ALICE, 3000e6, 3000e6, d, dX, dY);
        uint256 s0 = pair.balanceOf(ALICE, ID0);
        uint256 sm = pair.balanceOf(ALICE, ID0 - 1);
        uint256 sp = pair.balanceOf(ALICE, ID0 + 1);
        assertGt(s0, 0);
        assertGt(sm, 0);
        assertGt(sp, 0);
        uint256 supply0 = pair.totalSupply(ID0);
        assertGt(supply0, s0); // the whale holds the rest

        // ALICE burns all three bins through the router: she needs approveForAll(router)
        uint256[] memory ids = new uint256[](3);
        uint256[] memory am = new uint256[](3);
        ids[0] = ID0 - 1;
        ids[1] = ID0;
        ids[2] = ID0 + 1;
        am[0] = sm;
        am[1] = s0;
        am[2] = sp;
        address xt = pair.tokenX();
        address yt = pair.tokenY();
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MockLBPair.LBToken__SpenderNotApproved.selector, ALICE, address(router)));
        router.removeLiquidity(xt, yt, BIN_STEP, 0, 0, ids, am, ALICE, block.timestamp + 1);
        pair.approveForAll(address(router), true);
        (uint256 ax, uint256 ay) = router.removeLiquidity(xt, yt, BIN_STEP, 0, 0, ids, am, ALICE, block.timestamp + 1);
        vm.stopPrank();
        // pro rata, rounding down: the user never gets more than put in (equal price 1 +- 1bp bins, so within 2 bps of 3000/3000)
        assertLe(ax + ay, 6000e6 + 1e6 / 100);
        assertGe(ax + ay, 6000e6 - 1e6 / 100);
        assertEq(pair.balanceOf(ALICE, ID0), 0);
    }

    function test_burnZeroAmountAndZeroOut() public {
        (int256[] memory d, uint256[] memory dX, uint256[] memory dY) = _three();
        _vaultLike(ALICE, 3000e6, 3000e6, d, dX, dY);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory am = new uint256[](1);
        ids[0] = ID0 - 1;
        vm.startPrank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MockLBPair.LBPair__ZeroAmount.selector, ID0 - 1));
        pair.burn(ALICE, ALICE, ids, am);
        // one share of a deep bin pays floor(reserve / supply) which is zero when supply > reserves
        am[0] = 1;
        (, uint128 by) = pair.getBin(ID0 - 1);
        uint256 supply = pair.totalSupply(ID0 - 1);
        if (by < supply) {
            vm.expectRevert(abi.encodeWithSelector(MockLBPair.LBPair__ZeroAmountsOut.selector, ID0 - 1));
            pair.burn(ALICE, ALICE, ids, am);
        }
        vm.stopPrank();
    }

    function test_sharesAreNonTransferableThroughHook() public {
        (int256[] memory d, uint256[] memory dX, uint256[] memory dY) = _three();
        _vaultLike(ALICE, 3000e6, 3000e6, d, dX, dY);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory am = new uint256[](1);
        ids[0] = ID0;
        am[0] = 1;
        vm.prank(ALICE);
        vm.expectRevert(bytes("transfers disabled"));
        pair.batchTransferFrom(ALICE, BOB, ids, am);
    }

    function test_swapMovesActiveBinAndFeeStaysInBin() public {
        uint24 a0 = pair.getActiveId();
        uint256 usdcBefore;
        (usdcBefore,) = _bin(ID0);
        // sell 150k USDC into the pool: the active bin holds only 100k of the other token, so the active id moves
        uint256 out = _marketSwap(true, 150_000e6);
        assertGt(out, 148_000e6);
        assertLt(out, 150_000e6); // fee + price slope
        assertTrue(pair.getActiveId() != a0);
        assertEq(pair.swapCount(), 1);
        // and back: the active id returns near the start
        _marketSwap(false, 300_000e6);
        uint24 a2 = pair.getActiveId();
        assertTrue(a2 > a0 - 3 && a2 < a0 + 3);
    }

    function test_swapOutOfLiquidity() public {
        usdc.mint(address(0x5AAB), 10_000_000e6);
        vm.startPrank(address(0x5AAB));
        usdc.approve(address(router), type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(usdt);
        uint256[] memory steps = new uint256[](1);
        steps[0] = 1;
        MockRouter.Version[] memory vers = new MockRouter.Version[](1);
        vm.expectRevert(MockLBPair.LBPair__OutOfLiquidity.selector);
        router.swapExactTokensForTokens(10_000_000e6, 0, MockRouter.Path(steps, vers, path), address(0x5AAB), block.timestamp + 1);
        vm.stopPrank();
    }

    function test_hookRevertBlocksMintBurnSwapIndependently() public {
        (int256[] memory d, uint256[] memory dX, uint256[] memory dY) = _three();
        _vaultLike(ALICE, 3000e6, 3000e6, d, dX, dY);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory am = new uint256[](1);
        ids[0] = ID0;
        am[0] = pair.balanceOf(ALICE, ID0) / 2;

        rewarder.setRevert(false, false, true); // burn hook down
        vm.prank(ALICE);
        vm.expectRevert(bytes("rewarder: burn hook down"));
        pair.burn(ALICE, ALICE, ids, am);
        _marketSwap(true, 10e6); // swap still fine

        rewarder.setRevert(true, false, false);
        vm.expectRevert(bytes("rewarder: swap hook down"));
        this.extSwap();

        rewarder.setRevertAll(false);
        rewarder.setWrongSelector(true);
        vm.prank(ALICE);
        vm.expectRevert(MockLBPair.LBPair__InvalidHooks.selector);
        pair.burn(ALICE, ALICE, ids, am);
        rewarder.setWrongSelector(false);
        vm.prank(ALICE);
        pair.burn(ALICE, ALICE, ids, am); // healthy again
    }

    function extSwap() external {
        _marketSwap(true, 10e6);
    }

    function test_unlinkRemovesHookAndRewarderReportsUnlinked() public {
        pair.setHook(address(0));
        assertFalse(rewarder.isLinked());
        vm.prank(ALICE);
        vm.expectRevert(bytes("unlinked"));
        rewarder.claim(ALICE, new uint256[](0));
        _marketSwap(true, 10e6); // no hook: swaps and burns are not blocked
    }

    function test_rewarderClaim() public {
        phar.mint(address(rewarder), 100e18);
        rewarder.setPending(ALICE, 7e18);
        uint256[] memory ids = new uint256[](0);
        assertEq(rewarder.getPendingRewards(ALICE, ids), 7e18);
        vm.prank(BOB);
        vm.expectRevert(bytes("caller"));
        rewarder.claim(ALICE, ids);
        vm.prank(ALICE);
        rewarder.claim(ALICE, ids);
        assertEq(phar.balanceOf(ALICE), 7e18);
    }

    function test_beaconImplementationCodehashesDiffer() public {
        assertTrue(address(implA).codehash != address(implB).codehash);
        assertEq(beacon.implementation(), address(implA));
        beacon.setImplementation(address(implB));
        assertEq(beacon.implementation(), address(implB));
    }

    function test_feedSwitches() public {
        (, int256 a,, uint256 u,) = feedUsdc.latestRoundData();
        assertEq(a, 1e8);
        assertEq(u, block.timestamp);
        feedUsdc.setRevertLatest(true);
        vm.expectRevert(bytes("feed: down"));
        feedUsdc.latestRoundData();
        assertEq(feedUsdc.decimals(), 8);
        feedUsdc.setRevertAll(true);
        vm.expectRevert(bytes("feed: dead"));
        feedUsdc.decimals();
        (bool ok,) = address(feedUsdc).call(abi.encodeWithSignature("anything()"));
        assertFalse(ok);
    }

    function test_feedIncompleteRound() public {
        feedUsdc.setIncompleteRound();
        (uint80 r,,,, uint80 ar) = feedUsdc.latestRoundData();
        assertLt(ar, r);
    }
}

/// @notice The same self-tests with USDC as token X (the reverse token order).
contract MocksSelfFlippedTest is MocksSelfTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}
