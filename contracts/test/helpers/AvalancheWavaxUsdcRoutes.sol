// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IRtV3Pool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function liquidity() external view returns (uint128);
}

interface IRtUniV3Slot0 {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint16, uint8, bool);
    function fee() external view returns (uint24);
}

interface IRtPharaohPool {
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16, uint16, uint8, uint32, bool);
    function fee() external view returns (uint24);
    function tickSpacing() external view returns (int24);
}

interface IRtV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IRtLBPair {
    function getTokenX() external view returns (address);
    function getTokenY() external view returns (address);
    function getBinStep() external view returns (uint16);
    function getActiveId() external view returns (uint24);
    function getReserves() external view returns (uint128, uint128);
    function getPriceFromId(uint24 id) external view returns (uint256);
    function getSwapOut(uint128 amountIn, bool swapForY) external view returns (uint128 amountInLeft, uint128 amountOut, uint128 fee);
}

interface IRtLBRouter {
    struct Path {
        uint256[] pairBinSteps;
        uint8[] versions; // 0 V1, 1 V2, 2 V2_1, 3 V2_2
        address[] tokenPath;
    }

    function getFactory() external view returns (address);
    function getV1Factory() external view returns (address);
    function getLegacyFactory() external view returns (address);
    function getWNATIVE() external view returns (address);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Path memory path, address to, uint256 deadline)
        external
        returns (uint256 amountOut);
}

/// @dev Test helper only: swaps WAVAX for native USDC on the REAL routers of the fork, route by route. No mocks of any venue.
abstract contract AvalancheWavaxUsdcRoutes is Test {
    address internal constant RT_USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant RT_WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    // routers (see the doc for the verification of each)
    address internal constant PHARAOH_ROUTER_ = 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c;
    address internal constant PHARAOH_FACTORY_ = 0xAE6E5c62328ade73ceefD42228528b70c8157D0d;
    address internal constant UNI_V3_FACTORY = 0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD;
    address internal constant UNI_SWAPROUTER02 = 0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE;
    address internal constant UNI_QUOTER_V2 = 0xbe0F5544EC67e9B3b2D979aaA43f18Fd87E6257F;
    address internal constant UNI_V2_FACTORY = 0x9e5A52f57b3038F1B8EeE45F28b3C1967e22799C;
    address internal constant SUSHI_V3_FACTORY = 0x3e603C14aF37EBdaD31709C4f848Fc6aD5BEc715;
    address internal constant SUSHI_V3_ROUTER = 0x8E4638eefee96732C56291fBF48bBB98725c6b31;
    address internal constant SUSHI_V2_FACTORY = 0xc35DADB65012eC5796536bD9864eD8773aBc74C4;
    address internal constant SUSHI_V2_ROUTER = 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506;
    address internal constant PANGOLIN_FACTORY = 0xefa94DE7a4656D787667C749f7E1223D71E9FD88;
    address internal constant PANGOLIN_ROUTER = 0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106;
    address internal constant LFJ_LB_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E; // V2.2 router, also routes V1/V2/V2.1 hops
    address internal constant LFJ_LB_FACTORY_V22 = 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c;
    address internal constant LFJ_LB_FACTORY_V21 = 0x8e42f2F4101563bF679975178e880FD87d3eFd4e;
    address internal constant LFJ_LB_FACTORY_V20 = 0x6E77932A92582f504FF6c4BdbCef7Da6c198aEEf;
    address internal constant LFJ_V1_FACTORY = 0x9Ad6C38BE94206cA50bb0d90783181662f0Cfa10;
    address internal constant LFJ_V1_ROUTER = 0x60aE616a2155Ee3d9A68541Ba4544862310933d4;

    enum Kind {
        UNI_V3, // SwapRouter02 (no deadline field)
        SUSHI_V3, // v3-periphery SwapRouter (deadline field)
        PHARAOH, // Ramses-style CL router (tick spacing)
        LB, // LFJ LBRouter (any version)
        V2 // Uniswap-V2 style router
    }

    struct Route {
        string name;
        Kind kind;
        address router;
        address pool;
        uint24 fee; // V3 tiers: ppm. V2-style: 3000. Pharaoh: read on chain. LB: dynamic (from getSwapOut)
        int24 spacing; // Pharaoh tick spacing
        uint256 binStep; // LB
        uint8 version; // LB version enum
    }

    // route ids
    uint256 internal constant R_PHARAOH_TS10 = 0;
    uint256 internal constant R_PHARAOH_TS5 = 1;
    uint256 internal constant R_PHARAOH_TS50 = 2;
    uint256 internal constant R_PHARAOH_TS100 = 3;
    uint256 internal constant R_UNI3_100 = 4;
    uint256 internal constant R_UNI3_500 = 5;
    uint256 internal constant R_UNI3_3000 = 6;
    uint256 internal constant R_UNI3_10000 = 7;
    uint256 internal constant R_SUSHI3_100 = 8;
    uint256 internal constant R_SUSHI3_500 = 9;
    uint256 internal constant R_SUSHI3_3000 = 10;
    uint256 internal constant R_SUSHI3_10000 = 11;
    uint256 internal constant R_LB22_BS10 = 12;
    uint256 internal constant R_LB22_BS25 = 13;
    uint256 internal constant R_LB22_BS50 = 14;
    uint256 internal constant R_LB22_BS100 = 15;
    uint256 internal constant R_LB21_BS5 = 16;
    uint256 internal constant R_LB21_BS20 = 17;
    uint256 internal constant R_LB21_BS25 = 18;
    uint256 internal constant R_LB21_BS50 = 19;
    uint256 internal constant R_LB21_BS100 = 20;
    uint256 internal constant R_LB20_BS20 = 21;
    uint256 internal constant R_LFJ_V1 = 22;
    uint256 internal constant R_PANGOLIN = 23;
    uint256 internal constant R_SUSHI2 = 24;
    uint256 internal constant ROUTE_COUNT = 25;

    struct SwapRes {
        bool ok;
        uint256 spent; // WAVAX actually taken from the trader (balance delta)
        uint256 out; // USDC actually received (balance delta)
        uint256 gasUsed; // gas of the router call only (no 21,000 base, no approvals)
        uint256 quotedFee; // input-token fee (WAVAX wei) for LB (getSwapOut), else spent x tier
        bytes revertData;
    }

    function _route(uint256 id) internal pure returns (Route memory r) {
        if (id == R_PHARAOH_TS10) return Route("Pharaoh CL ts10", Kind.PHARAOH, PHARAOH_ROUTER_, 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534, 0, 10, 0, 0);
        if (id == R_PHARAOH_TS5) return Route("Pharaoh CL ts5", Kind.PHARAOH, PHARAOH_ROUTER_, 0x1Abbf74e863e19940ED364C6EE1Ffb782e204d20, 0, 5, 0, 0);
        if (id == R_PHARAOH_TS50) return Route("Pharaoh CL ts50", Kind.PHARAOH, PHARAOH_ROUTER_, 0xb1E1Db50a98D49eC8eA9a1CCBBD4Af56842C43c1, 0, 50, 0, 0);
        if (id == R_PHARAOH_TS100) return Route("Pharaoh CL ts100", Kind.PHARAOH, PHARAOH_ROUTER_, 0x2eB24B12177B7DF1c85fAC74d06675cbEadeD3d7, 0, 100, 0, 0);
        if (id == R_UNI3_100) return Route("Uniswap V3 0.01%", Kind.UNI_V3, UNI_SWAPROUTER02, 0x1951BD56E82cC1eDFEc8546c3202eCBcC5B74A29, 100, 0, 0, 0);
        if (id == R_UNI3_500) return Route("Uniswap V3 0.05%", Kind.UNI_V3, UNI_SWAPROUTER02, 0xfAe3f424a0a47706811521E3ee268f00cFb5c45E, 500, 0, 0, 0);
        if (id == R_UNI3_3000) return Route("Uniswap V3 0.3%", Kind.UNI_V3, UNI_SWAPROUTER02, 0x0E663593657B064e1baE76d28625Df5D0eBd4421, 3000, 0, 0, 0);
        if (id == R_UNI3_10000) return Route("Uniswap V3 1%", Kind.UNI_V3, UNI_SWAPROUTER02, 0xd18384F4398BF5415902aD5d87eAA96549Fd4f1E, 10000, 0, 0, 0);
        if (id == R_SUSHI3_100) return Route("Sushi V3 0.01%", Kind.SUSHI_V3, SUSHI_V3_ROUTER, 0x0bA96F2F9E56BBB75e5bb0Bd951B07adea3D2072, 100, 0, 0, 0);
        if (id == R_SUSHI3_500) return Route("Sushi V3 0.05%", Kind.SUSHI_V3, SUSHI_V3_ROUTER, 0x4A5c0E100F830A1F6B76A42e6bb4Be2A7fE0d61B, 500, 0, 0, 0);
        if (id == R_SUSHI3_3000) return Route("Sushi V3 0.3%", Kind.SUSHI_V3, SUSHI_V3_ROUTER, 0xD937a05dF90918f584A17a168026cc06f9cB099D, 3000, 0, 0, 0);
        if (id == R_SUSHI3_10000) return Route("Sushi V3 1%", Kind.SUSHI_V3, SUSHI_V3_ROUTER, 0x8EAf84001447da898054D06EdF6e4Ebc010f33a1, 10000, 0, 0, 0);
        if (id == R_LB22_BS10) return Route("LFJ LB V2.2 bin10", Kind.LB, LFJ_LB_ROUTER, 0x864d4e5Ee7318e97483DB7EB0912E09F161516EA, 0, 0, 10, 3);
        if (id == R_LB22_BS25) return Route("LFJ LB V2.2 bin25", Kind.LB, LFJ_LB_ROUTER, 0xE52BeDE8CFd7C5C8894c8616E49Fb25811c97367, 0, 0, 25, 3);
        if (id == R_LB22_BS50) return Route("LFJ LB V2.2 bin50", Kind.LB, LFJ_LB_ROUTER, 0x411E7f9e9F0584804bA23DF1182c28d28df0d69C, 0, 0, 50, 3);
        if (id == R_LB22_BS100) return Route("LFJ LB V2.2 bin100", Kind.LB, LFJ_LB_ROUTER, 0xE4379C25faaB825cF19cDd57b52187BDcF056729, 0, 0, 100, 3);
        if (id == R_LB21_BS5) return Route("LFJ LB V2.1 bin5", Kind.LB, LFJ_LB_ROUTER, 0x55a50aDBa067530b96d30225f9de86640431e86f, 0, 0, 5, 2);
        if (id == R_LB21_BS20) return Route("LFJ LB V2.1 bin20", Kind.LB, LFJ_LB_ROUTER, 0xD446eb1660F766d533BeCeEf890Df7A69d26f7d1, 0, 0, 20, 2);
        if (id == R_LB21_BS25) return Route("LFJ LB V2.1 bin25", Kind.LB, LFJ_LB_ROUTER, 0xe3a7045112cA6Bcc7f9A80B61c3fBA6EaD3d7124, 0, 0, 25, 2);
        if (id == R_LB21_BS50) return Route("LFJ LB V2.1 bin50", Kind.LB, LFJ_LB_ROUTER, 0x79925795dF91424DB1d7d427859FFF709d731c8e, 0, 0, 50, 2);
        if (id == R_LB21_BS100) return Route("LFJ LB V2.1 bin100", Kind.LB, LFJ_LB_ROUTER, 0x75577CA07649B4824A0B24e78d5b8CeA54243699, 0, 0, 100, 2);
        if (id == R_LB20_BS20) return Route("LFJ LB V2.0 bin20", Kind.LB, LFJ_LB_ROUTER, 0xB5352A39C11a81FE6748993D586EC448A01f08b5, 0, 0, 20, 1);
        if (id == R_LFJ_V1) return Route("LFJ V1 (constant product)", Kind.V2, LFJ_V1_ROUTER, 0xf4003F4efBE8691B60249E6afbD307aBE7758adb, 3000, 0, 0, 0);
        if (id == R_PANGOLIN) return Route("Pangolin V2", Kind.V2, PANGOLIN_ROUTER, 0x0e0100Ab771E9288e0Aa97e11557E6654C3a9665, 3000, 0, 0, 0);
        if (id == R_SUSHI2) return Route("Sushi V2", Kind.V2, SUSHI_V2_ROUTER, 0x6539bF462F73fF9497054bA261C195DA8639ED61, 3000, 0, 0, 0);
        revert("unknown route");
    }

    // ----------------------------------------------------------------- views
    /// @dev Pool spot price in Chainlink units (USD x 1e8 per WAVAX), before fee. 0 if undefined.
    function _spot8(uint256 id) internal view returns (uint256) {
        Route memory r = _route(id);
        if (r.kind == Kind.UNI_V3 || r.kind == Kind.SUSHI_V3) {
            (uint160 s,,,,,,) = IRtUniV3Slot0(r.pool).slot0();
            return Math.mulDiv(Math.mulDiv(uint256(s), uint256(s), 1 << 64), 1e20, 1 << 128);
        }
        if (r.kind == Kind.PHARAOH) {
            (uint160 s,,,,,,) = IRtPharaohPool(r.pool).slot0();
            return Math.mulDiv(Math.mulDiv(uint256(s), uint256(s), 1 << 64), 1e20, 1 << 128);
        }
        if (r.kind == Kind.LB) {
            if (r.version == 1) return 0; // V2.0 pair: different ABI, no spot read
            uint256 p = IRtLBPair(r.pool).getPriceFromId(IRtLBPair(r.pool).getActiveId());
            return Math.mulDiv(p, 1e20, 1 << 128);
        }
        (uint112 r0, uint112 r1,) = IRtV2Pair(r.pool).getReserves();
        // token0 = WAVAX (0xB31f < 0xB97E) on every V2 pair here (asserted in the address test)
        return r0 == 0 ? 0 : Math.mulDiv(uint256(r1), 1e20, uint256(r0));
    }

    /// @dev Route fee in ppm of the input (V3 tiers, Pharaoh pool fee, V2 0.3%). LB: 0 (dynamic: see getSwapOut).
    function _feePpm(uint256 id) internal view returns (uint256) {
        Route memory r = _route(id);
        if (r.kind == Kind.PHARAOH) return IRtPharaohPool(r.pool).fee();
        if (r.kind == Kind.LB) return 0;
        return r.fee;
    }

    // ----------------------------------------------------------------- execution
    function _calldata(Route memory r, address trader, uint256 amountIn, uint256 minOut) internal view returns (bytes memory) {
        if (r.kind == Kind.UNI_V3) {
            // SwapRouter02.exactInputSingle((tokenIn, tokenOut, fee, recipient, amountIn, amountOutMinimum, sqrtPriceLimitX96))
            return abi.encodeWithSelector(
                bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))")),
                RT_WAVAX, RT_USDC, r.fee, trader, amountIn, minOut, uint160(0)
            );
        }
        if (r.kind == Kind.SUSHI_V3) {
            return abi.encodeWithSelector(
                bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))")),
                RT_WAVAX, RT_USDC, r.fee, trader, block.timestamp + 1 hours, amountIn, minOut, uint160(0)
            );
        }
        if (r.kind == Kind.PHARAOH) {
            return abi.encodeWithSelector(
                bytes4(keccak256("exactInputSingle((address,address,int24,address,uint256,uint256,uint256,uint160))")),
                RT_WAVAX, RT_USDC, r.spacing, trader, block.timestamp + 1 hours, amountIn, minOut, uint160(0)
            );
        }
        if (r.kind == Kind.LB) {
            uint256[] memory steps = new uint256[](1);
            steps[0] = r.binStep;
            uint8[] memory vers = new uint8[](1);
            vers[0] = r.version;
            address[] memory toks = new address[](2);
            toks[0] = RT_WAVAX;
            toks[1] = RT_USDC;
            return abi.encodeCall(
                IRtLBRouter.swapExactTokensForTokens,
                (amountIn, minOut, IRtLBRouter.Path(steps, vers, toks), trader, block.timestamp + 1 hours)
            );
        }
        address[] memory path = new address[](2);
        path[0] = RT_WAVAX;
        path[1] = RT_USDC;
        return abi.encodeWithSelector(
            bytes4(keccak256("swapExactTokensForTokens(uint256,uint256,address[],address,uint256)")),
            amountIn, minOut, path, trader, block.timestamp + 1 hours
        );
    }

    /// @dev Real swap WAVAX -> USDC on route `id` for `trader` (who must already hold the WAVAX). Never reverts: failures are returned.
    ///      Warm/cold state is reset with vm.cool for the router and pool so that gas resembles a first call in a transaction.
    function _swapRoute(uint256 id, address trader, uint256 amountIn, uint256 minOut) internal returns (SwapRes memory s) {
        Route memory r = _route(id);
        uint256 w0 = IERC20(RT_WAVAX).balanceOf(trader);
        uint256 u0 = IERC20(RT_USDC).balanceOf(trader);
        if (r.kind == Kind.LB) {
            (bool qok, bytes memory qret) = r.pool.staticcall(abi.encodeCall(IRtLBPair.getSwapOut, (uint128(amountIn), true)));
            if (qok && qret.length >= 96) {
                (, , uint128 f) = abi.decode(qret, (uint128, uint128, uint128));
                s.quotedFee = f;
            }
        }
        bytes memory data = _calldata(r, trader, amountIn, minOut);
        vm.prank(trader);
        IERC20(RT_WAVAX).approve(r.router, amountIn);
        vm.cool(r.router);
        vm.cool(r.pool);
        vm.cool(RT_WAVAX);
        vm.cool(RT_USDC);
        vm.prank(trader);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = r.router.call(data);
        s.gasUsed = g - gasleft();
        s.ok = ok;
        if (!ok) s.revertData = ret;
        vm.prank(trader);
        IERC20(RT_WAVAX).approve(r.router, 0);
        s.spent = w0 - IERC20(RT_WAVAX).balanceOf(trader);
        s.out = IERC20(RT_USDC).balanceOf(trader) - u0;
        if (r.kind != Kind.LB) s.quotedFee = Math.mulDiv(s.spent, _feePpm(id), 1e6);
    }
}
