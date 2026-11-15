// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
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

/// @dev Extra pool reads used only by the F-IK-2 ledger (protocol fees accrued inside the pool, TWAP accumulator).
interface ITAPoolX {
    function protocolFees() external view returns (uint128, uint128);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory, uint160[] memory);
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


    // ================================================================== F-IK-2 LEDGER (log prefix "FIK2|")
    //
    // Everything below is MEASUREMENT code for observation F-IK-2 (a later deposit lowers the incumbent's in-kind,
    // oracle-valued holdings). It asserts only exact accounting identities (see the tests), never a fairness threshold.
    //
    // Holdings of the vault are measured EXACTLY, in token units:  H = idle balances + position principal + uncollected
    // fees. Principal and fees are not computed from a formula: they are read by replaying `collect` and a full
    // `decreaseLiquidity` + `collect` as the vault inside a snapshot that is reverted (the same calls the vault makes).
    // A holder's in-kind entitlement is H * shares / supply (floor); it is cross-checked against a real `redeemInKind`
    // replayed inside a snapshot (`_hypotheticalKind`).
    // Token conservation: the changes of every account that can hold the two tokens in these tests (the five wallets,
    // the vault holdings, the pool balance, the router and the position manager) must sum to zero; the pool balance
    // is split into "vault principal + vault fees", "protocol fees accrued in the pool" and "everything else" (other
    // liquidity providers: principal and fees; derived as pool balance minus the other two).

    struct FSnap {
        uint160 sqrtP;
        int24 tick;
        int24 twap;
        uint128 poolLiq;
        uint128 vLiq;
        uint256 supply;
        uint256 idleA;
        uint256 idleP;
        uint256 prinA;
        uint256 prinP;
        uint256 feeA;
        uint256 feeP;
        uint256 poolA;
        uint256 poolP;
        uint256 pfA;
        uint256 pfP;
        uint256 rtA;
        uint256 rtP;
        uint256 pmA;
        uint256 pmP;
        uint256[4] sh; // shares: ALICE, BOB, CAROL, SAFE
        uint256[5] wA; // wallet asset: ALICE, BOB, CAROL, SAFE, WHALE
        uint256[5] wP; // wallet paired
    }

    struct SwapInfo {
        bool seen;
        bool inIsAsset;
        uint256 amtIn; // token in, includes the pool fee (pool Swap event amount)
        uint256 amtOut;
        uint160 sqrtPost;
        int24 tickPost;
        uint256 count;
    }

    function _holder(uint256 i) internal pure returns (address) {
        if (i == 0) return ALICE;
        if (i == 1) return BOB;
        if (i == 2) return CAROL;
        if (i == 3) return SAFE;
        return WHALE;
    }

    function _hname(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "ALICE";
        if (i == 1) return "BOB";
        if (i == 2) return "CAROL";
        if (i == 3) return "SAFE(seed)";
        return "WHALE(external swapper)";
    }

    function _prefundWhale() internal {
        _fund(address(asset), WHALE, 4_000_000_000 * aUnit);
        _fund(address(paired), WHALE, 4_000_000_000 * pUnit);
    }

    function _twapTickX() internal view returns (int24) {
        uint32 per = v.twapPeriod();
        uint32[] memory ago = new uint32[](2);
        ago[0] = per;
        ago[1] = 0;
        (int56[] memory c,) = ITAPoolX(address(pool)).observe(ago);
        int56 delta = c[1] - c[0];
        int56 p = int56(uint56(per));
        int56 mean = delta / p;
        if (delta < 0 && (delta % p != 0)) mean--;
        return int24(mean);
    }

    /// @dev Exact principal and uncollected fees of the vault's NFT, in (asset, paired) units. Replays the vault's own
    ///      calls on a snapshot that is reverted before returning.
    function _vaultPosition() internal returns (uint256 prinA, uint256 prinP, uint256 feeA, uint256 feeP) {
        uint256 tid = v.tokenId();
        if (tid == 0) return (0, 0, 0, 0);
        (,,,,, uint128 liq,,,,) = ITAPositionManager(POSITION_MANAGER).positions(tid);
        IERC20 t0 = IERC20(pool.token0());
        IERC20 t1 = IERC20(pool.token1());
        address vault = address(v);
        uint256 snap = vm.snapshotState();
        uint256 b0 = t0.balanceOf(vault);
        uint256 b1 = t1.balanceOf(vault);
        uint256 f0;
        uint256 f1;
        uint256 p0;
        uint256 p1;
        vm.startPrank(vault);
        (bool ok1,) = POSITION_MANAGER.call(
            abi.encodeWithSignature("collect((uint256,address,uint128,uint128))", tid, vault, type(uint128).max, type(uint128).max)
        );
        require(ok1, "fik2: replay collect failed");
        f0 = t0.balanceOf(vault) - b0;
        f1 = t1.balanceOf(vault) - b1;
        if (liq > 0) {
            (bool ok2,) = POSITION_MANAGER.call(
                abi.encodeWithSignature("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))", tid, liq, 0, 0, block.timestamp)
            );
            require(ok2, "fik2: replay decreaseLiquidity failed");
            (bool ok3,) = POSITION_MANAGER.call(
                abi.encodeWithSignature("collect((uint256,address,uint128,uint128))", tid, vault, type(uint128).max, type(uint128).max)
            );
            require(ok3, "fik2: replay collect 2 failed");
            p0 = t0.balanceOf(vault) - b0 - f0;
            p1 = t1.balanceOf(vault) - b1 - f1;
        }
        vm.stopPrank();
        vm.revertToState(snap);
        if (v.assetIsToken0()) return (p0, p1, f0, f1);
        return (p1, p0, f1, f0);
    }

    /// @dev The vault's own `valueBefore` of a deposit: totalAssets() after the fees were collected into idle.
    function _navAfterCollect() internal returns (uint256 nav) {
        uint256 tid = v.tokenId();
        if (tid == 0) return v.totalAssets();
        address vault = address(v);
        uint256 snap = vm.snapshotState();
        vm.prank(vault);
        (bool ok,) = POSITION_MANAGER.call(
            abi.encodeWithSignature("collect((uint256,address,uint128,uint128))", tid, vault, type(uint128).max, type(uint128).max)
        );
        require(ok, "fik2: replay collect failed (nav)");
        nav = v.totalAssets();
        vm.revertToState(snap);
    }

    function _fSnap() internal returns (FSnap memory s) {
        (s.sqrtP, s.tick,,,,,) = pool.slot0();
        s.twap = _twapTickX();
        s.poolLiq = pool.liquidity();
        s.vLiq = _positionLiquidity();
        s.supply = v.totalSupply();
        s.idleA = asset.balanceOf(address(v));
        s.idleP = paired.balanceOf(address(v));
        (s.prinA, s.prinP, s.feeA, s.feeP) = _vaultPosition();
        s.poolA = asset.balanceOf(address(pool));
        s.poolP = paired.balanceOf(address(pool));
        (uint128 f0, uint128 f1) = ITAPoolX(address(pool)).protocolFees();
        (s.pfA, s.pfP) = v.assetIsToken0() ? (uint256(f0), uint256(f1)) : (uint256(f1), uint256(f0));
        s.rtA = asset.balanceOf(ROUTER);
        s.rtP = paired.balanceOf(ROUTER);
        s.pmA = asset.balanceOf(POSITION_MANAGER);
        s.pmP = paired.balanceOf(POSITION_MANAGER);
        for (uint256 i; i < 5; ++i) {
            address h = _holder(i);
            s.wA[i] = asset.balanceOf(h);
            s.wP[i] = paired.balanceOf(h);
            if (i < 4) s.sh[i] = v.balanceOf(h);
        }
    }

    function _hA(FSnap memory s) internal pure returns (uint256) {
        return s.idleA + s.prinA + s.feeA;
    }

    function _hP(FSnap memory s) internal pure returns (uint256) {
        return s.idleP + s.prinP + s.feeP;
    }

    function _ent(FSnap memory s, uint256 i) internal pure returns (uint256 a, uint256 p) {
        if (s.supply == 0) return (0, 0);
        a = Math.mulDiv(_hA(s), s.sh[i], s.supply);
        p = Math.mulDiv(_hP(s), s.sh[i], s.supply);
    }

    // ---- prices: paired -> asset and asset -> paired at a pool sqrt price, and at the vault's oracle
    function _p2a(uint256 pAmt, uint160 sq) internal view returns (uint256) {
        if (pAmt == 0) return 0;
        if (v.assetIsToken0()) return Math.mulDiv(Math.mulDiv(pAmt, 1 << 96, sq), 1 << 96, sq);
        return Math.mulDiv(Math.mulDiv(pAmt, sq, 1 << 96), sq, 1 << 96);
    }

    function _a2p(uint256 aAmt, uint160 sq) internal view returns (uint256) {
        if (aAmt == 0) return 0;
        if (v.assetIsToken0()) return Math.mulDiv(Math.mulDiv(aAmt, sq, 1 << 96), sq, 1 << 96);
        return Math.mulDiv(Math.mulDiv(aAmt, 1 << 96, sq), 1 << 96, sq);
    }

    function _vO(int256 dA, int256 dP) internal view returns (int256) {
        return dA + (dP >= 0 ? int256(_pairedInAsset(uint256(dP))) : -int256(_pairedInAsset(uint256(-dP))));
    }

    function _vS(int256 dA, int256 dP, uint160 sq) internal view returns (int256) {
        return dA + (dP >= 0 ? int256(_p2a(uint256(dP), sq)) : -int256(_p2a(uint256(-dP), sq)));
    }

    function _ppm(int256 x, uint256 ref) internal pure returns (int256) {
        return ref == 0 ? int256(0) : x * 1_000_000 / int256(ref);
    }

    function _i(uint256 x) internal pure returns (int256) {
        return int256(x);
    }

    /// @dev One ledger line: token units and the same amount valued at three bases (oracle, pool spot before, pool spot after).
    function _fl(string memory tag, string memory name, int256 dA, int256 dP, uint160 s0, uint160 s1, uint256 ref) internal view {
        int256 vo = _vO(dA, dP);
        int256 v0 = _vS(dA, dP, s0);
        int256 v1 = _vS(dA, dP, s1);
        string memory l1 = string.concat("FIK2|", tag, "|", name, "| dAsset ", _ti(dA), " dPaired ", _ti(dP));
        string memory l2 = string.concat(" | @oracle ", _ti(vo), " (", _ti(_ppm(vo, ref)), " ppm)");
        string memory l3 = string.concat(" | @spotBefore ", _ti(v0), " (", _ti(_ppm(v0, ref)), " ppm)");
        string memory l4 = string.concat(" | @spotAfter ", _ti(v1), " (", _ti(_ppm(v1, ref)), " ppm)");
        console2.log(string.concat(l1, l2, l3, l4));
    }

    function _pairSum(FSnap memory b, uint256 hi) internal pure returns (uint256 sumShares) {
        for (uint256 i; i < hi; ++i) sumShares += b.sh[i];
    }

    struct LS {
        int256 sumA;
        int256 sumP;
        uint256 eA0;
        uint256 eP0;
        uint256 eA1;
        uint256 eP1;
    }

    function _fAdd(LS memory L, string memory tag, string memory name, int256 dA, int256 dP, FSnap memory a, FSnap memory b, uint256 ref, bool verbose) internal view {
        L.sumA += dA;
        L.sumP += dP;
        if (verbose && (dA != 0 || dP != 0)) _fl(tag, name, dA, dP, a.sqrtP, b.sqrtP, ref);
    }

    function _fHolderLine(LS memory L, string memory tag, FSnap memory a, FSnap memory b, uint256 i, uint256 ref, bool verbose) internal view {
        (uint256 a0, uint256 p0) = _ent(a, i);
        (uint256 a1, uint256 p1) = _ent(b, i);
        L.eA0 += a0;
        L.eP0 += p0;
        L.eA1 += a1;
        L.eP1 += p1;
        _fAdd(L, tag, string.concat("holder ", _hname(i), " [wallet + in-kind entitlement]"), _i(a1) - _i(a0) + _i(b.wA[i]) - _i(a.wA[i]), _i(p1) - _i(p0) + _i(b.wP[i]) - _i(a.wP[i]), a, b, ref, verbose);
    }

    /// @notice Token-conservation ledger from snapshot `a` to snapshot `b`. Returns the residual (sum of all lines) per token;
    ///         the lines are logged with the valuations of `_fl` when `verbose`.
    function _fLedger(string memory tag, FSnap memory a, FSnap memory b, uint256 ref, bool verbose)
        internal
        returns (int256, int256)
    {
        require(_pairSum(a, 4) == a.supply && _pairSum(b, 4) == b.supply, "fik2: a share holder is not in the list");
        LS memory L;
        for (uint256 i; i < 4; ++i) _fHolderLine(L, tag, a, b, i, ref, verbose);
        _fAdd(L, tag, "external swapper wallet", _i(b.wA[4]) - _i(a.wA[4]), _i(b.wP[4]) - _i(a.wP[4]), a, b, ref, verbose);
        // vault holdings not assigned to any share because of the floors of the entitlement formula
        _fAdd(L, tag, "vault floor remainder (unassigned)", (_i(_hA(b)) - _i(L.eA1)) - (_i(_hA(a)) - _i(L.eA0)), (_i(_hP(b)) - _i(L.eP1)) - (_i(_hP(a)) - _i(L.eP0)), a, b, ref, verbose);
        // other liquidity providers in the pool: pool balance - vault principal - vault pending fees - protocol fees
        _fAdd(
            L, tag, "other LPs in the pool (principal + fees, derived)",
            (_i(b.poolA) - _i(b.prinA) - _i(b.feeA) - _i(b.pfA)) - (_i(a.poolA) - _i(a.prinA) - _i(a.feeA) - _i(a.pfA)),
            (_i(b.poolP) - _i(b.prinP) - _i(b.feeP) - _i(b.pfP)) - (_i(a.poolP) - _i(a.prinP) - _i(a.feeP) - _i(a.pfP)),
            a, b, ref, verbose
        );
        _fAdd(L, tag, "pool protocol fees accrued", _i(b.pfA) - _i(a.pfA), _i(b.pfP) - _i(a.pfP), a, b, ref, verbose);
        _fAdd(L, tag, "router + position manager balances (dust)", _i(b.rtA) - _i(a.rtA) + _i(b.pmA) - _i(a.pmA), _i(b.rtP) - _i(a.rtP) + _i(b.pmP) - _i(a.pmP), a, b, ref, verbose);
        console2.log(string.concat("FIK2|", tag, "|LEDGER residual (sum of all lines; 0 = every token accounted for) asset ", _ti(L.sumA), " paired ", _ti(L.sumP)));
        return (L.sumA, L.sumP);
    }

    /// @dev Asserts the exact conservation identity of `_fLedger` (the residual must be 0: tokens only move between the listed accounts).
    function _fLedgerAssert(string memory tag, FSnap memory a, FSnap memory b, uint256 ref, bool verbose) internal {
        (int256 rA, int256 rP) = _fLedger(tag, a, b, ref, verbose);
        assertEq(rA, int256(0), string.concat(tag, ": ledger residual (asset) != 0"));
        assertEq(rP, int256(0), string.concat(tag, ": ledger residual (paired) != 0"));
    }

    function _parseSwaps(Vm.Log[] memory logs) internal view returns (SwapInfo memory s) {
        bytes32 topic = keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)");
        bool a0 = v.assetIsToken0();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool) || logs[i].topics.length == 0 || logs[i].topics[0] != topic) continue;
            (int256 x0, int256 x1, uint160 sq,, int24 tk) = abi.decode(logs[i].data, (int256, int256, uint160, uint128, int24));
            bool in0 = x0 > 0;
            bool inAsset = (in0 == a0);
            if (s.count == 0) s.inIsAsset = inAsset;
            else require(s.inIsAsset == inAsset, "fik2: swaps of both directions inside one call");
            s.amtIn += uint256(in0 ? x0 : x1);
            s.amtOut += uint256(in0 ? -x1 : -x0);
            s.sqrtPost = sq;
            s.tickPost = tk;
            s.seen = true;
            s.count++;
        }
    }

    function _tkn(bool isAsset) internal view returns (address) {
        return isAsset ? address(asset) : address(paired);
    }

    // ---- newcomer-deposit decomposition ------------------------------------------------------------------------
    struct DC {
        uint256 idx; // holder index of the newcomer
        uint256 inc; // holder index of the reference incumbent (0 = ALICE, 3 = SAFE seed)
        uint256 D; // newcomer deposit, asset units
        uint256 ref; // reference size for ppm of the incumbent (Alice's deposit)
        uint256 minted;
        uint256 valBefore; // the vault's own valueBefore (totalAssets after collect)
        uint256 navAfter; // totalAssets() after the deposit
        FSnap a0; // before the deposit
        FSnap a1; // after the real deposit
        FSnap a1r; // after the real deposit and an external swap that restores the tick
        FSnap c1; // CONTROL: same pool swap by an external account, no deposit
        FSnap c1r; // control, tick restored
        SwapInfo sw;
        uint256 hk0A; // Alice real in-kind legs before (replayed redeemInKind)
        uint256 hk0P;
        uint256 hk1A; // ... after
        uint256 hk1P;
        uint256 hkNA; // newcomer real in-kind legs after
        uint256 hkNP;
    }

    /// @dev Runs the newcomer deposit three times from the same state (real; real + tick restored; control swap) and leaves
    ///      the state AFTER the real deposit. The newcomer's wallet is pre-funded so that no `deal` happens inside a step.
    function _dcRun(DC memory d) internal {
        address who = _holder(d.idx);
        if (asset.balanceOf(who) < d.D) _fund(address(asset), who, d.D);
        d.a0 = _fSnap();
        d.valBefore = _navAfterCollect();
        (d.hk0A, d.hk0P) = _hypotheticalKind(_holder(d.inc));
        uint256 s1 = vm.snapshotState();
        vm.recordLogs();
        (bool ok, uint256 m, bytes memory e) = _depositAs(who, d.D);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(ok, string.concat("fik2: newcomer deposit failed: ", _err(e)));
        d.minted = m;
        d.sw = _parseSwaps(logs);
        d.a1 = _fSnap();
        d.navAfter = v.totalAssets();
        (d.hk1A, d.hk1P) = _hypotheticalKind(_holder(d.inc));
        (d.hkNA, d.hkNP) = _hypotheticalKind(who);
        uint256 s2 = vm.snapshotState();
        _moveToTick(d.a0.tick);
        d.a1r = _fSnap();
        vm.revertToState(s2);
        vm.revertToState(s1);
        // control: the same pool swap by an external account, no deposit
        s1 = vm.snapshotState();
        if (d.sw.seen) _swapAs(WHALE, _tkn(d.sw.inIsAsset), _tkn(!d.sw.inIsAsset), d.sw.amtIn, 0);
        d.c1 = _fSnap();
        s2 = vm.snapshotState();
        _moveToTick(d.a0.tick);
        d.c1r = _fSnap();
        vm.revertToState(s2);
        vm.revertToState(s1);
        (ok,,) = _depositAs(who, d.D);
        require(ok, "fik2: re-run of the real deposit failed");
    }

    /// @dev LOCAL VM ONLY mutation (a control, never a proposal): overwrite the vault's `valuationHaircutBps` in storage. The
    ///      packed risk-parameter slot is located by matching all six packed values against the public getters.
    function _mutateHaircut(uint16 newH) internal {
        uint256 want = uint256(uint24(v.tickRange()));
        want |= uint256(v.twapPeriod()) << 24;
        want |= uint256(v.maxTwapDeviationTicks()) << 56;
        want |= uint256(v.maxOracleDeviationBps()) << 80;
        want |= uint256(v.slippageBps()) << 96;
        want |= uint256(v.valuationHaircutBps()) << 112;
        bytes32 found;
        uint256 n;
        for (uint256 i; i < 40; ++i) {
            bytes32 w = vm.load(address(v), bytes32(i));
            if (uint256(w) & ((1 << 128) - 1) == want) {
                found = bytes32(i);
                ++n;
            }
        }
        require(n == 1, "fik2: risk-parameter slot not found uniquely");
        uint256 cur = uint256(vm.load(address(v), found));
        cur = (cur & ~(uint256(0xFFFF) << 112)) | (uint256(newH) << 112);
        vm.store(address(v), found, bytes32(cur));
        require(v.valuationHaircutBps() == newH, "fik2: haircut mutation failed");
    }

    function _dcLog(DC memory d, string memory tag) internal {
        _dcLogHeader(d, tag);
        _dcLogSwap(d, tag);
        _dcLogEffects(d, tag);
        _dcLogChain(d, tag, 0);
        _dcLogChain(d, tag, 1);
        _dcAssert(d, tag);
    }

    function _dcLogHeader(DC memory d, string memory tag) internal view {
        uint256 oR = _pairedInAsset(pUnit); // asset units per one paired unit, oracle
        uint256 pR = _p2a(pUnit, d.a0.sqrtP); // ... pool spot before
        int256 gapPpm = oR == 0 ? int256(0) : (_i(oR) - _i(pR)) * 1_000_000 / _i(oR);
        string memory m = string.concat("FIK2|", tag, "|HEADER newcomer ", _hname(d.idx), " deposit D ", _t(d.D), " incumbent size ", _t(d.ref), " reference incumbent ", _hname(d.inc));
        m = string.concat(m, " (D = ", _t(d.D * 10_000 / d.ref), " bp of the incumbent), minted shares ", _t(d.minted), " of supply before ", _t(d.a0.supply));
        console2.log(m);
        m = string.concat("FIK2|", tag, "|HEADER ticks: spot before ", _ti(d.a0.tick), " TWAP before ", _ti(d.a0.twap), " spot after ", _ti(d.a1.tick));
        m = string.concat(m, "; position range ", _ti(v.positionTickLower()), " ", _ti(v.positionTickUpper()));
        m = string.concat(m, "; pool liquidity ", _t(d.a0.poolLiq), " vault liquidity before/after ", _t(d.a0.vLiq), " ", _t(d.a1.vLiq));
        console2.log(m);
        m = string.concat("FIK2|", tag, "|HEADER basis: oracle asset-per-paired ", _t(oR), " pool spot ", _t(pR), " -> oracle above pool by ", _ti(gapPpm));
        m = string.concat(m, " ppm; pool fee ppm ", _t(pool.fee()), " haircut bps ", _t(v.valuationHaircutBps()));
        console2.log(m);
    }

    struct SW {
        uint256 fee;
        uint256 fIn;
        uint256 expSpot;
        uint256 expOra;
        uint256 feeOut;
        int256 costSpot;
        int256 impactOut;
        int256 basisOut;
    }

    function _dcLogSwap(DC memory d, string memory tag) internal view {
        SwapInfo memory sw = d.sw;
        if (!sw.seen) {
            console2.log(string.concat("FIK2|", tag, "|SWAP the vault made no deployment swap"));
            return;
        }
        SW memory w;
        uint160 s0 = d.a0.sqrtP;
        w.fee = pool.fee();
        w.fIn = sw.amtIn * w.fee / 1_000_000; // fee paid, in token-in units
        w.expSpot = sw.inIsAsset ? _a2p(sw.amtIn, s0) : _p2a(sw.amtIn, s0);
        w.expOra = sw.inIsAsset ? ITAOracle(oracleAddr).quoteAssetToPair(sw.amtIn) : _pairedInAsset(sw.amtIn);
        w.feeOut = w.expSpot * w.fee / 1_000_000;
        w.costSpot = _i(w.expSpot) - _i(sw.amtOut); // fee + price impact
        w.impactOut = w.costSpot - _i(w.feeOut);
        w.basisOut = (_i(w.expOra) - _i(sw.amtOut)) - w.costSpot; // extra apparent cost at the oracle: oracle/pool basis
        uint256 inAssetEq = sw.inIsAsset ? sw.amtIn : _p2a(sw.amtIn, s0);
        string memory m = string.concat("FIK2|", tag, "|SWAP direction ", sw.inIsAsset ? "asset->paired" : "paired->asset", " count ", _t(sw.count), " amountIn ", _t(sw.amtIn), " amountOut ", _t(sw.amtOut));
        m = string.concat(m, " ; amountIn in asset terms ", _t(inAssetEq), " = ", _t(inAssetEq * 1_000_000 / d.D), " ppm of D; tick after swap ", _ti(sw.tickPost));
        console2.log(m);
        _dcLogSwapCost(d, tag, w);
        _dcLogSwapFee(d, tag, w);
        {
            int256 dIn = sw.inIsAsset ? _i(d.c1.poolA) - _i(d.a0.poolA) : _i(d.c1.poolP) - _i(d.a0.poolP);
            int256 dOut = sw.inIsAsset ? _i(d.c1.poolP) - _i(d.a0.poolP) : _i(d.c1.poolA) - _i(d.a0.poolA);
            console2.log(string.concat("FIK2|", tag, "|SWAP pool balance change in the control: token-in ", _ti(dIn), " token-out ", _ti(dOut), " (Swap event: +", _t(sw.amtIn), " -", _t(sw.amtOut), ")"));
        }
    }

    function _toAssetS(bool outIsPaired, int256 x, uint160 s0) internal view returns (int256) {
        return outIsPaired ? _vS(0, x, s0) : x;
    }

    function _dcLogSwapCost(DC memory d, string memory tag, SW memory w) internal view {
        bool outPaired = d.sw.inIsAsset;
        uint160 s0 = d.a0.sqrtP;
        int256 cS = _toAssetS(outPaired, w.costSpot, s0);
        int256 iS = _toAssetS(outPaired, w.impactOut, s0);
        int256 fS = _toAssetS(outPaired, _i(w.feeOut), s0);
        int256 bS = _toAssetS(outPaired, w.basisOut, s0);
        string memory m = string.concat("FIK2|", tag, "|SWAP execution cost vs pool spot before, in asset units: total ", _ti(cS), " (", _ti(_ppm(cS, d.D)), " ppm of D) = fee ", _ti(fS), " (", _ti(_ppm(fS, d.D)), ")");
        m = string.concat(m, " + price impact ", _ti(iS), " (", _ti(_ppm(iS, d.D)), ")");
        console2.log(m);
        m = string.concat("FIK2|", tag, "|SWAP oracle/pool basis on this swap: expected out at oracle ", _t(w.expOra), " vs at pool spot ", _t(w.expSpot));
        m = string.concat(m, " -> extra apparent cost at the oracle ", _ti(bS), " asset units = ", _ti(_ppm(bS, d.D)), " ppm of D");
        console2.log(m);
    }

    function _dcLogSwapFee(DC memory d, string memory tag, SW memory w) internal view {
        bool inA = d.sw.inIsAsset;
        uint160 s0 = d.a0.sqrtP;
        uint256 pfIn = inA ? d.c1.pfA - d.a0.pfA : d.c1.pfP - d.a0.pfP;
        uint256 vIn = inA ? d.c1.feeA - d.a0.feeA : d.c1.feeP - d.a0.feeP;
        int256 others = _i(w.fIn) - _i(pfIn) - _i(vIn);
        int256 aF = inA ? _i(w.fIn) : _vS(0, _i(w.fIn), s0);
        int256 aPf = inA ? _i(pfIn) : _vS(0, _i(pfIn), s0);
        int256 aV = inA ? _i(vIn) : _vS(0, _i(vIn), s0);
        int256 aO = inA ? others : _vS(0, others, s0);
        string memory m = string.concat("FIK2|", tag, "|FEE paid by the swap (amountIn x fee): ", _t(w.fIn), " token-in units = ", _ti(aF), " asset units (", _ti(_ppm(aF, d.D)), " ppm of D); to pool protocol fees ", _ti(aPf), " (", _ti(_ppm(aPf, d.D)), ")");
        m = string.concat(m, "; to the vault's own position (pending fees, shared by all holders) ", _ti(aV), " (", _ti(_ppm(aV, d.D)), "); to other LPs (derived) ", _ti(aO), " (", _ti(_ppm(aO, d.D)), ")");
        console2.log(m);
    }

    function _dcLogEffects(DC memory d, string memory tag) internal {
        _dcLogIncumbent(d, tag);
        _dcLogNewcomer(d, tag);
    }

    function _flE(string memory tag, string memory name, uint256 xA, uint256 xP, uint256 yA, uint256 yP, DC memory d, uint256 ref) internal view {
        _fl(tag, name, _i(xA) - _i(yA), _i(xP) - _i(yP), d.a0.sqrtP, d.a1.sqrtP, ref);
    }

    function _dcLogIncumbent(DC memory d, string memory tag) internal view {
        (uint256 e0A, uint256 e0P) = _ent(d.a0, d.inc);
        (uint256 e1A, uint256 e1P) = _ent(d.a1, d.inc);
        (uint256 ecA, uint256 ecP) = _ent(d.c1, d.inc);
        (uint256 e1rA, uint256 e1rP) = _ent(d.a1r, d.inc);
        (uint256 ecrA, uint256 ecrP) = _ent(d.c1r, d.inc);
        _flE(tag, "INCUMBENT (reference holder), total change of her in-kind entitlement (real deposit)", e1A, e1P, e0A, e0P, d, d.ref);
        _flE(tag, "INCUMBENT (reference holder), (i) POOL effect: same swap by an external account, no deposit", ecA, ecP, e0A, e0P, d, d.ref);
        _flE(tag, "INCUMBENT (reference holder), (ii) SHARE effect: real deposit minus control", e1A, e1P, ecA, ecP, d, d.ref);
        _flE(tag, "INCUMBENT (reference holder), total change with the tick restored by an external swap (real deposit)", e1rA, e1rP, e0A, e0P, d, d.ref);
        _flE(tag, "INCUMBENT (reference holder), pool effect with the tick restored (control + restore)", ecrA, ecrP, e0A, e0P, d, d.ref);
        _flE(tag, "INCUMBENT (reference holder), share effect with the tick restored", e1rA, e1rP, ecrA, ecrP, d, d.ref);
        // parity with test_17: real replayed redeemInKind legs
        int256 pv = _vO(_i(d.hk1A) - _i(d.hk0A), _i(d.hk1P) - _i(d.hk0P));
        string memory m = string.concat("FIK2|", tag, "|PARITY reference holder replayed redeemInKind legs before ", _t(d.hk0A), " ", _t(d.hk0P), " after ", _t(d.hk1A), " ", _t(d.hk1P));
        m = string.concat(m, " ; oracle value change ", _ti(pv), " = ", _ti(_ppm(pv, d.ref)), " ppm of the incumbent size (for Alice this is the quantity test_17 measures)");
        console2.log(m);
    }

    function _dcLogNewcomer(DC memory d, string memory tag) internal view {
        uint160 s0 = d.a0.sqrtP;
        uint160 s1 = d.a1.sqrtP;
        int256 kA = _i(_hA(d.a1)) - _i(_hA(d.c1));
        int256 kP = _i(_hP(d.a1)) - _i(_hP(d.c1));
        (uint256 nA, uint256 nP) = _ent(d.a1, d.idx);
        _fl(tag, "NEWCOMER contribution K = vault holdings after minus control holdings", kA, kP, s0, s1, d.D);
        _fl(tag, "NEWCOMER in-kind entitlement after the deposit", _i(nA), _i(nP), s0, s1, d.D);
        _fl(tag, "NEWCOMER share transfer T = entitlement - K (what the share price gives him beyond what he put in)", _i(nA) - kA, _i(nP) - kP, s0, s1, d.D);
        _fl(tag, "NEWCOMER execution cost K - D (swap fee + price impact + basis, as valued)", kA - _i(d.D), kP, s0, s1, d.D);
        _fl(tag, "NEWCOMER net change entitlement - D", _i(nA) - _i(d.D), _i(nP), s0, s1, d.D);
        _fl(tag, "IDLE balances of the vault BEFORE the deposit (not deployed; shared by all holders)", _i(d.a0.idleA), _i(d.a0.idleP), s0, s1, d.D);
        _fl(tag, "IDLE balances of the vault AFTER the deposit (undeployed residual: ratio mismatch + liquidity floor)", _i(d.a1.idleA), _i(d.a1.idleP), s0, s1, d.D);
        uint256 hO0 = uint256(_vO(_i(_hA(d.a0)), _i(_hP(d.a0))));
        uint256 kO = uint256(_vO(kA, kP));
        uint256 pk = kP > 0 ? _pairedInAsset(uint256(kP)) : 0;
        uint256 pk0 = _pairedInAsset(_hP(d.a0));
        string memory m = string.concat("FIK2|", tag, "|COMPOSITION paired share of value at oracle: vault before ", _t(pk0 * 1_000_000 / (hO0 == 0 ? 1 : hO0)), " ppm, newcomer contribution K ", _t(pk * 1_000_000 / (kO == 0 ? 1 : kO)));
        m = string.concat(m, " ppm (a haircut of ", _t(v.valuationHaircutBps()), " bp on the paired leg makes unequal mixes get unequal share prices)");
        console2.log(m);
    }

    function _sgnOra(int256 dP) internal view returns (int256) {
        return dP >= 0 ? int256(_pairedInAsset(uint256(dP))) : -int256(_pairedInAsset(uint256(-dP)));
    }

    struct CH {
        int256 fAct;
        int256 fEx;
        int256 fS;
        int256 fO;
        int256 fS1;
        int256 hB;
        int256 fFair;
        int256 tRound;
        int256 tVal;
        int256 tHair;
        int256 tBasis;
        int256 total;
        int256 tDirect;
    }

    /// @dev Telescoping chain of the share-price difference between the fraction the vault minted and the fraction that
    ///      matches the newcomer's contribution K, at one valuation basis (0 = oracle, 1 = pool spot after the deposit).
    function _dcChain(DC memory d, uint256 basis) internal view returns (CH memory c) {
        int256 kA = _i(_hA(d.a1)) - _i(_hA(d.c1));
        int256 kP = _i(_hP(d.a1)) - _i(_hP(d.c1));
        uint160 s1 = d.a1.sqrtP;
        int256 hc = _i(10_000 - v.valuationHaircutBps());
        c.fAct = _i(Math.mulDiv(d.minted, 1e18, d.a0.supply + d.minted));
        c.fEx = _i(_fEx(d, d.a0.supply));
        c.fS = (kA + _sgnOra(kP) * hc / 10_000) * 1e18 / (_i(_hA(d.a1)) + _sgnOra(_i(_hP(d.a1))) * hc / 10_000);
        int256 h1O = _vO(_i(_hA(d.a1)), _i(_hP(d.a1)));
        int256 h1S = _vS(_i(_hA(d.a1)), _i(_hP(d.a1)), s1);
        c.fO = _vO(kA, kP) * 1e18 / h1O;
        c.fS1 = _vS(kA, kP, s1) * 1e18 / h1S;
        c.hB = basis == 0 ? h1O : h1S;
        c.fFair = basis == 0 ? c.fO : c.fS1;
        c.tRound = (c.fAct - c.fEx) * c.hB / 1e18;
        c.tVal = (c.fEx - c.fS) * c.hB / 1e18;
        c.tHair = (c.fS - c.fO) * c.hB / 1e18;
        c.tBasis = (c.fO - c.fFair) * c.hB / 1e18;
        c.total = c.tRound + c.tVal + c.tHair + c.tBasis;
        (uint256 nA, uint256 nP) = _ent(d.a1, d.idx);
        c.tDirect = basis == 0 ? _vO(_i(nA) - kA, _i(nP) - kP) : _vS(_i(nA) - kA, _i(nP) - kP, s1);
    }

    function _dcLogChain(DC memory d, string memory tag, uint256 basis) internal view {
        CH memory c = _dcChain(d, basis);
        string memory bn = basis == 0 ? "oracle" : "pool spot after";
        string memory m = string.concat("FIK2|", tag, "|CHAIN[", bn, "] fractions (1e18): minted ", _ti(c.fAct), " exact-vault-formula ", _ti(c.fEx), " spot-haircut-NAV ", _ti(c.fS), " oracle-no-haircut ", _ti(c.fO), " pool-spot-no-haircut ", _ti(c.fS1));
        console2.log(m);
        m = string.concat("FIK2|", tag, "|CHAIN[", bn, "] share transfer to the newcomer T (asset units) = ", _ti(c.tDirect), " = ", _ti(_ppm(c.tDirect, d.D)), " ppm of D; terms: rounding (floor of mint) ", _ti(c.tRound));
        m = string.concat(m, " | valuation tick/fee exclusion (vault values the position at the TWAP tick, not spot) ", _ti(c.tVal), " | paired-leg haircut ", _ti(c.tHair), " | oracle vs pool basis ", _ti(c.tBasis));
        m = string.concat(m, " ; sum of terms ", _ti(c.total), " (", _ti(_ppm(c.total, d.D)), " ppm of D)");
        console2.log(m);
    }

    function _fEx(DC memory d, uint256 sup) internal pure returns (uint256) {
        uint256 net = d.navAfter - d.valBefore;
        uint256 shEx = Math.mulDiv(net, (sup + 1) * 1e18, d.valBefore + 1);
        return Math.mulDiv(shEx, 1e18, sup * 1e18 + shEx);
    }

    function _dcAssert(DC memory d, string memory tag) internal {
        // (1) exact: shares minted = the vault's formula applied to the totalAssets() it reported before/after
        assertEq(d.minted, Math.mulDiv(d.navAfter - d.valBefore, d.a0.supply + 1, d.valBefore + 1), string.concat(tag, ": minted shares != mulDiv(netContribution, supply+1, valueBefore+1)"));
        // (2) exact: token conservation, real deposit and control swap
        _fLedgerAssert(string.concat(tag, " REAL deposit"), d.a0, d.a1, d.ref, true);
        _fLedgerAssert(string.concat(tag, " CONTROL swap-only"), d.a0, d.c1, d.ref, true);
        // (3) exact: pool balance moves by exactly the Swap event amounts in the control
        if (d.sw.seen) {
            int256 dIn = d.sw.inIsAsset ? _i(d.c1.poolA) - _i(d.a0.poolA) : _i(d.c1.poolP) - _i(d.a0.poolP);
            int256 dOut = d.sw.inIsAsset ? _i(d.c1.poolP) - _i(d.a0.poolP) : _i(d.c1.poolA) - _i(d.a0.poolA);
            assertEq(dIn, _i(d.sw.amtIn), string.concat(tag, ": control pool token-in change != Swap event amountIn"));
            assertEq(dOut, -_i(d.sw.amtOut), string.concat(tag, ": control pool token-out change != -Swap event amountOut"));
        }
        // (4) identity: change of all incumbents' entitlements (real vs control) + newcomer entitlement = K, within floors
        {
            int256 incA;
            int256 incP;
            for (uint256 i; i < 4; ++i) {
                if (i == d.idx) continue;
                (uint256 a1, uint256 p1) = _ent(d.a1, i);
                (uint256 ac, uint256 pc) = _ent(d.c1, i);
                incA += _i(a1) - _i(ac);
                incP += _i(p1) - _i(pc);
            }
            (uint256 nA, uint256 nP) = _ent(d.a1, d.idx);
            int256 rA = incA + _i(nA) - (_i(_hA(d.a1)) - _i(_hA(d.c1)));
            int256 rP = incP + _i(nP) - (_i(_hP(d.a1)) - _i(_hP(d.c1)));
            console2.log(string.concat("FIK2|", tag, "|IDENTITY sum(incumbents real-minus-control) + newcomer entitlement - K = asset ", _ti(rA), " paired ", _ti(rP), " (floor rounding only; asserted |x| <= 8)"));
            assertLe(_absI(rA), 8, string.concat(tag, ": incumbents + newcomer != K (asset)"));
            assertLe(_absI(rP), 8, string.concat(tag, ": incumbents + newcomer != K (paired)"));
        }
        // (5) formula entitlement equals the real replayed in-kind legs (rounding only)
        _dcAssertHk(d, tag);
        // (6) exact algebra: the haircut term of the share-transfer chain equals h*(K*P1 - O(kP)*H1)/(1e4*H1 - h*P1) (oracle basis)
        _dcAssertHair(d, tag);
    }

    /// @dev The haircut term of the chain, recomputed from the closed form (all values at the oracle, asset units):
    ///      T_hair = h * (K * P1 - O(kP) * H1) / (1e4 * H1 - h * P1), with K = oracle value of the newcomer's contribution,
    ///      H1 = oracle value of the vault holdings after, P1 = oracle value of their paired part, O(kP) = oracle value of K's paired part.
    function _dcHairClosedForm(DC memory d) internal view returns (int256) {
        int256 kA = _i(_hA(d.a1)) - _i(_hA(d.c1));
        int256 kP = _i(_hP(d.a1)) - _i(_hP(d.c1));
        int256 K = _vO(kA, kP);
        int256 H1 = _vO(_i(_hA(d.a1)), _i(_hP(d.a1)));
        int256 P1 = _sgnOra(_i(_hP(d.a1)));
        int256 kPo = _sgnOra(kP);
        int256 h = _i(v.valuationHaircutBps());
        return h * (K * P1 - kPo * H1) / (10_000 * H1 - h * P1);
    }

    function _dcAssertHair(DC memory d, string memory tag) internal {
        CH memory c = _dcChain(d, 0);
        int256 pred = _dcHairClosedForm(d);
        console2.log(string.concat("FIK2|", tag, "|ALGEBRA haircut term measured ", _ti(c.tHair), " closed form h*(K*P1 - O(kP)*H1)/(1e4*H1 - h*P1) = ", _ti(pred), " ; difference ", _ti(c.tHair - pred)));
        int256 H1 = _vO(_i(_hA(d.a1)), _i(_hP(d.a1)));
        assertLe(_absI(c.tHair - pred), uint256(H1) / 1e12 + 64, string.concat(tag, ": haircut term != closed form"));
    }

    function _absI(int256 x) internal pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function _hkTol(uint256 x, uint256 supply, uint256 shares) internal pure returns (uint256) {
        return KIND_TOL_WEI + 4 * (supply / (shares == 0 ? 1 : shares) + 1) + x / 1e9;
    }

    function _dcAssertHk(DC memory d, string memory tag) internal pure {
        (uint256 a0A, uint256 a0P) = _ent(d.a0, d.inc);
        (uint256 a1A, uint256 a1P) = _ent(d.a1, d.inc);
        (uint256 nA, uint256 nP) = _ent(d.a1, d.idx);
        require(_absDiff(a0A, d.hk0A) <= _hkTol(a0A, d.a0.supply, d.a0.sh[d.inc]), string.concat(tag, ": Alice before: formula entitlement != replayed in-kind (asset)"));
        require(_absDiff(a0P, d.hk0P) <= _hkTol(a0P, d.a0.supply, d.a0.sh[d.inc]), string.concat(tag, ": Alice before: formula entitlement != replayed in-kind (paired)"));
        require(_absDiff(a1A, d.hk1A) <= _hkTol(a1A, d.a1.supply, d.a1.sh[d.inc]), string.concat(tag, ": Alice after: formula entitlement != replayed in-kind (asset)"));
        require(_absDiff(a1P, d.hk1P) <= _hkTol(a1P, d.a1.supply, d.a1.sh[d.inc]), string.concat(tag, ": Alice after: formula entitlement != replayed in-kind (paired)"));
        require(_absDiff(nA, d.hkNA) <= _hkTol(nA, d.a1.supply, d.a1.sh[d.idx]), string.concat(tag, ": newcomer: formula entitlement != replayed in-kind (asset)"));
        require(_absDiff(nP, d.hkNP) <= _hkTol(nP, d.a1.supply, d.a1.sh[d.idx]), string.concat(tag, ": newcomer: formula entitlement != replayed in-kind (paired)"));
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
