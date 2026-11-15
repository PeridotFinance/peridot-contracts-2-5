// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "./helpers/AvalancheWavaxUsdcRoutes.sol";

interface IRtRouterFactory {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
    function WETH() external view returns (address);
    function WAVAX() external view returns (address);
    function deployer() external view returns (address);
}

interface IRtV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

interface IRtPharaohFactory {
    function getPool(address, address, int24) external view returns (address);
}

interface IRtV2Factory {
    function getPair(address, address) external view returns (address);
}

interface IRtLBFactory {
    function getAllLBPairs(address, address) external view returns (IRtLBInfo[] memory);
}

struct IRtLBInfo {
    uint256 binStep;
    address pair;
    bool createdByOwner;
    bool ignoredForRouting;
}

/**
 * @notice PART A of the cash-only liquidation-cycle study: REAL WAVAX -> native USDC swaps on the pinned Avalanche fork (block 99,200,000),
 *         route by route, at USD 500 / 1,000 / 5,000 / 10,000 / 50,000 / 100,000 (Chainlink valuation at the pin: 8.549), plus depth limits
 *         and the best split. No venue is mocked; the input WAVAX is `deal`t to the trader (funding, not a venue mock). Every execution starts
 *         from a fresh snapshot of the pin. Output lines `ADDR|`, `ROUTE|`, `DEPTH|`, `SPLIT|` are parsed into the doc.
 *         Read RPC + local VM writes only: nothing is signed or broadcast.
 */
contract AvalancheWavaxUsdcRoutesForkTest is AvalancheWavaxUsdcRoutes {
    uint256 internal constant PIN_BLOCK = 99_200_000;
    address internal constant AVAX_FEED_ = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant TRADER = address(0x7A0DE);

    uint256 internal P8; // Chainlink AVAX/USD at the pin, 8 decimals
    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, PIN_BLOCK);
        require(block.chainid == 43_114, "not Avalanche C-Chain");
        (, int256 a,,,) = AggregatorV3Interface(AVAX_FEED_).latestRoundData();
        P8 = uint256(a);
        live = true;
    }

    // ================================================================= helpers
    function _usdSizes() internal pure returns (uint256[6] memory s) {
        s = [uint256(500), 1_000, 5_000, 10_000, 50_000, 100_000];
    }

    function _wavaxFor(uint256 usd) internal view returns (uint256) {
        return Math.mulDiv(usd * 1e6, 1e12 * 1e8, P8) ; // USDC units x 1e12 (to 18 dec) x 1e8 / price8
    }

    function _oracleUsdc(uint256 wavax) internal view returns (uint256) {
        return Math.mulDiv(wavax, P8, 1e8 * 1e12);
    }

    function _i(int256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    struct M {
        bool full; // router call succeeded and the whole input was consumed
        SwapRes s;
        uint256 oracleVal; // Chainlink value of the amount spent, USDC units
        int256 slipBp; // (oracleVal - out) / oracleVal in bp, signed
        int256 impactBp; // vs the pool spot price net of the fee, signed
        uint256 effP8;
        uint256 feeUsdc; // fee paid, valued at Chainlink, USDC units
    }

    /// @dev One execution from a fresh snapshot of the pin. minOut 0 (measurement); the min-out verdicts are computed from the result.
    function _measure(uint256 id, uint256 usd) internal returns (M memory m) {
        uint256 amountIn = _wavaxFor(usd);
        uint256 snap = vm.snapshotState();
        deal(RT_WAVAX, TRADER, amountIn);
        uint256 spot8 = _spot8(id);
        m.s = _swapRoute(id, TRADER, amountIn, 0);
        vm.revertToState(snap);
        m.full = m.s.ok && m.s.spent == amountIn && m.s.out > 0;
        m.oracleVal = _oracleUsdc(m.s.spent);
        if (m.s.spent > 0) {
            m.effP8 = Math.mulDiv(m.s.out, 1e20, m.s.spent);
            m.slipBp = (int256(m.oracleVal) - int256(m.s.out)) * 10_000 / int256(m.oracleVal);
            // spot net of fee: the pool's marginal price after the input fee
            uint256 feeShare = m.s.spent == 0 ? 0 : Math.mulDiv(m.s.quotedFee, 1e18, m.s.spent);
            uint256 spotNet8 = Math.mulDiv(spot8, 1e18 - feeShare, 1e18);
            m.impactBp = spotNet8 == 0 ? int256(0) : (int256(spotNet8) - int256(m.effP8)) * 10_000 / int256(spotNet8);
            m.feeUsdc = _oracleUsdc(m.s.quotedFee);
        }
    }

    function _log(uint256 id, uint256 usd, M memory m) internal {
        Route memory r = _route(id);
        uint256 fillBp = amountOrOne(_wavaxFor(usd)) == 0 ? 0 : Math.mulDiv(m.s.spent, 10_000, _wavaxFor(usd));
        string memory head = string.concat("ROUTE|", r.name, "|", vm.toString(usd), "|", m.full ? "FULL" : (m.s.ok ? "PARTIAL" : "REVERT"));
        string memory body = string.concat(
            "|fillBp=", vm.toString(fillBp), "|spentWavax=", vm.toString(m.s.spent), "|outUsdc=", vm.toString(m.s.out),
            "|effP8=", vm.toString(m.effP8), "|feeUsdc=", vm.toString(m.feeUsdc)
        );
        string memory tail = string.concat(
            "|impactBp=", _i(m.impactBp), "|slipBp=", _i(m.slipBp), "|gas=", vm.toString(m.s.gasUsed),
            "|m05=", _met(m, 50), "|m1=", _met(m, 100), "|m2=", _met(m, 200), "|m3=", _met(m, 300)
        );
        emit log_string(string.concat(head, body, tail));
    }

    function amountOrOne(uint256 a) internal pure returns (uint256) {
        return a;
    }

    /// @dev min-out limit "oracle minus L bp" is met iff the swap completed in full and out >= oracle value x (1 - L).
    function _met(M memory m, uint256 limitBp) internal pure returns (string memory) {
        bool ok = m.full && m.s.out >= Math.mulDiv(m.oracleVal, 10_000 - limitBp, 10_000);
        return ok ? "Y" : "N";
    }

    function _sweep(uint256 id) internal {
        if (!live) return;
        uint256[6] memory sizes = _usdSizes();
        for (uint256 i; i < 6; ++i) {
            M memory m = _measure(id, sizes[i]);
            _log(id, sizes[i], m);
            // harness identity: the trader never ends with more WAVAX than it started with, and received exactly `out` USDC (balance deltas)
            assertLe(m.s.spent, _wavaxFor(sizes[i]), "spent <= input");
        }
    }

    // ================================================================= address verification (reproduced by cast in the evidence)
    function test_A00_verifyAddresses() public {
        if (!live) return;
        // tokens
        assertGt(RT_WAVAX.code.length, 0, "WAVAX code");
        assertGt(RT_USDC.code.length, 0, "USDC code");
        emit log_string(string.concat("ADDR|Chainlink AVAX/USD|", vm.toString(AVAX_FEED_), "|answer8=", vm.toString(P8)));
        // routers
        _router("UniswapV3 SwapRouter02", UNI_SWAPROUTER02, UNI_V3_FACTORY, true);
        _router("Sushi V3 SwapRouter", SUSHI_V3_ROUTER, SUSHI_V3_FACTORY, true);
        _router("Sushi V2 Router", SUSHI_V2_ROUTER, SUSHI_V2_FACTORY, false);
        _router("Pangolin Router", PANGOLIN_ROUTER, PANGOLIN_FACTORY, false);
        _router("LFJ V1 Router", LFJ_V1_ROUTER, LFJ_V1_FACTORY, false);
        assertEq(IRtRouterFactory(PHARAOH_ROUTER_).WETH9(), RT_WAVAX, "pharaoh router WETH9");
        emit log_string(string.concat("ADDR|Pharaoh CL router|", vm.toString(PHARAOH_ROUTER_), "|WETH9=WAVAX|deployer=", vm.toString(IRtRouterFactory(PHARAOH_ROUTER_).deployer())));
        IRtLBRouter lb = IRtLBRouter(LFJ_LB_ROUTER);
        assertEq(lb.getWNATIVE(), RT_WAVAX, "lb router WNATIVE");
        assertEq(lb.getFactory(), LFJ_LB_FACTORY_V22, "lb router factory v2.2");
        assertEq(lb.getV1Factory(), LFJ_V1_FACTORY, "lb router v1 factory");
        assertEq(lb.getLegacyFactory(), LFJ_LB_FACTORY_V20, "lb router legacy factory");
        emit log_string(string.concat("ADDR|LFJ LBRouter|", vm.toString(LFJ_LB_ROUTER), "|WNATIVE=WAVAX|factoryV2.2=", vm.toString(lb.getFactory()), "|v1Factory=", vm.toString(lb.getV1Factory()), "|legacyV2.0=", vm.toString(lb.getLegacyFactory())));
        // every pool
        for (uint256 id; id < ROUTE_COUNT; ++id) _verifyPool(id);
    }

    function _router(string memory name, address router, address factory, bool v3) internal {
        assertGt(router.code.length, 0, "router code");
        assertEq(IRtRouterFactory(router).factory(), factory, "router.factory()");
        address wnative;
        if (v3) {
            wnative = IRtRouterFactory(router).WETH9();
        } else {
            (bool ok, bytes memory ret) = router.staticcall(abi.encodeCall(IRtRouterFactory.WAVAX, ()));
            if (!(ok && ret.length == 32)) (ok, ret) = router.staticcall(abi.encodeCall(IRtRouterFactory.WETH, ()));
            require(ok && ret.length == 32, "no native getter");
            wnative = abi.decode(ret, (address));
        }
        assertEq(wnative, RT_WAVAX, "router wrapped native");
        emit log_string(string.concat("ADDR|", name, "|", vm.toString(router), "|factory()=", vm.toString(factory), "|wrappedNative=WAVAX"));
    }

    function _verifyPool(uint256 id) internal {
        Route memory r = _route(id);
        assertGt(r.pool.code.length, 0, string.concat("pool code ", r.name));
        string memory line = string.concat("ADDR|pool ", r.name, "|", vm.toString(r.pool));
        if (r.kind == Kind.UNI_V3 || r.kind == Kind.SUSHI_V3) {
            address f = r.kind == Kind.UNI_V3 ? UNI_V3_FACTORY : SUSHI_V3_FACTORY;
            assertEq(IRtV3Pool(r.pool).token0(), RT_WAVAX, "token0");
            assertEq(IRtV3Pool(r.pool).token1(), RT_USDC, "token1");
            assertEq(IRtUniV3Slot0(r.pool).fee(), r.fee, "fee");
            assertEq(IRtV3Factory(f).getPool(RT_WAVAX, RT_USDC, r.fee), r.pool, "factory lookup");
            (uint160 s, int24 t,,,,,) = IRtUniV3Slot0(r.pool).slot0();
            line = string.concat(line, "|token0=WAVAX|token1=USDC|fee=", vm.toString(uint256(r.fee)), "|factoryLookup=OK|liquidity=", vm.toString(uint256(IRtV3Pool(r.pool).liquidity())), "|tick=", vm.toString(int256(t)), "|spot8=", vm.toString(_spot8(id)));
            s;
        } else if (r.kind == Kind.PHARAOH) {
            assertEq(IRtV3Pool(r.pool).token0(), RT_WAVAX, "token0");
            assertEq(IRtV3Pool(r.pool).token1(), RT_USDC, "token1");
            assertEq(IRtPharaohPool(r.pool).tickSpacing(), r.spacing, "ts");
            assertEq(IRtPharaohFactory(PHARAOH_FACTORY_).getPool(RT_WAVAX, RT_USDC, r.spacing), r.pool, "factory lookup");
            line = string.concat(line, "|token0=WAVAX|token1=USDC|tickSpacing=", vm.toString(int256(r.spacing)), "|fee=", vm.toString(uint256(IRtPharaohPool(r.pool).fee())), "|factoryLookup=OK|liquidity=", vm.toString(uint256(IRtV3Pool(r.pool).liquidity())), "|spot8=", vm.toString(_spot8(id)));
        } else if (r.kind == Kind.LB) {
            IRtLBPair p = IRtLBPair(r.pool);
            address f = r.version == 3 ? LFJ_LB_FACTORY_V22 : (r.version == 2 ? LFJ_LB_FACTORY_V21 : LFJ_LB_FACTORY_V20);
            IRtLBInfo[] memory all = IRtLBFactory(f).getAllLBPairs(RT_WAVAX, RT_USDC);
            bool found;
            for (uint256 k; k < all.length; ++k) {
                if (all[k].pair == r.pool && all[k].binStep == r.binStep) found = true;
            }
            assertTrue(found, "pair listed by its factory with that bin step");
            if (r.version != 1) {
                assertEq(p.getTokenX(), RT_WAVAX, "tokenX");
                assertEq(p.getTokenY(), RT_USDC, "tokenY");
                assertEq(uint256(p.getBinStep()), r.binStep, "bin step");
                (uint128 rx, uint128 ry) = p.getReserves();
                line = string.concat(line, "|tokenX=WAVAX|tokenY=USDC|binStep=", vm.toString(r.binStep), "|factoryLookup=OK|activeId=", vm.toString(uint256(p.getActiveId())), "|totalReservesWavax=", vm.toString(uint256(rx)), "|totalReservesUsdc=", vm.toString(uint256(ry)), "|activeBinPrice8=", vm.toString(_spot8(id)));
            } else {
                line = string.concat(line, "|V2.0 pair listed by legacy factory (no getTokenX): swaps not supported by the V2.2 adapter route; liquidity read as 0 or reverting");
            }
        } else {
            IRtV2Pair p = IRtV2Pair(r.pool);
            address f = id == R_LFJ_V1 ? LFJ_V1_FACTORY : (id == R_PANGOLIN ? PANGOLIN_FACTORY : SUSHI_V2_FACTORY);
            assertEq(p.factory(), f, "pair.factory()");
            assertEq(IRtV2Factory(f).getPair(RT_WAVAX, RT_USDC), r.pool, "factory lookup");
            assertEq(p.token0(), RT_WAVAX, "token0");
            assertEq(p.token1(), RT_USDC, "token1");
            (uint112 r0, uint112 r1,) = p.getReserves();
            line = string.concat(line, "|token0=WAVAX|token1=USDC|factoryLookup=OK|reserveWavax=", vm.toString(uint256(r0)), "|reserveUsdc=", vm.toString(uint256(r1)), "|spot8=", vm.toString(_spot8(id)));
        }
        emit log_string(line);
    }

    // ================================================================= sweeps: one test per route so that a slow or failing route does not hide the others
    function test_route_pharaoh_ts10() public { _sweep(R_PHARAOH_TS10); }
    function test_route_pharaoh_ts5() public { _sweep(R_PHARAOH_TS5); }
    function test_route_pharaoh_ts50() public { _sweep(R_PHARAOH_TS50); }
    function test_route_pharaoh_ts100() public { _sweep(R_PHARAOH_TS100); }
    function test_route_uni3_100() public { _sweep(R_UNI3_100); }
    function test_route_uni3_500() public { _sweep(R_UNI3_500); }
    function test_route_uni3_3000() public { _sweep(R_UNI3_3000); }
    function test_route_uni3_10000() public { _sweep(R_UNI3_10000); }
    function test_route_sushi3_100() public { _sweep(R_SUSHI3_100); }
    function test_route_sushi3_500() public { _sweep(R_SUSHI3_500); }
    function test_route_sushi3_3000() public { _sweep(R_SUSHI3_3000); }
    function test_route_sushi3_10000() public { _sweep(R_SUSHI3_10000); }
    function test_route_lb22_bs10() public { _sweep(R_LB22_BS10); }
    function test_route_lb22_bs25() public { _sweep(R_LB22_BS25); }
    function test_route_lb22_bs50() public { _sweep(R_LB22_BS50); }
    function test_route_lb22_bs100() public { _sweep(R_LB22_BS100); }
    function test_route_lb21_bs5() public { _sweep(R_LB21_BS5); }
    function test_route_lb21_bs20() public { _sweep(R_LB21_BS20); }
    function test_route_lb21_bs25() public { _sweep(R_LB21_BS25); }
    function test_route_lb21_bs50() public { _sweep(R_LB21_BS50); }
    function test_route_lb21_bs100() public { _sweep(R_LB21_BS100); }
    function test_route_lb20_bs20() public { _sweep(R_LB20_BS20); }
    function test_route_lfj_v1() public { _sweep(R_LFJ_V1); }
    function test_route_pangolin() public { _sweep(R_PANGOLIN); }
    function test_route_sushi2() public { _sweep(R_SUSHI2); }

    // ================================================================= depth limits: largest size whose slippage vs Chainlink stays <= threshold
    uint256 internal constant DEPTH_LO = 500;
    uint256 internal constant DEPTH_HI = 2_000_000;

    function _within(uint256 id, uint256 usd, int256 thrBp) internal returns (bool) {
        M memory m = _measure(id, usd);
        return m.full && m.slipBp <= thrBp;
    }

    function _depth(uint256 id) internal {
        if (!live) return;
        int256[2] memory thr = [int256(100), 300];
        for (uint256 t; t < 2; ++t) {
            uint256 lo = DEPTH_LO;
            uint256 hi = DEPTH_HI;
            string memory res;
            if (!_within(id, lo, thr[t])) {
                res = "below-500";
            } else if (_within(id, hi, thr[t])) {
                res = string.concat(">=", vm.toString(hi));
            } else {
                for (uint256 k; k < 12; ++k) {
                    uint256 mid = Math.sqrt(lo * hi);
                    if (mid <= lo || mid >= hi) break;
                    if (_within(id, mid, thr[t])) lo = mid; else hi = mid;
                }
                res = vm.toString(lo);
            }
            emit log_string(string.concat("DEPTH|", _route(id).name, "|slippage<=", _i(thr[t]), "bp|maxUsd=", res));
        }
    }

    function test_depth_pharaoh_ts10() public { _depth(R_PHARAOH_TS10); }
    function test_depth_uni3_500() public { _depth(R_UNI3_500); }
    function test_depth_uni3_3000() public { _depth(R_UNI3_3000); }
    function test_depth_lb22_bs10() public { _depth(R_LB22_BS10); }
    function test_depth_lfj_v1() public { _depth(R_LFJ_V1); }
    function test_depth_pangolin() public { _depth(R_PANGOLIN); }
    function test_depth_sushi3_3000() public { _depth(R_SUSHI3_3000); }
    function test_depth_sushi2() public { _depth(R_SUSHI2); }

    // ================================================================= best split of one notional across two routes (10% grid)
    function _split(uint256 a, uint256 b, uint256 usd) internal {
        if (!live) return;
        uint256 total = _wavaxFor(usd);
        uint256 bestOut;
        uint256 bestK = 99;
        for (uint256 k; k <= 10; ++k) {
            uint256 inA = (total * k) / 10;
            uint256 inB = total - inA;
            uint256 snap = vm.snapshotState();
            deal(RT_WAVAX, TRADER, total);
            uint256 out;
            bool full = true;
            if (inA > 0) {
                SwapRes memory sa = _swapRoute(a, TRADER, inA, 0);
                out += sa.out;
                full = full && sa.ok && sa.spent == inA;
            }
            if (inB > 0) {
                SwapRes memory sb = _swapRoute(b, TRADER, inB, 0);
                out += sb.out;
                full = full && sb.ok && sb.spent == inB;
            }
            vm.revertToState(snap);
            uint256 ov = _oracleUsdc(total);
            int256 slip = (int256(ov) - int256(out)) * 10_000 / int256(ov);
            emit log_string(string.concat("SPLIT|", _route(a).name, "|", _route(b).name, "|usd=", vm.toString(usd), "|shareA=", vm.toString(k * 10), "%|", full ? "FULL" : "PARTIAL", "|outUsdc=", vm.toString(out), "|slipBp=", _i(slip)));
            if (full && out > bestOut) {
                bestOut = out;
                bestK = k;
            }
        }
        emit log_string(string.concat("SPLITBEST|", _route(a).name, "|", _route(b).name, "|usd=", vm.toString(usd), "|shareA=", vm.toString(bestK * 10), "%|outUsdc=", vm.toString(bestOut)));
    }

    function test_split_uni3_500_lb22_bs10() public { _split(R_UNI3_500, R_LB22_BS10, 50_000); _split(R_UNI3_500, R_LB22_BS10, 100_000); }
    function test_split_uni3_500_lfj_v1() public { _split(R_UNI3_500, R_LFJ_V1, 50_000); _split(R_UNI3_500, R_LFJ_V1, 100_000); }
    function test_split_uni3_500_pharaoh_ts10() public { _split(R_UNI3_500, R_PHARAOH_TS10, 50_000); _split(R_UNI3_500, R_PHARAOH_TS10, 100_000); }
    function test_split_uni3_500_pangolin() public { _split(R_UNI3_500, R_PANGOLIN, 50_000); _split(R_UNI3_500, R_PANGOLIN, 100_000); }
}
