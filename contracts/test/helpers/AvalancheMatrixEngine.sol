// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./AvalancheSection5Base.sol";
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

abstract contract AvalancheMatrixEngine is AvalancheSection5Base {
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
        uint256 insU; // insurance fund pTokens valued in USDC base units (before)
        uint256 insW; // insurance fund pTokens valued in WAVAX base units (before)
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
    // Funded in-kind fallback mode for the NEXT slice: 0 = normal route only, 1 = fallback with a break-even floor
    // (minSeizeValueBps 10_000), 2 = fallback with NO floor (the funder absorbs any shortfall).
    uint8 internal fbMode;
    bool internal drainMode; // drain the redemption market of the position token to ZERO cash after opening
    uint256 internal usdcPeg8; // 0 = pinned USDC answer; otherwise USDC/USD answer (8 dec) used for the whole scenario
    address internal constant FUNDER = address(0xF00D);
    uint256 internal constant FB_USDC = 30_000e6; // finite budgets, funded ONCE per scenario, never replenished
    uint256 internal constant FB_WAVAX = 3_500e18;
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

    /// @dev '|' is the log field separator: never let a revert string shift fields.
    function _clean(string memory x) internal pure returns (string memory) {
        bytes memory b = bytes(x);
        for (uint256 i; i < b.length; ++i) if (b[i] == "|" || b[i] == "\n") b[i] = "/";
        return string(b);
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
        // The test contract's own storage is restored by revertToState; vm.mockCall state is NOT. Assert every scenario starts
        // from the pinned prices before re-serving them.
        require(avaxAnswer == realAvaxAnswer && block.number == 99_200_000, "scenario does not start at the pin");
        _setPrices(avaxAnswer, usdcAnswer);
        _scaleVenues();
        _activateCfg(s.cfg);
        // (a USDC depeg, if any, is applied AFTER the positions are opened, at the first stress step)
        if (fbMode != 0) _setupFunder();
        if (drainMode) {
            PToken[] memory dps = new PToken[](2);
            dps[0] = PToken(address(pWavax));
            dps[1] = PToken(address(pUsdc));
            uint256[] memory dcaps = new uint256[](2);
            dcaps[0] = type(uint128).max;
            dcaps[1] = type(uint128).max;
            controller._setMarketBorrowCaps(dps, dcaps);
        }
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
                        "MXOPEN|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k), "|", _u(opened), "|", _clean(_revName(retOpen)), "|END"
                    )
                );
                break;
            }
            ids[opened++] = abi.decode(retOpen, (uint256));
        }
        {
            // the ACTUAL opened position ids (generator reconciles snapshots and attempts against exactly this set)
            string memory idList;
            for (uint256 j; j < opened; ++j) idList = string.concat(idList, j == 0 ? "" : ",", _u(ids[j]));
            emit log_string(
                string.concat(
                    "MXIDS|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k), "|", _u(opened), "|", idList, "|END"
                )
            );
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
        if (drainMode) _drainCash(s.short ? pUsdc : pWavax, s.short ? pWavax : pUsdc); // zero cash where the seized pTokens would be redeemed
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
            if (usdcPeg8 != 0) usdcAnswer = int256(usdcPeg8); // depeg shock lands after opening
            _setPrices(oracleAnswer, usdcAnswer);
            bool reached = s.short ? poolBps >= int256(target) - 50 : poolBps <= int256(target) + 50;
            for (uint256 i; i < s.k; ++i) {
                if (done[i]) continue;
                IsolatedMarginTypes.Position memory p = _position(ids[i]);
                bool liqable = riskEngine.isLiquidatable(p.account);
                if (!liqable) {
                    if (i == 0) _logMx(s, Row(st, target, poolBps, oracleAnswer, false, false, "-", 0, 0, 0), Pre(0, 0, 0, 0, 0, 0, 0, 0));
                    continue;
                }
                _attempt(s, st, target, ids[i], poolBps, oracleAnswer);
                if (_position(ids[i]).status == IsolatedMarginTypes.Status.LIQUIDATED) done[i] = true;
            }
            // Fallback at the SAME stressed state: positions the normal route left liquidatable go to the funded route.
            if (fbMode != 0) {
                for (uint256 i; i < s.k; ++i) {
                    if (done[i]) continue;
                    IsolatedMarginTypes.Position memory fp = _position(ids[i]);
                    if (fp.status != IsolatedMarginTypes.Status.ACTIVE || !riskEngine.isLiquidatable(fp.account)) continue;
                    _attemptFunded(s, st, ids[i], poolBps);
                    if (_position(ids[i]).status == IsolatedMarginTypes.Status.LIQUIDATED) done[i] = true;
                }
            }
            if (s.path != 0 && !reached && poolBps == lastPool) break; // pool cannot move further (floor/wall)
            lastPool = poolBps;
        }
        _logEnd(s, ids);
        if (fbMode != 0) _logFunder(s);
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
        (pre.insU, pre.insW) = _insTok();
        vm.recordLogs();
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(id)));
        uint256 gasUsed = g - gasleft();
        (uint256 worstCost, uint256 execE8) = _swapCost(oracleAnswer);
        _logMx(s, Row(step, target, poolBps, oracleAnswer, true, ok, ok ? "-" : _revName(ret), worstCost, execE8, gasUsed), pre);
        _logTok(s, id, step, ok, pre);
    }

    function _setupFunder() internal {
        mConfig.queueFundedLiquidator(FUNDER);
        vm.warp(block.timestamp + mConfig.actionDelay());
        _refreshFeeds();
        mConfig.addFundedLiquidator(FUNDER);
        deal(USDC, FUNDER, FB_USDC);
        deal(WAVAX, FUNDER, FB_WAVAX);
        vm.startPrank(FUNDER);
        IERC20(USDC).approve(address(liquidator), FB_USDC); // approve only the budget
        IERC20(WAVAX).approve(address(liquidator), FB_WAVAX);
        vm.stopPrank();
    }

    function _funderInventory() internal view returns (uint256 invU, uint256 invW) {
        invU = Math.mulDiv(pUsdc.balanceOf(FUNDER), pUsdc.exchangeRateStored(), 1e18);
        invW = Math.mulDiv(pWavax.balanceOf(FUNDER), pWavax.exchangeRateStored(), 1e18);
    }

    function _attemptFunded(Scn memory s, uint256 step, uint256 id, int256 poolBps) internal {
        IsolatedMarginTypes.Position memory p = _position(id);
        address debtAsset = s.short ? WAVAX : USDC;
        uint256 budgetBefore = IERC20(debtAsset).balanceOf(FUNDER);
        (uint256 invUb, uint256 invWb) = _funderInventory();
        uint256 debtBefore = PErc20Delegator(payable(p.debtPToken)).borrowBalanceCurrent(p.account);
        IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams memory fp = IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(
            id, FUNDER, budgetBefore, 0, 0, fbMode == 1 ? 10_000 : 0
        );
        vm.prank(FUNDER);
        (bool ok, bytes memory ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidateFunded.selector, fp));
        (uint256 invUa, uint256 invWa) = _funderInventory();
        uint256 repaidTok = budgetBefore - IERC20(debtAsset).balanceOf(FUNDER);
        uint256 seizedValC = _cents(USDC, invUa > invUb ? invUa - invUb : 0) + _cents(WAVAX, invWa > invWb ? invWa - invWb : 0);
        string memory a = string.concat(
            "MXF|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k), "|", _u(id), "|", _u(step), "|", ok ? "1" : "0",
            "|", ok ? "-" : _clean(_revName(ret)), "|", _i(poolBps)
        );
        a = string.concat(a, "|", _u(debtBefore), "|", _u(repaidTok), "|", _u(_cents(debtAsset, repaidTok)), "|", _u(seizedValC), "|", _u(uint8(_position(id).status)), "|END");
        emit log_string(a);
    }

    function _logFunder(Scn memory s) internal {
        (uint256 invU, uint256 invW) = _funderInventory();
        uint256 invC = _cents(USDC, invU) + _cents(WAVAX, invW);
        // what the inventory could be redeemed for right now: limited by market cash
        uint256 redU = invU < pUsdc.getCash() ? invU : pUsdc.getCash();
        uint256 redW = invW < pWavax.getCash() ? invW : pWavax.getCash();
        emit log_string(
            string.concat(
                "MXFSUM|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k), "|", _u(FB_USDC), "|", _u(FB_WAVAX),
                "|", _u(IERC20(USDC).balanceOf(FUNDER)), "|", _u(IERC20(WAVAX).balanceOf(FUNDER)), "|", _u(invU), "|", _u(invW), "|", _u(invC),
                "|", _u(redU), "|", _u(redW), "|END"
            )
        );
    }

    function _insTok() internal view returns (uint256 u, uint256 w) {
        u = Math.mulDiv(pUsdc.balanceOf(address(insuranceFund)), pUsdc.exchangeRateStored(), 1e18);
        w = Math.mulDiv(pWavax.balanceOf(address(insuranceFund)), pWavax.exchangeRateStored(), 1e18);
    }

    /// @dev Token-unit accounting for one attempt: what moved, in base units of each asset, and what funding is left.
    function _logTok(Scn memory s, uint256 id, uint256 step, bool ok, Pre memory pre) internal {
        IsolatedMarginTypes.Position memory p = _position(id);
        PErc20Delegator debtM = PErc20Delegator(payable(p.debtPToken));
        PErc20Delegator posM = PErc20Delegator(payable(p.positionPToken));
        address debtAsset = s.short ? WAVAX : USDC;
        uint256 debtAfter = debtM.borrowBalanceStored(p.account);
        uint256 posAfter = posM.balanceOf(p.account);
        uint256 seizedTok = Math.mulDiv(pre.positionTokens > posAfter ? pre.positionTokens - posAfter : 0, posM.exchangeRateStored(), 1e18);
        uint256 freeAfter = mVault.freeBalance(p.owner, address(pUsdc));
        uint256 surplusTok = Math.mulDiv(freeAfter > pre.marginFree ? freeAfter - pre.marginFree : 0, pUsdc.exchangeRateStored(), 1e18);
        (uint256 iu, uint256 iw) = _insTok();
        string memory a = string.concat(
            "MXT|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k), "|", _u(id), "|", _u(step), "|", ok ? "1" : "0"
        );
        a = string.concat(a, "|", _u(pre.debt > debtAfter ? pre.debt - debtAfter : 0), "|", _u(seizedTok), "|", _u(IERC20(debtAsset).balanceOf(KEEPER_RECIPIENT) - pre.reward), "|", _u(surplusTok));
        a = string.concat(a, "|", _u(pre.insU > iu ? pre.insU - iu : 0), "|", _u(pre.insW > iw ? pre.insW - iw : 0), "|", _u(debtAfter), "|", _u(uint8(p.status)));
        a = string.concat(a, "|", _u(IERC20(USDC).balanceOf(address(lender))), "|", _u(IERC20(WAVAX).balanceOf(address(lender))), "|", _u(pUsdc.getCash()), "|", _u(pWavax.getCash()), "|END");
        emit log_string(a);
    }

    /// @dev End-of-scenario snapshot of EVERY opened position (outstanding debt, remaining collateral, bad debt).
    function _logEnd(Scn memory s, uint256[] memory ids) internal {
        for (uint256 i; i < s.k; ++i) {
            IsolatedMarginTypes.Position memory p = _position(ids[i]);
            PErc20Delegator debtM = PErc20Delegator(payable(p.debtPToken));
            address debtAsset = s.short ? WAVAX : USDC;
            uint256 debtTok = debtM.borrowBalanceStored(p.account);
            uint256 collC = _accountCollC(p);
            uint256 debtC = _cents(debtAsset, debtTok);
            uint256 pool8 = _poolAnswer8() > 0 ? uint256(_poolAnswer8()) : 0;
            uint256 collP = _accountCollAt(p, pool8);
            uint256 debtP = _centsAt(debtAsset, debtTok, pool8);
            bool liqable;
            try riskEngine.isLiquidatable(p.account) returns (bool l) {
                liqable = l;
            } catch {}
            emit log_string(
                string.concat(
                    "MXEND|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k), "|", _u(ids[i]), "|", _u(uint8(p.status)),
                    "|", liqable ? "1" : "0", "|", _u(debtTok), "|", _u(debtC), "|", _u(collC), "|", _u(debtC > collC ? debtC - collC : 0), "|", _u(debtP > collP ? debtP - collP : 0), "|END"
                )
            );
        }
        (uint256 iu, uint256 iw) = _insTok();
        emit log_string(
            string.concat(
                "MXSUM|", s.slice, "|", s.cfg.name, "|", s.short ? "short" : "long", "|", _u(s.marginUsd), "|", _u(s.k), "|", _u(IERC20(USDC).balanceOf(address(lender))),
                "|", _u(IERC20(WAVAX).balanceOf(address(lender))), "|", _u(pUsdc.getCash()), "|", _u(pWavax.getCash()), "|", _u(iu), "|", _u(iw), "|", _u(_insuranceCents()), "|END"
            )
        );
    }

    /// @dev Same as `_cents` but with an explicit AVAX price (8 decimals): used to value end states at the REAL pool price.
    function _centsAt(address asset, uint256 amt, uint256 avax8) internal view returns (uint256) {
        if (asset == USDC) return Math.mulDiv(amt, uint256(usdcAnswer), 1e8 * 1e4);
        return Math.mulDiv(amt, avax8, 1e8 * 1e16);
    }

    function _accountCollAt(IsolatedMarginTypes.Position memory p, uint256 avax8) internal view returns (uint256 c) {
        PErc20Delegator posM = PErc20Delegator(payable(p.positionPToken));
        address posAsset = p.positionPToken == address(pUsdc) ? USDC : WAVAX;
        c = _centsAt(posAsset, Math.mulDiv(posM.balanceOf(p.account), posM.exchangeRateStored(), 1e18), avax8);
        if (p.marginPToken != p.positionPToken) {
            PErc20Delegator mM = PErc20Delegator(payable(p.marginPToken));
            c += _centsAt(USDC, Math.mulDiv(mM.balanceOf(p.account), mM.exchangeRateStored(), 1e18), avax8);
        }
    }

    function _accountCollC(IsolatedMarginTypes.Position memory p) internal view returns (uint256 c) {
        PErc20Delegator posM = PErc20Delegator(payable(p.positionPToken));
        address posAsset = p.positionPToken == address(pUsdc) ? USDC : WAVAX;
        c = _cents(posAsset, Math.mulDiv(posM.balanceOf(p.account), posM.exchangeRateStored(), 1e18));
        if (p.marginPToken != p.positionPToken) {
            PErc20Delegator mM = PErc20Delegator(payable(p.marginPToken));
            c += _cents(USDC, Math.mulDiv(mM.balanceOf(p.account), mM.exchangeRateStored(), 1e18));
        }
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
        head = string.concat(head, "|", _i(r.poolBps), "|", _i(_bps(r.oracleAnswer)), "|", r.liqable ? "1" : "0", "|", r.ok ? "1" : "0", "|", _clean(r.rev));
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

    function _sizes2(uint256 a, uint256 b) internal pure returns (uint256[] memory x) {
        x = new uint256[](2);
        x[0] = a;
        x[1] = b;
    }

    function _sizes(uint256 a) internal pure returns (uint256[] memory x) {
        x = new uint256[](1);
        x[0] = a;
    }
}
