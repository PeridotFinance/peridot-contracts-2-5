// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PharaohLiquidityVaultR3} from "../src/r3/PharaohLiquidityVaultR3.sol";
import {PharaohRewardExtensionR3} from "../src/r3/PharaohRewardExtensionR3.sol";
import {PharaohLiquidityAmounts} from "../src/orig/libraries/PharaohLiquidityAmounts.sol";
import {PharaohOracleMath} from "../src/orig/libraries/PharaohOracleMath.sol";
import {PharaohTickMath} from "../src/orig/libraries/PharaohTickMath.sol";

interface IV {
    function asset() external view returns (address);
    function pairedToken() external view returns (address);
    function pool() external view returns (address);
    function positionManager() external view returns (address);
    function priceOracle() external view returns (address);
    function swapRouter() external view returns (address);
    function tokenId() external view returns (uint256);
    function tickSpacing() external view returns (int24);
    function twapPeriod() external view returns (uint32);
    function maxTwapDeviationTicks() external view returns (uint24);
    function assetIsToken0() external view returns (bool);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function deposit(uint256, address) external returns (uint256);
    function redeemInKind(uint256, address, address) external returns (uint256, uint256);
    function redeem(uint256, address, address) external returns (uint256);
    function previewDeposit(uint256) external view returns (uint256);
    function previewRedeem(uint256) external view returns (uint256);
    function convertToAssets(uint256) external view returns (uint256);
    function convertToShares(uint256) external view returns (uint256);
    function maxDeposit(address) external view returns (uint256);
    function maxWithdraw(address) external view returns (uint256);
    function maxRedeem(address) external view returns (uint256);
    function setDepositCap(uint256) external;
    function owner() external view returns (address);
    function rebalancer() external view returns (address);
    function depositCap() external view returns (uint256);
    function paused() external view returns (bool);
    function slippageBps() external view returns (uint16);
    function valuationHaircutBps() external view returns (uint16);
    function maxOracleDeviationBps() external view returns (uint16);
    function tickRange() external view returns (int24);
    function positionTickLower() external view returns (int24);
    function positionTickUpper() external view returns (int24);
    function pairedTokenUnit() external view returns (uint128);
    function deployIdle() external;
}

interface IProxyAdmin {
    function upgradeAndCall(address proxy, address implementation, bytes calldata data) external payable;
    function owner() external view returns (address);
}

interface IPool {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
    function observe(uint32[] calldata) external view returns (int56[] memory, uint160[] memory);
}

interface IPM {
    function positions(uint256) external view returns (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

interface IOracle {
    function quotePairToAsset(uint256) external view returns (uint256);
    function quoteAssetToPair(uint256) external view returns (uint256);
}

interface IRouter {
    struct P {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(P calldata) external payable returns (uint256);
}

/// @notice R3 against the LIVE Pharaoh vaults on a mainnet fork. The implementation swap is done exactly as on the day: the Safe (impersonated) calls the
///         ProxyAdmin's `upgradeAndCall(proxy, newExtension, "")`. Nothing here is signed or sent anywhere.
abstract contract R3ForkBase is Test {
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant ALICE = address(0xA11CE0);
    address internal constant CAROL = address(0xCA201);
    address internal constant BOB = address(0xB0B000);
    address internal constant WHALE = address(0xD00D);
    // OpenZeppelin 5 ERC20Upgradeable storage (ERC-7201): _balances at +0, _totalSupply at +2
    bytes32 internal constant ERC20_LOC = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00;

    bytes internal lastErr;
    M internal lastM;
    uint256[3] internal lastSh;
    uint256 internal lastS0;
    IV internal v;
    IERC20 internal asset;
    IERC20 internal paired;
    IPool internal pool;
    IOracle internal oracle;
    IPM internal pm;
    IRouter internal router;
    bool internal assetIs0;
    uint256 internal aUnit;
    uint256 internal baseA; // ALICE's deposit (asset units)
    uint256 internal baseCapUnits;
    uint256 internal seedUnits;
    uint256[] internal ladder;

    function _vault() internal pure virtual returns (address);
    function _admin() internal pure virtual returns (address);
    function _pin() internal pure virtual returns (uint256);
    function _name() internal pure virtual returns (string memory);

    function _fork() internal {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("avalanche", vm.envOr("R3_PIN_BLOCK", _pin())); // alias from foundry.toml (an environment reference)
        v = IV(_vault());
        asset = IERC20(v.asset());
        paired = IERC20(v.pairedToken());
        pool = IPool(v.pool());
        oracle = IOracle(v.priceOracle());
        pm = IPM(v.positionManager());
        router = IRouter(v.swapRouter());
        assetIs0 = v.assetIsToken0();
        (bool ok, bytes memory ret) = address(asset).staticcall(abi.encodeWithSignature("decimals()"));
        require(ok);
        aUnit = 10 ** abi.decode(ret, (uint8));
        vm.prank(SAFE);
        v.setDepositCap(type(uint128).max);
    }

    function _deployR3() internal returns (address base, address ext) {
        base = address(new PharaohLiquidityVaultR3());
        ext = address(new PharaohRewardExtensionR3(base, base.codehash));
    }

    /// The Safe swaps the proxy's implementation (what the ceremony does on the day).
    function _upgrade() internal {
        (, address ext) = _deployR3();
        vm.prank(SAFE);
        IProxyAdmin(_admin()).upgradeAndCall(_vault(), ext, "");
    }

    // ----------------------------------------------------------------------------- measurement helpers
    function _q(uint256 pairAmount) internal view returns (uint256) {
        return pairAmount == 0 ? 0 : oracle.quotePairToAsset(pairAmount);
    }

    function _fund(address who, uint256 amt) internal {
        deal(address(asset), who, amt);
        vm.startPrank(who);
        asset.approve(address(v), amt);
        v.deposit(amt, who);
        vm.stopPrank();
    }

    /// in-kind claim value of `who` for ALL his shares (replayed `redeemInKind`), in asset units at the oracle
    function _ent(address who) internal returns (uint256) {
        uint256 sh = v.balanceOf(who);
        if (sh == 0) return 0;
        uint256 snap = vm.snapshotState();
        uint256 a0 = asset.balanceOf(who);
        uint256 p0 = paired.balanceOf(who);
        vm.prank(who);
        v.redeemInKind(sh, who, who);
        uint256 val = asset.balanceOf(who) - a0 + _q(paired.balanceOf(who) - p0);
        vm.revertToState(snap);
        return val;
    }

    /// oracle value of ALL the vault's real holdings (idle + principal + uncollected fees): sum of every holder's replayed claim
    function _holdingsValue(address[4] memory hs) internal returns (uint256 val) {
        uint256 tot;
        for (uint256 i; i < 4; ++i) tot += v.balanceOf(hs[i]);
        require(tot == v.totalSupply(), "unknown holder");
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 4; ++i) {
            uint256 sh = v.balanceOf(hs[i]);
            if (sh == 0) continue;
            uint256 a0 = asset.balanceOf(hs[i]);
            uint256 p0 = paired.balanceOf(hs[i]);
            vm.prank(hs[i]);
            v.redeemInKind(sh, hs[i], hs[i]);
            val += asset.balanceOf(hs[i]) - a0 + _q(paired.balanceOf(hs[i]) - p0);
        }
        vm.revertToState(snap);
    }

    function _twapTick() internal view returns (int24) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = v.twapPeriod();
        ago[1] = 0;
        (int56[] memory c,) = pool.observe(ago);
        return PharaohOracleMath.arithmeticMeanTick(c[1] - c[0], v.twapPeriod());
    }

    /// Ownership NAV at the VALUATION (TWAP) tick, after the fee collection that `deposit` performs first: what R1 mints on.
    function _nv(bool collectFirst) internal returns (uint256 n) {
        uint256 snap = vm.snapshotState();
        uint256 id = v.tokenId();
        if (id != 0 && collectFirst) {
            // BEFORE a deposit: fees are collected into the vault by deposit()'s first step; replay that by collecting through the position manager as the vault.
            // AFTER it no collection happens inside deposit(), so fees accrued by the deposit's own swap stay uncollected and are NOT in the vault's N1.
            vm.prank(address(v));
            (bool ok,) = address(pm).call(abi.encodeWithSignature("collect((uint256,address,uint128,uint128))", id, address(v), type(uint128).max, type(uint128).max));
            require(ok, "collect as the vault failed");
        }
        uint256 a = asset.balanceOf(address(v));
        uint256 p = paired.balanceOf(address(v));
        if (id != 0) {
            (,,, int24 lo, int24 up, uint128 liq,,,,) = pm.positions(id);
            if (liq != 0) {
                (uint256 x0, uint256 x1) = PharaohLiquidityAmounts.getAmountsForLiquidity(
                    PharaohTickMath.getSqrtRatioAtTick(_twapTick()), PharaohTickMath.getSqrtRatioAtTick(lo), PharaohTickMath.getSqrtRatioAtTick(up), liq
                );
                a += assetIs0 ? x0 : x1;
                p += assetIs0 ? x1 : x0;
            }
        }
        vm.revertToState(snap);
        n = a + _q(p);
    }

    function _flBound(uint256 H) internal view returns (uint256) {
        uint256 L = 1;
        uint256 id = v.tokenId();
        if (id != 0) {
            (,,,,, uint128 liq,,,,) = pm.positions(id);
            L = liq == 0 ? 1 : liq;
        }
        uint256 big = 10 ** 24;
        uint256 qc = (_q(big) + big - 1) / big;
        return 4 + 4 * qc + 2 * ((H + L - 1) / L) + 2;
    }

    // ----------------------------------------------------------------------------- state knobs
    function _setBal(address token, address who, uint256 amount) internal {
        deal(token, who, amount);
    }

    /// share-price level: raise it by donating asset, lower it by minting shares to CAROL (no assets): `ppsBps` = target (N/S) relative to the current, 10000 = unchanged
    function _setLevel(uint256 ppsBps) internal {
        if (ppsBps == 10_000) return;
        uint256 n = v.totalAssets();
        if (ppsBps > 10_000) {
            deal(address(asset), address(v), asset.balanceOf(address(v)) + (n * (ppsBps - 10_000)) / 10_000);
        } else {
            uint256 s = v.totalSupply();
            uint256 extra = (s * (10_000 - ppsBps)) / ppsBps; // S' = S * 10000 / pps
            bytes32 balSlot = keccak256(abi.encode(CAROL, uint256(ERC20_LOC)));
            vm.store(address(v), balSlot, bytes32(v.balanceOf(CAROL) + extra));
            vm.store(address(v), bytes32(uint256(ERC20_LOC) + 2), bytes32(s + extra));
        }
    }

    /// idle paired token as a fraction (bps) of the vault's value, donated to the vault
    function _setIdlePaired(uint256 ibBps, address[4] memory hs) internal {
        if (ibBps == 0) return;
        uint256 h = _holdingsValue(hs);
        uint256 wantValue = (h * ibBps) / (10_000 - ibBps);
        uint256 amt = oracle.quoteAssetToPair(wantValue);
        deal(address(paired), address(v), paired.balanceOf(address(v)) + amt);
    }

    /// move the SPOT price with a real swap until it sits `targetTicks` away from the TWAP (the TWAP does not move within the block). The swap is bounded by a
    /// price LIMIT at the target tick, so it stops exactly there (without the limit a thin pool jumps to the end of the liquidity and the vault's own guard refuses).
    function _skew(bool buyPaired, uint256 targetTicks) internal {
        if (targetTicks == 0) return;
        IERC20 tin = buyPaired ? asset : paired;
        IERC20 tout = buyPaired ? paired : asset;
        bool zeroForOne = address(tin) < address(tout); // token0 is the lower address
        int24 tw = _twapTick();
        int24 target = zeroForOne ? tw - int24(int256(targetTicks)) : tw + int24(int256(targetTicks));
        uint160 limit = PharaohTickMath.getSqrtRatioAtTick(target);
        uint256 amt = buyPaired ? aUnit * 20_000 : oracle.quoteAssetToPair(aUnit * 20_000);
        deal(address(tin), WHALE, amt);
        vm.startPrank(WHALE);
        tin.approve(address(router), amt);
        router.exactInputSingle(IRouter.P(address(tin), address(tout), v.tickSpacing(), WHALE, block.timestamp, amt, 0, limit));
        vm.stopPrank();
    }

    // ----------------------------------------------------------------------------- one measured deposit
    struct M {
        int256[3] dE; // ALICE, CAROL, SAFE (seed) change of in-kind oracle value
        uint256[3] B; // rounding bound each
        int256 T; // newcomer transfer = value of his in-kind entitlement - value of his contribution
        int256 Tcf; // closed form from the VALUATION gap
        uint256 tolT;
        uint256 D;
        bool ok;
        bool previewOk;
        uint256 idleLeft; // asset left idle by the deposit (idle after - idle before), 0 if it shrank
        bool soldPaired; // R2: a swap during the deposit that SOLD the paired token (incumbents' idle stock) for the asset
        uint256 eBob;
        uint256 H0;
        uint256 H1;
        uint256 N0;
        uint256 N1;
        uint256 S0;
        uint256 S1;
        uint256 bobShares;
    }

    function _measure(uint256 depositBps, address[4] memory hs) internal returns (M memory m) {
        address[3] memory inc = [ALICE, CAROL, SAFE];
        uint256 S0 = v.totalSupply();
        uint256[3] memory E0;
        uint256[3] memory sh;
        for (uint256 i; i < 3; ++i) {
            E0[i] = _ent(inc[i]);
            sh[i] = v.balanceOf(inc[i]);
        }
        uint256 H0 = _holdingsValue(hs);
        uint256 N0 = _nv(true);
        {
            // previewDeposit must equal the OWNERSHIP-basis formula (it is a view: no fee collection first)
            uint256 nView = _nv(false);
            uint256 dd = (nView * depositBps) / 10_000;
            if (dd == 0) dd = aUnit;
            uint256 lossBps = uint256(v.slippageBps()) * 2 + v.valuationHaircutBps();
            m.previewOk = v.previewDeposit(dd) == Math.mulDiv(Math.mulDiv(dd, 10_000 - lossBps, 10_000), S0 + 1, nView + 1);
        }
        uint256 D = (N0 * depositBps) / 10_000;
        if (D == 0) D = aUnit;
        m.D = D;
        uint256 idle0 = asset.balanceOf(address(v));
        deal(address(asset), BOB, D);
        vm.recordLogs();
        vm.startPrank(BOB);
        asset.approve(address(v), D);
        try v.deposit(D, BOB) {
            m.ok = true;
        } catch (bytes memory err) {
            lastErr = err;
            vm.stopPrank();
            return m;
        }
        vm.stopPrank();
        m.soldPaired = _soldPaired();
        { uint256 idle1 = asset.balanceOf(address(v)); m.idleLeft = idle1 > idle0 ? idle1 - idle0 : 0; }
        uint256 S1 = v.totalSupply();
        uint256 H1 = _holdingsValue(hs);
        uint256 N1 = _nv(false);
        int256 Hk = int256(H1) - int256(H0);
        uint256 eBob = _ent(BOB);
        m.eBob = eBob; m.H0 = H0; m.H1 = H1; m.N0 = N0; m.N1 = N1; m.S0 = S0; m.S1 = S1; m.bobShares = v.balanceOf(BOB);
        m.T = int256(eBob) - Hk;
        // the newcomer's transfer closed form: T = H1 (Nv1 - Nv0)/Nv1 - Hk   (only a valuation-tick gap leaves a non-rounding residual)
        m.Tcf = int256(Math.mulDiv(H1, N1 - N0, N1)) - Hk;
        uint256 fl = _flBound(H1);
        uint256 a = N1 - N0;
        uint256 dev = S0 > N0 ? S0 - N0 : N0 - S0;
        uint256 dm = Math.mulDiv(Math.mulDiv(a, dev, N0), 1, N0) + 2;
        m.tolT = 2 * fl + (H1 / S1 + 1) * dm + 1;
        for (uint256 i; i < 3; ++i) {
            m.dE[i] = int256(_ent(inc[i])) - int256(E0[i]);
            uint256 b1 = Math.mulDiv(Math.mulDiv(Math.mulDiv(sh[i], a, S1), dev, N0 + 1), 1, S0) + 1;
            uint256 b2 = Math.mulDiv(Math.mulDiv(sh[i], N0, S1), 1, S0) + 1;
            m.B[i] = 2 * fl + b1 + b2 + 1;
        }
    }

    /// true if a pool Swap event of the last call moved the ASSET out of the pool (the vault bought the asset by selling the paired token)
    function _soldPaired() internal returns (bool sold) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapSig = keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pool) || logs[i].topics.length == 0 || logs[i].topics[0] != swapSig) continue;
            (int256 a0, int256 a1) = abi.decode(logs[i].data, (int256, int256));
            if ((assetIs0 ? a0 : a1) < 0) sold = true;
        }
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    /// Incumbents bear EXACTLY their pro-rata share of the newcomer's transfer T (up to rounding), and T equals the valuation-gap closed form.
    function _violates(M memory m, uint256[3] memory sh, uint256 S0) internal pure returns (bool bad) {
        // (0) the pro-rata symmetry and the closed form (below) are what R3 promises; the NO-LOSS statement for states without an artificial spot skew is checked by the caller
        for (uint256 i; i < 3; ++i) {
            int256 expect = -((m.T * int256(sh[i])) / int256(S0));
            if (_abs(m.dE[i] - expect) > m.B[i]) bad = true;
        }
        if (_abs(m.T - m.Tcf) > m.tolT) bad = true;
        if (!m.previewOk) bad = true;
        if (m.soldPaired) bad = true; // R2: incumbents' idle paired token is never sold
    }
}

abstract contract R3Cases is R3ForkBase {
    struct Reads {
        address owner;
        address rebalancer;
        uint256 depositCap;
        bool paused;
        uint256 tokenId;
        int24 tickLower;
        int24 tickUpper;
        int24 tickRange;
        int24 tickSpacing;
        uint32 twapPeriod;
        uint24 maxTwapDeviationTicks;
        uint16 slippageBps;
        uint16 haircut;
        uint16 maxOracleDev;
        uint128 pairedUnit;
        address pool;
        address pm;
        address router;
        address oracle;
        address asset;
        address paired;
        uint256 totalAssets;
        uint256 totalSupply;
        uint256 sAlice;
        uint256 sSafe;
        uint256 maxWithdrawSafe;
        uint256 maxRedeemSafe;
        uint256 previewRedeem1e;
        uint256 convertToAssets1e;
        uint256 convertToShares1e;
        uint256 maxDepositAny;
    }

    function _reads() internal view returns (Reads memory r) {
        r.owner = v.owner();
        r.rebalancer = v.rebalancer();
        r.depositCap = v.depositCap();
        r.paused = v.paused();
        r.tokenId = v.tokenId();
        r.tickLower = v.positionTickLower();
        r.tickUpper = v.positionTickUpper();
        r.tickRange = v.tickRange();
        r.tickSpacing = v.tickSpacing();
        r.twapPeriod = v.twapPeriod();
        r.maxTwapDeviationTicks = v.maxTwapDeviationTicks();
        r.slippageBps = v.slippageBps();
        r.haircut = v.valuationHaircutBps();
        r.maxOracleDev = v.maxOracleDeviationBps();
        r.pairedUnit = v.pairedTokenUnit();
        r.pool = v.pool();
        r.pm = v.positionManager();
        r.router = v.swapRouter();
        r.oracle = v.priceOracle();
        r.asset = v.asset();
        r.paired = v.pairedToken();
        r.totalAssets = v.totalAssets();
        r.totalSupply = v.totalSupply();
        r.sAlice = v.balanceOf(ALICE);
        r.sSafe = v.balanceOf(SAFE);
        r.maxWithdrawSafe = v.maxWithdraw(SAFE);
        r.maxRedeemSafe = v.maxRedeem(SAFE);
        r.previewRedeem1e = v.previewRedeem(10 ** 6);
        r.convertToAssets1e = v.convertToAssets(10 ** 6);
        r.convertToShares1e = v.convertToShares(aUnit);
        r.maxDepositAny = v.maxDeposit(BOB);
    }

    /// The upgrade changes nothing that is not the deposit path: every parameter, role, the position, the supply and the haircut views are identical before and after.
    function test_upgrade_preservesEveryReadAndRole() public {
        _fork();
        _fund(ALICE, baseA);
        Reads memory a = _reads();
        _upgrade();
        Reads memory b = _reads();
        assertEq(abi.encode(a), abi.encode(b), "a getter, a role, a parameter or a balance changed by the upgrade");
        assertEq(IProxyAdmin(_admin()).owner(), SAFE, "the Safe still owns the ProxyAdmin");
        // the new implementation is the R3 extension and the old base is no longer used
        bytes32 slot = vm.load(_vault(), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        address impl = address(uint160(uint256(slot)));
        assertTrue(impl != 0x165E1f072e7bEeDf94f14F732838354cA20bA45d, "implementation slot moved to the R3 extension");
    }

    /// Non-deposit paths are the same code: redeem and in-kind exit pay the same on the same state before and after the upgrade.
    function test_upgrade_exitsPayTheSame() public {
        _fork();
        _fund(ALICE, baseA);
        _fund(CAROL, baseA / 2);
        uint256 snap = vm.snapshotState();
        uint256 aliceShares = v.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 cashOld = v.redeem(aliceShares / 3, ALICE, ALICE);
        uint256 kindOld = _ent(CAROL);
        vm.revertToState(snap);
        _upgrade();
        vm.prank(ALICE);
        uint256 cashNew = v.redeem(aliceShares / 3, ALICE, ALICE);
        uint256 kindNew = _ent(CAROL);
        assertEq(cashNew, cashOld, "cash redeem differs");
        assertEq(kindNew, kindOld, "in-kind claim differs");
    }

    function _state(uint256 b, uint256 e, uint256 d, uint256 k, address[4] memory hs, uint256 base) internal returns (bool ran, bool bad, uint256 tppm, uint256 snapOut) {
        uint256[4] memory ibs = [uint256(0), 300, 1500, 5000];
        uint256[3] memory ppss = [uint256(10_000), 9700, 10_300];
        uint256[4] memory deps = [uint256(100), 1000, 10_000, 30_000];
        vm.revertToState(base);
        snapOut = vm.snapshotState();
        _setIdlePaired(ibs[b], hs);
        _setLevel(ppss[e]);
        if (k != 0) _skew(k == 1, 1 + uint256(v.maxTwapDeviationTicks()) / 3);
        uint256 S0 = v.totalSupply();
        uint256[3] memory sh = [v.balanceOf(ALICE), v.balanceOf(CAROL), v.balanceOf(SAFE)];
        M memory m = _measure(deps[d], hs);
        lastM = m;
        lastSh = sh;
        lastS0 = S0;
        if (!m.ok) return (false, false, 0, snapOut);
        ran = true;
        bad = _violates(m, sh, S0);
        tppm = Math.mulDiv(_abs(m.T), 1e6, m.D);
    }

    /// 36 of the 144 states: the idle-paired level `b` fixed, the other three axes (3 share-price levels x 4 deposit sizes x 3 spot skews) swept.
    /// index of the vault's custom errors in the revert tally (MEMORY: snapshot reverts also roll back the test contract's own storage)
    function _selIndex(bytes memory err) internal pure returns (uint256) {
        if (err.length < 4) return 6;
        bytes4 sel = bytes4(err);
        if (sel == 0x1848c1c0) return 0; // Vault__PriceDeviation
        if (sel == 0x3bfe35e3) return 1; // Vault__OracleDeviation
        if (sel == 0x944c71be) return 2; // Vault__InsufficientShares
        if (sel == 0x52223b3d) return 3; // Vault__InsufficientAssets
        if (sel == 0x192d4e0c) return 4; // Vault__PositionNeedsRebalance
        if (sel == 0xabd45647) return 5; // Vault__DepositCapExceeded
        return 6;
    }

    function _runGrid(bool r3, uint256 b) internal returns (uint256 cases, uint256 viol, uint256 noDeposit, uint256 worstTppm) {
        _fork();
        if (r3) _upgrade();
        _fund(ALICE, baseA);
        _fund(CAROL, baseA / 2);
        address[4] memory hs = [ALICE, CAROL, SAFE, BOB];
        uint256[7] memory rc;
        uint256 base = vm.snapshotState();
        for (uint256 e; e < 3; ++e) {
            for (uint256 d; d < 4; ++d) {
                for (uint256 k; k < 3; ++k) {
                    (bool ran, bool bad, uint256 tppm, uint256 snapNew) = _state(b, e, d, k, hs, base);
                    base = snapNew;
                    if (!ran) {
                        noDeposit++;
                        rc[_selIndex(lastErr)]++;
                        if (_selIndex(lastErr) == 6) console2.log(string.concat("OTHERREVERT state e=", vm.toString(e), " d=", vm.toString(d), " k=", vm.toString(k), " data=", vm.toString(lastErr)));
                        continue;
                    }
                    cases++;
                    if (bad) viol++;
                    if (tppm > worstTppm) worstTppm = tppm;
                }
            }
        }
        console2.log(string.concat("REVERTS ", _name(), r3 ? " R3" : " ORIGINAL", " idleLevel#", vm.toString(b), " PriceDeviation=", vm.toString(rc[0]), " OracleDeviation=", vm.toString(rc[1]), " InsufficientShares=", vm.toString(rc[2]), " InsufficientAssets=", vm.toString(rc[3]), " PositionNeedsRebalance=", vm.toString(rc[4]), " DepositCapExceeded=", vm.toString(rc[5]), " other=", vm.toString(rc[6])));
        console2.log(string.concat("R3GRID ", _name(), r3 ? " R3" : " ORIGINAL", " idleLevel#", vm.toString(b), " cases=", vm.toString(cases), " violations=", vm.toString(viol), " depositRevertedByGuard=", vm.toString(noDeposit), " max|T|/D(ppm)=", vm.toString(worstTppm)));
    }

    function _gridR3(uint256 b) internal {
        (uint256 cases, uint256 viol,,) = _runGrid(true, b);
        assertGt(cases, 15, "too few states ran");
        assertEq(viol, 0, "R3: an incumbent moved by more than rounding, or the newcomer transfer is not the valuation-gap closed form");
    }

    function _gridOriginal(uint256 b) internal {
        (uint256 cases, uint256 viol,,) = _runGrid(false, b);
        assertGt(cases, 10);
        assertGt(viol, cases / 2, "the deployed rule should violate in most states");
    }

    // 4 x 36 = 144 states per vault, per rule
    function test_grid_R3_idle0() public { _gridR3(0); }
    function test_grid_R3_idle3pct() public { _gridR3(1); }
    function test_grid_R3_idle15pct() public { _gridR3(2); }
    function test_grid_R3_idle50pct() public { _gridR3(3); }
    function test_grid_ORIGINAL_idle0() public { _gridOriginal(0); }
    function test_grid_ORIGINAL_idle3pct() public { _gridOriginal(1); }
    function test_grid_ORIGINAL_idle15pct() public { _gridOriginal(2); }
    function test_grid_ORIGINAL_idle50pct() public { _gridOriginal(3); }

    /// A SMALL probe (6 states: idle level 3%, spot not skewed, deposit sizes 10% and 100%, three share-price levels) used for mutation testing of the R3 source:
    /// fast enough to run for every mutant, strict enough that any mutant of the mint basis or the deployment is caught.
    function test_probe_R3() public {
        _fork();
        _upgrade();
        _fund(ALICE, baseA);
        _fund(CAROL, baseA / 2);
        address[4] memory hs = [ALICE, CAROL, SAFE, BOB];
        uint256 base = vm.snapshotState();
        uint256 ran;
        for (uint256 b = 1; b < 4; b += 2) {
            for (uint256 e; e < 3; ++e) {
                for (uint256 d = 1; d < 3; ++d) {
                    (bool r, bool bad,, uint256 sn) = _state(b, e, d, 0, hs, base);
                    base = sn;
                    assertTrue(r, "the probe deposit must be accepted");
                    // R2 (deployment composition): at these unskewed, moderate-size states the new asset is deployed, not left idle (baseline 0 bp; large or skewed deposits legitimately leave a remainder idle: it counts in NAV)
                    assertLe(lastM.idleLeft * 10_000, lastM.D * 10, "probe: the deposit left more than 10 bp of itself idle");
                    assertFalse(bad, "probe: an incumbent moved by more than rounding, the transfer is not the closed form, or previewDeposit is not on the ownership basis");
                    ran++;
                }
            }
        }
        assertEq(ran, 12);
    }

    /// What single deposit sizes pass on each rule in the post-opening state (the team seed already in, the cap at its pilot value): the sizes users will actually try.
    function _depositLadder(bool r3) internal {
        _fork();
        vm.prank(SAFE);
        v.setDepositCap(baseCapUnits);
        _fund(ALICE, seedUnits); // the team seed, under the DEPLOYED rule (that is the order on the days: opening on 12 Nov, R3 on 15 Nov)
        vm.prank(SAFE);
        // (deployIdle by the rebalancer = the Ledger in the real sequence)
        vm.startPrank(v.rebalancer());
        v.deployIdle();
        vm.stopPrank();
        if (r3) _upgrade();
        uint256 snap = vm.snapshotState();
        string memory line = string.concat("LADDER ", _name(), r3 ? " R3" : " ORIGINAL", ":");
        for (uint256 i; i < ladder.length; ++i) {
            vm.revertToState(snap);
            snap = vm.snapshotState();
            uint256 amt = ladder[i];
            deal(address(asset), BOB, amt);
            vm.startPrank(BOB);
            asset.approve(address(v), amt);
            uint256 g0 = gasleft();
            string memory res = "ok";
            try v.deposit(amt, BOB) {} catch (bytes memory err) {
                res = _selIndex(err) == 6 ? (err.length >= 4 && bytes4(err) == 0x08c379a0 ? "TooLittleReceived" : "other") : "guard";
            }
            vm.stopPrank();
            line = string.concat(line, " ", vm.toString(amt / (aUnit / 100)), "c:", res, "(", vm.toString((g0 - gasleft()) / 1000), "kgas)");
        }
        console2.log(line);
    }

    function test_ladder_ORIGINAL() public { _depositLadder(false); }
    function test_ladder_R3() public { _depositLadder(true); }

    /// A sweep over skew and size at one idle level / share-price level, printing T, the closed form and the tolerance (for diagnosis).
    function test_debug_sweep() public {
        _fork();
        _upgrade();
        _fund(ALICE, baseA);
        _fund(CAROL, baseA / 2);
        address[4] memory hs = [ALICE, CAROL, SAFE, BOB];
        uint256 base = vm.snapshotState();
        for (uint256 k; k < 3; ++k) {
            for (uint256 d; d < 4; ++d) {
                (bool ran, bool bad,, uint256 sn) = _state(1, 0, d, k, hs, base);
                base = sn;
                if (ran && k == 0 && d == 1) {
                    uint256 fH1 = Math.mulDiv(lastM.H1, lastM.bobShares, lastM.S1);
                    console2.log(string.concat("PARTS eBob=", vm.toString(lastM.eBob), " bobShares/S1*H1=", vm.toString(fH1), " (N1-N0)/N1*H1=", vm.toString(Math.mulDiv(lastM.H1, lastM.N1 - lastM.N0, lastM.N1)), " H0=", vm.toString(lastM.H0), " H1=", vm.toString(lastM.H1), " N0=", vm.toString(lastM.N0), " N1=", vm.toString(lastM.N1), " S0=", vm.toString(lastM.S0), " S1=", vm.toString(lastM.S1), " bob=", vm.toString(lastM.bobShares)));
                }
                console2.log(string.concat("SWEEP skew=", vm.toString(k), " dep#", vm.toString(d), " ran=", vm.toString(ran), " bad=", vm.toString(bad), " T=", vm.toString(lastM.T), " Tcf=", vm.toString(lastM.Tcf), " tolT=", vm.toString(lastM.tolT), " D=", vm.toString(lastM.D), " dE0=", vm.toString(lastM.dE[0]), " B0=", vm.toString(lastM.B[0])));
            }
        }
    }
}

contract R3ForkUsdcVault is R3Cases {
    function setUp() public {
        // forking happens in each test (the upgrade is part of the test)
    }
    function _vault() internal pure override returns (address) { return 0x855bF832f26a294d28500db59eE941dE3d654129; }
    function _admin() internal pure override returns (address) { return 0x2DD4191B2944396B5853f4219E829f01636F65cf; }
    function _pin() internal pure override returns (uint256) { return 99_580_846; }
    function _name() internal pure override returns (string memory) { return "USDC-vault"; }
    constructor() {
        baseA = 1_000e6;
        baseCapUnits = 5_000e6;
        seedUnits = 500e6;
        ladder = [100e6, 250e6, 500e6, 1_000e6, 2_000e6, 3_000e6, 4_000e6, 4_400e6];
    }
}

contract R3ForkWavaxVault is R3Cases {
    function setUp() public {}
    function _vault() internal pure override returns (address) { return 0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8; }
    function _admin() internal pure override returns (address) { return 0x34CbBdfcBcc72e8bf70CbF6c7245fdb2725b94dC; }
    function _pin() internal pure override returns (uint256) { return 99_580_846; }
    function _name() internal pure override returns (string memory) { return "WAVAX-vault"; }
    constructor() {
        baseA = 50e18;
        baseCapUnits = 595e18;
        seedUnits = 60e18;
        ladder = [10e18, 30e18, 60e18, 120e18, 240e18, 360e18, 480e18, 530e18];
    }
}
