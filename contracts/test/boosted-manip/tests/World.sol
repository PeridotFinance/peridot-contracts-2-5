// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockDlmmFactory, MockDlmmVoter, MockRewarderBeacon, MockRewarderImplA, MockRewarderImplB} from "./mocks/MockDlmmInfra.sol";
import {MockLBPair} from "./mocks/MockLBPair.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockRewarder} from "./mocks/MockRewarder.sol";

/// @notice The mocked Pharaoh DLMM world (tokens, feeds, factory, voter, beacon, pair, router, rewarder, a whale LP) WITHOUT the vault. Token order follows the real chain
///         (USDt 0x9702.. < USDC 0xB97E..: X = USDt, Y = USDC); `_flipped()` reverses it so the same suite exercises both orderings.
abstract contract World is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint24 internal constant ID0 = 1 << 23;
    uint16 internal constant BIN_STEP = 1;

    address internal constant USDC_REAL = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant USDT_REAL = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address internal constant USDC_FLIP = 0x0000000000000000000000000000000000C0FFEE;

    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant KEEPER = address(0x4B33FE2);
    address internal constant ALICE = address(0xA11CE0);
    address internal constant BOB = address(0xB0B000);
    address internal constant CAROL = address(0xCA201);
    address internal constant WHALE = address(0xD00D);
    address internal constant ATTACKER = address(0xBAD);

    MockERC20 internal usdc;
    MockERC20 internal usdt;
    MockERC20 internal phar;
    MockChainlinkFeed internal feedUsdc;
    MockChainlinkFeed internal feedUsdt;
    MockDlmmFactory internal factory;
    MockDlmmVoter internal voter;
    MockRewarderBeacon internal beacon;
    MockRewarderImplA internal implA;
    MockRewarderImplB internal implB;
    MockLBPair internal pair;
    MockRouter internal router;
    MockRewarder internal rewarder;

    bool internal usdcIsX; // true only when flipped

    function _flipped() internal view virtual returns (bool) {
        return false;
    }

    function _deployWorld() internal {
        vm.warp(T0);
        usdcIsX = _flipped();
        address usdcA = usdcIsX ? USDC_FLIP : USDC_REAL;
        address usdtA = USDT_REAL;
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("USD Coin", "USDC", uint8(6)), usdcA);
        deployCodeTo("MockERC20.sol:MockERC20", abi.encode("Tether USD", "USDt", uint8(6)), usdtA);
        usdc = MockERC20(usdcA);
        usdt = MockERC20(usdtA);
        phar = new MockERC20("Pharaoh", "PHAR", 18);
        feedUsdc = new MockChainlinkFeed(1e8);
        feedUsdt = new MockChainlinkFeed(1e8);

        factory = new MockDlmmFactory();
        voter = new MockDlmmVoter();
        implA = new MockRewarderImplA();
        implB = new MockRewarderImplB();
        beacon = new MockRewarderBeacon(address(implA));
        voter.setBeacon(address(beacon));

        (address x, address y) = address(usdc) < address(usdt) ? (address(usdc), address(usdt)) : (address(usdt), address(usdc));
        pair = new MockLBPair(x, y, BIN_STEP, ID0, address(factory));
        factory.setPair(x, y, BIN_STEP, address(pair));
        router = new MockRouter(address(factory));
        voter.setManager(address(router), true);
        rewarder = new MockRewarder(address(pair), address(phar), address(voter));
        beacon.setRewarder(address(pair), address(rewarder));
        pair.setHook(address(rewarder));

        // a whale LP: 11 bins ID0-5..ID0+5, USD 1.2m each side, so the vault is a small LP like on chain
        _lpWhale(600_000e6, 600_000e6);
    }

    // ------------------------------------------------------------------ helpers
    function _xIs(address t) internal view returns (bool) {
        return pair.tokenX() == t;
    }

    function _mintTokens(address to, uint256 usdcAmt, uint256 usdtAmt) internal {
        if (usdcAmt != 0) usdc.mint(to, usdcAmt);
        if (usdtAmt != 0) usdt.mint(to, usdtAmt);
    }

    /// whale liquidity through the router on 11 bins; the active bin gets both tokens
    function _lpWhale(uint256 usdcAmt, uint256 usdtAmt) internal {
        _mintTokens(WHALE, usdcAmt, usdtAmt);
        int256[] memory d = new int256[](11);
        uint256[] memory dX = new uint256[](11);
        uint256[] memory dY = new uint256[](11);
        for (uint256 i; i < 11; ++i) {
            d[i] = int256(i) - 5;
            // Y (the quote token) on ids <= active, X on ids >= active (6 bins each)
            if (d[i] <= 0) dY[i] = uint256(1e18) / 6;
            if (d[i] >= 0) dX[i] = uint256(1e18) / 6;
        }
        (uint256 aX, uint256 aY) = _split(usdcAmt, usdtAmt);
        vm.startPrank(WHALE);
        usdc.approve(address(router), type(uint256).max);
        usdt.approve(address(router), type(uint256).max);
        router.addLiquidity(
            MockRouter.LiquidityParameters(
                pair.tokenX(), pair.tokenY(), BIN_STEP, aX, aY, 0, 0, pair.getActiveId(), 0, d, dX, dY, WHALE, WHALE, block.timestamp + 1
            )
        );
        vm.stopPrank();
    }

    /// (usdc, usdt) -> (amountX, amountY) by the pair's token order
    function _split(uint256 usdcAmt, uint256 usdtAmt) internal view returns (uint256 aX, uint256 aY) {
        return _xIs(address(usdc)) ? (usdcAmt, usdtAmt) : (usdtAmt, usdcAmt);
    }

    function _bin(uint24 id) internal view returns (uint256 usdcIn, uint256 usdtIn) {
        (uint128 bx, uint128 by) = pair.getBin(id);
        return _xIs(address(usdc)) ? (uint256(bx), uint256(by)) : (uint256(by), uint256(bx));
    }

    /// a third-party swap through the router that moves the active bin: sells `amountIn` of `tokenIn` (usdc or usdt) into the pool
    function _marketSwap(bool sellUsdc, uint256 amountIn) internal returns (uint256 out) {
        address who = address(0x5AAB);
        MockERC20 tin = sellUsdc ? usdc : usdt;
        MockERC20 tout = sellUsdc ? usdt : usdc;
        tin.mint(who, amountIn);
        vm.startPrank(who);
        tin.approve(address(router), amountIn);
        address[] memory path = new address[](2);
        path[0] = address(tin);
        path[1] = address(tout);
        uint256[] memory steps = new uint256[](1);
        steps[0] = BIN_STEP;
        MockRouter.Version[] memory vers = new MockRouter.Version[](1);
        vers[0] = MockRouter.Version.V2_1;
        out = router.swapExactTokensForTokens(amountIn, 0, MockRouter.Path(steps, vers, path), who, block.timestamp + 1);
        vm.stopPrank();
    }

    function _setFeeds(int256 usdcAnswer, int256 usdtAnswer) internal {
        feedUsdc.setAnswer(usdcAnswer);
        feedUsdt.setAnswer(usdtAnswer);
    }

    function _refreshFeeds() internal {
        feedUsdc.setUpdatedAt(block.timestamp);
        feedUsdt.setUpdatedAt(block.timestamp);
    }
}
