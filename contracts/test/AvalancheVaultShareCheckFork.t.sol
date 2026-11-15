// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../contracts/pancakev3/libraries/TickMath.sol";

/// @title AvalancheVaultShareCheckFork
/// @notice INDEPENDENT replay (fork, local VM only) of the F-IK-2 share-pricing claim on the two live Pharaoh vaults.
///         It does NOT use TrackAVaultsBase or any helper of AvalancheTrackAVaultsFork.t.sol: interfaces, funding, the
///         holdings read, the ledger and the decomposition below are written from scratch. No key is used, nothing is
///         signed or broadcast; `vm.prank` impersonates the owner Safe (only to open the deposit cap) and the depositors.
///
///         Measurement: every in-kind entitlement is the amount a REPLAYED `redeemInKind` pays inside a snapshot that is
///         reverted. The vault's whole holdings H are the sum of the holders' replayed claims (the last claim takes the
///         remainder). Value is the vault's own oracle: `priceOracle.quotePairToAsset`.
///
///         Asserted: exact identities only (token-conservation ledger, the vault's mint formula reproduced to the share, the
///         telescoping decomposition of the newcomer's transfer, round-trip accounting identity) and rounding-derived bounds
///         (documented at `_flBound`). No fairness threshold and no ppm tolerance.
///         Method, definitions, results: docs/deployment-handoffs/avalanche-vault-share-pricing-remedy.md (section 2).
interface IVSCVault {
    function asset() external view returns (address);
    function pairedToken() external view returns (address);
    function pool() external view returns (address);
    function positionManager() external view returns (address);
    function priceOracle() external view returns (address);
    function swapRouter() external view returns (address);
    function tokenId() external view returns (uint256);
    function tickSpacing() external view returns (int24);
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function deposit(uint256, address) external returns (uint256);
    function redeemInKind(uint256, address, address) external returns (uint256, uint256);
    function setDepositCap(uint256) external;
    function paused() external view returns (bool);
    function tickRange() external view returns (int24);
    function twapPeriod() external view returns (uint32);
    function maxTwapDeviationTicks() external view returns (uint24);
    function maxOracleDeviationBps() external view returns (uint16);
    function slippageBps() external view returns (uint16);
    function valuationHaircutBps() external view returns (uint16);
}

interface IVSCPool {
    function protocolFees() external view returns (uint128, uint128);
    function factory() external view returns (address);
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

interface IVSCPM {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata) external returns (uint256, uint256);
    function positions(uint256)
        external
        view
        returns (address, address, int24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

interface IVSCOracle {
    function quotePairToAsset(uint256) external view returns (uint256);
}

interface IVSCRouter {
    struct Params {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(Params calldata) external payable returns (uint256);
}

interface IVSCVoter {
    function gaugeForPool(address) external view returns (address);
}

interface IVSCFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

abstract contract VSCBase is Test {
    address internal constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    address internal constant VOTER = 0x922b9Ca8e2207bfB850B6FF647c054d4b58a2Aa7;
    address internal constant AVAX_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant ALICE = address(0xA11CE0);
    address internal constant BOB = address(0xB0B000);

    IVSCVault internal v;
    IERC20 internal asset;
    IERC20 internal paired;
    IVSCPool internal pool;
    IVSCOracle internal oracle;
    address internal router;
    address internal pm;
    uint256 internal aUnit;
    string internal tag;

    function _vaultAddr() internal pure virtual returns (address);
    function _defaultPin() internal pure virtual returns (uint256);
    function _name() internal pure virtual returns (string memory);
    /// Incumbent deposit in asset units (the earlier report's USD 2,000 on the USDC vault, USD 10,000 on the WAVAX vault).
    function _aliceAmount() internal view virtual returns (uint256);
    /// USD-denominated size in asset units (USDC at USD 1; WAVAX at the Chainlink AVAX/USD answer at the pin).
    function _usd(uint256 usd) internal view virtual returns (uint256);
    function _seedOnlyMaxUsd() internal pure virtual returns (uint256);

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, vm.envOr("TRACKA_PIN_BLOCK", _defaultPin()));
        require(block.chainid == 43_114, "not Avalanche C-Chain");
        v = IVSCVault(_vaultAddr());
        asset = IERC20(v.asset());
        paired = IERC20(v.pairedToken());
        pool = IVSCPool(v.pool());
        oracle = IVSCOracle(v.priceOracle());
        router = v.swapRouter();
        pm = v.positionManager();
        aUnit = 10 ** IVSCDec(address(asset)).decimals();
        tag = _name();
        // LOCAL VM ONLY: impersonate the owner Safe to lift the live 1-wei deposit cap; fund the two actors with `deal`.
        vm.prank(SAFE);
        v.setDepositCap(type(uint128).max);
    }

    // ------------------------------------------------------------------ small helpers
    function _s(int256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function _u(uint256 x) internal pure returns (string memory) {
        return vm.toString(x);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function _val(uint256 p) internal view returns (uint256) {
        return p == 0 ? 0 : oracle.quotePairToAsset(p);
    }

    function _valS(int256 p) internal view returns (int256) {
        return p >= 0 ? int256(_val(uint256(p))) : -int256(_val(uint256(-p)));
    }

    function _ppm(int256 num, uint256 den) internal pure returns (int256) {
        return den == 0 ? int256(0) : num * 1_000_000 / int256(den);
    }

    function _fundAndDeposit(address who, uint256 amt) internal returns (uint256 minted) {
        deal(address(asset), who, amt);
        vm.startPrank(who);
        asset.approve(address(v), amt);
        minted = v.deposit(amt, who);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ holdings and entitlements (snapshot replays)
    function _holders() internal pure returns (address[3] memory h) {
        h[0] = ALICE;
        h[1] = BOB;
        h[2] = SAFE;
    }

    /// In-kind claim of `who` for ALL of his shares, as paid by a replayed `redeemInKind`.
    function _ent(address who) internal returns (uint256 a, uint256 p) {
        uint256 sh = v.balanceOf(who);
        if (sh == 0) return (0, 0);
        uint256 snap = vm.snapshotState();
        uint256 a0 = asset.balanceOf(who);
        uint256 p0 = paired.balanceOf(who);
        vm.prank(who);
        v.redeemInKind(sh, who, who);
        a = asset.balanceOf(who) - a0;
        p = paired.balanceOf(who) - p0;
        vm.revertToState(snap);
    }

    /// Whole holdings of the vault: idle + principal + uncollected fees = sum of every holder's replayed claim (the
    /// last claim burns the whole supply and takes the remainder). The three holders must own the whole supply.
    function _holdings() internal returns (uint256 a, uint256 p) {
        address[3] memory hs = _holders();
        uint256 tot;
        for (uint256 i; i < 3; ++i) {
            tot += v.balanceOf(hs[i]);
        }
        require(tot == v.totalSupply(), "an unknown holder owns shares");
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 3; ++i) {
            uint256 sh = v.balanceOf(hs[i]);
            if (sh == 0) continue;
            uint256 a0 = asset.balanceOf(hs[i]);
            uint256 p0 = paired.balanceOf(hs[i]);
            vm.prank(hs[i]);
            v.redeemInKind(sh, hs[i], hs[i]);
            a += asset.balanceOf(hs[i]) - a0;
            p += paired.balanceOf(hs[i]) - p0;
        }
        vm.revertToState(snap);
    }

    /// totalAssets() as the vault computes it AFTER the `_collectFees()` that `deposit` performs first.
    function _totalAssetsAfterCollect() internal returns (uint256 t) {
        uint256 snap = vm.snapshotState();
        uint256 id = v.tokenId();
        if (id != 0) {
            vm.prank(address(v));
            IVSCPM(pm).collect(IVSCPM.CollectParams(id, address(v), type(uint128).max, type(uint128).max));
        }
        t = v.totalAssets();
        vm.revertToState(snap);
    }

    // ------------------------------------------------------------------ ledger
    struct Bal {
        int256[10] a;
        int256[10] p;
        uint256 pfA; // pool protocol fees (token0 / token1 order resolved by the caller)
        uint256 pfP;
    }

    function _accounts() internal view returns (address[10] memory ac) {
        ac[0] = ALICE;
        ac[1] = BOB;
        ac[2] = SAFE;
        ac[3] = address(v); // vault idle balance
        ac[4] = address(pool);
        ac[5] = router;
        ac[6] = pm;
        ac[7] = _feeCollector();
        ac[8] = IVSCVoter(VOTER).gaugeForPool(address(pool));
        ac[9] = VOTER;
    }

    function _feeCollector() internal view returns (address) {
        (bool ok, bytes memory r) = pool.factory().staticcall(abi.encodeWithSignature("feeCollector()"));
        if (ok && r.length >= 32) return abi.decode(r, (address));
        return address(0xFEE);
    }

    function _labels() internal pure returns (string[10] memory l) {
        l = ["Alice(incumbent)", "Bob(newcomer)", "Safe(seed)", "vault idle", "pool(total)", "router", "positionManager", "feeCollector", "gauge", "voter"];
    }

    function _bal() internal view returns (Bal memory b) {
        address[10] memory ac = _accounts();
        for (uint256 i; i < 10; ++i) {
            b.a[i] = int256(asset.balanceOf(ac[i]));
            b.p[i] = int256(paired.balanceOf(ac[i]));
        }
        (uint128 f0, uint128 f1) = pool.protocolFees();
        bool assetIs0 = address(asset) < address(paired);
        b.pfA = assetIs0 ? f0 : f1;
        b.pfP = assetIs0 ? f1 : f0;
    }

    // ------------------------------------------------------------------ bound (rounding only)
    /// @dev flBound bounds |replayed in-kind claim - exact pro-rata of the true holdings| of ONE holder, per the floors of
    ///      `redeemInKind` (V:367-375): idle asset floor (<1), idle paired floor (<1 paired unit), floor of the liquidity
    ///      removed (<1 liquidity unit, worth at most H/L), the pool's floor of both amounts (<1 each), and the oracle
    ///      quote floor (<1). In asset units: 4 + 4*ceil(q) + 2*ceil(H/L). `qc` = ceil(asset per paired unit).
    function _flBound(uint256 Hv) internal view returns (uint256) {
        uint256 id = v.tokenId();
        uint256 L = 1;
        if (id != 0) {
            (,,,,, uint128 liq,,,,) = IVSCPM(pm).positions(id);
            L = liq == 0 ? 1 : liq;
        }
        uint256 qc = _qCeil();
        return 4 + 4 * qc + 2 * ((Hv + L - 1) / L);
    }

    function _qCeil() internal view returns (uint256) {
        // asset raw units per ONE paired raw unit, rounded up: quote a large amount to avoid the floor of a single unit
        uint256 big = 10 ** 24;
        uint256 q = _val(big);
        return (q + big - 1) / big;
    }

    // ------------------------------------------------------------------ one deposit, fully measured
    struct Rep {
        // inputs
        uint256 D;
        uint256 S0;
        uint256 minted;
        uint256 V0c; // totalAssets after collect, before
        uint256 V1; // totalAssets after
        // holdings (tokens)
        uint256 H0a;
        uint256 H0p;
        uint256 H1a;
        uint256 H1p;
        // entitlement values (oracle)
        uint256 EalA0;
        uint256 EalA1;
        uint256 EsfA0;
        uint256 EsfA1;
        uint256 EbobA;
        uint256 EbobP;
        // derived
        int256 Hk;
        int256 Pk;
        int256 T;
        int256 Tcf;
        int256 partHair;
        int256 partTwap;
        int256 partMintFloor;
        int256 partRedeem;
        uint256 fl;
    }

    function _measureDeposit(uint256 D) internal returns (Rep memory r) {
        r.D = D;
        r.S0 = v.totalSupply();
        // before
        (r.H0a, r.H0p) = _holdings();
        (uint256 ea0, uint256 ep0) = _ent(ALICE);
        (uint256 es0, uint256 eq0) = _ent(SAFE);
        r.EalA0 = ea0 + _val(ep0);
        r.EsfA0 = es0 + _val(eq0);
        r.V0c = _totalAssetsAfterCollect();
        deal(address(asset), BOB, D); // funding happens BEFORE the measured window
        Bal memory b0 = _bal();
        vm.startPrank(BOB);
        asset.approve(address(v), D);
        r.minted = v.deposit(D, BOB);
        vm.stopPrank();
        Bal memory b1 = _bal();
        r.V1 = v.totalAssets();
        // after
        (r.H1a, r.H1p) = _holdings();
        (ea0, ep0) = _ent(ALICE);
        (es0, eq0) = _ent(SAFE);
        (r.EbobA, r.EbobP) = _ent(BOB);
        r.EalA1 = ea0 + _val(ep0);
        r.EsfA1 = es0 + _val(eq0);
        _decompose(r);
        _ledger(b0, b1, r);
    }

    function _decompose(Rep memory r) internal view {
        uint256 h = v.valuationHaircutBps();
        uint256 P0v = _val(r.H0p);
        uint256 P1v = _val(r.H1p);
        uint256 H0v = r.H0a + P0v;
        uint256 H1v = r.H1a + P1v;
        r.Hk = int256(H1v) - int256(H0v);
        r.Pk = int256(P1v) - int256(P0v);
        uint256 Eb = r.EbobA + _val(r.EbobP);
        r.T = int256(Eb) - r.Hk;
        // closed form (continuous), V:T = h (K P1 - kP H1) / (1e4 H1 - h P1)
        r.Tcf = (int256(h) * (r.Hk * int256(P1v) - r.Pk * int256(H1v))) / (1e4 * int256(H1v) - int256(h) * int256(P1v));
        // spot-consistent haircut NAV of the real holdings (what the vault would compute if it valued principal at spot)
        uint256 Vs0 = r.H0a + Math.mulDiv(P0v, 1e4 - h, 1e4);
        uint256 Vs1 = r.H1a + Math.mulDiv(P1v, 1e4 - h, 1e4);
        uint256 Es = _entFromV(H1v, Vs1, Vs0, r.S0);
        uint256 EV = _entFromV(H1v, r.V1, r.V0c, r.S0);
        // E_a: entitlement value of the integer shares actually minted, as a fraction of the post-deposit supply
        uint256 Ea = Math.mulDiv(H1v, r.minted, r.S0 + r.minted);
        r.partHair = int256(Es) - r.Hk;
        r.partTwap = int256(EV) - int256(Es);
        r.partMintFloor = int256(Ea) - int256(EV);
        r.partRedeem = int256(Eb) - int256(Ea);
        r.fl = _flBound(H1v);
    }

    /// E = H1 * X / (S0 * den + X) with X = (V1 - V0)(S0 + 1), den = V0 + 1: the newcomer's fraction of the post-deposit
    /// supply if the vault minted the exact (unfloored) quotient of its formula, times the true holdings.
    function _entFromV(uint256 H1v, uint256 Vafter, uint256 Vbefore, uint256 S0) internal pure returns (uint256) {
        require(Vafter > Vbefore, "no contribution");
        uint256 X = Math.mulDiv(Vafter - Vbefore, S0 + 1, 1);
        uint256 den = Vbefore + 1;
        return Math.mulDiv(H1v, X, S0 * den + X);
    }

    function _ledger(Bal memory b0, Bal memory b1, Rep memory r) internal view {
        string[10] memory lab = _labels();
        int256 sumA;
        int256 sumP;
        for (uint256 i; i < 10; ++i) {
            sumA += b1.a[i] - b0.a[i];
            sumP += b1.p[i] - b0.p[i];
        }
        console2.log(string.concat("VSC|", tag, "|LEDGER residual asset ", _s(sumA), " paired ", _s(sumP), " (asserted 0)"));
        assertEq(sumA, 0, "asset ledger residual");
        assertEq(sumP, 0, "paired ledger residual");
        // pool decomposition: pool total = vault position+fees (H - idle) + protocol fees + other LPs (derived remainder)
        int256 poolA = b1.a[4] - b0.a[4];
        int256 poolP = b1.p[4] - b0.p[4];
        int256 vposA = (int256(r.H1a) - b1.a[3]) - (int256(r.H0a) - b0.a[3]);
        int256 vposP = (int256(r.H1p) - b1.p[3]) - (int256(r.H0p) - b0.p[3]);
        int256 pfA = int256(b1.pfA) - int256(b0.pfA);
        int256 pfP = int256(b1.pfP) - int256(b0.pfP);
        console2.log(string.concat("VSC|", tag, "|POOL delta asset ", _s(poolA), " = vault position ", _s(vposA), " + protocol fees ", _s(pfA), " + other LPs (derived) ", _s(poolA - vposA - pfA)));
        console2.log(string.concat("VSC|", tag, "|POOL delta paired ", _s(poolP), " = vault position ", _s(vposP), " + protocol fees ", _s(pfP), " + other LPs (derived) ", _s(poolP - vposP - pfP)));
        for (uint256 i; i < 10; ++i) {
            if (b1.a[i] != b0.a[i] || b1.p[i] != b0.p[i]) {
                console2.log(string.concat("VSC|", tag, "|ACCT ", lab[i], " asset ", _s(b1.a[i] - b0.a[i]), " paired ", _s(b1.p[i] - b0.p[i])));
            }
        }
        // router, position manager and the other fee recipients must not retain tokens
        assertEq(b1.a[5] - b0.a[5], 0, "router kept asset");
        assertEq(b1.p[5] - b0.p[5], 0, "router kept paired");
        assertEq(b1.a[6] - b0.a[6], 0, "position manager kept asset");
        assertEq(b1.p[6] - b0.p[6], 0, "position manager kept paired");
    }

    function _report(Rep memory r, string memory what) internal view {
        uint256 H1v = r.H1a + _val(r.H1p);
        console2.log(string.concat("VSC|", tag, "|", what, " D ", _u(r.D), " S0 ", _u(r.S0), " minted ", _u(r.minted), " haircut bps ", _u(v.valuationHaircutBps())));
        console2.log(string.concat("VSC|", tag, "|", what, " incumbent Alice change ppm ", _s(_ppm(int256(r.EalA1) - int256(r.EalA0), r.EalA0)), " (", _s(int256(r.EalA1) - int256(r.EalA0)), " asset units); Safe seed ppm ", _s(_ppm(int256(r.EsfA1) - int256(r.EsfA0), r.EsfA0)), " (", _s(int256(r.EsfA1) - int256(r.EsfA0)), ")"));
        console2.log(string.concat("VSC|", tag, "|", what, " contribution K (oracle) ", _s(r.Hk), " paired part ", _s(r.Pk), " ; newcomer transfer T = entitlement - K = ", _s(r.T), " = ", _s(_ppm(r.T, r.D)), " ppm of D"));
        console2.log(string.concat("VSC|", tag, "|", what, " closed form T_cf ", _s(r.Tcf), " (|T_cf - haircut part| ", _u(_abs(r.Tcf - r.partHair)), ")"));
        console2.log(string.concat("VSC|", tag, "|", what, " DECOMP haircut ", _s(r.partHair), " + TWAP-vs-spot valuation ", _s(r.partTwap), " + mint floor ", _s(r.partMintFloor), " + redeem floors ", _s(r.partRedeem), " = ", _s(r.partHair + r.partTwap + r.partMintFloor + r.partRedeem), " (T = ", _s(r.T), ")"));
        console2.log(string.concat("VSC|", tag, "|", what, " paired share of value: holdings before ", _u(_val(r.H0p) * 1_000_000 / (r.H0a + _val(r.H0p))), " ppm, K ", _s(_ppm(r.Pk, uint256(r.Hk < 0 ? -r.Hk : r.Hk))), " ppm (signed), holdings after ", _u(_val(r.H1p) * 1_000_000 / H1v), " ppm"));
    }

    function _assertRep(Rep memory r) internal view {
        // (1) the vault mints exactly floor((V1 - V0)(S0+1)/(V0+1)) with V0 read after the collect
        uint256 pred = Math.mulDiv(r.V1 - r.V0c, r.S0 + 1, r.V0c + 1);
        assertEq(r.minted, pred, "mint formula");
        // (2) the telescoping parts add up to T exactly
        assertEq(r.partHair + r.partTwap + r.partMintFloor + r.partRedeem, r.T, "decomposition");
        // (3) value ledger: incumbents' changes + newcomer entitlement = K, to the floors of 3 replayed claims
        int256 ledger = (int256(r.EalA1) - int256(r.EalA0)) + (int256(r.EsfA1) - int256(r.EsfA0)) + (int256(r.EbobA + _val(r.EbobP)) - r.Hk);
        assertLe(_abs(ledger), 3 * r.fl + 4, "value ledger");
        // (4) mint floor loses < 1 share (value H1/(S0+m)); redeem floors <= fl
        uint256 oneShare = (r.H1a + _val(r.H1p)) / (r.S0 + r.minted) + 1;
        assertLe(_abs(r.partMintFloor), oneShare + 1, "mint floor <= one share");
        assertLe(_abs(r.partRedeem), r.fl, "redeem floors <= fl");
        // (5) closed form = haircut part, to the effect of the +1 virtual offsets and of the floors
        uint256 Hv = r.H1a + _val(r.H1p);
        uint256 tolCf = r.fl + Hv / r.S0 + Hv / r.V0c + 8;
        assertLe(_abs(r.Tcf - r.partHair), tolCf, "closed form vs exact haircut part");
    }

    // ------------------------------------------------------------------ scenario
    address internal constant WHALE = address(0xDEAD0002);

    function _spotTick() internal view returns (int24 t) {
        (, t,,,,,) = pool.slot0();
    }

    function _fundToken(address token, address to, uint256 amt) internal {
        if (token != 0x2b2C81e08f1Af8835a78Bb2A90AE924ACE0eA4bE) {
            deal(token, to, amt);
            return;
        }
        // BENQI sAVAX is a staking token: mint through submit() with native AVAX (local VM only)
        vm.deal(to, amt * 2);
        vm.prank(to);
        (bool ok2,) = token.call{value: amt * 2}(abi.encodeWithSignature("submit()"));
        require(ok2 && IERC20(token).balanceOf(to) >= amt, "fund paired token");
    }

    /// An arbitrageur moves the REAL pool back to `target` with one real swap through the real router (price limit at the
    /// target). Real arbitrage does this after a deposit moves the price; the TWAP does not move within the block.
    function _restoreTick(int24 target) internal {
        int24 t = _spotTick();
        if (t == target) return;
        bool zeroForOne = t > target; // price (token1 per token0) must fall: sell token0
        address token0 = address(asset) < address(paired) ? address(asset) : address(paired);
        address token1 = token0 == address(asset) ? address(paired) : address(asset);
        address tin = zeroForOne ? token0 : token1;
        address tout = zeroForOne ? token1 : token0;
        uint256 big = 5_000_000 * (10 ** IVSCDec(tin).decimals());
        _fundToken(tin, WHALE, big);
        vm.startPrank(WHALE);
        IERC20(tin).approve(router, big);
        IVSCRouter(router).exactInputSingle(
            IVSCRouter.Params(tin, tout, v.tickSpacing(), WHALE, block.timestamp + 1, big, 0, TickMath.getSqrtRatioAtTick(target))
        );
        vm.stopPrank();
    }

    bool internal restore; // set by the *_restored tests: arbitrage the pool back to the pre-deposit tick after the incumbent's deposit

    function _incumbent() internal {
        uint256 A = _aliceAmount();
        int24 t0 = _spotTick();
        uint256 minted = _fundAndDeposit(ALICE, A);
        int24 t1 = _spotTick();
        if (restore) _restoreTick(t0);
        console2.log(string.concat("VSC|", tag, "|SETUP spot tick before Alice ", _s(t0), " after her deposit ", _s(t1), " after optional arbitrage ", _s(_spotTick()), " (restore=", restore ? "yes" : "no", ")"));
        console2.log(string.concat("VSC|", tag, "|SETUP incumbent Alice deposit ", _u(A), " shares ", _u(minted), " ; Safe seed shares ", _u(v.balanceOf(SAFE)), " ; total supply ", _u(v.totalSupply()), " ; haircut bps ", _u(v.valuationHaircutBps())));
    }

    function _depositCase(uint256 pctBps, string memory what) internal {
        _incumbent();
        Rep memory r = _measureDeposit(_aliceAmount() * pctBps / 10_000);
        _report(r, what);
        _assertRep(r);
    }

    function test_01_deposit_pct100() public {
        _depositCase(10_000, "deposit=100%");
    }

    /// Same as test_01..03 but the pool is arbitraged back to the pre-deposit tick after the incumbent's deposit (the
    /// state the earlier report's `_buildPosition` leaves). Spot == TWAP then, so the TWAP-vs-spot term is ~0.
    function test_01r_deposit_pct100_tickRestored() public {
        restore = true;
        _depositCase(10_000, "deposit=100% [tick restored]");
    }

    function test_02r_deposit_pct10_tickRestored() public {
        restore = true;
        _depositCase(1_000, "deposit=10% [tick restored]");
    }

    function test_03r_deposit_pct1_tickRestored() public {
        restore = true;
        _depositCase(100, "deposit=1% [tick restored]");
    }

    function test_04r_roundTrip_pct10_tickRestored() public {
        restore = true;
        _roundTripCase(1_000, "deposit=10% [tick restored]");
    }

    function test_05r_roundTrip_pct100_tickRestored() public {
        restore = true;
        _roundTripCase(10_000, "deposit=100% [tick restored]");
    }

    function test_06r_cycling_5x_pct10_tickRestored() public {
        restore = true;
        _cycling(1_000, 5, "deposit=10% x5 [tick restored]");
    }

    function test_08r_mutation_haircutZero_pct100_tickRestored() public {
        restore = true;
        _mutatedDeposit(10_000, "deposit=100% [tick restored]");
    }

    function test_10r_mutation_haircutZero_cycling_5x_pct10_tickRestored() public {
        restore = true;
        test_10_mutation_haircutZero_cycling_5x_pct10();
    }

    function test_02_deposit_pct10() public {
        _depositCase(1_000, "deposit=10%");
    }

    function test_03_deposit_pct1() public {
        _depositCase(100, "deposit=1%");
    }

    // ------------------------------------------------------------------ round trip and cycling
    function _sellPaired(address who, uint256 amt) internal returns (uint256 out) {
        if (amt == 0) return 0;
        vm.startPrank(who);
        paired.approve(router, amt);
        out = IVSCRouter(router).exactInputSingle(
            IVSCRouter.Params(address(paired), address(asset), v.tickSpacing(), who, block.timestamp + 1, amt, 0, 0)
        );
        vm.stopPrank();
    }

    struct Cyc {
        int256 netPpm; // cumulative attacker net, ppm of D
        int256 aliceChange; // cumulative change of Alice's in-kind oracle value
        int256 aliceChangePpm;
    }

    /// One round trip: deposit all of his asset, redeem in kind, sell the paired leg through the real router.
    /// Returns (net P&L of this cycle, entitlement value minus D, sale delta).
    function _cycle(uint256 D) internal returns (int256 net, int256 entMinusD, int256 saleDelta) {
        uint256 a0 = asset.balanceOf(BOB);
        require(a0 >= D, "bob short");
        vm.startPrank(BOB);
        asset.approve(address(v), D);
        uint256 sh = v.deposit(D, BOB);
        (uint256 ra, uint256 rp) = v.redeemInKind(sh, BOB, BOB);
        vm.stopPrank();
        uint256 proceeds = _sellPaired(BOB, rp);
        uint256 a1 = asset.balanceOf(BOB);
        net = int256(a1) - int256(a0);
        entMinusD = int256(ra + _val(rp)) - int256(D);
        saleDelta = int256(proceeds) - int256(_val(rp));
        // exact identity of the accounting: net = (entitlement value - D) + (sale proceeds - oracle value of the leg)
        assertEq(net, entMinusD + saleDelta, "round trip identity");
        assertEq(paired.balanceOf(BOB), 0, "paired leg fully sold");
    }

    function _roundTripCase(uint256 pctBps, string memory what) internal {
        _incumbent();
        uint256 D = _aliceAmount() * pctBps / 10_000;
        deal(address(asset), BOB, D);
        (uint256 ea, uint256 ep) = _ent(ALICE);
        uint256 alice0 = ea + _val(ep);
        // T of this deposit is measured in a snapshot (a separate, identical run), so the cycle below is a clean state
        uint256 snap = vm.snapshotState();
        Rep memory r = _measureDeposit(D);
        vm.revertToState(snap);
        deal(address(asset), BOB, D);
        (int256 net, int256 entMinusD, int256 saleDelta) = _cycle(D);
        (ea, ep) = _ent(ALICE);
        int256 aliceDelta = int256(ea + _val(ep)) - int256(alice0);
        console2.log(string.concat("VSC|", tag, "|ROUNDTRIP ", what, " D ", _u(D), ": net P&L ", _s(net), " = ", _s(_ppm(net, D)), " ppm of D = (entitlement - D) ", _s(entMinusD), " [of which T ", _s(r.T), ", deployment cost K-D ", _s(r.Hk - int256(D)), "] + (sale proceeds - oracle value of the paired leg) ", _s(saleDelta)));
        console2.log(string.concat("VSC|", tag, "|ROUNDTRIP ", what, " Alice in-kind value change ", _s(aliceDelta), " = ", _s(_ppm(aliceDelta, alice0)), " ppm"));
    }

    function test_04_roundTrip_pct10() public {
        _roundTripCase(1_000, "deposit=10%");
    }

    function test_05_roundTrip_pct100() public {
        _roundTripCase(10_000, "deposit=100%");
    }

    /// Cycle `n` times from the same incumbent state; cumulative attacker P&L and Alice's change after each cycle.
    function _cycling(uint256 pctBps, uint256 n, string memory what) internal returns (int256 attackerTotal, int256 aliceTotal) {
        _incumbent();
        uint256 D = _aliceAmount() * pctBps / 10_000;
        deal(address(asset), BOB, D);
        (uint256 ea, uint256 ep) = _ent(ALICE);
        uint256 alice0 = ea + _val(ep);
        int256 cum;
        for (uint256 i; i < n; ++i) {
            (int256 net,,) = _cycle(asset.balanceOf(BOB)); // he deposits his whole balance each cycle
            cum += net;
            (ea, ep) = _ent(ALICE);
            int256 ad = int256(ea + _val(ep)) - int256(alice0);
            console2.log(string.concat("VSC|", tag, "|CYCLING ", what, " cycle ", _u(i + 1), " attacker cumulative ", _s(cum), " (", _s(_ppm(cum, D)), " ppm of D) ; Alice cumulative ", _s(ad), " (", _s(_ppm(ad, alice0)), " ppm)"));
            attackerTotal = cum;
            aliceTotal = ad;
        }
    }

    function test_06_cycling_5x_pct10() public {
        (int256 att, int256 al) = _cycling(1_000, 5, "deposit=10% x5");
        att;
        al;
    }

    function test_07_cycling_5x_pct100() public {
        _cycling(10_000, 5, "deposit=100% x5");
    }

    /// Live seed-only state (no incumbent deposit: only the Safe's seed exists, as at the pin). The earlier report found
    /// the same round trip LOSES here (USDC -53/-52 ppm at USD 100/1,000; WAVAX -391/-133/-103 at USD 100/1,000/10,000).
    function _seedOnly(uint256 usd) internal {
        if (usd > _seedOnlyMaxUsd()) {
            // a USD 10,000 deposit into the seed-only Pharaoh USDC vault reverts ("Too little received": the swap slippage
            // bound); the earlier report ran USDC at USD 100 and 1,000 only. Not run, not a result.
            console2.log(string.concat("VSC|", tag, "|SEED-ONLY roundtrip USD ", _u(usd), " not run on this vault (deposit reverts at this size in the seed-only state)"));
            return;
        }
        uint256 D = _usd(usd);
        deal(address(asset), BOB, D);
        (int256 net, int256 entMinusD, int256 saleDelta) = _cycle(D);
        console2.log(string.concat("VSC|", tag, "|SEED-ONLY roundtrip USD ", _u(usd), " D ", _u(D), ": net ", _s(net), " = ", _s(_ppm(net, D)), " ppm of D; (entitlement - D) ", _s(entMinusD), " ; sale delta ", _s(saleDelta)));
    }

    function test_11_seedOnly_roundTrip_usd100() public {
        _seedOnly(100);
    }

    function test_11_seedOnly_roundTrip_usd1000() public {
        _seedOnly(1_000);
    }

    function test_11_seedOnly_roundTrip_usd10000() public {
        _seedOnly(10_000);
    }

    // ------------------------------------------------------------------ mutation control (local VM storage overwrite)
    function _zeroHaircut() internal {
        uint256 exp = uint256(uint24(v.tickRange())) | (uint256(v.twapPeriod()) << 24)
            | (uint256(v.maxTwapDeviationTicks()) << 56) | (uint256(v.maxOracleDeviationBps()) << 80)
            | (uint256(v.slippageBps()) << 96) | (uint256(v.valuationHaircutBps()) << 112);
        for (uint256 slot; slot < 64; ++slot) {
            bytes32 w = vm.load(address(v), bytes32(slot));
            if ((uint256(w) & ((uint256(1) << 128) - 1)) == exp) {
                uint256 cleared = uint256(w) & ~(uint256(0xFFFF) << 112);
                vm.store(address(v), bytes32(slot), bytes32(cleared));
                require(v.valuationHaircutBps() == 0, "mutation did not take");
                console2.log(string.concat("VSC|", tag, "|MUTATION valuationHaircutBps set to 0 in slot ", _u(slot), " (local VM only)"));
                return;
            }
        }
        revert("risk-parameter slot not found");
    }

    function _mutatedDeposit(uint256 pctBps, string memory what) internal {
        _incumbent();
        _zeroHaircut();
        Rep memory r = _measureDeposit(_aliceAmount() * pctBps / 10_000);
        _report(r, string.concat(what, " [haircut mutated to 0]"));
        // with the haircut at 0 the haircut part of T is exactly 0 by algebra; the decomposition is still an identity
        assertEq(r.partHair + r.partTwap + r.partMintFloor + r.partRedeem, r.T, "decomposition (mutated)");
        assertEq(r.minted, Math.mulDiv(r.V1 - r.V0c, r.S0 + 1, r.V0c + 1), "mint formula (mutated)");
        assertEq(r.Tcf, int256(0), "closed form is zero at h = 0");
    }

    function test_08_mutation_haircutZero_pct100() public {
        _mutatedDeposit(10_000, "deposit=100%");
    }

    function test_09_mutation_haircutZero_pct10() public {
        _mutatedDeposit(1_000, "deposit=10%");
    }

    function test_10_mutation_haircutZero_cycling_5x_pct10() public {
        // the same 5-cycle loop as test_06 with the haircut removed from the mint NAV
        _incumbent();
        _zeroHaircut();
        uint256 D = _aliceAmount() * 1_000 / 10_000;
        deal(address(asset), BOB, D);
        (uint256 ea, uint256 ep) = _ent(ALICE);
        uint256 alice0 = ea + _val(ep);
        int256 cum;
        for (uint256 i; i < 5; ++i) {
            (int256 net,,) = _cycle(asset.balanceOf(BOB));
            cum += net;
            (ea, ep) = _ent(ALICE);
            int256 ad = int256(ea + _val(ep)) - int256(alice0);
            console2.log(string.concat("VSC|", tag, "|CYCLING [haircut=0] deposit=10% x5 cycle ", _u(i + 1), " attacker cumulative ", _s(cum), " (", _s(_ppm(cum, D)), " ppm of D) ; Alice cumulative ", _s(ad), " (", _s(_ppm(ad, alice0)), " ppm)"));
        }
    }
}

interface IVSCDec {
    function decimals() external view returns (uint8);
}

contract AvalancheVaultShareCheckUsdcFork is VSCBase {
    function _vaultAddr() internal pure override returns (address) {
        return 0x855bF832f26a294d28500db59eE941dE3d654129;
    }

    function _defaultPin() internal pure override returns (uint256) {
        return 99216397;
    }

    function _name() internal pure override returns (string memory) {
        return "Pharaoh USDC vault (pair USDC/USDt, deposited USDC)";
    }

    function _aliceAmount() internal pure override returns (uint256) {
        return 2_000 * 1e6; // USD 2,000, the earlier report's incumbent on this vault
    }

    function _usd(uint256 usd) internal pure override returns (uint256) {
        return usd * 1e6;
    }

    function _seedOnlyMaxUsd() internal pure override returns (uint256) {
        return 1_000;
    }
}

contract AvalancheVaultShareCheckWavaxFork is VSCBase {
    function _vaultAddr() internal pure override returns (address) {
        return 0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8;
    }

    function _defaultPin() internal pure override returns (uint256) {
        return 99216312;
    }

    function _name() internal pure override returns (string memory) {
        return "Pharaoh WAVAX vault (pair sAVAX/WAVAX, deposited WAVAX)";
    }

    function _aliceAmount() internal view override returns (uint256) {
        return _usd(10_000); // the earlier report's incumbent: 1,169.36 WAVAX
    }

    function _usd(uint256 usd) internal view override returns (uint256) {
        (, int256 answer,,,) = IVSCFeed(AVAX_FEED).latestRoundData();
        return Math.mulDiv(usd * 1e8, 1e18, uint256(answer));
    }

    function _seedOnlyMaxUsd() internal pure override returns (uint256) {
        return 10_000;
    }
}
