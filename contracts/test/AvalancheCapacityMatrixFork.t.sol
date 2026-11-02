// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheSection5Base.sol";
import {Vm} from "forge-std/Vm.sol";

/**
 * @notice Handoff 00 section 4 / handoff 09 section 5 CAPACITY MATRIX on an Avalanche fork. Tests only.
 *
 * Every scenario runs the REAL contracts (controller, markets, margin stack, `PharaohCLRouterAdapter`, the real
 * Pharaoh router and WAVAX/USDC pool) from a snapshot of the pinned state and logs one machine-readable line:
 *
 *   MX|slice|cfg|side|marginUsd|k|path|lagBps|removalBps|step|poolBps|oracleBps|liqable|ok|revert|
 *      repayC|seizedC|rewardC|surplusC|insuranceC|residualC|worstCostBps|execE8|poolE8|oracleE8|gas
 *
 * (amounts in USD cents; bps relative to the pinned AVAX price; see tools/avalanche-capacity-report.py).
 *
 * Evidence classes, never mixed:
 *   path=oracle  : MOCKED oracle only, pool untouched (original fork pool).
 *   path=pool    : pool moved by REAL swaps (WHALE) and the oracle follows the pool price.
 *   path=lag     : pool moved by REAL swaps, oracle only follows `lagBps` of the way back toward the pin.
 *   removal>0    : EMULATED third-party liquidity removal: the adapter's router is replaced by a shim that executes
 *                  swaps of size 1/(1-r) in the real pool and returns (1-r) of the output. Exact for uniform removal
 *                  of third-party liquidity at all ticks (CL scale invariance); NOT a model of LPs leaving selectively.
 *   cfg ALT-*    : alternative risk parameters or LOOSENED GUARDS, shown for comparison; only `cand-2x25` is the
 *                  candidate launch configuration.
 *
 * Run: see the header of AvalancheSection5Base.sol; add --match-contract AvalancheCapacityMatrixForkTest -vv, then
 *   python3 tools/avalanche-capacity-report.py <forge output>.
 */
contract ScaledLiquidityRouterShim {
    IPharaohCLRouter public immutable real;
    uint256 public immutable num; // realIn = amountIn * num / den
    uint256 public immutable den;

    constructor(address real_, uint256 num_, uint256 den_) {
        real = IPharaohCLRouter(real_);
        num = num_;
        den = den_;
    }

    function deployer() external view returns (address) {
        return real.deployer();
    }

    function WETH9() external view returns (address) {
        return real.WETH9();
    }

    /// @dev Pulls the caller's input, trades `num/den` times as much from the shim's own inventory in the REAL
    ///      pool, forwards `den/num` of the output. Reverts like the router when the scaled output is too small.
    function exactInputSingle(IPharaohCLRouter.ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        uint256 realIn = p.amountIn * num / den;
        IERC20(p.tokenIn).approve(address(real), realIn);
        uint256 realOut = real.exactInputSingle(
            IPharaohCLRouter.ExactInputSingleParams(
                p.tokenIn, p.tokenOut, p.tickSpacing, address(this), p.deadline, realIn, 0, p.sqrtPriceLimitX96
            )
        );
        out = realOut * den / num;
        require(out >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

contract AvalancheCapacityMatrixForkTest is AvalancheSection5Base {
    struct Cfg {
        string name;
        uint16 lev;
        uint16 init;
        uint16 maint;
        uint16 slip;
        uint16 dev;
        uint16 flashFeeBps;
    }

    struct Scn {
        string slice;
        Cfg cfg;
        bool short;
        uint256 marginUsd;
        uint256 k;
        uint8 path; // 0 oracle-only, 1 pool follows, 2 pool moves and oracle lags
        uint16 lagBps;
        uint16 removalBps;
        uint16 accrualDays;
    }

    struct Pre {
        uint256 debt;
        uint256 positionTokens;
        uint256 marginFree;
        uint256 insurance;
        uint256 reward;
        int256 poolE8;
    }

    struct Row {
        uint256 step;
        uint256 target;
        int256 poolBps;
        int256 oracleAnswer;
        bool liqable;
        bool ok;
        string rev;
        uint256 worstCost;
        uint256 execE8;
        uint256 gasUsed;
    }

    uint256 internal snapPre;
    address internal shimAdapter;

    // ------------------------------------------------------------------ configurations
    function _cfg(uint256 i) internal pure returns (Cfg memory c) {
        if (i == 0) return Cfg("cand-2x25", 200, 5000, 2500, 100, 100, 0); // candidate launch configuration
        if (i == 1) return Cfg("ALT-2x40", 200, 5000, 4000, 100, 100, 0); // alternative maintenance margin
        if (i == 2) return Cfg("ALT-1.5x25", 150, 6700, 2500, 100, 100, 0); // alternative leverage
        return Cfg("ALT-guard300-2x25", 200, 5000, 2500, 300, 300, 0); // LOOSENED GUARDS (diagnostic only)
    }

    function _activateCfg(Cfg memory c) internal {
        // Large caps so that the pair caps never mask the measured liquidation limit.
        IsolatedMarginTypes.PairRiskConfig memory r = IsolatedMarginTypes.PairRiskConfig(
            true, c.lev, c.init, c.maint, 12_500, 5000, 5000, 500, c.slip, c.dev, 10_000_000e18, 10_000_000e18
        );
        mConfig.queuePairRisk(address(pUsdc), address(pWavax), address(pUsdc), r);
        mConfig.queuePairRisk(address(pUsdc), address(pUsdc), address(pWavax), r);
        mConfig.queueUnpauseOpens();
        vm.warp(block.timestamp + mConfig.actionDelay());
        _setPrices(avaxAnswer, usdcAnswer);
        mConfig.setPairRisk(address(pUsdc), address(pWavax), address(pUsdc), r);
        mConfig.setPairRisk(address(pUsdc), address(pUsdc), address(pWavax), r);
        mConfig.unpauseOpens();
        _activateLendingBorrows();
        lender.setFeeBps(c.flashFeeBps);
    }

    /// @dev More supplier cash, flash liquidity and borrow headroom so funding never masks the measured limit.
    function _scaleVenues() internal {
        _mintP(pUsdc, LP, 3_000_000e6);
        _mintP(pWavax, LP, 100_000e18);
        deal(USDC, address(this), 3_000_000e6);
        deal(WAVAX, address(this), 100_000e18);
        IERC20(USDC).approve(address(lender), type(uint256).max);
        IERC20(WAVAX).approve(address(lender), type(uint256).max);
        lender.depositLiquidity(USDC, 3_000_000e6);
        lender.depositLiquidity(WAVAX, 100_000e18);
        PToken[] memory ps = new PToken[](2);
        ps[0] = PToken(address(pWavax));
        ps[1] = PToken(address(pUsdc));
        uint256[] memory caps = new uint256[](2);
        caps[0] = 90_000e18;
        caps[1] = 2_500_000e6;
        controller._setMarketBorrowCaps(ps, caps);
    }

    function _installShim(uint16 removalBps) internal {
        // r removed => trade 1/(1-r) as much: num = 10000, den = 10000 - r
        ScaledLiquidityRouterShim shim = new ScaledLiquidityRouterShim(PHARAOH_ROUTER, 10_000, 10_000 - removalBps);
        deal(USDC, address(shim), 20_000_000e6);
        deal(WAVAX, address(shim), 2_000_000e18);
        PharaohCLRouterAdapter a =
            new PharaohCLRouterAdapter(address(shim), PHARAOH_FACTORY, PHARAOH_POOL, WAVAX, USDC, TICK_SPACING);
        shimAdapter = address(a);
        mConfig.queueExecutionEndpoints(address(a), address(lender));
        vm.warp(block.timestamp + mConfig.actionDelay());
        _refreshFeeds();
        mConfig.setExecutionEndpoints(address(a), address(lender));
    }

    // ------------------------------------------------------------------ valuation + logging helpers
    function _cents(address asset, uint256 amt) internal view returns (uint256) {
        if (asset == USDC) return Math.mulDiv(amt, uint256(usdcAnswer), 1e8 * 1e4);
        return Math.mulDiv(amt, uint256(avaxAnswer), 1e8 * 1e16);
    }

    function _u(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _i(int256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _bps(int256 answer8) internal view returns (int256) {
        return answer8 * 10_000 / realAvaxAnswer;
    }

    function _revName(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 4) return "empty";
        bytes4 sel = _selectorOf(ret);
        if (sel == 0x08c379a0) {
            bytes memory body = new bytes(ret.length - 4);
            for (uint256 i; i < body.length; ++i) body[i] = ret[i + 4];
            return abi.decode(body, (string));
        }
        if (sel == IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector) return "PriceUnavailable";
        if (sel == bytes4(0x91240a1b)) return "RedeemTransferOutNotPossible";
        if (sel == bytes4(keccak256("LiquidationError(uint8)"))) return string.concat("LiquidationError(", vm.toString(uint256(uint8(ret[ret.length - 1]))), ")");
        if (sel == bytes4(keccak256("SwapError(uint8)"))) return string.concat("SwapError(", vm.toString(uint256(uint8(ret[ret.length - 1]))), ")");
        return vm.toString(bytes32(sel));
    }

    /// @dev Move the real pool toward targetBps of the pinned price: coarse chunks first, fine near the target.
    function _movePoolAdaptive(uint256 targetBps) internal returns (uint256 usd) {
        bool down = targetBps < 10_000;
        uint256 coarseTarget = down ? targetBps + 500 : targetBps - 500;
        int256 cur = _bps(_poolAnswer8());
        bool needCoarse = down ? int256(coarseTarget) < cur : int256(coarseTarget) > cur;
        if (needCoarse) {
            (uint256 a,) = _movePoolTo(coarseTarget, 400e18, 50_000e6, 600);
            usd += a;
        }
        (uint256 b,) = _movePoolTo(targetBps, 25e18, 2_500e6, 1_500);
        usd += b;
    }

    // ------------------------------------------------------------------ scenario engine
    function _run(Scn memory s, uint256[] memory steps) internal {
        vm.revertToState(snapPre);
        snapPre = vm.snapshotState();
        _setPrices(avaxAnswer, usdcAnswer); // vm.mockCall state survives revertToState: re-serve the pinned answers
        _scaleVenues();
        _activateCfg(s.cfg);
        // open k positions; an open that fails (e.g. the pool moved by earlier opens) is a RESULT, not an abort
        uint256[] memory ids = new uint256[](s.k);
        uint256 opened;
        for (uint256 i; i < s.k; ++i) {
            address user = address(uint160(0x7000 + i));
            uint256 shares = _marginPTokens(user, s.marginUsd * 1e6);
            (IsolatedMarginExecutorUpgradeable.OpenParams memory op,) = _openParams(s.short, shares, s.cfg.lev);
            vm.prank(user);
            (bool okOpen, bytes memory retOpen) =
                address(executor).call(abi.encodeWithSelector(IsolatedMarginExecutorUpgradeable.openPosition.selector, op));
            if (!okOpen) {
                emit log_string(
                    string.concat(
                        "MXOPEN|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k), "|", _u(opened), "|", _revName(retOpen), "|END"
                    )
                );
                break;
            }
            ids[opened++] = abi.decode(retOpen, (uint256));
        }
        if (opened < s.k) {
            if (opened == 0) return;
            s.k = opened; // liquidate only what opened
        }
        if (s.accrualDays > 0) {
            vm.roll(block.number + uint256(s.accrualDays) * 86_400);
            vm.warp(block.timestamp + uint256(s.accrualDays) * 86_400);
            _refreshFeeds();
            pUsdc.accrueInterest();
            pWavax.accrueInterest();
        }
        if (s.removalBps > 0) _installShim(s.removalBps);
        bool[] memory done = new bool[](s.k);
        int256 lastPool;
        for (uint256 st; st < steps.length; ++st) {
            uint256 target = steps[st];
            int256 poolBps;
            int256 oracleAnswer;
            if (s.path == 0) {
                poolBps = _bps(_poolAnswer8());
                oracleAnswer = int256((uint256(realAvaxAnswer) * target) / 10_000);
            } else {
                _movePoolAdaptive(target);
                poolBps = _bps(_poolAnswer8());
                int256 poolAns = _poolAnswer8();
                oracleAnswer = poolAns;
                if (s.path == 2) oracleAnswer = poolAns + (realAvaxAnswer - poolAns) * int256(uint256(s.lagBps)) / 10_000;
                // path 3: oracle sits a FIXED gap behind the pool (above it when the pool falls, below when it rises)
                if (s.path == 3) oracleAnswer = poolAns * (s.short ? int256(10_000) - int256(uint256(s.lagBps)) : int256(10_000) + int256(uint256(s.lagBps))) / 10_000;
            }
            _setPrices(oracleAnswer, usdcAnswer);
            bool reached = s.short ? poolBps >= int256(target) - 50 : poolBps <= int256(target) + 50;
            for (uint256 i; i < s.k; ++i) {
                if (done[i]) continue;
                IsolatedMarginTypes.Position memory p = _position(ids[i]);
                bool liqable = riskEngine.isLiquidatable(p.account);
                if (!liqable) {
                    if (i == 0) _logMx(s, Row(st, target, poolBps, oracleAnswer, false, false, "-", 0, 0, 0), Pre(0, 0, 0, 0, 0, 0));
                    continue;
                }
                _attempt(s, st, target, ids[i], poolBps, oracleAnswer);
                if (_position(ids[i]).status == IsolatedMarginTypes.Status.LIQUIDATED) done[i] = true;
            }
            if (s.path != 0 && !reached && poolBps == lastPool) break; // pool cannot move further (floor/wall)
            lastPool = poolBps;
        }
    }

    function _attempt(Scn memory s, uint256 step, uint256 target, uint256 id, int256 poolBps, int256 oracleAnswer) internal {
        lastId = id;
        IsolatedMarginTypes.Position memory p = _position(id);
        PErc20Delegator debtM = PErc20Delegator(payable(p.debtPToken));
        PErc20Delegator posM = PErc20Delegator(payable(p.positionPToken));
        address debtAsset = s.short ? WAVAX : USDC;
        Pre memory pre;
        pre.debt = debtM.borrowBalanceCurrent(p.account);
        pre.positionTokens = posM.balanceOf(p.account);
        pre.marginFree = mVault.freeBalance(p.owner, address(pUsdc));
        pre.insurance = _insuranceCents();
        pre.reward = IERC20(debtAsset).balanceOf(KEEPER_RECIPIENT);
        pre.poolE8 = _poolAnswer8();
        vm.recordLogs();
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(id)));
        uint256 gasUsed = g - gasleft();
        (uint256 worstCost, uint256 execE8) = _swapCost(oracleAnswer);
        _logMx(s, Row(step, target, poolBps, oracleAnswer, true, ok, ok ? "-" : _revName(ret), worstCost, execE8, gasUsed), pre);
    }

    /// @dev Execution cost of every pool swap in the recorded logs versus the oracle price at execution (bps,
    ///      only the UNFAVOURABLE direction counts), and the volume-weighted execution price (USD/AVAX e8).
    function _swapCost(int256 oracleAnswer) internal returns (uint256 worstCostBps, uint256 execE8) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 volWavax;
        uint256 volUsd;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != PHARAOH_POOL || logs[i].topics.length != 3 || logs[i].data.length < 64) continue;
            (int256 a0, int256 a1) = abi.decode(logs[i].data, (int256, int256));
            if (a0 == 0 || a1 == 0) continue;
            uint256 w = uint256(a0 < 0 ? -a0 : a0);
            uint256 u = uint256(a1 < 0 ? -a1 : a1);
            uint256 e8 = Math.mulDiv(u, 1e20, w); // USD per AVAX, 8 decimals
            volWavax += w;
            volUsd += u;
            uint256 oracle8 = uint256(oracleAnswer);
            uint256 cost;
            if (a0 > 0) {
                // pool received WAVAX (we sold): unfavourable when exec < oracle
                if (e8 < oracle8) cost = (oracle8 - e8) * 10_000 / oracle8;
            } else {
                // pool paid out WAVAX (we bought): unfavourable when exec > oracle
                if (e8 > oracle8) cost = (e8 - oracle8) * 10_000 / oracle8;
            }
            if (cost > worstCostBps) worstCostBps = cost;
        }
        if (volWavax > 0) execE8 = Math.mulDiv(volUsd, 1e20, volWavax);
    }

    function _insuranceCents() internal view returns (uint256) {
        uint256 u = Math.mulDiv(pUsdc.balanceOf(address(insuranceFund)), pUsdc.exchangeRateStored(), 1e18);
        uint256 w = Math.mulDiv(pWavax.balanceOf(address(insuranceFund)), pWavax.exchangeRateStored(), 1e18);
        return _cents(USDC, u) + _cents(WAVAX, w);
    }

    function _logMx(Scn memory s, Row memory r, Pre memory pre) internal {
        uint256[6] memory d; // repay, seized, reward, surplus, insurance, residual (USD cents)
        if (r.liqable) (d[0], d[1], d[2], d[3], d[4], d[5]) = _deltas(s, pre);
        string memory head = string.concat(
            "MX|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k)
        );
        head = string.concat(head, "|", _u(s.path), "|", _u(s.lagBps), "|", _u(s.removalBps), "|", _u(r.step), "|", _u(r.target));
        head = string.concat(head, "|", _i(r.poolBps), "|", _i(_bps(r.oracleAnswer)), "|", r.liqable ? "1" : "0", "|", r.ok ? "1" : "0", "|", r.rev);
        head = string.concat(head, "|", _u(d[0]), "|", _u(d[1]), "|", _u(d[2]), "|", _u(d[3]), "|", _u(d[4]), "|", _u(d[5]));
        head = string.concat(head, "|", _u(r.worstCost), "|", _u(r.execE8), "|", _u(r.gasUsed), "|END");
        emit log_string(head);
    }

    uint256 internal lastId;

    function _deltas(Scn memory s, Pre memory pre)
        internal
        view
        returns (uint256 repayC, uint256 seizedC, uint256 rewardC, uint256 surplusC, uint256 insuranceC, uint256 residualC)
    {
        if (lastId == 0) return (0, 0, 0, 0, 0, 0);
        IsolatedMarginTypes.Position memory p = _position(lastId);
        PErc20Delegator debtM = PErc20Delegator(payable(p.debtPToken));
        PErc20Delegator posM = PErc20Delegator(payable(p.positionPToken));
        address debtAsset = s.short ? WAVAX : USDC;
        address posAsset = s.short ? USDC : WAVAX;
        uint256 debtAfter = debtM.borrowBalanceStored(p.account);
        repayC = _cents(debtAsset, pre.debt > debtAfter ? pre.debt - debtAfter : 0);
        residualC = _cents(debtAsset, debtAfter);
        uint256 posAfter = posM.balanceOf(p.account);
        uint256 seizedTokens = pre.positionTokens > posAfter ? pre.positionTokens - posAfter : 0;
        seizedC = _cents(posAsset, Math.mulDiv(seizedTokens, posM.exchangeRateStored(), 1e18));
        rewardC = _cents(debtAsset, IERC20(debtAsset).balanceOf(KEEPER_RECIPIENT) - pre.reward);
        uint256 freeAfter = mVault.freeBalance(p.owner, address(pUsdc));
        surplusC = _cents(USDC, Math.mulDiv(freeAfter > pre.marginFree ? freeAfter - pre.marginFree : 0, pUsdc.exchangeRateStored(), 1e18));
        uint256 insNow = _insuranceCents();
        insuranceC = pre.insurance > insNow ? pre.insurance - insNow : 0;
    }

    // ------------------------------------------------------------------ slices
    function _steps(bool short, uint256 n) internal pure returns (uint256[] memory a) {
        a = new uint256[](n);
        // finer steps near the pool's liquidity walls (sell side ~ -20%, buy side ~ +50%), coarse beyond them
        uint256[8] memory dn = [uint256(9_500), 9_000, 8_500, 8_250, 8_000, 7_000, 5_000, 2_000];
        uint256[8] memory up = [uint256(11_000), 11_500, 12_000, 12_500, 13_500, 15_000, 20_000, 30_000];
        for (uint256 i; i < n; ++i) a[i] = short ? up[i] : dn[i];
    }

    function _slice(string memory slice, uint8 path, uint16 lag, uint16 removal, uint16 accrual, uint16 flashFee, uint256 cfgCount, uint256[] memory sizes, uint256 k)
        internal
    {
        snapPre = vm.snapshotState();
        for (uint256 c; c < cfgCount; ++c) {
            for (uint256 sd; sd < 2; ++sd) {
                for (uint256 z; z < sizes.length; ++z) {
                    Cfg memory cfg = _cfg(c);
                    cfg.flashFeeBps = flashFee;
                    Scn memory s = Scn(slice, cfg, sd == 1, sizes[z], k, path, lag, removal, accrual);
                    _runTracked(s, _steps(sd == 1, 8));
                }
            }
        }
    }

    /// @dev wrapper that remembers the id of the position under liquidation for `_deltas`
    function _runTracked(Scn memory s, uint256[] memory steps) internal {
        _run(s, steps);
    }

    function _sizes1(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory x) {
        x = new uint256[](3);
        x[0] = a;
        x[1] = b;
        x[2] = c;
    }

    function _cfgs(uint256 n) internal pure returns (uint256) {
        return n;
    }

    function _sizes2(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        x[0] = a;
        x[1] = b;
    }

    function _sizes(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }

    // A. MOCKED oracle only, pool untouched, one position.
    function testMatrix_A_oracleOnly_singlePosition() public {
        _slice("oracle-only", 0, 0, 0, 0, 0, 4, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // B. REAL pool swaps, oracle follows the pool (consistent adverse path), one position.
    function testMatrix_B_poolFollows_singlePosition() public {
        _slice("pool-follows", 1, 0, 0, 0, 0, 4, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // C. REAL pool swaps, oracle lags: 50% and 90% of the move still to come.
    function testMatrix_C1_oracleLag50() public {
        _slice("lag50", 2, 5_000, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    function testMatrix_C2_oracleLag90() public {
        _slice("lag90", 2, 9_000, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // C3. Oracle a FIXED absolute gap behind the REAL pool: 50 / 100 / 200 bps (reachable between feed updates)
    function testMatrix_C3_fixedLag50() public {
        _slice("fixedlag50", 3, 50, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    function testMatrix_C4_fixedLag100() public {
        _slice("fixedlag100", 3, 100, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    function testMatrix_C5_fixedLag200() public {
        _slice("fixedlag200", 3, 200, 0, 0, 0, 2, _sizes1(1_000, 5_000, 25_000), 1);
    }

    // D. EMULATED removal of 50% of third-party liquidity (shim), pool follows.
    function testMatrix_D_removal50_poolFollows() public {
        _slice("removal50", 1, 0, 5_000, 0, 0, 2, _sizes2(5_000, 25_000), 1);
    }

    // E. 90 days of accrued debt and a 9 bps flash fee.
    function testMatrix_E_accrual90d_flashFee9() public {
        _slice("accrual90d-fee9", 1, 0, 0, 90, 9, 2, _sizes2(5_000, 25_000), 1);
    }

    // F. Correlated sequential liquidations: k positions of the same size, largest first, pool/cash/funding updated.
    function testMatrix_F1_aggregate_1k_x5() public {
        _slice("agg-k5", 1, 0, 0, 0, 0, 2, _sizes(1_000), 5);
    }

    function testMatrix_F2_aggregate_5k_x10() public {
        _slice("agg-k10", 1, 0, 0, 0, 0, 2, _sizes(5_000), 10);
    }

    function testMatrix_F3_aggregate_25k_x4() public {
        _slice("agg-k4", 1, 0, 0, 0, 0, 2, _sizes(25_000), 4);
    }

    // ------------------------------------------------------------------ G. ordinary lending liquidations
    function testMatrix_G_ordinaryLending() public {
        snapPre = vm.snapshotState();
        for (uint256 dir; dir < 2; ++dir) {
            uint256[3] memory utils = [uint256(70), 90, 99];
            uint256[2] memory counts = [uint256(1), 5];
            for (uint256 ui; ui < utils.length; ++ui) {
                for (uint256 ci; ci < counts.length; ++ci) {
                    _ordinary(dir == 1, utils[ui], counts[ci], type(uint256).max);
                }
            }
        }
    }

    // G2. ordinary lending after a price GAP (no intermediate liquidations): jump straight to the step price
    function testMatrix_G2_ordinaryGap() public {
        snapPre = vm.snapshotState();
        for (uint256 dir; dir < 2; ++dir) {
            uint256[2] memory utils = [uint256(70), 99];
            uint256[4] memory steps = [uint256(3), 5, 6, 7];
            for (uint256 ui; ui < utils.length; ++ui) {
                for (uint256 si; si < steps.length; ++si) {
                    _ordinary(dir == 1, utils[ui], 5, steps[si]);
                }
            }
        }
    }

    struct Ord {
        bool usdcCol;
        bool gap;
        uint256 util;
        uint256 n;
        PErc20Delegator colM;
        PErc20Delegator debtM;
        address debtAsset;
        address colAsset;
        address[] bs;
    }

    function _ordinary(bool usdcCollateral, uint256 util, uint256 n, uint256 onlyStep) internal {
        vm.revertToState(snapPre);
        snapPre = vm.snapshotState();
        _setPrices(avaxAnswer, usdcAnswer); // vm.mockCall state survives revertToState: re-serve the pinned answers
        _scaleVenues();
        _activateLendingBorrows();
        Ord memory o;
        o.usdcCol = usdcCollateral;
        o.gap = onlyStep != type(uint256).max;
        o.util = util;
        o.n = n;
        o.colM = usdcCollateral ? pUsdc : pWavax;
        o.debtM = usdcCollateral ? pWavax : pUsdc;
        o.debtAsset = usdcCollateral ? WAVAX : USDC;
        o.colAsset = usdcCollateral ? USDC : WAVAX;
        o.bs = new address[](n);
        for (uint256 i; i < n; ++i) {
            o.bs[i] = address(uint160(0x9000 + i));
            _mintP(o.colM, o.bs[i], usdcCollateral ? 10_000e6 : Math.mulDiv(10_000e6 * 1e12, 1e8, uint256(realAvaxAnswer)));
            _enter(o.bs[i]);
            (, uint256 liq,) = controller.getAccountLiquidity(o.bs[i]);
            uint256 amt = usdcCollateral ? Math.mulDiv(liq * util / 100, 1e8, uint256(realAvaxAnswer)) : liq * util / 100 / 1e12;
            (bool ok,) = _borrow(o.debtM, o.bs[i], amt);
            require(ok, string.concat("ordinary setup borrow util=", _u(util)));
        }
        for (uint256 st; st < 8; ++st) {
            if (onlyStep != type(uint256).max && st != onlyStep) continue; // gap: jump straight to this price
            _ordinaryStep(o, st);
        }
    }

    function _ordinaryStep(Ord memory o, uint256 st) internal {
        uint256[8] memory dn = [uint256(9_000), 8_000, 7_000, 6_000, 5_000, 4_000, 3_000, 2_000];
        uint256[8] memory up = [uint256(11_000), 12_500, 15_000, 17_500, 20_000, 25_000, 30_000, 40_000];
        uint256 target = o.usdcCol ? up[st] : dn[st];
        _setAvaxBps(target);
        uint256[6] memory agg; // inShortfall, repayC, netSeizedC, protocolC, residualDebtC, badDebtC
        for (uint256 i; i < o.n; ++i) _ordinaryBorrower(o, o.bs[i], agg);
        emit log_string(
            string.concat(
                "OX|", o.gap ? "GAP " : "path ", o.usdcCol ? "usdc-collateral/wavax-debt" : "wavax-collateral/usdc-debt", "|", _u(o.util), "|", _u(o.n), "|", _u(st), "|",
                _u(target), "|", _u(agg[0]), "|", _u(agg[1]), "|", _u(agg[2]), "|", _u(agg[3]), "|", _u(agg[4]), "|", _u(agg[5]), "|END"
            )
        );
    }

    function _ordinaryBorrower(Ord memory o, address b, uint256[6] memory agg) internal {
        (,, uint256 sf) = controller.getAccountLiquidity(b);
        if (sf == 0) return;
        agg[0]++;
        for (uint256 it; it < 12; ++it) {
            (,, uint256 sf2) = controller.getAccountLiquidity(b);
            if (sf2 == 0 || o.colM.balanceOf(b) == 0) break;
            uint256 repay = o.debtM.borrowBalanceCurrent(b) / 2; // close factor
            bool done;
            // a sophisticated liquidator halves the repay until the seize fits the remaining collateral
            for (uint256 h; h < 12 && repay > 0; ++h) {
                (bool ok,, uint256 seized) = _liquidateOrdinary(o.debtM, o.colM, b, repay);
                if (ok) {
                    agg[1] += _cents(o.debtAsset, repay);
                    uint256 net = _cents(o.colAsset, Math.mulDiv(seized, o.colM.exchangeRateStored(), 1e18));
                    agg[2] += net;
                    agg[3] += net * 28 / 972;
                    done = true;
                    break;
                }
                repay /= 2;
            }
            if (!done) break;
        }
        uint256 left = _cents(o.debtAsset, o.debtM.borrowBalanceStored(b));
        uint256 collLeft = _cents(o.colAsset, Math.mulDiv(o.colM.balanceOf(b), o.colM.exchangeRateStored(), 1e18));
        agg[4] += left;
        if (left > collLeft) agg[5] += left - collLeft; // debt not covered by remaining collateral
    }

    // ------------------------------------------------------------------ H. swap-guard reconciliation
    /// @dev Calls the REAL IsolatedMarginSwapModule with the oracle placed above/below the pool price and logs the
    ///      oracle price, pool price, expected/min/actual output and the exact revert, in both directions.
    ///      The module's conditions: protocolMinOut = expectedOut(oracle) * (1 - maxSlippageBps); the adapter hands
    ///      max(userMin, protocolMinOut) to the router, which reverts "Too little received" when the pool pays less;
    ///      afterwards SwapError(7) if out < min and SwapError(8) if oracleValue(out) < oracleValue(in)*(1-dev).
    ///      Favourable execution (pool pays MORE than the oracle expects) always passes: it is not a symmetric check.
    function testSwapGuard_directionTable() public {

        int256[13] memory d = [int256(-300), -150, -101, -100, -99, -50, 0, 50, 99, 100, 101, 150, 300];
        uint256 snap = vm.snapshotState();
        _activate();
        for (uint256 dir; dir < 2; ++dir) {
            for (uint256 j; j < d.length; ++j) {
                vm.revertToState(snap);
                snap = vm.snapshotState();
                _guardPoint(dir == 1, d[j], 5_000e6, 100, 100, "candidate-guard");
            }
        }
        // ALTERED GUARD (diagnostic only, not a candidate): slippage 300 / deviation 50 makes SwapError(8) reachable.
        int256[3] memory dd = [int256(250), 100, 40]; // oracle ABOVE the pool: the sell leg is UNFAVOURABLE
        for (uint256 j; j < dd.length; ++j) {
            vm.revertToState(snap);
            snap = vm.snapshotState();
            _guardPoint(false, dd[j], 5_000e6, 300, 50, "ALTERED-guard-slip300-dev50");
        }
    }

    function _guardPoint(bool buyWavax, int256 deltaBps, uint256 usd6, uint16 slip, uint16 dev, string memory label) internal {
        int256 poolAns = _poolAnswer8();
        int256 oracleAns = poolAns + poolAns * deltaBps / 10_000; // oracle relative to the pool
        _setPrices(oracleAns, usdcAnswer);
        address tin = buyWavax ? USDC : WAVAX;
        address tout = buyWavax ? WAVAX : USDC;
        uint256 amountIn = buyWavax ? usd6 : Math.mulDiv(usd6 * 1e12, 1e8, uint256(poolAns));
        deal(tin, address(this), amountIn);
        IERC20(tin).approve(address(swapModule), amountIn);
        uint256 expected = quoter.expectedOut(tin, tout, amountIn);
        uint256 minOut = Math.mulDiv(expected, 10_000 - slip, 10_000);
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory ret) = address(swapModule)
            .call(abi.encodeWithSelector(IsolatedMarginSwapModule.executeSwap.selector, tin, tout, amountIn, uint256(0), slip, dev, bytes("")));
        uint256 actual;
        if (ok) {
            actual = abi.decode(ret, (uint256));
        } else {
            // learn what the pool would actually pay, by trading it directly in a reverted branch
            vm.revertToState(snap);
            IERC20(tin).approve(address(clAdapter), amountIn);
            (bool ok2, uint256 o2) = _adapterOut(tin, tout, amountIn);
            actual = ok2 ? o2 : 0;
        }
        uint256 execE8 = actual == 0 ? 0 : (buyWavax ? Math.mulDiv(amountIn, 1e20, actual) : Math.mulDiv(actual, 1e20, amountIn));
        emit log_string(
            string.concat(
                "SG|", label, "|", buyWavax ? "buy-WAVAX" : "sell-WAVAX", "|", _i(deltaBps), "|oracleE8=", _i(oracleAns), "|poolE8=", _i(poolAns),
                "|expectedOut=", _u(expected), "|minOut=", _u(minOut), "|actualOut=", _u(actual), "|execE8=", _u(execE8)
            )
        );
        emit log_string(string.concat("SG2|", ok ? "PASS" : "REVERT", "|", ok ? "-" : _revName(ret), "|END"));
    }

    function _adapterOut(address tin, address tout, uint256 amountIn) internal returns (bool, uint256) {
        try clAdapter.swap(address(this), tin, tout, amountIn, 1, "") returns (uint256 o) {
            return (true, o);
        } catch {
            return (false, 0);
        }
    }
}
