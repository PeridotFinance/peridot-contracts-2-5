// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console2} from "forge-std/Test.sol";

import {PharaohDlmmVault} from "../vault-src/PharaohDlmmVault.sol";
import {IPharaohDlmmVault} from "../vault-src/IPharaohDlmmVault.sol";
import {World} from "./World.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

import {PharaohVaultShareOracle} from "../../../contracts/PharaohVaultShareOracle.sol";
import {PriceOracle} from "../../../contracts/PriceOracle.sol";
import {PToken} from "../../../contracts/PToken.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC4626 as IERC4626OZ} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @dev stands in for the pToken of the bpPHAR-USDC market: the oracle only calls `underlying()` on it
contract MockPTokenShare {
    address public underlying;

    constructor(address u) {
        underlying = u;
    }
}

/// @dev the existing GuardedAvalanchePriceOracle stands in for pUSDC: it reads the SAME Chainlink USDC/USD feed live (no peg clamp, R: contracts/margin/GuardedAvalanchePriceOracle.sol),
///      so pUSDC is priced 10^(36-6) x answer / 1e8. The share oracle never calls it for the registered share market.
contract MockBaseOracle is PriceOracle {
    AggregatorV3Interface public immutable feed;

    constructor(AggregatorV3Interface f) {
        feed = f;
    }

    function getUnderlyingPrice(PToken) external view override returns (uint256) {
        (, int256 a,,,) = feed.latestRoundData();
        return uint256(a) * 1e22; // 1e8 -> 1e30
    }
}

/// @notice Shared fixture: the REAL PharaohDlmmVault (vendored byte for byte, see ../vault-src.sha256) behind a TransparentUpgradeableProxy on the mocked Pharaoh DLMM world
///         of the vault project (MockLBPair copies the verified pair source: bins, one-sided rule, balance-minus-reserve consumption by mint/swap, shares non-transferable through the hook,
///         fee stays in the bin). Live-like start: dead seed 1 share + operator 16 shares = USD 17, one band opened, deposit cap USD 200, CF/caps of the lending harness as on chain.
abstract contract ManipBase is World {
    // ---- live parameters (BRIEF.md, verified 18 Nov)
    uint256 internal constant CAP = 200_000_000;
    uint256 internal constant CF_BPS = 5000; // collateral factor once raised
    uint256 internal constant BORROW_CAP = 200_000_000; // pUSDC borrow cap, strict `<` in the controller
    uint256 internal constant CASH_FLOOR = 50_000_000;
    uint256 internal constant POOL_CASH = 274_000_000;
    uint256 internal constant LIQ_INCENTIVE_BPS = 10_800;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address internal constant LEDGER = address(0x1ED6E4);

    PharaohDlmmVault internal v;
    IERC20 internal sh;
    PharaohVaultShareOracle internal shareOracle;
    MockPTokenShare internal pShare;
    address internal proxyAddr;

    // ------------------------------------------------------------------ deployment
    function _initParams() internal view returns (IPharaohDlmmVault.InitParams memory p) {
        p = IPharaohDlmmVault.InitParams({
            asset: address(usdc),
            pairToken: address(usdt),
            pair: address(pair),
            router: address(router),
            factory: address(factory),
            rewarder: address(rewarder),
            rewarderImplCodehash: address(implA).codehash,
            feedAsset: address(feedUsdc),
            feedPair: address(feedUsdt),
            binStep: BIN_STEP,
            owner: SAFE,
            rebalancer: KEEPER,
            depositCap: CAP,
            name: "Peridot Pharaoh DLMM USDC/USDt",
            symbol: "pDLMM"
        });
    }

    /// extra USDC the operator deposits before the band opens (0 = the live USD 17 vault; 183e6 = a vault at its USD 200 cap)
    function _extraLedger() internal view virtual returns (uint256) {
        return 0;
    }

    function _setUpManip() internal {
        _deployWorld();
        PharaohDlmmVault impl = new PharaohDlmmVault();
        proxyAddr = address(
            new TransparentUpgradeableProxy(address(impl), SAFE, abi.encodeCall(PharaohDlmmVault.initialize, (_initParams())))
        );
        v = PharaohDlmmVault(proxyAddr);
        sh = IERC20(proxyAddr);
        vm.prank(SAFE);
        v.unpause();

        address[7] memory us = [ALICE, BOB, CAROL, ATTACKER, SAFE, LEDGER, DEAD];
        for (uint256 i; i < us.length; ++i) {
            vm.prank(us[i]);
            usdc.approve(proxyAddr, type(uint256).max);
        }
        // live-like start: dead seed 1 share, the operator 16 shares (USD 17 in total)
        usdc.mint(DEAD, 1e6);
        vm.prank(DEAD);
        IERC4626(proxyAddr).deposit(1e6, DEAD);
        usdc.mint(LEDGER, 16e6 + _extraLedger());
        vm.prank(LEDGER);
        IERC4626(proxyAddr).deposit(16e6 + _extraLedger(), LEDGER);
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        v.openBand(a, 1, 0, 0, 0, block.timestamp + 120);

        // the share-market oracle wrapper (REAL contract) in front of a base oracle
        shareOracle = new PharaohVaultShareOracle(SAFE, new MockBaseOracle(AggregatorV3Interface(address(feedUsdc))));
        pShare = new MockPTokenShare(proxyAddr);
        vm.prank(SAFE);
        shareOracle.registerVault(IERC4626OZ(proxyAddr), AggregatorV3Interface(address(feedUsdc)), 90_000);
    }

    // ------------------------------------------------------------------ views / valuation
    function _ta() internal view returns (uint256) {
        return v.totalAssets();
    }

    function _supply() internal view returns (uint256) {
        return sh.totalSupply();
    }

    /// oracle price of the share market as the controller reads it (1e18-scaled, 10^(36-6) per share-wei semantics)
    function _shareMantissa() internal view returns (uint256) {
        return shareOracle.getUnderlyingPrice(PToken(address(pShare)));
    }

    /// USD value (1e18) the controller assigns to `shares` (exchange rate of the pToken abstracted to 1: see the doc)
    function _oracleValueUsd18(uint256 shares) internal view returns (uint256) {
        return shares * _shareMantissa() / 1e18;
    }

    /// USD per USDC (1e18) as pUSDC is priced by the base oracle: the live USDC/USD feed answer
    function _usdcUsd18() internal view returns (uint256) {
        (, int256 a,,,) = feedUsdc.latestRoundData();
        return uint256(a) * 1e10;
    }

    /// max USDC (6 dec) borrowable against `shares` at CF: value in USD (the wrapper) / the USDC price the controller uses for pUSDC. The wrapper's x USDC/USD cancels against pUSDC's own price,
    /// so this is CF x convertToAssets(shares) x (1 + feed effects on the USDt leg); mirrors Peridottroller.getHypotheticalAccountLiquidityInternal
    function _borrowPower(uint256 shares) internal view returns (uint256) {
        return _oracleValueUsd18(shares) * CF_BPS / 10_000 * 1e6 / _usdcUsd18();
    }

    /// what the pro-rata in-kind exit of `shares` pays, valued at the feeds; reverts the state (snapshot) so it is a pure probe
    function _inKindProbe(address holder, uint256 shares) internal returns (uint256 usdcOut, uint256 usdtOut) {
        uint256 snap = vm.snapshotState();
        vm.prank(holder);
        // dust shares revert ExitFailed (both legs round to zero): they pay 0, which is what the probe reports
        try v.redeemInKind(shares, holder, holder) returns (uint256 ax, uint256 ay) {
            (usdcOut, usdtOut) = usdcIsX ? (ax, ay) : (ay, ax);
        } catch {}
        vm.revertToState(snap);
    }

    /// value in USDC-6 of a basket at the FEEDS
    function _atFeeds(uint256 usdcAmt, uint256 usdtAmt) internal view returns (uint256) {
        (, int256 pc,,,) = feedUsdc.latestRoundData();
        (, int256 pt,,,) = feedUsdt.latestRoundData();
        return usdcAmt + usdtAmt * uint256(pt) / uint256(pc);
    }

    /// value in USDC-6 of a basket when USDt really trades at `usdtMarketBps` of USDC (10_000 = par), USDC at 1
    function _atMarket(uint256 usdcAmt, uint256 usdtAmt, uint256 usdtMarketBps) internal pure returns (uint256) {
        return usdcAmt + usdtAmt * usdtMarketBps / 10_000;
    }

    // ------------------------------------------------------------------ users
    function _fund(address u, uint256 amt) internal {
        usdc.mint(u, amt);
        vm.prank(u);
        usdc.approve(proxyAddr, type(uint256).max);
    }

    function _dep(address u, uint256 assets) internal returns (uint256 s) {
        _fund(u, assets);
        vm.prank(u);
        s = IERC4626(proxyAddr).deposit(assets, u);
    }

    // ------------------------------------------------------------------ keeper
    function _rebalanceCall() internal view returns (bytes memory) {
        (uint256 c, uint256 t) = _holdingsAtPair();
        bool overUsdc = c >= t;
        uint256 bulk = overUsdc ? c : t;
        bool swapXForY = overUsdc ? usdcIsX : !usdcIsX;
        uint256 swapIn = bulk / 2;
        uint256 minOut = (swapIn * 9_900) / 10_000;
        return abi.encodeCall(IPharaohDlmmVault.rebalance, (pair.getActiveId(), 1, swapXForY, swapIn, minOut, 0, 0, block.timestamp + 120));
    }

    function _rebalance() internal {
        bytes memory cd = _rebalanceCall();
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = proxyAddr.call(cd);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// independent arithmetic of the vault's holdings (idle + pro-rata bins over a window around the active id)
    function _holdingsAtPair() internal view returns (uint256 usdcAmt, uint256 usdtAmt) {
        usdcAmt = usdc.balanceOf(proxyAddr);
        usdtAmt = usdt.balanceOf(proxyAddr);
        uint24 act = pair.getActiveId();
        for (uint24 id = act - 40; id <= act + 40; ++id) {
            uint256 s = pair.balanceOf(proxyAddr, id);
            if (s == 0) continue;
            uint256 sup = pair.totalSupply(id);
            (uint128 bx, uint128 by) = pair.getBin(id);
            uint256 ox = (s * bx) / sup;
            uint256 oy = (s * by) / sup;
            if (usdcIsX) {
                usdcAmt += ox;
                usdtAmt += oy;
            } else {
                usdtAmt += ox;
                usdcAmt += oy;
            }
        }
    }

    function _bandOut() internal view returns (bool) {
        (,,,, bool oor) = v.bandState();
        return oor;
    }

    function _warpFresh(uint256 dt) internal {
        vm.warp(block.timestamp + dt);
        _refreshFeeds();
    }

    function _bp(uint256 num, uint256 den) internal pure returns (uint256) {
        return den == 0 ? 0 : num * 10_000 / den;
    }

    function _swapAs(address who, bool sellUsdc, uint256 amountIn) internal returns (uint256 out) {
        MockERC20 tin = sellUsdc ? usdc : usdt;
        MockERC20 tout = sellUsdc ? usdt : usdc;
        if (tin.balanceOf(who) < amountIn) tin.mint(who, amountIn - tin.balanceOf(who));
        uint256 b0 = tout.balanceOf(who);
        vm.startPrank(who);
        tin.approve(address(router), amountIn);
        address[] memory path = new address[](2);
        path[0] = address(tin);
        path[1] = address(tout);
        uint256[] memory steps = new uint256[](1);
        steps[0] = BIN_STEP;
        MockRouter.Version[] memory vers = new MockRouter.Version[](1);
        vers[0] = MockRouter.Version.V2_1;
        router.swapExactTokensForTokens(amountIn, 0, MockRouter.Path(steps, vers, path), who, block.timestamp + 1);
        vm.stopPrank();
        out = tout.balanceOf(who) - b0;
    }

    function _pushOut(bool up) internal {
        (uint24 lo, uint24 hi,,,) = v.bandState();
        bool sellUsdc = up ? !usdcIsX : usdcIsX;
        uint256 guard;
        while (guard++ < 40) {
            uint24 a = pair.getActiveId();
            if (a > hi || a < lo) return;
            _swapAs(address(0x5AAB), sellUsdc, 60_000e6);
        }
        revert("pushOut: band not left");
    }

    function _flipped() internal view virtual override returns (bool) {
        return false;
    }
}
