// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheSection5Base.sol";
import {Vm} from "forge-std/Vm.sol";
import {IsolatedMarginAccount} from "../contracts/margin/IsolatedMarginAccount.sol";

/**
 * @notice Fork tests for the FUNDED IN-KIND forced-liquidation fallback
 *         (`IsolatedMarginLiquidatorUpgradeable.liquidateFunded`, handoff 00 s10 / handoff 09 s3b).
 *
 * Nothing here signs or broadcasts. Same pinned fork, harness and mocked-feed conventions as
 * `AvalanchePharaohSection5Fork.t.sol` (see `helpers/AvalancheSection5Base.sol` for run instructions).
 *
 * Shock conventions (oracle-only unless a test moves the pool): the 2x/50%/25% profile, margin 5,000 USDC.
 *   LONG  (margin pUSDC, position pWAVAX, debt pUSDC)  partial at ~66% of pin, FULL below ~56%, insolvent below ~49%.
 *   SHORT (margin pUSDC, position pUSDC, debt pWAVAX)  partial at ~151% of pin, FULL above ~177%, insolvent above ~202%.
 */
contract AvalancheFundedFallbackForkTest is AvalancheSection5Base {
    // Reuse the harness' addresses: their token slots are already in the local fork cache (a public RPC cannot
    // serve never-touched historical slots reliably), so runs stay reproducible on the public endpoint.
    address internal constant FUNDER = CAROL;
    address internal constant RECIPIENT = KEEPER_RECIPIENT;
    address internal constant STRANGER = DAVE;

    uint256 internal constant LONG_FULL_BPS = 5_400; // solvent, full liquidation, small borrower surplus
    uint256 internal constant SHORT_FULL_BPS = 18_000;
    uint256 internal constant LONG_SECOND_BPS = 4_500; // after a partial at ~66%: remaining position solvent but HF < 50%
    uint256 internal constant SHORT_SECOND_BPS = 23_000;
    uint256 internal constant LONG_INSOLVENT_BPS = 3_000;
    uint256 internal constant SHORT_INSOLVENT_BPS = 28_000;
    bytes4 internal constant REDEEM_TRANSFER_OUT = 0x91240a1b; // RedeemTransferOutNotPossible

    // ================================================================= helpers
    /// @dev Allowlist addition is timelocked: queue first so that the base's activation warp matures it.
    function _boot() internal {
        mConfig.queueFundedLiquidator(FUNDER);
        _activate();
        mConfig.addFundedLiquidator(FUNDER);
        assertTrue(mConfig.fundedLiquidators(FUNDER), "funder allowlisted after the delay");
    }

    function _openSide(bool short, uint256 marginUsdc) internal returns (uint256 id, address account) {
        OpenReport memory r = _open(short ? BOB : ALICE, short, marginUsdc, MAX_LEV_X100);
        id = r.id;
        account = _position(id).account;
    }

    function _shockPartial(address account, bool short) internal returns (uint256) {
        return _thresholdBps(account, short);
    }

    function _shockFull(bool short) internal {
        _setAvaxBps(short ? SHORT_FULL_BPS : LONG_FULL_BPS);
    }

    function _debtAsset(uint256 id) internal view returns (address) {
        return PErc20(_position(id).debtPToken).underlying();
    }

    /// @dev Gives `who` the debt asset (a multiple of the current debt) and a max approval to the liquidator.
    function _fundFor(address who, uint256 id, uint256 multipleBps) internal returns (uint256 amount) {
        IsolatedMarginTypes.Position memory p = _position(id);
        uint256 owed = PErc20(p.debtPToken).borrowBalanceCurrent(p.account);
        amount = (owed * multipleBps) / 10_000 + 1;
        address asset = PErc20(p.debtPToken).underlying();
        deal(asset, who, IERC20(asset).balanceOf(who) + amount);
        vm.prank(who);
        IERC20(asset).approve(address(liquidator), type(uint256).max);
    }

    function _fp(uint256 id, uint256 minPos, uint256 minMargin, uint256 maxRepay)
        internal
        pure
        returns (IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams memory)
    {
        return IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, RECIPIENT, maxRepay, minPos, minMargin, 0);
    }

    function _fpv(uint256 id, uint256 minValueBps)
        internal
        pure
        returns (IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams memory p)
    {
        p = _fp(id, 0, 0, type(uint256).max);
        p.minSeizeValueBps = minValueBps;
    }

    function _funded(address caller, IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams memory p)
        internal
        returns (bool ok, bytes memory ret)
    {
        vm.prank(caller);
        (ok, ret) = address(liquidator)
            .call(abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.liquidateFunded, (p)));
        lastRevert = ret;
    }

    function _fundedOk(uint256 id) internal returns (bool ok, bytes memory ret) {
        return _funded(FUNDER, _fp(id, 0, 0, type(uint256).max));
    }

    function _flash(uint256 id) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(liquidator)
            .call(abi.encodeWithSelector(IsolatedMarginLiquidatorUpgradeable.liquidate.selector, _liqParams(id)));
    }

    function _liqErr(bytes memory ret) internal pure returns (uint256 code) {
        if (ret.length != 36 || _selectorOf(ret) != IsolatedMarginLiquidatorUpgradeable.LiquidationError.selector) {
            return type(uint256).max;
        }
        assembly { code := mload(add(ret, 36)) }
    }

    function _unavailableAsset(bytes memory ret) internal pure returns (address a) {
        if (ret.length != 36 || _selectorOf(ret) != IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector) {
            return address(0xdead);
        }
        uint256 w;
        assembly { w := mload(add(ret, 36)) }
        a = address(uint160(w));
    }

    function _coreStatus(address account) internal view returns (uint8 st) {
        (,,,,,, IsolatedMarginTypes.Status s) = riskEngine.accounts(account);
        st = uint8(s);
    }

    /// @dev Everything a failed/blocked call must leave untouched.
    function _stateHash(uint256 id) internal view returns (bytes32) {
        IsolatedMarginTypes.Position memory p = _position(id);
        (uint256 lockAmt,,,) = _lock(id);
        bytes32 h1 = keccak256(
            abi.encode(
                pUsdc.borrowBalanceStored(p.account),
                pWavax.borrowBalanceStored(p.account),
                pUsdc.balanceOf(p.account),
                pWavax.balanceOf(p.account),
                _coreStatus(p.account),
                uint8(p.status),
                p.lockedMarginPTokens,
                lockAmt
            )
        );
        bytes32 h2 = keccak256(
            abi.encode(
                mVault.lockedBalance(p.owner, address(pUsdc)),
                mVault.freeBalance(p.owner, address(pUsdc)),
                mVault.totalLockedBalance(address(pUsdc)),
                mVault.totalFreeBalance(address(pUsdc)),
                IERC20(USDC).balanceOf(FUNDER),
                IERC20(WAVAX).balanceOf(FUNDER),
                pUsdc.balanceOf(RECIPIENT),
                pWavax.balanceOf(RECIPIENT)
            )
        );
        bytes32 h3 = keccak256(
            abi.encode(
                pUsdc.balanceOf(address(insuranceFund)),
                pWavax.balanceOf(address(insuranceFund)),
                pUsdc.balanceOf(address(liquidator)),
                pWavax.balanceOf(address(liquidator)),
                IERC20(USDC).balanceOf(address(liquidator)),
                IERC20(WAVAX).balanceOf(address(liquidator))
            )
        );
        return keccak256(abi.encode(h1, h2, h3));
    }

    function _lock(uint256 id) internal view returns (uint256 amount, address user, address account, address pToken) {
        (user, account, pToken, amount) = _lockTuple(id);
    }

    function _lockTuple(uint256 id) internal view returns (address user, address account, address pToken, uint256 amount) {
        (user, account, pToken, amount) = mVault.positionLocks(id);
    }

    function _usd(address pToken, uint256 amount) internal view returns (uint256) {
        return riskEngine.pTokenValueUsd(pToken, amount);
    }

    /// @dev seized value <= repaid value x (1 + bonus), measured with the risk engine's own helpers.
    function _assertBonusBound(uint256 id, uint256 repaid, uint256 posSeized, uint256 marginSeized) internal view {
        IsolatedMarginTypes.Position memory p = _position(id);
        IsolatedMarginTypes.PairRiskConfig memory risk = mConfig.getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken);
        uint256 repaidUsd = riskEngine.underlyingValueUsd(p.debtPToken, repaid);
        uint256 cap = repaidUsd + (repaidUsd * risk.liquidationBonusBps) / 10_000;
        uint256 seized = _usd(p.positionPToken, posSeized);
        if (marginSeized > 0) seized += _usd(p.marginPToken, marginSeized);
        assertLe(seized, cap, "seized value exceeds repaid x (1 + bonus)");
    }

    /// @dev Exhausts the CASH of `drainM` by borrowing all of it. Borrower: LP against its own pUSDC when the
    ///      collateral market is pUSDC (a public RPC cannot serve never-touched historical USDC slots, so WHALE
    ///      is only used for the WAVAX side, which the Section 5 suite already warmed), else WHALE against pWAVAX.
    function _moveDrain(PErc20Delegator drainM, PErc20Delegator collM) internal {
        address who = collM == pUsdc ? LP : WHALE;
        if (collM != pUsdc) {
            uint256 cashUsd6 = drainM == pUsdc ? drainM.getCash() : _wavaxUsd(drainM.getCash());
            _mintP(collM, who, Math.mulDiv(cashUsd6 * 3 * 1e12, 1e8, uint256(avaxAnswer)));
        }
        _enter(who);
        uint256 target = drainM.getCash() - 1;
        uint256 cap = controller.borrowCaps(address(drainM));
        uint256 borrowed = drainM.totalBorrows();
        if (cap != 0 && borrowed + target >= cap) target = cap - borrowed - 1;
        (bool ok,) = _borrow(drainM, who, target);
        require(ok, "drain borrow failed");
    }

    struct Outcome {
        bool full;
        uint256 repaid; // debt asset units paid by the funder
        uint256 posGot; // position pTokens received by RECIPIENT
        uint256 marginGot;
        uint256 gasUsed;
    }

    /// @dev Runs a successful funded liquidation and returns what the funder paid and received.
    function _runFunded(uint256 id) internal returns (Outcome memory o) {
        IsolatedMarginTypes.Position memory p = _position(id);
        address debtAsset = PErc20(p.debtPToken).underlying();
        _fundFor(FUNDER, id, 15_000);
        uint256 debtBalBefore = IERC20(debtAsset).balanceOf(FUNDER);
        uint256 posBefore = PErc20(p.positionPToken).balanceOf(RECIPIENT);
        uint256 marginBefore = PErc20(p.marginPToken).balanceOf(RECIPIENT);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = _fundedOk(id);
        o.gasUsed = g - gasleft();
        require(ok, string.concat("funded liquidation reverted code ", vm.toString(_liqErr(ret))));
        o.repaid = debtBalBefore - IERC20(debtAsset).balanceOf(FUNDER);
        if (p.positionPToken == p.marginPToken) {
            o.posGot = PErc20(p.positionPToken).balanceOf(RECIPIENT) - posBefore;
        } else {
            o.posGot = PErc20(p.positionPToken).balanceOf(RECIPIENT) - posBefore;
            o.marginGot = PErc20(p.marginPToken).balanceOf(RECIPIENT) - marginBefore;
        }
        o.full = uint8(_position(id).status) == uint8(IsolatedMarginTypes.Status.LIQUIDATED);
    }

    // ================================================================= (a) zero collateral-market cash
    function _scenarioZeroCash(bool short, bool full) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        // The market the normal route must REDEEM from is the position market: pWAVAX (long) / pUSDC (short).
        if (short) _moveDrain(pUsdc, pWavax);
        else _moveDrain(pWavax, pUsdc);
        PErc20Delegator posMarket = short ? pUsdc : pWavax;
        assertLe(posMarket.getCash(), 1, "position-market cash exhausted");
        if (full) _shockFull(short);
        else _shockPartial(account, short);
        assertTrue(riskEngine.isLiquidatable(account));

        // Normal flash route cannot redeem the seized collateral.
        (bool fok, bytes memory fret) = _flash(id);
        assertFalse(fok, "flash route must fail with zero collateral-market cash");
        _logSel("flash route revert", _selector(fret));
        assertEq(_selector(fret), REDEEM_TRANSFER_OUT, "flash route: RedeemTransferOutNotPossible");

        // Funded route succeeds; the funder receives pTokens, not underlying.
        uint256 debtBefore = PErc20(_position(id).debtPToken).borrowBalanceCurrent(account);
        Outcome memory o = _runFunded(id);
        IsolatedMarginTypes.Position memory p = _position(id);
        if (full) {
            assertTrue(o.full, "full liquidation reaches LIQUIDATED");
            assertEq(PErc20(p.debtPToken).borrowBalanceStored(account), 0, "debt cleared");
            assertEq(o.repaid, debtBefore, "funder paid the whole debt");
        } else {
            assertFalse(o.full, "partial liquidation returns to ACTIVE");
            assertEq(uint8(p.status), uint8(IsolatedMarginTypes.Status.ACTIVE));
            assertEq(_coreStatus(account), uint8(IsolatedMarginTypes.Status.ACTIVE));
            assertLt(PErc20(p.debtPToken).borrowBalanceStored(account), debtBefore, "debt reduced");
            assertEq(o.repaid, debtBefore - PErc20(p.debtPToken).borrowBalanceStored(account), "paid == debt delta");
        }
        assertGt(o.posGot, 0, "funder received position pTokens");
        assertEq(IERC20(short ? USDC : WAVAX).balanceOf(RECIPIENT), 0, "no underlying delivered");
        _assertBonusBound(id, o.repaid, o.posGot, o.marginGot);
        assertLe(posMarket.getCash(), 1, "still zero cash: nothing was redeemed");
        emit log_named_uint(short ? "SHORT zero-cash gas" : "LONG zero-cash gas", o.gasUsed);
    }

    function testZeroCash_Long_Partial() public { _scenarioZeroCash(false, false); }
    function testZeroCash_Long_Full() public { _scenarioZeroCash(false, true); }
    function testZeroCash_Short_Partial() public { _scenarioZeroCash(true, false); }
    function testZeroCash_Short_Full() public { _scenarioZeroCash(true, true); }

    // ================================================================= (b) swap route dead / pool wall
    /// @dev Pool sold to its floor (results doc finding 1), oracle left at 60% of pin: the position is liquidatable
    ///      and still solvent, but the pool pays far below the oracle floor, so the swap leg reverts.
    function testPoolWall_Long_FlashFailsFundedSucceeds() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        (uint256 usd, uint256 n) = _movePoolTo(6_000, 100e18, 0, 400);
        emit log_named_uint("USD sold into the pool (1e6)", usd);
        emit log_named_uint("sell chunks", n);
        emit log_named_int("pool-implied USD/AVAX e8", _poolAnswer8());
        _setAvaxBps(6_000);
        assertTrue(riskEngine.isLiquidatable(account));
        (bool fok, bytes memory fret) = _flash(id);
        assertFalse(fok, "flash route fails against the pool wall");
        assertTrue(_reasonContains(fret, "Too little received"), "cause: router minimum output");
        Outcome memory o = _runFunded(id);
        assertGt(o.posGot, 0);
        _assertBonusBound(id, o.repaid, o.posGot, o.marginGot);
        emit log_named_uint("LONG pool-wall funded: repaid USDC (1e6)", o.repaid);
    }

    function testPoolWall_Short_FlashFailsFundedSucceeds() public {
        _boot();
        (uint256 id, address account) = _openSide(true, 5_000e6);
        (uint256 usd, uint256 n) = _movePoolTo(15_250, 0, 25_000e6, 400);
        emit log_named_uint("USDC spent pumping the pool (1e6)", usd);
        emit log_named_uint("pump chunks", n);
        emit log_named_int("pool-implied USD/AVAX e8", _poolAnswer8());
        _setAvaxBps(15_500); // oracle stays moderate: liquidatable, solvent; the pool has no WAVAX left to sell
        assertTrue(riskEngine.isLiquidatable(account));
        (bool fok, bytes memory fret) = _flash(id);
        assertFalse(fok, "flash route fails against the pool wall");
        _logSel("flash revert", _selector(fret));
        assertTrue(_reasonContains(fret, "Too little received"), "cause: router minimum output");
        Outcome memory o = _runFunded(id);
        assertGt(o.posGot, 0);
        _assertBonusBound(id, o.repaid, o.posGot, o.marginGot);
        emit log_named_uint("SHORT pool-wall funded: repaid WAVAX (1e18)", o.repaid);
    }

    /// @dev Router dead (every swap reverts) AND flash lender endpoint disabled by governance. The funded route
    ///      still works on FULL liquidation. (A PARTIAL one still sizes through the risk engine's flash-fee quote;
    ///      see testFinding_PartialSizingNeedsFlashLenderView.)
    function testSwapDeadAndLenderDisabled_FullFundedStillWorks() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        mConfig.disableExecutionEndpoints(); // routerAdapter = 0, flashLoanProvider = 0
        _shockFull(false);
        assertTrue(riskEngine.isLiquidatable(account));
        (bool fok,) = _flash(id);
        assertFalse(fok, "flash route has no lender");
        Outcome memory o = _runFunded(id);
        assertTrue(o.full);
    }

    /// @dev FINDING: with the flash lender endpoint disabled, a PARTIAL liquidation cannot be sized because
    ///      `riskEngine.beginLiquidation` calls `_liquidationQuote`, which reads `config.flashLoanProvider()`.
    ///      Asserts current behaviour (revert) so a risk-engine fix shows up as a failing test to re-evaluate.
    function testFinding_PartialSizingNeedsFlashLenderView() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _shockPartial(account, false);
        mConfig.disableExecutionEndpoints();
        _fundFor(FUNDER, id, 15_000);
        bytes32 h = _stateHash(id);
        (bool ok, bytes memory ret) = _fundedOk(id);
        assertFalse(ok, "FINDING: partial funded sizing reverts when the lender view is disabled");
        _reasonContains(ret, "lender unavailable");
        assertEq(_stateHash(id), h, "state unchanged");
    }

    // ================================================================= (c) exhausted funding
    function _scenarioFundingExhausted(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        _shockPartial(account, short);
        bytes32 h0 = _stateHash(id);
        address debtAsset = _debtAsset(id);
        uint256 owed = PErc20(_position(id).debtPToken).borrowBalanceCurrent(account);

        // (1) no balance, no allowance
        (bool ok, bytes memory ret) = _fundedOk(id);
        assertFalse(ok, "no balance/allowance reverts");
        assertEq(_stateHash(id), h0, "unchanged after no-funds revert");

        // (2) balance but no allowance (the funder's own balance is part of the hash: re-take it after funding)
        deal(debtAsset, FUNDER, owed * 2);
        bytes32 hb = _stateHash(id);
        (ok, ret) = _fundedOk(id);
        assertFalse(ok, "no allowance reverts");
        assertEq(_stateHash(id), hb, "unchanged after no-allowance revert");

        // (3) allowance but too little balance (one unit short of what a partial repay needs)
        vm.startPrank(FUNDER);
        IERC20(debtAsset).approve(address(liquidator), type(uint256).max);
        vm.stopPrank();
        uint256 need = owed / 2; // about the partial repay (maxLiquidationBps 50%)
        deal(debtAsset, FUNDER, need / 4);
        bytes32 h1 = _stateHash(id);
        (ok, ret) = _fundedOk(id);
        assertFalse(ok, "balance below repay amount reverts");
        assertEq(_stateHash(id), h1, "unchanged after short-balance revert");

        // (4) allowance too small
        deal(debtAsset, FUNDER, owed * 2);
        vm.prank(FUNDER);
        IERC20(debtAsset).approve(address(liquidator), need / 4);
        bytes32 h2 = _stateHash(id);
        (ok, ret) = _fundedOk(id);
        assertFalse(ok, "allowance below repay amount reverts");
        assertEq(_stateHash(id), h2, "unchanged after small-allowance revert");
        assertEq(_coreStatus(account), uint8(IsolatedMarginTypes.Status.ACTIVE), "risk engine back to ACTIVE");

        // positive control: with enough funds the same call works, so the reverts above were the funding.
        vm.prank(FUNDER);
        IERC20(debtAsset).approve(address(liquidator), type(uint256).max);
        (ok, ret) = _fundedOk(id);
        assertTrue(ok, "control: funded call works once funded");
    }

    function testFundingExhausted_Long_RevertsAtomically() public { _scenarioFundingExhausted(false); }
    function testFundingExhausted_Short_RevertsAtomically() public { _scenarioFundingExhausted(true); }

    // ================================================================= (d) invalid prices
    function _scenarioInvalidPrices(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        _shockFull(short); // underwater (but solvent) at the real price, so health is not what blocks
        _fundFor(FUNDER, id, 15_000);
        bytes32 h = _stateHash(id);

        // control: a fresh, valid price makes the call work
        uint256 snap = vm.snapshotState();
        (bool cok,) = _fundedOk(id);
        assertTrue(cok, "control: valid prices -> funded liquidation works");
        vm.revertToState(snap);
        _refreshFeeds();

        // 1. stale AVAX feed (USDC feed has a 25h window and stays fresh)
        uint256 snap1 = vm.snapshotState();
        vm.warp(block.timestamp + AVAX_MAX_AGE + 1);
        assertEq(oracle.getPrice(WAVAX), 0, "guarded oracle: stale AVAX -> 0");
        assertGt(oracle.getPrice(USDC), 0, "USDC still valid");
        (bool ok, bytes memory ret) = _fundedOk(id);
        assertFalse(ok, "stale AVAX");
        assertEq(_selector(ret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "stale: PriceUnavailable");
        assertEq(_unavailableAsset(ret), WAVAX, "stale: the unavailable asset is WAVAX");
        assertEq(_stateHash(id), h);

        // 2. emergency price on the INNER oracle does not help (guarded oracle ignores it)
        inner.setEmergencyPrice(WAVAX, uint192(2e18), uint64(block.timestamp + 30 minutes));
        assertEq(inner.getPrice(WAVAX), 2e18, "inner would serve the emergency price");
        (ok, ret) = _fundedOk(id);
        assertFalse(ok, "stale AVAX + emergency price");
        assertEq(_selector(ret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "emergency: PriceUnavailable");
        assertEq(_unavailableAsset(ret), WAVAX);
        assertEq(_stateHash(id), h);
        vm.revertToState(snap1);

        // 3. USDC feed failure: reverting aggregator (AVAX fresh again, proven by the precondition)
        uint256 snap2 = vm.snapshotState();
        _refreshFeeds();
        assertGt(oracle.getPrice(WAVAX), 0, "precondition: AVAX valid");
        vm.mockCallRevert(USDC_FEED, abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector), "feed down");
        assertEq(oracle.getPrice(USDC), 0, "guarded oracle: USDC feed reverting -> 0");
        (ok, ret) = _fundedOk(id);
        assertFalse(ok, "USDC feed failure");
        assertEq(_selector(ret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "usdc revert: PriceUnavailable");
        assertEq(_unavailableAsset(ret), USDC, "the unavailable asset is USDC");
        assertEq(_stateHash(id), h);
        vm.revertToState(snap2);

        // 4. USDC feed returns zero
        _refreshFeeds();
        assertGt(oracle.getPrice(WAVAX), 0, "precondition: AVAX valid");
        vm.mockCall(
            USDC_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1000), int256(0), block.timestamp, block.timestamp, uint80(1000))
        );
        assertEq(oracle.getPrice(USDC), 0);
        (ok, ret) = _fundedOk(id);
        assertFalse(ok, "USDC zero answer");
        assertEq(_selector(ret), IsolatedMarginRiskEngineUpgradeable.PriceUnavailable.selector, "usdc zero: PriceUnavailable");
        assertEq(_unavailableAsset(ret), USDC);
        assertEq(_stateHash(id), h);
        assertEq(_coreStatus(account), uint8(IsolatedMarginTypes.Status.ACTIVE));
    }

    function testInvalidPrices_Long_Revert() public { _scenarioInvalidPrices(false); }
    function testInvalidPrices_Short_Revert() public { _scenarioInvalidPrices(true); }

    // ================================================================= (e) repeated calls and sequences
    function _scenarioSequence(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        uint256 threshold = _shockPartial(account, short);
        // partial #1
        Outcome memory o1 = _runFunded(id);
        assertFalse(o1.full, "first call at the threshold is partial");
        assertEq(_coreStatus(account), uint8(IsolatedMarginTypes.Status.ACTIVE));
        // immediate repeat: healthier now -> "healthy" revert, state unchanged
        _fundFor(FUNDER, id, 15_000);
        bytes32 h = _stateHash(id);
        (bool ok, bytes memory ret) = _fundedOk(id);
        assertFalse(ok, "repeat call on a no-longer-liquidatable account");
        assertTrue(_reasonContains(ret, "healthy"), "RiskEngine: healthy");
        assertEq(_stateHash(id), h);
        // push deeper -> full
        threshold;
        _setAvaxBps(short ? SHORT_SECOND_BPS : LONG_SECOND_BPS);
        assertTrue(riskEngine.isLiquidatable(account));
        Outcome memory o2 = _runFunded(id);
        assertTrue(o2.full, "second call fully liquidates");
        assertEq(PErc20(_position(id).debtPToken).borrowBalanceStored(account), 0);
        assertEq(uint8(_position(id).status), uint8(IsolatedMarginTypes.Status.LIQUIDATED));
        assertEq(_coreStatus(account), uint8(IsolatedMarginTypes.Status.LIQUIDATED));
        (uint256 lockAmt,,,) = _lock(id);
        assertEq(lockAmt, 0, "position lock released");
        // repeat after LIQUIDATED: both routes reject, state unchanged
        _fundFor(FUNDER, id, 15_000);
        h = _stateHash(id);
        (ok, ret) = _fundedOk(id);
        assertFalse(ok, "repeat after full liquidation");
        assertEq(_liqErr(ret), 8, "LiquidationError(8): not ACTIVE");
        (ok, ret) = _flash(id);
        assertFalse(ok);
        assertEq(_liqErr(ret), 8);
        assertEq(_stateHash(id), h);
        emit log_named_uint(short ? "SHORT partial-then-full: total repaid (debt asset)" : "LONG partial-then-full: total repaid (debt asset)", o1.repaid + o2.repaid);
    }

    function testSequence_Long_PartialThenFullThenRepeat() public { _scenarioSequence(false); }
    function testSequence_Short_PartialThenFullThenRepeat() public { _scenarioSequence(true); }

    /// @dev Mixed routes: a funded partial followed by the ordinary flash route (works while swaps work).
    function testSequence_FundedPartialThenFlashFull_Long() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        uint256 threshold = _shockPartial(account, false);
        Outcome memory o = _runFunded(id);
        assertFalse(o.full);
        threshold;
        _setAvaxBps(LONG_SECOND_BPS);
        (bool ok,) = _flash(id);
        assertTrue(ok, "flash route completes what the funded partial started");
        assertEq(uint8(_position(id).status), uint8(IsolatedMarginTypes.Status.LIQUIDATED));
        assertEq(pUsdc.borrowBalanceStored(account), 0);
    }

    // ================================================================= (f) authorization
    function testAuthorization_UnauthorizedCallerAndAllowlistGovernance() public {
        mConfig.queueFundedLiquidator(FUNDER);
        _activate();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _shockPartial(account, false);
        _fundFor(STRANGER, id, 15_000);
        _fundFor(FUNDER, id, 15_000);
        bytes32 h = _stateHash(id);

        // not yet added: even the queued funder is refused
        (bool ok, bytes memory ret) = _fundedOk(id);
        assertFalse(ok);
        assertEq(_liqErr(ret), 27, "queued but not added -> unauthorized");

        // add: owner only
        vm.prank(STRANGER);
        vm.expectRevert();
        mConfig.addFundedLiquidator(FUNDER);
        vm.prank(STRANGER);
        vm.expectRevert();
        mConfig.queueFundedLiquidator(STRANGER);
        // add without a queued action
        vm.expectRevert(bytes("MarginConfig: not queued"));
        mConfig.addFundedLiquidator(STRANGER);
        // timelock: the base activation already warped past the delay, so re-queue a fresh one and try early
        mConfig.queueFundedLiquidator(STRANGER);
        vm.expectRevert(bytes("MarginConfig: not ready"));
        mConfig.addFundedLiquidator(STRANGER);
        // queue zero
        vm.expectRevert(bytes("MarginConfig: zero liquidator"));
        mConfig.queueFundedLiquidator(address(0));
        // cancel works through the existing cancelAction
        mConfig.cancelAction(keccak256(abi.encode("fundedLiquidator", STRANGER)));
        vm.expectRevert(bytes("MarginConfig: not queued"));
        mConfig.addFundedLiquidator(STRANGER);

        mConfig.addFundedLiquidator(FUNDER);
        // a never-added caller is refused
        (ok, ret) = _funded(STRANGER, _fp(id, 0, 0, type(uint256).max));
        assertFalse(ok);
        assertEq(_liqErr(ret), 27, "stranger unauthorized");
        assertEq(_stateHash(id), h);

        // removal is immediate and owner only
        vm.prank(STRANGER);
        vm.expectRevert();
        mConfig.removeFundedLiquidator(FUNDER);
        mConfig.removeFundedLiquidator(FUNDER);
        (ok, ret) = _fundedOk(id);
        assertFalse(ok);
        assertEq(_liqErr(ret), 27, "removed funder is refused immediately");
        assertEq(_stateHash(id), h);

        // the permissionless flash route is unchanged by the allowlist
        (ok,) = _flash(id);
        assertTrue(ok, "flash liquidate() stays permissionless");
    }

    function testAuthorization_NoOtherEntryPointsToMoveCollateral() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _shockPartial(account, false);
        IsolatedMarginTypes.Position memory p = _position(id);
        // the new account function is liquidator-only
        vm.prank(STRANGER);
        vm.expectRevert(bytes("IsolatedAccount: not liquidator"));
        IsolatedMarginAccount(account).liquidationTransfer(p.positionPToken, 1, STRANGER);
        vm.prank(address(executor));
        vm.expectRevert(bytes("IsolatedAccount: not liquidator"));
        IsolatedMarginAccount(account).liquidationTransfer(p.positionPToken, 1, STRANGER);
        // authorization source is liquidator/executor only
        vm.prank(STRANGER);
        vm.expectRevert(bytes("RiskEngine: not operator"));
        riskEngine.authorizeMovement(account, p.positionPToken, 1);
        // the vault release is liquidator only
        vm.prank(STRANGER);
        vm.expectRevert(bytes("MarginVault: not liquidator"));
        mVault.releaseFromLiquidation(id, 1, 0);
        // executor bookkeeping is liquidator only
        vm.prank(STRANGER);
        vm.expectRevert();
        executor.recordLiquidation(id, 1, false);
        // the liquidator, even if it were to call the account directly, still needs a same-block authorization
        // while the account has debt: a direct transfer by a faked liquidator is impossible, and the controller
        // rejects an unauthorised movement.
        vm.prank(address(liquidator));
        (bool tok, bytes memory tret) = address(account)
            .call(abi.encodeCall(IsolatedMarginAccount.liquidationTransfer, (p.positionPToken, 1, STRANGER)));
        assertFalse(tok, "unauthorised movement");
        _assertRejection(tret, "TransferPeridottrollerRejection(uint256)", 4, "no same-block authorization");
        // only supported collateral
        vm.prank(address(liquidator));
        vm.expectRevert(bytes("IsolatedAccount: unsupported collateral"));
        IsolatedMarginAccount(account).liquidationTransfer(address(0xdead), 1, STRANGER);
    }

    // ================================================================= (g) bonus and surplus bounds
    function _scenarioBonusBound(bool short, bool full) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        if (full) _shockFull(short);
        else _shockPartial(account, short);
        IsolatedMarginTypes.Position memory p = _position(id);
        uint256 ownerFreeBefore = mVault.freeBalance(p.owner, address(pUsdc));
        uint256 ownerPosBefore = PErc20(p.positionPToken).balanceOf(p.owner);
        uint256 accPosBefore = PErc20(p.positionPToken).balanceOf(account);
        uint256 accMarginBefore = PErc20(p.marginPToken).balanceOf(account);
        uint256 grossUsdBefore = riskEngine.getMetrics(account).grossAssetValueUsd;
        Outcome memory o = _runFunded(id);
        _assertBonusBound(id, o.repaid, o.posGot, o.marginGot);

        IsolatedMarginTypes.PairRiskConfig memory risk = mConfig.getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken);
        uint256 repaidUsd = riskEngine.underlyingValueUsd(p.debtPToken, o.repaid);
        uint256 seizedUsd = _usd(p.positionPToken, o.posGot) + (o.marginGot > 0 ? _usd(p.marginPToken, o.marginGot) : 0);
        uint256 cap = repaidUsd + (repaidUsd * risk.liquidationBonusBps) / 10_000;
        emit log_named_uint(short ? "SHORT repaid USD (1e18)" : "LONG repaid USD (1e18)", repaidUsd);
        emit log_named_uint("   seized USD (1e18)", seizedUsd);
        emit log_named_uint("   cap USD (1e18)", cap);
        // the position was big enough: the funder gets (almost) exactly the bonus, never more
        assertGe(seizedUsd + (cap / 1e9), cap, "funder gets the full permitted bonus (within rounding)");
        // adversarial variants run on a reverted state below.

        if (full) {
            // Borrower surplus: everything not seized stays with the borrower or goes back through the vault.
            uint256 ownerGotPos = PErc20(p.positionPToken).balanceOf(p.owner) - ownerPosBefore;
            uint256 vaultReturn = mVault.freeBalance(p.owner, address(pUsdc)) - ownerFreeBefore;
            uint256 accPosAfter = PErc20(p.positionPToken).balanceOf(account);
            uint256 accMarginAfter = PErc20(p.marginPToken).balanceOf(account);
            assertEq(accPosAfter, 0, "account emptied of position pTokens");
            assertEq(accMarginAfter, 0, "account emptied of margin pTokens");
            if (p.positionPToken == p.marginPToken) {
                assertEq(o.posGot + vaultReturn, accPosBefore, "short: seized + returned == account balance");
                assertEq(ownerGotPos, 0);
            } else {
                assertEq(o.posGot + ownerGotPos, accPosBefore, "long: seized + owner remainder == position balance");
                assertEq(o.marginGot + vaultReturn, accMarginBefore, "long: margin pTokens fully accounted");
            }
            uint256 borrowerUsd = _usd(p.positionPToken, ownerGotPos) + _usd(address(pUsdc), vaultReturn);
            assertGt(borrowerUsd, 0, "borrower keeps the surplus above the bonus");
            // value conservation: liquidator + borrower == original gross (within 1e-9 relative)
            assertApproxEqRel(seizedUsd + borrowerUsd, grossUsdBefore, 1e9, "no value lost or created");
            emit log_named_uint("   borrower surplus USD (1e18)", borrowerUsd);
            (uint256 lockAmt,,,) = _lock(id);
            assertEq(lockAmt, 0, "lock deleted");
            assertEq(mVault.lockedBalance(p.owner, address(pUsdc)), 0, "owner locked balance cleared");
        }
    }

    function testBonusBound_Long_Partial() public { _scenarioBonusBound(false, false); }
    function testBonusBound_Long_Full() public { _scenarioBonusBound(false, true); }
    function testBonusBound_Short_Partial() public { _scenarioBonusBound(true, false); }
    function testBonusBound_Short_Full() public { _scenarioBonusBound(true, true); }

    /// @dev Adversarial funder asks for more than the contract allows / protects itself with bounds.
    function _scenarioAdversarial(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        _shockPartial(account, short);
        _fundFor(FUNDER, id, 15_000);
        bytes32 h = _stateHash(id);

        // measure what a normal call would give (then revert)
        uint256 snap = vm.snapshotState();
        Outcome memory o = _runFunded(id);
        vm.revertToState(snap);
        _refreshFeeds();
        assertEq(_stateHash(id), h, "snapshot restored");

        // asking for even one pToken more than the bonus-bounded amount reverts (LiquidationError(30))
        (bool ok, bytes memory ret) = _funded(FUNDER, _fp(id, o.posGot + 1, 0, type(uint256).max));
        assertFalse(ok, "asking for more than the bound");
        assertEq(_liqErr(ret), 30, "minPositionPTokens above bound");
        assertEq(_stateHash(id), h);
        // asking for margin pTokens when none may be seized in a partial liquidation
        (ok, ret) = _funded(FUNDER, _fp(id, 0, 1, type(uint256).max));
        assertFalse(ok);
        assertEq(_liqErr(ret), 30);
        // spend cap lower than the repay amount
        (ok, ret) = _funded(FUNDER, _fp(id, 0, 0, o.repaid - 1));
        assertFalse(ok);
        assertEq(_liqErr(ret), 28, "maxRepayUnderlying below the risk-engine repay");
        // asking for more value than repaid x (1 + bonus 5%) can never be met: LiquidationError(32)
        (ok, ret) = _funded(FUNDER, _fpv(id, 10_501));
        assertFalse(ok, "value floor above the bonus bound");
        assertEq(_liqErr(ret), 32, "minSeizeValueBps above 1 + bonus");
        // and the realistic floor (break-even) passes in a solvent position
        uint256 snapOk = vm.snapshotState();
        (ok, ret) = _funded(FUNDER, _fpv(id, 10_000));
        assertTrue(ok, "break-even floor passes on a solvent position");
        vm.revertToState(snapOk);
        _refreshFeeds();
        // recipient == the margin account is refused
        (ok, ret) = _funded(FUNDER, IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, account, type(uint256).max, 0, 0, 0));
        assertFalse(ok);
        assertEq(_liqErr(ret), 9);
        // zero recipient
        (ok, ret) = _funded(FUNDER, IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, address(0), type(uint256).max, 0, 0, 0));
        assertFalse(ok);
        assertEq(_liqErr(ret), 9);
        assertEq(_stateHash(id), h, "all adversarial calls atomic");
        // exactly-at-bound mins succeed
        (ok, ret) = _funded(FUNDER, _fp(id, o.posGot, 0, o.repaid));
        assertTrue(ok, "exact bound call succeeds");
    }

    function testAdversarialFunder_Long() public { _scenarioAdversarial(false); }
    function testAdversarialFunder_Short() public { _scenarioAdversarial(true); }

    /// @dev A funder cannot manufacture a larger repay value (and so a larger cap) by donating the debt asset to
    ///      the liquidator or the account: the repay amount is the risk engine's, the cap is repay-derived.
    function testAdversarial_DonationsDoNotChangeSeizure() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _shockPartial(account, false);
        _fundFor(FUNDER, id, 15_000);
        uint256 snap = vm.snapshotState();
        Outcome memory base = _runFunded(id);
        vm.revertToState(snap);
        _refreshFeeds();
        deal(USDC, address(liquidator), 1_000_000e6);
        deal(USDC, account, 1_000_000e6);
        Outcome memory donated = _runFunded(id);
        assertEq(donated.posGot, base.posGot, "seizure independent of stray balances");
        assertEq(donated.repaid, base.repaid);
    }

    // ================================================================= (h) deep underwater
    function _scenarioInsolvent(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        IsolatedMarginTypes.Position memory p = _position(id);
        _setAvaxBps(short ? SHORT_INSOLVENT_BPS : LONG_INSOLVENT_BPS);
        IsolatedMarginTypes.AccountMetrics memory m = riskEngine.getMetrics(account);
        assertLt(m.equityUsd, 0, "scenario is insolvent");
        uint256 debtUsd = m.debtValueUsd;
        uint256 assetsUsd = m.grossAssetValueUsd;
        uint256 insUsdc = pUsdc.balanceOf(address(insuranceFund));
        uint256 insWavax = pWavax.balanceOf(address(insuranceFund));
        uint256 insUsd = _usd(address(pUsdc), insUsdc) + _usd(address(pWavax), insWavax);
        emit log_named_uint(short ? "SHORT insolvent: debt USD (1e18)" : "LONG insolvent: debt USD (1e18)", debtUsd);
        emit log_named_uint("   assets USD (1e18)", assetsUsd);
        emit log_named_uint("   residual bad debt if nobody liquidates, USD (1e18)", debtUsd - assetsUsd);
        emit log_named_uint("   insurance fund USD (1e18)", insUsd);
        emit log_named_uint("   insurance covers (% of bad debt)", (insUsd * 100) / (debtUsd - assetsUsd));

        // A rational funder protects itself: it demands position pTokens worth at least what it repays.
        _fundFor(FUNDER, id, 15_000);
        uint256 posBal = PErc20(p.positionPToken).balanceOf(account);
        // The funder's loss protection: a break-even value floor refuses the insolvent position, atomically.
        bytes32 hIns = _stateHash(id);
        (bool pok, bytes memory pret) = _funded(FUNDER, _fpv(id, 10_000));
        assertFalse(pok, "break-even floor refuses an insolvent position");
        assertEq(_liqErr(pret), 32);
        assertEq(_stateHash(id), hIns, "refused call leaves state unchanged");
        uint256 snap0 = vm.snapshotState();
        // protected call: minPositionPTokens = position balance would need cap >= balance; here it is, but the
        // value protection a funder really wants is off-chain; on-chain it can only bound the pToken count.
        Outcome memory o = _runFunded(id);
        assertTrue(o.full, "insolvent position fully liquidated by a willing funder");
        assertEq(PErc20(p.debtPToken).borrowBalanceStored(account), 0, "debt cleared by the funder");
        assertEq(o.posGot, posBal, "funder takes the whole position: all of it is below the cap");
        uint256 repaidUsd = riskEngine.underlyingValueUsd(p.debtPToken, o.repaid);
        uint256 gotUsd = _usd(p.positionPToken, o.posGot) + (o.marginGot > 0 ? _usd(p.marginPToken, o.marginGot) : 0);
        emit log_named_uint("   funder repaid USD (1e18)", repaidUsd);
        emit log_named_uint("   funder received USD (1e18)", gotUsd);
        emit log_named_uint("   funder LOSS USD (1e18)", repaidUsd - gotUsd);
        assertLt(gotUsd, repaidUsd, "funder absorbs the shortfall");
        // no insurance draw in the fallback
        assertEq(pUsdc.balanceOf(address(insuranceFund)), insUsdc, "insurance pUSDC untouched");
        assertEq(pWavax.balanceOf(address(insuranceFund)), insWavax, "insurance pWAVAX untouched");
        assertEq(IERC20(USDC).balanceOf(address(liquidator)) + IERC20(WAVAX).balanceOf(address(liquidator)), 0);
        (uint256 lockAmt,,,) = _lock(id);
        assertEq(lockAmt, 0);
        vm.revertToState(snap0);
        _refreshFeeds();
        // an unwilling funder: nobody calls -> the bad debt stays in the market (measured above), the
        // position stays ACTIVE and liquidatable.
        assertEq(uint8(_position(id).status), uint8(IsolatedMarginTypes.Status.ACTIVE));
        assertGt(PErc20(p.debtPToken).borrowBalanceStored(account), 0);
    }

    function testInsolvent_Long_FundedAbsorbsLossNoInsurance() public { _scenarioInsolvent(false); }
    function testInsolvent_Short_FundedAbsorbsLossNoInsurance() public { _scenarioInsolvent(true); }

    /// @dev At a barely insolvent price band partial liquidation is impossible (health cannot improve) and the
    ///      risk engine itself forces a full liquidation; the funded route inherits that.
    function testInsolvent_BorderlineForcesFull() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _setAvaxBps(4_800); // gross ~4.75k vs debt ~4.9k: just insolvent
        assertLt(riskEngine.getMetrics(account).equityUsd, 0);
        Outcome memory o = _runFunded(id);
        assertTrue(o.full);
    }

    // ================================================================= (i) ownership and locked-margin accounting
    function _scenarioOwnership(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        IsolatedMarginTypes.Position memory p0 = _position(id);
        _shockPartial(account, short);
        uint256 lockedPos0 = p0.lockedMarginPTokens;
        uint256 vaultLocked0 = mVault.lockedBalance(p0.owner, address(pUsdc));
        uint256 vaultTotalLocked0 = mVault.totalLockedBalance(address(pUsdc));
        uint256 vaultFree0 = mVault.freeBalance(p0.owner, address(pUsdc));
        uint256 vaultPTokens0 = pUsdc.balanceOf(address(mVault));
        uint256 accPos0 = PErc20(p0.positionPToken).balanceOf(account);
        uint256 recipUnderlying0 = IERC20(USDC).balanceOf(RECIPIENT) + IERC20(WAVAX).balanceOf(RECIPIENT);
        Outcome memory o = _runFunded(id);
        IsolatedMarginTypes.Position memory p1 = _position(id);
        // recipient got position pTokens, not underlying
        assertEq(PErc20(p0.positionPToken).balanceOf(RECIPIENT), o.posGot);
        assertEq(IERC20(USDC).balanceOf(RECIPIENT) + IERC20(WAVAX).balanceOf(RECIPIENT), recipUnderlying0);
        // account lost exactly what the recipient got
        assertEq(accPos0 - PErc20(p0.positionPToken).balanceOf(account), o.posGot);
        // locked-margin accounting: executor, vault per-user, vault total and the position lock all moved together
        uint256 reduction = lockedPos0 - p1.lockedMarginPTokens;
        assertGt(reduction, 0);
        assertLt(p1.lockedMarginPTokens, lockedPos0);
        assertEq(vaultLocked0 - mVault.lockedBalance(p0.owner, address(pUsdc)), reduction);
        assertEq(vaultTotalLocked0 - mVault.totalLockedBalance(address(pUsdc)), reduction);
        (uint256 lockAmt,,,) = _lock(id);
        assertEq(lockAmt, p1.lockedMarginPTokens, "position lock == executor locked");
        // proportionality (ceil): reduction == ceil(locked * seized / accountBalance)
        assertEq(reduction, Math.mulDiv(lockedPos0, o.posGot, accPos0, Math.Rounding.Ceil));
        // partial: nothing returned to the owner, vault pTokens untouched (no phantom free balance)
        assertEq(mVault.freeBalance(p0.owner, address(pUsdc)), vaultFree0);
        assertEq(pUsdc.balanceOf(address(mVault)), vaultPTokens0);
        // the vault stays covered
        assertGe(pUsdc.balanceOf(address(mVault)), mVault.totalFreeBalance(address(pUsdc)));
        // liquidator contract holds nothing afterwards
        assertEq(pUsdc.balanceOf(address(liquidator)) + pWavax.balanceOf(address(liquidator)), 0);
        assertEq(IERC20(USDC).balanceOf(address(liquidator)) + IERC20(WAVAX).balanceOf(address(liquidator)), 0);
        assertEq(pUsdc.allowance(address(liquidator), address(mVault)), 0);
        assertEq(IERC20(PErc20(p0.debtPToken).underlying()).allowance(address(liquidator), p0.debtPToken), 0);
    }

    function testOwnership_Long_PartialAccounting() public { _scenarioOwnership(false); }
    function testOwnership_Short_PartialAccounting() public { _scenarioOwnership(true); }


    // ================================================================= long with extra margin pTokens in the account
    /// @dev A long that added margin pUSDC (`addCollateral`): the account then holds position pWAVAX AND margin
    ///      pUSDC. Funded seizure takes position pTokens FIRST and margin pTokens only to top up to the bonus cap;
    ///      anything left (position or margin) stays with the borrower.
    function _longWithExtraMargin(uint256 extraUsdc) internal returns (uint256 id, address account, uint256 extraShares) {
        _boot();
        (id, account) = _openSide(false, 5_000e6);
        extraShares = _marginPTokens(ALICE, extraUsdc);
        vm.prank(ALICE);
        executor.addCollateral(id, extraShares);
        assertEq(pUsdc.balanceOf(account), extraShares, "margin pUSDC sits in the account");
    }

    function testExtraMargin_Partial_LeavesMarginUntouched() public {
        (uint256 id, address account, uint256 extra) = _longWithExtraMargin(2_000e6);
        _setAvaxBps(4_400);
        assertTrue(riskEngine.isLiquidatable(account));
        uint256 lockedBefore = _position(id).lockedMarginPTokens;
        Outcome memory o = _runFunded(id);
        assertFalse(o.full, "partial");
        assertEq(o.marginGot, 0, "partial never takes margin pTokens");
        assertEq(pUsdc.balanceOf(account), extra, "margin pUSDC untouched");
        assertGt(o.posGot, 0);
        assertLt(_position(id).lockedMarginPTokens, lockedBefore);
        _assertBonusBound(id, o.repaid, o.posGot, o.marginGot);
    }

    /// @dev Position (pWAVAX) worth less than the cap: funder takes ALL pWAVAX, then margin pUSDC up to the cap;
    ///      the unused rest of the margin returns to the owner through the vault release accounting.
    function testExtraMargin_Full_TopsUpFromMarginAndReturnsRemainder() public {
        (uint256 id, address account, uint256 extra) = _longWithExtraMargin(2_000e6);
        IsolatedMarginTypes.Position memory p = _position(id);
        _setAvaxBps(3_300);
        assertTrue(riskEngine.isLiquidatable(account));
        uint256 posBal = PErc20(p.positionPToken).balanceOf(account);
        uint256 freeBefore = mVault.freeBalance(p.owner, address(pUsdc));
        Outcome memory o = _runFunded(id);
        assertTrue(o.full);
        assertEq(o.posGot, posBal, "position pTokens first, all of them");
        assertGt(o.marginGot, 0, "margin pTokens used for the top-up");
        assertLt(o.marginGot, extra, "but not all of them: the borrower keeps the remainder");
        assertEq(mVault.freeBalance(p.owner, address(pUsdc)) - freeBefore, extra - o.marginGot, "remainder returned via vault");
        assertEq(pUsdc.balanceOf(account), 0);
        assertEq(PErc20(p.positionPToken).balanceOf(p.owner), 0, "no position pTokens left to return");
        _assertBonusBound(id, o.repaid, o.posGot, o.marginGot);
        (uint256 lockAmt,,,) = _lock(id);
        assertEq(lockAmt, 0);
        assertGe(pUsdc.balanceOf(address(mVault)), mVault.totalFreeBalance(address(pUsdc)), "vault covered");
    }

    /// @dev Deeper: even position + all margin cannot reach the cap. The funder takes everything, the borrower none.
    function testExtraMargin_Full_TakesEverythingWhenBelowCap() public {
        (uint256 id, address account, uint256 extra) = _longWithExtraMargin(2_000e6);
        IsolatedMarginTypes.Position memory p = _position(id);
        _setAvaxBps(3_000);
        uint256 freeBefore = mVault.freeBalance(p.owner, address(pUsdc));
        Outcome memory o = _runFunded(id);
        assertTrue(o.full);
        assertEq(o.marginGot, extra, "all margin pTokens taken");
        assertEq(mVault.freeBalance(p.owner, address(pUsdc)), freeBefore, "nothing returned");
        assertEq(PErc20(p.positionPToken).balanceOf(account) + pUsdc.balanceOf(account), 0);
        // the min-margin bound is honoured: a call demanding more margin than exists would have reverted
        assertEq(uint8(_position(id).status), uint8(IsolatedMarginTypes.Status.LIQUIDATED));
    }



    /// @dev The ordinary case with added margin: the position ALONE covers the cap. The funder takes only position
    ///      pTokens (up to the cap); the position remainder goes to the owner in kind AND all margin pTokens go back
    ///      through the vault, in the same call, with two different pTokens.
    function testExtraMargin_Full_PositionAloneCoversCap_TwoRemaindersReturned() public {
        (uint256 id, address account, uint256 extra) = _longWithExtraMargin(200e6);
        IsolatedMarginTypes.Position memory p = _position(id);
        _setAvaxBps(5_300);
        assertTrue(riskEngine.isLiquidatable(account));
        uint256 posBal = PErc20(p.positionPToken).balanceOf(account);
        uint256 freeBefore = mVault.freeBalance(p.owner, address(pUsdc));
        uint256 ownerPosBefore = PErc20(p.positionPToken).balanceOf(p.owner);
        Outcome memory o = _runFunded(id);
        assertTrue(o.full, "full liquidation");
        assertLt(o.posGot, posBal, "position alone covered the cap");
        assertEq(o.marginGot, 0, "no margin pTokens taken");
        assertEq(PErc20(p.positionPToken).balanceOf(p.owner) - ownerPosBefore, posBal - o.posGot, "position remainder to the owner");
        assertEq(mVault.freeBalance(p.owner, address(pUsdc)) - freeBefore, extra, "all margin returned through the vault");
        assertEq(PErc20(p.positionPToken).balanceOf(account) + pUsdc.balanceOf(account), 0, "account emptied");
        _assertBonusBound(id, o.repaid, o.posGot, o.marginGot);
        (uint256 lockAmt,,,) = _lock(id);
        assertEq(lockAmt, 0);
        assertGe(pUsdc.balanceOf(address(mVault)), mVault.totalFreeBalance(address(pUsdc)), "vault covered");
    }

    /// @dev Seized pTokens may not be sent into another isolated margin account.
    function testAdversarial_RecipientCannotBeAnotherMarginAccount() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        (, address otherAccount) = _openSide(true, 2_000e6);
        _shockPartial(account, false);
        _fundFor(FUNDER, id, 15_000);
        bytes32 h = _stateHash(id);
        (bool ok, bytes memory ret) = _funded(
            FUNDER, IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, otherAccount, type(uint256).max, 0, 0, 0)
        );
        assertFalse(ok, "recipient is another margin account");
        assertEq(_liqErr(ret), 9);
        assertEq(_stateHash(id), h);
    }

    /// @dev The event carries exactly what moved.
    function testEvent_FundedPositionLiquidatedMatchesMovements() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _shockFull(false);
        IsolatedMarginTypes.Position memory p = _position(id);
        uint256 posBal = PErc20(p.positionPToken).balanceOf(account);
        vm.recordLogs();
        Outcome memory o = _runFunded(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("FundedPositionLiquidated(uint256,address,address,uint256,uint256,uint256,uint256,uint256,uint256,bool)");
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(liquidator) || logs[i].topics[0] != sig) continue;
            found = true;
            assertEq(uint256(logs[i].topics[1]), id);
            assertEq(address(uint160(uint256(logs[i].topics[2]))), FUNDER);
            assertEq(address(uint160(uint256(logs[i].topics[3]))), RECIPIENT);
            (uint256 repaid, uint256 posSeized, uint256 marginSeized, uint256 posLeft, uint256 marginLeft, uint256 locked, bool full) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256, bool));
            assertEq(repaid, o.repaid);
            assertEq(posSeized, o.posGot);
            assertEq(marginSeized, 0);
            assertEq(posLeft, posBal - o.posGot, "owner remainder");
            assertEq(marginLeft, 0);
            assertEq(locked, p.lockedMarginPTokens);
            assertTrue(full);
        }
        assertTrue(found, "event emitted");
    }

    /// @dev Residual bad debt as a function of the price shock, for cap-sized positions (24,000 USDC margin).
    ///      If nobody liquidates, this is what stays in the lending market; the funded route clears it only when a
    ///      funder is willing to absorb it (no insurance draw).
    function testQuantify_BadDebtSweep() public {
        _boot();
        uint256[6] memory longBps = [uint256(4_900), 4_500, 4_000, 3_000, 2_000, 1_000];
        uint256[6] memory shortBps = [uint256(20_500), 22_000, 25_000, 30_000, 40_000, 60_000];
        for (uint256 side; side < 2; ++side) {
            for (uint256 i; i < 6; ++i) {
                uint256 snap = vm.snapshotState();
                (uint256 id, address account) = _openSide(side == 1, 24_000e6);
                _setAvaxBps(side == 1 ? shortBps[i] : longBps[i]);
                IsolatedMarginTypes.AccountMetrics memory m = riskEngine.getMetrics(account);
                uint256 bad = m.equityUsd < 0 ? uint256(-m.equityUsd) : 0;
                emit log_string(side == 1 ? "SHORT cap-sized position" : "LONG cap-sized position");
                emit log_named_uint("   AVAX price (% of pin x100)", side == 1 ? shortBps[i] : longBps[i]);
                emit log_named_uint("   debt USD (1e18)", m.debtValueUsd);
                emit log_named_uint("   assets USD (1e18)", m.grossAssetValueUsd);
                emit log_named_uint("   bad debt USD (1e18)", bad);
                emit log_named_uint("   bad debt % of debt (x100)", (bad * 10_000) / m.debtValueUsd);
                id;
                vm.revertToState(snap);
                _setAvaxBps(10_000);
            }
        }
        emit log_named_uint("insurance fund pUSDC USD (1e18)", _usd(address(pUsdc), pUsdc.balanceOf(address(insuranceFund))));
        emit log_named_uint("insurance fund pWAVAX USD (1e18)", _usd(address(pWavax), pWavax.balanceOf(address(insuranceFund))));
    }

    // ================================================================= quantification
    /// @dev Per-position budgets at two sizes (5,000 and 24,000 USDC margin = the proposed debt cap), partial and
    ///      full, both sides: debt asset the funder must hold, pTokens it receives, value, bonus and gas.
    function testQuantify_PerPositionBudgets() public {
        _boot();
        uint256[2] memory margins = [uint256(5_000e6), 24_000e6];
        for (uint256 m; m < 2; ++m) {
            for (uint256 s; s < 2; ++s) {
                bool short = s == 1;
                for (uint256 mode; mode < 2; ++mode) {
                    uint256 snap = vm.snapshotState();
                    (uint256 id, address account) = _openSide(short, margins[m]);
                    if (mode == 0) _shockPartial(account, short);
                    else _shockFull(short);
                    IsolatedMarginTypes.Position memory p = _position(id);
                    uint256 debtBefore = PErc20(p.debtPToken).borrowBalanceCurrent(account);
                    Outcome memory o = _runFunded(id);
                    uint256 repaidUsd = riskEngine.underlyingValueUsd(p.debtPToken, o.repaid);
                    uint256 gotUsd = _usd(p.positionPToken, o.posGot) + (o.marginGot > 0 ? _usd(p.marginPToken, o.marginGot) : 0);
                    emit log_string(
                        string.concat(
                            short ? "SHORT" : "LONG", " margin=", vm.toString(margins[m] / 1e6), " USDC ", mode == 0 ? "PARTIAL" : "FULL"
                        )
                    );
                    emit log_named_uint("   debt before (debt asset base units)", debtBefore);
                    emit log_named_uint("   funder budget needed = repay (debt asset base units)", o.repaid);
                    emit log_named_uint("   repay USD (1e18)", repaidUsd);
                    emit log_named_uint("   pTokens received (8 dec)", o.posGot + o.marginGot);
                    emit log_named_uint("   pTokens received USD (1e18)", gotUsd);
                    emit log_named_uint("   gross bonus USD (1e18)", gotUsd > repaidUsd ? gotUsd - repaidUsd : 0);
                    emit log_named_uint("   gas", o.gasUsed);
                    assertLe(gotUsd, repaidUsd + (repaidUsd * 500) / 10_000);
                    vm.revertToState(snap);
                    _setAvaxBps(10_000);
                }
            }
        }
    }

    /// @dev Aggregate stress: several positions on each side liquidated by one funder in sequence.
    ///      Measures cumulative debt-asset budget, pToken inventory and its share of the market.
    function testQuantify_AggregateStress() public {
        _boot();
        uint256 nLong = 4;
        uint256 nShort = 3;
        uint256[] memory ids = new uint256[](nLong + nShort);
        address[] memory accounts = new address[](nLong + nShort);
        for (uint256 i; i < nLong; ++i) {
            address u = ALICE;
            OpenReport memory r = _open(u, false, 10_000e6, MAX_LEV_X100);
            ids[i] = r.id;
            accounts[i] = _position(r.id).account;
        }
        for (uint256 i; i < nShort; ++i) {
            address u = BOB;
            OpenReport memory r = _open(u, true, 6_000e6, MAX_LEV_X100);
            ids[nLong + i] = r.id;
            accounts[nLong + i] = _position(r.id).account;
        }
        // the long shock and the short shock are different price directions: run them as two stress events
        uint256 usdcBudget;
        uint256 wavaxBudget;
        uint256 pWavaxInv;
        uint256 pUsdcInv;
        // --- AVAX crash: all longs full liquidation
        _shockFull(false);
        for (uint256 i; i < nLong; ++i) {
            require(riskEngine.isLiquidatable(accounts[i]), "long liquidatable");
            Outcome memory o = _runFunded(ids[i]);
            usdcBudget += o.repaid;
            pWavaxInv += o.posGot;
            pUsdcInv += o.marginGot;
        }
        _refreshFeeds();
        // --- (separate event) AVAX squeeze: all shorts full liquidation
        _shockFull(true);
        for (uint256 i; i < nShort; ++i) {
            require(riskEngine.isLiquidatable(accounts[nLong + i]), "short liquidatable");
            Outcome memory o = _runFunded(ids[nLong + i]);
            wavaxBudget += o.repaid;
            pUsdcInv += o.posGot;
        }
        emit log_named_uint("positions long / short", nLong * 1000 + nShort);
        emit log_named_uint("USDC budget for the longs (1e6)", usdcBudget);
        emit log_named_uint("WAVAX budget for the shorts (1e18)", wavaxBudget);
        emit log_named_uint("pWAVAX inventory (8 dec)", pWavaxInv);
        emit log_named_uint("pUSDC inventory (8 dec)", pUsdcInv);
        uint256 pWavaxUnderlying = Math.mulDiv(pWavaxInv, pWavax.exchangeRateStored(), 1e18);
        uint256 pUsdcUnderlying = Math.mulDiv(pUsdcInv, pUsdc.exchangeRateStored(), 1e18);
        emit log_named_uint("pWAVAX inventory underlying WAVAX (1e18)", pWavaxUnderlying);
        emit log_named_uint("pUSDC inventory underlying USDC (1e6)", pUsdcUnderlying);
        emit log_named_uint("pWAVAX market cash (1e18)", pWavax.getCash());
        emit log_named_uint("pUSDC market cash (1e6)", pUsdc.getCash());
        emit log_named_uint("pWAVAX inventory as % of market cash (x100)", pWavaxUnderlying * 10_000 / (pWavax.getCash() + 1));
        emit log_named_uint("pUSDC inventory as % of market cash (x100)", pUsdcUnderlying * 10_000 / (pUsdc.getCash() + 1));
    }

    /// @dev Inventory economics when redemption is delayed because the market has no cash.
    function testQuantify_RedemptionDelay_Long() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 24_000e6);
        _shockFull(false);
        account;
        Outcome memory o = _runFunded(id);
        // funder takes the pWAVAX to ITS OWN address to try a redemption
        uint256 inv = PErc20(address(pWavax)).balanceOf(RECIPIENT);
        assertEq(inv, o.posGot);
        uint256 invUnderlying = Math.mulDiv(inv, pWavax.exchangeRateStored(), 1e18);
        uint256 invUsd = _wavaxUsd(invUnderlying);
        emit log_named_uint("LONG inventory pWAVAX (8 dec)", inv);
        emit log_named_uint("LONG inventory WAVAX (1e18)", invUnderlying);
        emit log_named_uint("LONG inventory USD (1e6)", invUsd);
        emit log_named_uint("LONG repaid USDC (1e6)", o.repaid);
        emit log_named_uint("LONG bonus if redeemed at repay-time price, USDC (1e6)", invUsd > o.repaid ? invUsd - o.repaid : 0);
        _moveDrainAfterFunded(pWavax, pUsdc);
        vm.prank(RECIPIENT);
        (bool ok, bytes memory ret) = address(pWavax).call(abi.encodeWithSelector(PErc20.redeem.selector, inv));
        emit log_named_uint("redeem with zero cash succeeded (0/1)", ok && abi.decode(ret, (uint256)) == 0 ? 1 : 0);
        _logSel("redeem revert", _selector(ret));
        _carryAndPriceTable(pWavax, invUsd, [uint256(1_000), 2_000, 3_000], "WAVAX (long inventory)");
    }

    function testQuantify_RedemptionDelay_Short() public {
        _boot();
        (uint256 id, address account) = _openSide(true, 24_000e6);
        _shockFull(true);
        account;
        Outcome memory o = _runFunded(id);
        uint256 inv = PErc20(address(pUsdc)).balanceOf(RECIPIENT);
        assertEq(inv, o.posGot);
        uint256 invUnderlying = Math.mulDiv(inv, pUsdc.exchangeRateStored(), 1e18);
        emit log_named_uint("SHORT inventory pUSDC (8 dec)", inv);
        emit log_named_uint("SHORT inventory USDC (1e6)", invUnderlying);
        emit log_named_uint("SHORT repaid WAVAX (1e18)", o.repaid);
        emit log_named_uint("SHORT repaid USD (1e6)", _wavaxUsd(o.repaid));
        _moveDrainAfterFunded(pUsdc, pWavax);
        vm.prank(RECIPIENT);
        (bool ok, bytes memory ret) = address(pUsdc).call(abi.encodeWithSelector(PErc20.redeem.selector, inv));
        emit log_named_uint("redeem with zero cash succeeded (0/1)", ok && abi.decode(ret, (uint256)) == 0 ? 1 : 0);
        _logSel("redeem revert", _selector(ret));
        // USDC inventory: price risk is the USDC peg only; the cost of delay is the carry vs the alternative use.
        _carryAndPriceTable(pUsdc, invUnderlying, [uint256(100), 300, 1_000], "USDC (short inventory; peg risk only)");
    }

    function _moveDrainAfterFunded(PErc20Delegator drainM, PErc20Delegator collM) internal {
        _refreshFeeds();
        _moveDrain(drainM, collM);
        assertLe(drainM.getCash(), 1, "market cash exhausted after the funded liquidation");
    }

    /// @dev Supply carry at (near) 100% utilisation versus an instantaneous price shock on `valueUsd6` of inventory
    ///      held for 1 / 7 / 30 days. `shocks` are bps drops (three of them). Also reports the inventory's share of
    ///      the market, i.e. how much borrower repayment the exit needs when market cash is zero.
    function _carryAndPriceTable(PErc20Delegator m, uint256 valueUsd6, uint256[3] memory shocks, string memory tag) internal {
        uint256 borrows = m.totalBorrows();
        uint256 totalUnderlying = Math.mulDiv(m.totalSupply(), m.exchangeRateStored(), 1e18);
        uint256 rate = irm.getSupplyRate(0, borrows, m.totalReserves(), m.reserveFactorMantissa());
        uint256 apyBps = (rate * 31_536_000 * 10_000) / 1e18; // per-second rate, simple annualisation
        emit log_string(tag);
        emit log_named_uint("   market total borrows (underlying base units)", borrows);
        emit log_named_uint("   market total supply (underlying base units)", totalUnderlying);
        emit log_named_uint("   inventory USD (1e6)", valueUsd6);
        emit log_named_uint("   supply carry at 100% utilisation (APY bps, simple)", apyBps);
        uint256[3] memory days_ = [uint256(1), 7, 30];
        for (uint256 i; i < 3; ++i) {
            emit log_named_uint("   days of delay", days_[i]);
            emit log_named_uint("   carry earned USD (1e6)", (valueUsd6 * apyBps * days_[i]) / (10_000 * 365));
        }
        for (uint256 i; i < 3; ++i) {
            emit log_named_uint("   price shock (bps)", shocks[i]);
            emit log_named_uint("   shock loss USD (1e6)", (valueUsd6 * shocks[i]) / 10_000);
        }
    }
}
