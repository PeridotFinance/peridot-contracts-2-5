// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {PharaohDlmmVault} from "../../src/PharaohDlmmVault.sol";
import {IPharaohDlmmVault} from "../../src/IPharaohDlmmVault.sol";
import {IDLMMPair} from "../../src/interfaces/IDLMMPair.sol";
import {IDLMMRouter} from "../../src/interfaces/IDLMMRouter.sol";
import {IDLMMRewarder, IDLMMVoter, IDLMMRewarderBeacon} from "../../src/interfaces/IDLMMRewarder.sol";
import {IChainlinkFeed} from "../../src/interfaces/IChainlinkFeed.sol";

/// @notice Shared base of the W6 mainnet-fork tests of PharaohDlmmVault against the REAL Pharaoh DLMM USDC/USDt pair, router, rewarder/hook and the
///         two real Chainlink feeds. Nothing here is signed or sent anywhere: the fork is local, funding is `deal`, roles are `vm.prank`.
///         Gate: the tests run only when `DLMM_FORK_BLOCK` is set (use `run-locked.sh`, which holds the shared fork lock); the RPC endpoint is the
///         foundry.toml alias `avalanche` = ${AVALANCHE_MAINNET_RPC_URL} (an environment reference; no URL is in this repository).
abstract contract DlmmForkBase is Test {
    address internal constant POOL = 0x16888EE58E706C253b821EAA637ae9b2cFeA255C;
    address internal constant ROUTER = 0xff2BEFC4ff86CB0f3e8D3d9D6200B7A05BF5D93d;
    address internal constant FACTORY = 0xEb480050b016f6c6d45203D2346B68bDDDa23D4D;
    address internal constant REWARDER = 0x32E68C4b8Edc6d1F16E99EbA826B292FDC18daDC;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address internal constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
    address internal constant FEED_USDC = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;
    address internal constant FEED_USDT = 0xEBE676ee90Fe1112671f19b6B7459bC678B67e8a;
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;

    address internal constant KEEPER = address(0xBEEF0001);
    address internal constant ALICE = address(0xA11CE0);
    address internal constant BOB = address(0xB0B000);
    address internal constant TRADER = address(0x7ADE0001);
    address internal constant PROXY_ADMIN_OWNER = address(0xAD0001);

    // guard bits
    uint256 internal constant B_FEED_A = 1;
    uint256 internal constant B_FEED_P = 2;
    uint256 internal constant B_LEG_A = 4;
    uint256 internal constant B_LEG_P = 8;
    uint256 internal constant B_POOL = 16;
    uint256 internal constant B_REWARDER = 32;

    PharaohDlmmVault internal v;
    PharaohDlmmVault internal impl;
    IDLMMPair internal pair = IDLMMPair(POOL);
    address internal voter;
    address internal beacon;
    int256 internal realAnsA;
    int256 internal realAnsP;
    uint24 internal pinActiveId;
    uint256 internal forkBlock;

    function setUp() public virtual {
        forkBlock = vm.envOr("DLMM_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("avalanche", forkBlock);
        require(block.chainid == 43114, "not Avalanche C-chain");
        voter = IDLMMRewarder(REWARDER).owner();
        beacon = IDLMMVoter(voter).dlmmRewarderFactory();
        (, realAnsA,,,) = IChainlinkFeed(FEED_USDC).latestRoundData();
        (, realAnsP,,,) = IChainlinkFeed(FEED_USDT).latestRoundData();
        pinActiveId = pair.getActiveId();
        impl = new PharaohDlmmVault();
        v = _deployProxy(_params());
    }

    // ------------------------------------------------------------------ deployment
    function _pinnedCodehash() internal view returns (bytes32) {
        return IDLMMRewarderBeacon(beacon).implementation().codehash;
    }

    function _params() internal view returns (IPharaohDlmmVault.InitParams memory p) {
        p = IPharaohDlmmVault.InitParams({
            asset: USDC,
            pairToken: USDT,
            pair: POOL,
            router: ROUTER,
            factory: FACTORY,
            rewarder: REWARDER,
            rewarderImplCodehash: _pinnedCodehash(),
            feedAsset: FEED_USDC,
            feedPair: FEED_USDT,
            binStep: 1,
            owner: SAFE,
            rebalancer: KEEPER,
            depositCap: 200_000_000,
            name: "Peridot Pharaoh DLMM USDC/USDt",
            symbol: "pdUSDC"
        });
    }

    function _deployProxy(IPharaohDlmmVault.InitParams memory p) internal returns (PharaohDlmmVault) {
        TransparentUpgradeableProxy proxy =
            new TransparentUpgradeableProxy(address(impl), PROXY_ADMIN_OWNER, abi.encodeCall(PharaohDlmmVault.initialize, (p)));
        return PharaohDlmmVault(address(proxy));
    }

    // ------------------------------------------------------------------ roles and funding
    function _unpause() internal {
        vm.prank(SAFE);
        v.unpause();
    }

    function _fund(address who, address token, uint256 amount) internal {
        deal(token, who, amount);
        assertEq(IERC20(token).balanceOf(who), amount, "deal failed");
    }

    function _deposit(address who, uint256 assets) internal returns (uint256 shares) {
        _fund(who, USDC, IERC20(USDC).balanceOf(who) + assets);
        vm.startPrank(who);
        IERC20(USDC).approve(address(v), type(uint256).max);
        shares = v.deposit(assets, who);
        vm.stopPrank();
    }

    function _openBand() internal {
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        v.openBand(a, 0, 0, 0, 0, block.timestamp + 600);
    }

    /// unpause, ALICE deposits `assets`, keeper opens the band at the live active id
    function _live(uint256 assets) internal returns (uint256 shares) {
        _unpause();
        shares = _deposit(ALICE, assets);
        _openBand();
    }

    // ------------------------------------------------------------------ pool movers (a deal-funded test account trades through the real router)
    function _swap(address tin, address tout, uint256 amountIn) internal returns (uint256 out) {
        _fund(TRADER, tin, IERC20(tin).balanceOf(TRADER) + amountIn);
        uint256[] memory steps = new uint256[](1);
        steps[0] = 1;
        IDLMMRouter.Version[] memory vs = new IDLMMRouter.Version[](1);
        vs[0] = IDLMMRouter.Version.V2_1;
        address[] memory path = new address[](2);
        path[0] = tin;
        path[1] = tout;
        vm.startPrank(TRADER);
        IERC20(tin).approve(ROUTER, amountIn);
        out = IDLMMRouter(ROUTER).swapExactTokensForTokens(
            amountIn, 0, IDLMMRouter.Path({pairBinSteps: steps, versions: vs, tokenPath: path}), TRADER, block.timestamp + 600
        );
        vm.stopPrank();
    }

    /// buys USDt with USDC until the active id is >= target (price of USDt up, the vault ends holding USDC only when target > its upper id)
    function _pushUp(uint24 target) internal {
        for (uint256 i; i < 400 && pair.getActiveId() < target; ++i) _swap(USDC, USDT, 5_000e6);
        require(pair.getActiveId() >= target, "pushUp failed");
    }

    /// sells USDt for USDC until the active id is <= target (the vault ends holding USDt only when target < its lower id)
    function _pushDown(uint24 target) internal {
        for (uint256 i; i < 400 && pair.getActiveId() > target; ++i) _swap(USDT, USDC, 5_000e6);
        require(pair.getActiveId() <= target, "pushDown failed");
    }

    // ------------------------------------------------------------------ feed mocks (vm.mockCall on latestRoundData: the feeds' storage is never touched)
    function _mockFeed(address feed, int256 answer, uint256 updatedAt) internal {
        vm.mockCall(
            feed,
            abi.encodeCall(IChainlinkFeed.latestRoundData, ()),
            abi.encode(uint80(1000), answer, updatedAt, updatedAt, uint80(1000))
        );
    }

    function _mockFeedFull(address feed, uint80 roundId, int256 answer, uint256 updatedAt, uint80 answeredIn) internal {
        vm.mockCall(
            feed, abi.encodeCall(IChainlinkFeed.latestRoundData, ()), abi.encode(roundId, answer, updatedAt, updatedAt, answeredIn)
        );
    }

    function _mockFeedReverts(address feed) internal {
        vm.mockCallRevert(feed, abi.encodeCall(IChainlinkFeed.latestRoundData, ()), "feed down");
    }

    /// both feeds at their live answers, fresh as of now (re-call after every warp: warping ages the real feeds)
    function _freshFeeds() internal {
        _mockFeed(FEED_USDC, realAnsA, block.timestamp);
        _mockFeed(FEED_USDT, realAnsP, block.timestamp);
    }

    function _guard() internal view returns (bool unsafe, bool latched, uint256 reasons) {
        return v.guardState();
    }

    function _reasons() internal view returns (uint256 r) {
        (,, r) = v.guardState();
    }

    function _nav() internal view returns (uint256) {
        return v.totalAssets();
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return IERC20(token).balanceOf(who);
    }

    // ------------------------------------------------------------------ low-level helpers
    /// pranked low-level call: (ok, returndata) without reverting the test
    function _try(address from, address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(from);
        (ok, ret) = target.call(data);
    }

    function _sel(bytes memory ret) internal pure returns (bytes4 s) {
        if (ret.length >= 4) {
            assembly ("memory-safe") {
                s := mload(add(ret, 32))
            }
        }
    }

    function _arg0(bytes memory ret) internal pure returns (uint256 a) {
        if (ret.length >= 36) {
            assembly ("memory-safe") {
                a := mload(add(ret, 36))
            }
        }
    }

    function _ppm(uint256 before_, uint256 after_) internal pure returns (int256) {
        return (int256(before_) - int256(after_)) * 1e6 / int256(before_);
    }

    function _approveBob(uint256 funds) internal {
        _fund(BOB, USDC, funds);
        vm.prank(BOB);
        IERC20(USDC).approve(address(v), type(uint256).max);
    }

    // ------------------------------------------------------------------ rebalance helpers
    function _rebalance(bool xForY, uint256 swapIn) internal {
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        v.rebalance(a, 0, xForY, swapIn, 0, 0, 0, block.timestamp + 600);
    }

    /// re-centre after the active id left the band: the vault then holds ONE token, so swap half of NAV into the other
    function _rebalanceAuto() internal {
        (uint24 lo, uint24 hi, uint24 a,,) = v.bandState();
        uint256 half = v.totalAssets() / 2;
        require(a > hi || a < lo, "in range");
        _rebalance(a < lo, half); // below the band the vault holds X (USDt): sell X for Y
    }

    /// decodes the Rebalanced event: (swapIn, swapOut, navBefore, navAfter)
    function _rebalancedEvent(Vm.Log[] memory logs) internal pure returns (bool found, uint256 swapIn, uint256 swapOut, uint256 navBefore, uint256 navAfter) {
        bytes32 t0 = keccak256("Rebalanced(uint24,uint24,uint24,uint24,uint24,bool,uint256,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == t0) {
                (,,,,,, swapIn, swapOut, navBefore, navAfter) =
                    abi.decode(logs[i].data, (uint24, uint24, uint24, uint24, uint24, bool, uint256, uint256, uint256, uint256));
                return (true, swapIn, swapOut, navBefore, navAfter);
            }
        }
    }

    // ------------------------------------------------------------------ extra pool depth (a deal-funded LP adds single-sided liquidity so that deep moves are possible)
    /// below = true: USDC in bins active-to .. active-from (from <= to); below = false: USDt in bins active+from .. active+to
    function _seedDepth(bool below, uint256 fromDelta, uint256 toDelta, uint256 amount) internal {
        address lp = address(0x11DEAD);
        address tok = below ? USDC : USDT;
        _fund(lp, tok, amount);
        uint256 n = toDelta - fromDelta + 1;
        int256[] memory deltas = new int256[](n);
        uint256[] memory dist = new uint256[](n);
        uint256[] memory zero = new uint256[](n);
        uint256 acc;
        for (uint256 i; i < n; ++i) {
            uint256 d = fromDelta + i;
            deltas[i] = below ? -int256(d) : int256(d);
            dist[i] = 1e18 / n;
            acc += dist[i];
        }
        dist[n - 1] += 1e18 - acc;
        IDLMMRouter.LiquidityParameters memory lpp = IDLMMRouter.LiquidityParameters({
            tokenX: USDT,
            tokenY: USDC,
            binStep: 1,
            amountX: below ? 0 : amount,
            amountY: below ? amount : 0,
            amountXMin: 0,
            amountYMin: 0,
            activeIdDesired: pair.getActiveId(),
            idSlippage: 0,
            deltaIds: deltas,
            distributionX: below ? zero : dist,
            distributionY: below ? dist : zero,
            to: lp,
            refundTo: lp,
            deadline: block.timestamp + 600
        });
        vm.startPrank(lp);
        IERC20(tok).approve(ROUTER, amount);
        IDLMMRouter(ROUTER).addLiquidity(lpp);
        vm.stopPrank();
    }

    /// seeds depth and pushes the active id to `target` (a bigger swap chunk than _pushUp/_pushDown)
    function _pushUpBig(uint24 target, uint256 chunk) internal {
        for (uint256 i; i < 300 && pair.getActiveId() < target; ++i) _swap(USDC, USDT, chunk);
        require(pair.getActiveId() >= target, "pushUpBig failed");
    }

    function _pushDownBig(uint24 target, uint256 chunk) internal {
        for (uint256 i; i < 300 && pair.getActiveId() > target; ++i) _swap(USDT, USDC, chunk);
        require(pair.getActiveId() <= target, "pushDownBig failed");
    }
}
