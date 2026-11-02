// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../../contracts/pancakev3/libraries/TickMath.sol";

/// @dev Minimal interfaces for the two LIVE Pharaoh ERC-4626 vaults (PharaohLiquidityVault behind
///      PharaohRewardExtension behind a TransparentUpgradeableProxy). Verified source: see the Track A doc.
interface ITAVault {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function owner() external view returns (address);
    function rebalancer() external view returns (address);
    function paused() external view returns (bool);
    function depositCap() external view returns (uint256);
    function pool() external view returns (address);
    function positionManager() external view returns (address);
    function priceOracle() external view returns (address);
    function pairedToken() external view returns (address);
    function assetIsToken0() external view returns (bool);
    function tokenId() external view returns (uint256);
    function positionTickLower() external view returns (int24);
    function positionTickUpper() external view returns (int24);
    function tickRange() external view returns (int24);
    function twapPeriod() external view returns (uint32);
    function maxTwapDeviationTicks() external view returns (uint24);
    function maxOracleDeviationBps() external view returns (uint16);
    function slippageBps() external view returns (uint16);
    function valuationHaircutBps() external view returns (uint16);
    function maxDeposit(address) external view returns (uint256);
    function maxMint(address) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
    function previewDeposit(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function deposit(uint256, address) external returns (uint256);
    function withdraw(uint256, address, address) external returns (uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function redeemInKind(uint256, address, address) external returns (uint256, uint256);
    function deployIdle() external;
    function rebalance() external;
    function emergencyExit() external;
    function pause() external;
    function unpause() external;
    function setDepositCap(uint256) external;
    function setRebalancer(address) external;
    function harvestRewards(bool, uint256) external returns (uint256, uint256);
}

interface ITAPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

interface ITAPositionManager {
    function positions(uint256)
        external
        view
        returns (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
    function ownerOf(uint256) external view returns (address);
}

interface ITAGauge {
    function earned(address token, uint256 tokenId) external view returns (uint256);
}

interface ITAVoter {
    function gaugeForPool(address) external view returns (address);
}

interface ITARouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

interface ITAFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface ITAOwnable {
    function owner() external view returns (address);
}

interface ITASafe {
    function getOwners() external view returns (address[] memory);
    function getThreshold() external view returns (uint256);
}

interface ITAOracle {
    function asset() external view returns (address);
    function pairedToken() external view returns (address);
    function quotePairToAsset(uint256) external view returns (uint256);
    function quoteAssetToPair(uint256) external view returns (uint256);
}

/// @dev Drop-in replacement for the vault's price oracle (installed with vm.etch, LOCAL VM ONLY). Used to keep the
///      oracle fresh across vm.warp, or to make the oracle FOLLOW a real pool move (a genuine depeg / rate move).
contract TAMockOracle {
    address public immutable asset;
    address public immutable pairedToken;
    uint256 public immutable aUnit;
    uint256 public immutable pUnit;
    uint256 public ratio; // asset per ONE paired token, 1e18 scaled

    constructor(address a, address p, uint256 aU, uint256 pU) {
        asset = a;
        pairedToken = p;
        aUnit = aU;
        pUnit = pU;
    }

    function setRatio(uint256 r) external {
        ratio = r;
    }

    function quotePairToAsset(uint256 pairAmount) external view returns (uint256) {
        return Math.mulDiv(pairAmount, ratio * aUnit, 1e18 * pUnit);
    }

    function quoteAssetToPair(uint256 assetAmount) external view returns (uint256) {
        return Math.mulDiv(assetAmount, 1e18 * pUnit, ratio * aUnit);
    }
}

/// @notice Shared fixture for the Track A launch-gate fork suites. One concrete suite per vault.
abstract contract TrackAVaultsBase is Test {
    // ------------------------------------------------------------------ pin (one block per suite)
    uint256 internal constant PIN_BLOCK = 99208619;
    // block hash recorded by `cast block 99212200 -f hash` at pin time (documented; also checked by the suite)
    bytes32 internal constant PIN_HASH = 0xd42b05fafc04d45616e7c10d0b256a675f25e78e811fdaf6624dabe5e6b52549;

    // ------------------------------------------------------------------ labelled addresses (verified in test_00)
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant REBALANCER = 0x94696d767e65a75581145646960FA0eC886cE5d2;
    address internal constant USDC_VAULT = 0x855bF832f26a294d28500db59eE941dE3d654129;
    address internal constant WAVAX_VAULT = 0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8;
    address internal constant ROUTER = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    address internal constant FACTORY = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d;
    address internal constant VOTER = 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7;
    address internal constant POSITION_MANAGER = 0x0B4478e810D48B5882D4019D435A2f864Bab4F39;
    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant USDT = 0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address internal constant SAVAX = 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE;
    address internal constant PHAR = 0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7;
    address internal constant XPHAR = 0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A;
    address internal constant AVAX_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant BASE_IMPL = 0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770;
    address internal constant EXT_IMPL = 0x165E1f072e7bEeDf94f14F732838354cA20bA45d;
    bytes32 internal constant BASE_CODEHASH = 0x416f2a818693b20948fc44e9955ec7a370be051599b1eef6ca1fad932f3626ef;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA201);
    address internal constant WHALE = address(0xDEAD0001);

    // ------------------------------------------------------------------ per-suite configuration
    ITAVault internal v;
    IERC20 internal asset;
    IERC20 internal paired;
    ITAPool internal pool;
    address internal gauge;
    address internal oracleAddr;
    uint256 internal aUnit;
    uint256 internal pUnit;
    int24 internal tSpacing;
    bool internal live;

    function _vaultAddress() internal pure virtual returns (address);
    function _label() internal pure virtual returns (string memory);
    function _isUsd() internal pure virtual returns (bool);

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // The public node serves cold state only for roughly the last 128 blocks, so each run pins a block taken just
        // before it starts (env TRACKA_PIN_BLOCK); the constant is the pin of the documented reference run.
        vm.createSelectFork(rpc, vm.envOr("TRACKA_PIN_BLOCK", PIN_BLOCK));
        require(block.chainid == 43_114, "not Avalanche C-Chain");
        v = ITAVault(_vaultAddress());
        asset = IERC20(v.asset());
        paired = IERC20(v.pairedToken());
        pool = ITAPool(v.pool());
        gauge = ITAVoter(VOTER).gaugeForPool(address(pool));
        oracleAddr = v.priceOracle();
        aUnit = 10 ** _dec(address(asset));
        pUnit = 10 ** _dec(address(paired));
        tSpacing = 1;
        live = true;
    }

    function _dec(address t) internal view returns (uint256) {
        (bool ok, bytes memory r) = t.staticcall(abi.encodeWithSignature("decimals()"));
        require(ok, "decimals");
        return abi.decode(r, (uint8));
    }

    // ------------------------------------------------------------------ sizing
    function _avaxUsd8() internal view returns (uint256) {
        (, int256 a,,,) = ITAFeed(AVAX_FEED).latestRoundData();
        return uint256(a);
    }

    /// @dev USD (whole dollars) -> asset units. USDC is taken at USD 1; WAVAX at the Chainlink AVAX/USD answer at the pin.
    function _usdToAsset(uint256 usd) internal view returns (uint256) {
        if (_isUsd()) return usd * aUnit;
        return Math.mulDiv(usd * 1e8, aUnit, _avaxUsd8());
    }

    function _assetToUsdE2(uint256 amt) internal view returns (uint256) {
        if (_isUsd()) return amt * 100 / aUnit;
        return Math.mulDiv(amt, _avaxUsd8() * 100, aUnit * 1e8);
    }

    // ------------------------------------------------------------------ funding / swaps
    function _fund(address token, address to, uint256 amt) internal {
        if (token == SAVAX) {
            // sAVAX is a BENQI staking token: try storage deal first, then mint through submit() with native AVAX.
            (bool ok,) = address(vm).call(abi.encodeWithSignature("deal(address,address,uint256)", token, to, amt));
            if (ok && IERC20(token).balanceOf(to) >= amt) return;
            uint256 need = amt * 2;
            vm.deal(to, need);
            vm.prank(to);
            (bool ok2,) = token.call{value: need}(abi.encodeWithSignature("submit()"));
            require(ok2 && IERC20(token).balanceOf(to) >= amt, "fund sAVAX");
            return;
        }
        deal(token, to, amt);
    }

    function _swapAs(address who, address tin, address tout, uint256 amtIn, uint160 limit) internal returns (uint256 out) {
        if (IERC20(tin).balanceOf(who) < amtIn) _fund(tin, who, amtIn);
        vm.startPrank(who);
        IERC20(tin).approve(ROUTER, amtIn);
        out = ITARouter(ROUTER).exactInputSingle(
            ITARouter.ExactInputSingleParams(tin, tout, tSpacing, who, block.timestamp + 1, amtIn, 0, limit)
        );
        vm.stopPrank();
    }

    function _spotTick() internal view returns (int24 t) {
        (, t,,,,,) = pool.slot0();
    }

    /// @dev Move the REAL pool to `target` by one real swap through the real router, price-limited at the target.
    function _moveToTick(int24 target) internal returns (uint256 tokenInUsed) {
        int24 t = _spotTick();
        if (target == t) return 0;
        bool zeroForOne = target < t;
        address t0 = pool.token0();
        address t1 = pool.token1();
        address tin = zeroForOne ? t0 : t1;
        address tout = zeroForOne ? t1 : t0;
        uint256 big = 2_000_000_000 * (10 ** _dec(tin)); // ample, the limit stops the swap
        if (IERC20(tin).balanceOf(WHALE) < big) _fund(tin, WHALE, big);
        uint256 before = IERC20(tin).balanceOf(WHALE);
        _swapAs(WHALE, tin, tout, big, TickMath.getSqrtRatioAtTick(target));
        tokenInUsed = before - IERC20(tin).balanceOf(WHALE);
    }

    /// @dev Ping-pong swaps of `legAsset` size to generate swap fees for in-range LPs without moving the price.
    function _generateFees(uint256 rounds, uint256 legAsset) internal returns (uint256 volumeAsset) {
        for (uint256 i; i < rounds; ++i) {
            uint256 got = _swapAs(WHALE, address(asset), address(paired), legAsset, 0);
            _swapAs(WHALE, address(paired), address(asset), got, 0);
            volumeAsset += legAsset * 2;
        }
    }

    // ------------------------------------------------------------------ vault helpers
    function _openCap(uint256 usdCap) internal {
        uint256 cap = _usdToAsset(usdCap);
        vm.prank(SAFE); // LOCAL VM ONLY: forge cheatcode impersonation of the owner Safe, never a real transaction
        v.setDepositCap(cap);
    }

    function _try(address who, address target, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = target.call(data);
    }

    function _depositAs(address who, uint256 amt) internal returns (bool ok, uint256 shares, bytes memory err) {
        if (asset.balanceOf(who) < amt) _fund(address(asset), who, amt);
        vm.prank(who);
        asset.approve(address(v), amt);
        bytes memory ret;
        (ok, ret) = _try(who, address(v), abi.encodeCall(ITAVault.deposit, (amt, who)));
        if (ok) shares = abi.decode(ret, (uint256));
        else err = ret;
    }

    function _redeemAs(address who, uint256 shares) internal returns (bool ok, uint256 gotAsset, bytes memory err) {
        uint256 b = asset.balanceOf(who);
        bytes memory ret;
        (ok, ret) = _try(who, address(v), abi.encodeCall(ITAVault.redeem, (shares, who, who)));
        if (ok) gotAsset = asset.balanceOf(who) - b;
        else err = ret;
    }

    function _redeemKindAs(address who, uint256 shares)
        internal
        returns (bool ok, uint256 gotAsset, uint256 gotPaired, bytes memory err)
    {
        bytes memory ret;
        (ok, ret) = _try(who, address(v), abi.encodeCall(ITAVault.redeemInKind, (shares, who, who)));
        if (ok) (gotAsset, gotPaired) = abi.decode(ret, (uint256, uint256));
        else err = ret;
    }

    function _pps() internal view returns (uint256) {
        return Math.mulDiv(v.totalAssets(), 1e18, v.totalSupply());
    }

    function _viewTotalAssets() internal view returns (bool ok, uint256 val) {
        try v.totalAssets() returns (uint256 x) {
            return (true, x);
        } catch {
            return (false, 0);
        }
    }

    function _pairedInAsset(uint256 pairedAmt) internal view returns (uint256) {
        return ITAOracle(oracleAddr).quotePairToAsset(pairedAmt);
    }

    function _bps(uint256 num, uint256 den) internal pure returns (uint256) {
        return den == 0 ? 0 : Math.mulDiv(num, 10_000, den);
    }

    function _lossBps(uint256 invested, uint256 got) internal pure returns (int256) {
        if (invested == 0) return 0;
        return (int256(invested) - int256(got)) * 10_000 / int256(invested);
    }

    /// @dev Replace the vault's oracle with a mock holding the CURRENT oracle ratio (keeps it fresh across vm.warp).
    function _etchFreshOracle() internal returns (uint256 ratio) {
        ratio = Math.mulDiv(ITAOracle(oracleAddr).quotePairToAsset(pUnit), 1e18, aUnit);
        _etchOracleWithRatio(ratio);
    }

    function _etchOracleWithRatio(uint256 ratio) internal {
        TAMockOracle m = new TAMockOracle(address(asset), address(paired), aUnit, pUnit);
        vm.etch(oracleAddr, address(m).code);
        TAMockOracle(oracleAddr).setRatio(ratio);
    }

    /// @dev asset-per-paired ratio (1e18) implied by the pool at `tick` (asset is token1, paired token0 for both vaults).
    function _ratioAtTick(int24 tick) internal view returns (uint256) {
        uint256 s = TickMath.getSqrtRatioAtTick(tick);
        uint256 p1e18 = Math.mulDiv(s * s, 1e18, 1 << 192); // token1 per token0, raw units
        // raw -> decimals adjusted: asset per ONE paired = p * 10^pDec / 10^aDec; same 1e18 scale
        return Math.mulDiv(p1e18, pUnit, aUnit);
    }


    // ================================================================== IN-KIND RECOVERY GATE (asserted)
    //
    // REQUIRED OUTCOMES of `redeemInKind(shares, receiver, owner)` for BOTH vaults (the docs section "Required in-kind
    // recovery outcomes" in avalanche-track-a-evidence/inkind/README.md has the same list with the numeric thresholds):
    //   R1 liveness   : the call SUCCEEDS for any holder in the base case, in the thin-liquidity ladder, in every stress
    //                   shift (including the shifts where the TWAP/oracle gates freeze redeem/deposit/rebalance and the
    //                   ERC-4626 views), with the position OUT OF RANGE while the oracle follows the pool, in the
    //                   dislocation (oracle does not follow) and after emergencyExit.
    //   R2 value      : oracle-valued legs (asset + paired x oracle) versus the deposit that bought the shares stay inside
    //                   [-maxLossPpm, +maxGainPpm] (named per-vault constants in the concrete suites; 1 bp = 100 ppm). Where
    //                   the vault's own haircut NAV is readable the legs are also not worth less than that NAV.
    //   R3 accounting : exactly `shares` are burned from the owner, totalSupply falls by exactly `shares`, other holders'
    //                   share balances are unchanged, the receiver's token deltas equal the returned legs, tokenId is kept
    //                   (or burned when the last share leaves), the position liquidity falls by floor(L * shares / supply).
    //   R4 pro rata   : legs per share equal the legs per share a reference holder would receive from the same state
    //                   (within a stated rounding tolerance); no value is created.
    //   R5 other holder: the reference (second) holder's own in-kind entitlement is not reduced (and not increased) beyond
    //                   rounding by the redemption, and (when the views work) neither is his haircut NAV.
    //   R6 gates      : the call needs no oracle, no TWAP check and no ERC-4626 view; the gate state (views frozen or not)
    //                   is the same before and after the call.
    // A cash-exit measurement (redeem failing at some size) is a DIAGNOSTIC, not one of these outcomes.

    uint256 internal constant KIND_TOL_WEI = 16; // absolute rounding slack (a few floors of mulDiv / one liquidity unit)
    uint256 internal constant KIND_TOL_PPB = 1; // relative rounding slack, parts per 1e9 of the compared amount

    struct KindCase {
        string tag; // log label
        address who; // owner of the shares under test (also the receiver)
        uint256 shares; // shares to redeem in kind
        uint256 depositPart; // asset units that bought `shares` (0 = skip the value bounds)
        uint256 maxLossPpm; // R2: oracle value may fall short of depositPart by at most this (1 bp = 100 ppm)
        uint256 maxGainPpm; // R2: ... and exceed it by at most this
        uint256 minValue; // R2: oracle value of the legs must be >= this (0 = skip), e.g. the haircut NAV read before
        address ref; // reference holder for R4/R5 (must hold shares, must not be `who`)
        bool bothLegs; // R1/R4: require both the asset leg and the paired leg to be > 0
    }

    struct KindResult {
        uint256 gotA;
        uint256 gotP;
        uint256 value; // gotA + oracle(gotP)
        bool viewsFrozen; // totalAssets() reverted before the call
    }

    function _positionLiquidity() internal view returns (uint128 liq) {
        uint256 tid = v.tokenId();
        if (tid == 0) return 0;
        (,,,,, liq,,,,) = ITAPositionManager(POSITION_MANAGER).positions(tid);
    }

    function _kindTol(uint256 x) internal pure returns (uint256) {
        return KIND_TOL_WEI + x / 1e9 * KIND_TOL_PPB;
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @dev The legs `holder` would get from redeeming ALL his shares in kind from the CURRENT state. State is restored.
    function _hypotheticalKind(address holder) internal returns (uint256 a, uint256 p) {
        uint256 snap = vm.snapshotState();
        (bool ok, uint256 ga, uint256 gp, bytes memory e) = _redeemKindAs(holder, v.balanceOf(holder));
        vm.revertToState(snap);
        require(ok, string.concat("reference in-kind redeem failed: ", _err(e)));
        return (ga, gp);
    }

    struct KindPre {
        uint256 supply;
        uint256 whoShares;
        uint256 refShares;
        uint256 safeShares;
        uint256 tid;
        uint128 liq;
        bool paused;
        bool viewsOk;
        uint256 refNav;
        uint256 refA;
        uint256 refP;
        uint256 aBal;
        uint256 pBal;
    }

    /// @notice Executes `redeemInKind` for `c.who` and asserts R1..R6. Does NOT call any gate-dependent view unless
    ///         `totalAssets()` is readable (checked first). Any failed assertion fails the calling test.
    function _gateInKind(KindCase memory c) internal returns (KindResult memory r) {
        require(c.ref != c.who && v.balanceOf(c.ref) > 0, "kind gate: bad reference holder");
        KindPre memory p;
        p.supply = v.totalSupply();
        p.whoShares = v.balanceOf(c.who);
        p.refShares = v.balanceOf(c.ref);
        p.safeShares = v.balanceOf(SAFE);
        p.tid = v.tokenId();
        p.liq = _positionLiquidity();
        p.paused = v.paused();
        assertGe(p.whoShares, c.shares, string.concat(c.tag, ": test setup: owner holds fewer shares than asked"));
        (p.viewsOk, p.refNav) = _refNav(p.refShares);
        r.viewsFrozen = !p.viewsOk;
        (p.refA, p.refP) = _hypotheticalKind(c.ref);
        p.aBal = asset.balanceOf(c.who);
        p.pBal = paired.balanceOf(c.who);

        // ---- R1: the call must succeed
        {
            (bool ok, uint256 ga, uint256 gp, bytes memory e) = _redeemKindAs(c.who, c.shares);
            assertTrue(ok, string.concat("GATE FAIL ", c.tag, ": redeemInKind reverted: ", _err(e)));
            r.gotA = ga;
            r.gotP = gp;
        }
        assertTrue(r.gotA > 0 || r.gotP > 0, string.concat(c.tag, ": both legs zero"));
        if (c.bothLegs) {
            assertGt(r.gotA, 0, string.concat(c.tag, ": asset leg is zero"));
            assertGt(r.gotP, 0, string.concat(c.tag, ": paired leg is zero"));
        }
        _kindCheckAccounting(c, p, r);
        _kindCheckProRata(c, p, r);
        _kindCheckReference(c, p);
        _kindCheckValue(c, r);
        {
            (bool viewsOk1,) = _refNav(p.refShares);
            console2.log(string.concat("GATE|", c.tag, "|gated views frozen before/after the call: ", _tb(!p.viewsOk), " ", _tb(!viewsOk1), "; shares burned ", _t(c.shares), " of supply ", _t(p.supply)));
        }
    }

    /// @dev R3 accounting
    function _kindCheckAccounting(KindCase memory c, KindPre memory p, KindResult memory r) internal view {
        assertEq(asset.balanceOf(c.who) - p.aBal, r.gotA, string.concat(c.tag, ": asset delta != returned leg"));
        assertEq(paired.balanceOf(c.who) - p.pBal, r.gotP, string.concat(c.tag, ": paired delta != returned leg"));
        assertEq(v.balanceOf(c.who), p.whoShares - c.shares, string.concat(c.tag, ": owner shares not burned exactly"));
        assertEq(v.totalSupply(), p.supply - c.shares, string.concat(c.tag, ": totalSupply not reduced by shares"));
        assertEq(v.balanceOf(c.ref), p.refShares, string.concat(c.tag, ": reference holder shares changed"));
        if (c.who != SAFE) assertEq(v.balanceOf(SAFE), p.safeShares, string.concat(c.tag, ": Safe shares changed"));
        assertEq(v.paused(), p.paused, string.concat(c.tag, ": pause flag changed"));
        if (c.shares == p.supply) {
            assertEq(v.tokenId(), 0, string.concat(c.tag, ": last share out but NFT kept"));
        } else {
            assertEq(v.tokenId(), p.tid, string.concat(c.tag, ": tokenId changed by a partial in-kind exit"));
            if (p.liq != 0) {
                assertEq(
                    uint256(_positionLiquidity()),
                    uint256(p.liq) - Math.mulDiv(uint256(p.liq), c.shares, p.supply),
                    string.concat(c.tag, ": liquidity removed != floor(L*shares/supply)")
                );
            }
        }
    }

    /// @dev R4 pro rata: legs per share equal the reference holder's legs per share from the same pre-state
    function _kindCheckProRata(KindCase memory c, KindPre memory p, KindResult memory r) internal view {
        uint256 expA = Math.mulDiv(p.refA, c.shares, p.refShares);
        uint256 expP = Math.mulDiv(p.refP, c.shares, p.refShares);
        uint256 amp = c.shares / p.refShares + 1; // the reference's own floors are amplified by the share ratio
        uint256 tolA = KIND_TOL_WEI + 3 * amp + expA / 1e9 * KIND_TOL_PPB;
        uint256 tolP = KIND_TOL_WEI + 3 * amp + expP / 1e9 * KIND_TOL_PPB;
        console2.log(string.concat("GATE|", c.tag, "|prorata asset got/exp/|diff|/tol ", _t(r.gotA), " ", _t(expA), " ", _t(_absDiff(r.gotA, expA)), " ", _t(tolA)));
        console2.log(string.concat("GATE|", c.tag, "|prorata paired got/exp/|diff|/tol ", _t(r.gotP), " ", _t(expP), " ", _t(_absDiff(r.gotP, expP)), " ", _t(tolP)));
        assertLe(_absDiff(r.gotA, expA), tolA, string.concat(c.tag, ": asset leg not pro rata"));
        assertLe(_absDiff(r.gotP, expP), tolP, string.concat(c.tag, ": paired leg not pro rata"));
        // CONTROL: the tolerance must be tight enough that a 1 bp error in a leg would be caught (else the check is vacuous)
        if (expA > 1e7) assertGt(expA / 10_000, tolA, string.concat(c.tag, ": control: asset tolerance cannot detect a 1 bp error"));
        if (expP > 1e7) assertGt(expP / 10_000, tolP, string.concat(c.tag, ": control: paired tolerance cannot detect a 1 bp error"));
    }

    /// @dev R5 the other holder is not harmed (nor enriched beyond rounding); R6 gate state untouched
    function _kindCheckReference(KindCase memory c, KindPre memory p) internal {
        (uint256 refA1, uint256 refP1) = _hypotheticalKind(c.ref);
        console2.log(string.concat("GATE|", c.tag, "|reference holder in-kind legs before/after: asset ", _t(p.refA), " ", _t(refA1), " paired ", _t(p.refP), " ", _t(refP1)));
        assertGe(refA1 + _kindTol(p.refA), p.refA, string.concat(c.tag, ": other holder lost asset entitlement"));
        assertGe(refP1 + _kindTol(p.refP), p.refP, string.concat(c.tag, ": other holder lost paired entitlement"));
        assertLe(refA1, p.refA + _kindTol(p.refA), string.concat(c.tag, ": other holder asset entitlement grew (value moved)"));
        assertLe(refP1, p.refP + _kindTol(p.refP), string.concat(c.tag, ": other holder paired entitlement grew (value moved)"));
        (bool viewsOk1, uint256 refNav1) = _refNav(p.refShares);
        assertEq(viewsOk1, p.viewsOk, string.concat(c.tag, ": in-kind changed whether the gated views revert"));
        if (p.viewsOk) {
            assertGe(refNav1 + _kindTol(p.refNav), p.refNav, string.concat(c.tag, ": other holder NAV value fell"));
        }
    }

    /// @dev R2 value (oracle-valued; the oracle is read only for valuation, the vault call never used it)
    function _kindCheckValue(KindCase memory c, KindResult memory r) internal {
        r.value = r.gotA + (r.gotP == 0 ? 0 : _pairedInAsset(r.gotP));
        if (c.depositPart != 0) {
            if (r.value < c.depositPart) {
                assertLe((c.depositPart - r.value) * 1_000_000, c.maxLossPpm * c.depositPart, string.concat("GATE FAIL ", c.tag, ": oracle-valued shortfall above threshold"));
            } else {
                assertLe((r.value - c.depositPart) * 1_000_000, c.maxGainPpm * c.depositPart, string.concat("GATE FAIL ", c.tag, ": oracle-valued surplus above threshold"));
            }
        }
        if (c.minValue != 0) assertGe(r.value, c.minValue, string.concat("GATE FAIL ", c.tag, ": legs worth less than the vault's own haircut NAV"));
        console2.log(string.concat("GATE|", c.tag, "|inKind OK legs asset/paired ", _t(r.gotA), " ", _t(r.gotP), " valueInAsset ", _t(r.value), " depositPart ", _t(c.depositPart)));
        if (c.depositPart != 0) {
            console2.log(string.concat("GATE|", c.tag, "|oracle-valued shortfall vs deposit, ppm (negative = surplus; 100 ppm = 1 bp) ", _ti((int256(c.depositPart) - int256(r.value)) * 1_000_000 / int256(c.depositPart)), "; thresholds loss/gain ppm ", _t(c.maxLossPpm), " ", _t(c.maxGainPpm)));
        }
    }

    function _refNav(uint256 refShares) internal view returns (bool ok, uint256 nav) {
        try v.convertToAssets(refShares) returns (uint256 x) {
            return (true, x);
        } catch {
            return (false, 0);
        }
    }

    // ------------------------------------------------------------------ log formatting (console2 lacks mixed overloads)
    function _t(uint256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function _ti(int256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function _tb(bool x) internal pure returns (string memory) {
        return x ? "true" : "false";
    }

    function _ta(address x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    // ------------------------------------------------------------------ error decoding
    function _err(bytes memory r) internal pure returns (string memory) {
        if (r.length < 4) return "empty-revert";
        bytes4 sel;
        assembly { sel := mload(add(r, 32)) }
        if (sel == bytes4(keccak256("Vault__PriceDeviation(int24,int24)"))) return "Vault__PriceDeviation";
        if (sel == bytes4(keccak256("Vault__OracleDeviation(uint256,uint256)"))) return "Vault__OracleDeviation";
        if (sel == bytes4(keccak256("Vault__PositionNeedsRebalance()"))) return "Vault__PositionNeedsRebalance";
        if (sel == bytes4(keccak256("Vault__InsufficientAssets(uint256,uint256)"))) return "Vault__InsufficientAssets";
        if (sel == bytes4(keccak256("Vault__InsufficientShares(uint256,uint256)"))) return "Vault__InsufficientShares";
        if (sel == bytes4(keccak256("Vault__ExcessiveLoss(uint256,uint256)"))) return "Vault__ExcessiveLoss";
        if (sel == bytes4(keccak256("Vault__DepositCapExceeded(uint256,uint256)"))) return "Vault__DepositCapExceeded";
        if (sel == bytes4(keccak256("Vault__NotRebalancer()"))) return "Vault__NotRebalancer";
        if (sel == bytes4(keccak256("Vault__ZeroAmount()"))) return "Vault__ZeroAmount";
        if (sel == bytes4(keccak256("Vault__InvalidOracle()"))) return "Vault__InvalidOracle";
        if (sel == bytes4(keccak256("OwnableUnauthorizedAccount(address)"))) return "OwnableUnauthorizedAccount";
        if (sel == bytes4(keccak256("EnforcedPause()"))) return "EnforcedPause";
        if (sel == bytes4(keccak256("ERC4626ExceededMaxRedeem(address,uint256,uint256)"))) return "ERC4626ExceededMaxRedeem";
        if (sel == bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)"))) return "ERC4626ExceededMaxWithdraw";
        if (sel == bytes4(keccak256("Oracle__StaleAnswer(address,uint256)"))) return "Oracle__StaleAnswer";
        if (sel == bytes4(keccak256("Error(string)"))) {
            bytes memory tail = new bytes(r.length - 4);
            for (uint256 i; i < tail.length; ++i) tail[i] = r[i + 4];
            return string.concat("Error: ", abi.decode(tail, (string)));
        }
        if (sel == 0x4e487b71) return "Panic";
        return string.concat("sel:", vm.toString(bytes32(sel)));
    }

    function _short(bool ok, bytes memory err) internal pure returns (string memory) {
        return ok ? "ok" : _err(err);
    }
}
