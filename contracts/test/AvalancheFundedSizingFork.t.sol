// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./helpers/AvalancheSection5Base.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IsolatedMarginRiskEngineLegacy} from "./legacy/IsolatedMarginRiskEngineLegacy.sol";

/**
 * @notice Fork tests for the FUNDED sizing path (`riskEngine.beginFundedLiquidation`, `_fundedQuote`).
 *         Same pinned fork and harness as the other Avalanche suites. Nothing here signs or broadcasts.
 *
 * What is proven (each test says which):
 *   - the normal flash-liquidation sizing is UNCHANGED: every `beginLiquidation` result and every end-to-end `liquidate()`
 *     result is compared with a FROZEN COPY of the pre-change risk engine (`test/legacy`) behind the same proxy, same state;
 *   - the funded route no longer reads the flash lender (unset / no code / reverting / disabled token / extreme fee / governance
 *     disabled) and its outcome is identical in all of those states;
 *   - the funded quote floors the bonus (= the liquidator's seizure cap) and never exceeds the flash quote;
 *   - full/partial thresholds and the dust rule are shared and unchanged;
 *   - authorization, atomic rollback, upgrade ordering, upgrade rollback and storage compatibility.
 */
contract AvalancheFundedSizingForkTest is AvalancheSection5Base {
    address internal constant FUNDER = CAROL;
    address internal constant RECIPIENT = KEEPER_RECIPIENT;
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal legacyImpl; // frozen pre-change engine, deployed once BEFORE any snapshot

    // ------------------------------------------------------------------ helpers
    function _boot() internal {
        mConfig.queueFundedLiquidator(FUNDER);
        _activate();
        mConfig.addFundedLiquidator(FUNDER);
        legacyImpl = address(new IsolatedMarginRiskEngineLegacy());
    }

    function _impl() internal view returns (address) {
        return address(uint160(uint256(vm.load(address(riskEngine), IMPL_SLOT))));
    }

    function _openSide(bool short, uint256 marginUsdc) internal returns (uint256 id, address account) {
        OpenReport memory r = _open(short ? BOB : ALICE, short, marginUsdc, MAX_LEV_X100);
        id = r.id;
        account = _position(id).account;
    }

    function _hf(address account) internal view returns (uint256) {
        return riskEngine.getMetrics(account).healthFactorBps;
    }

    function _debt(address account, uint256 id) internal view returns (uint256) {
        return PErc20(_position(id).debtPToken).borrowBalanceStored(account);
    }

    function _fundFor(uint256 id) internal {
        IsolatedMarginTypes.Position memory p = _position(id);
        address asset = PErc20(p.debtPToken).underlying();
        uint256 owed = PErc20(p.debtPToken).borrowBalanceCurrent(p.account);
        deal(asset, FUNDER, owed * 2 + 1);
        vm.prank(FUNDER);
        IERC20(asset).approve(address(liquidator), type(uint256).max);
    }

    function _fp(uint256 id) internal pure returns (IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams memory) {
        return IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, RECIPIENT, type(uint256).max, 0, 0, 0);
    }

    function _funded(uint256 id) internal returns (bool ok, bytes memory ret) {
        vm.prank(FUNDER);
        (ok, ret) = address(liquidator).call(abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.liquidateFunded, (_fp(id))));
    }

    function _flashLiquidate(uint256 id) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(liquidator).call(abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.liquidate, (_liqParams(id))));
    }

    function _status(address account) internal view returns (uint8 st) {
        (,,,,,, IsolatedMarginTypes.Status s) = riskEngine.accounts(account);
        st = uint8(s);
    }

    /// @dev Everything a failed call must leave untouched, and what two equal runs must agree on.
    function _digest(uint256 id) internal view returns (bytes32) {
        IsolatedMarginTypes.Position memory p = _position(id);
        (, , , uint256 lockAmt) = mVault.positionLocks(id);
        return keccak256(
            abi.encode(
                pUsdc.borrowBalanceStored(p.account),
                pWavax.borrowBalanceStored(p.account),
                pUsdc.balanceOf(p.account),
                pWavax.balanceOf(p.account),
                _status(p.account),
                uint8(p.status),
                p.lockedMarginPTokens,
                lockAmt,
                mVault.lockedBalance(p.owner, address(pUsdc)),
                mVault.freeBalance(p.owner, address(pUsdc)),
                IERC20(USDC).balanceOf(FUNDER),
                IERC20(WAVAX).balanceOf(FUNDER),
                pUsdc.balanceOf(RECIPIENT),
                pWavax.balanceOf(RECIPIENT),
                pUsdc.balanceOf(p.owner),
                pWavax.balanceOf(p.owner),
                pUsdc.balanceOf(address(insuranceFund)),
                pWavax.balanceOf(address(insuranceFund)),
                IERC20(USDC).balanceOf(address(liquidator)),
                IERC20(WAVAX).balanceOf(address(liquidator))
            )
        );
    }

    function _engineProxyAdmin() internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(address(riskEngine), ADMIN_SLOT)))));
    }

    /// @dev The real upgrade path of the transparent proxy (admin contract owned by PROXY_ADMIN_OWNER).
    function _upgradeEngine(address impl) internal {
        ProxyAdmin pa = _engineProxyAdmin();
        vm.prank(PROXY_ADMIN_OWNER);
        pa.upgradeAndCall(ITransparentUpgradeableProxy(address(riskEngine)), impl, "");
    }

    function _asLiquidator(bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(liquidator));
        (ok, ret) = address(riskEngine).call(data);
    }

    struct Begin {
        bool ok;
        bytes ret; // revert data or abi-encoded (maxRepay, previousHealth)
        uint8 statusAfter;
    }

    /// @dev Calls `data` as the liquidator, records the result and the account status afterwards, then rolls the chain back.
    function _beginAndRollback(address account, bytes memory data) internal returns (Begin memory b) {
        uint256 snap = vm.snapshotState();
        (b.ok, b.ret) = _asLiquidator(data);
        b.statusAfter = _status(account);
        vm.revertToState(snap);
    }

    function _legacyImpl() internal view returns (address) {
        require(legacyImpl != address(0), "boot first");
        return legacyImpl;
    }

    /// @dev Result of `beginLiquidation` on the CURRENT implementation and on the frozen legacy one, from the same state.
    function _diff(address account) internal returns (Begin memory cur, Begin memory old) {
        bytes memory data = abi.encodeCall(IsolatedMarginRiskEngineUpgradeable.beginLiquidation, (account));
        address current = _impl();
        cur = _beginAndRollback(account, data);
        uint256 snap = vm.snapshotState();
        _upgradeEngine(_legacyImpl());
        assertEq(_impl(), legacyImpl, "legacy implementation is live for the comparison");
        old = _beginAndRollback(account, data);
        vm.revertToState(snap);
        assertEq(_impl(), current, "implementation restored");
    }

    function _same(Begin memory a, Begin memory b, string memory why) internal pure {
        assertEq(a.ok, b.ok, string.concat(why, ": ok"));
        assertEq(keccak256(a.ret), keccak256(b.ret), string.concat(why, ": return/revert data"));
        assertEq(a.statusAfter, b.statusAfter, string.concat(why, ": status after"));
    }

    function _decode(Begin memory b) internal pure returns (uint256 maxRepay, uint256 prevHf) {
        require(b.ok, "begin reverted");
        (maxRepay, prevHf) = abi.decode(b.ret, (uint256, uint256));
    }

    // =================================================================== 1. funded quote: formula, floor, <= flash
    function _quoteSweep(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        IsolatedMarginTypes.Position memory p = _position(id);
        IsolatedMarginTypes.PairRiskConfig memory risk = mConfig.getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken);
        uint256 debt = _debt(account, id);
        uint256 floorCeilDiffer;
        for (uint256 i; i < 48; ++i) {
            uint256 h = uint256(keccak256(abi.encode(short, i)));
            _setAvaxBps(3_000 + (h % 17_000));
            uint256 repay = 1 + (uint256(keccak256(abi.encode(h, "r"))) % debt);
            uint256 repayUsd = riskEngine.underlyingValueUsd(p.debtPToken, repay);
            uint256 expectFloor = repayUsd + (repayUsd * risk.liquidationBonusBps) / 10_000;
            uint256 expectCeil = repayUsd + Math.mulDiv(repayUsd, risk.liquidationBonusBps, 10_000, Math.Rounding.Ceil);
            if (expectCeil != expectFloor) ++floorCeilDiffer;
            uint256 funded = riskEngine.getFundedLiquidationQuote(account, repay);
            (uint256 flash,) = riskEngine.getLiquidationQuote(account, repay);
            assertEq(funded, expectFloor, "funded quote = repaid value + FLOORED bonus (the liquidator's cap)");
            assertLe(funded, flash, "funded requirement never exceeds the flash requirement for the same repay");
            assertLe(funded, expectCeil, "funded never above the ceil variant");
            assertLe(funded, repayUsd + (repayUsd * risk.liquidationBonusBps) / 10_000, "funded never above repay x (1 + bonus)");
        }
        // Short (WAVAX debt, 18 decimals): floor and ceil differ in some samples, so the sweep distinguishes them. Long (USDC debt):
        // 6-decimal amounts scaled to 1e18 make repay x 5% exact, so floor == ceil there by construction.
        if (short) assertGt(floorCeilDiffer, 0, "sweep is sensitive to floor vs ceil (at least one sample where they differ)");
    }

    function testQuote_Long_FloorsBonus_NeverAboveFlash() public { _quoteSweep(false); }
    function testQuote_Short_FloorsBonus_NeverAboveFlash() public { _quoteSweep(true); }

    // =================================================================== 2. normal path unchanged vs frozen legacy engine
    function _hfTable(bool short) internal returns (uint256 states) {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        uint256[9] memory longBps = [uint256(6_600), 6_300, 6_000, 5_800, 5_600, 5_500, 5_400, 4_500, 3_000];
        uint256[9] memory shortBps = [uint256(15_100), 15_500, 16_000, 17_000, 17_700, 18_000, 18_500, 23_000, 28_000];
        uint256[3] memory fees = [uint256(0), 9, 0]; // healthy lender at 0 bps, at 9 bps, and (pass 3) a mocked lender fee equal to the whole debt
        uint256 sensitive; // states where the FUNDED sizing differs from the flash sizing (proves the table can tell the two apart)
        for (uint256 f; f < 3; ++f) {
            lender.setFeeBps(fees[f]);
            if (f == 2) vm.mockCall(address(lender), abi.encodeWithSignature("flashFee(address,uint256)"), abi.encode(_debt(account, id)));
            for (uint256 i; i < 9; ++i) {
                _setAvaxBps(short ? shortBps[i] : longBps[i]);
                if (!riskEngine.isLiquidatable(account)) continue;
                (Begin memory cur, Begin memory old) = _diff(account);
                _same(cur, old, "beginLiquidation unchanged vs legacy");
                assertTrue(cur.ok, "table state is liquidatable");
                Begin memory fund = _beginAndRollback(account, abi.encodeCall(IsolatedMarginRiskEngineUpgradeable.beginFundedLiquidation, (account)));
                if (keccak256(fund.ret) != keccak256(cur.ret)) ++sensitive;
                ++states;
            }
        }
        assertGt(sensitive, 0, "the table includes states where funded and flash sizing differ, so a swapped/merged implementation would be caught");
        emit log_named_uint("states where funded != flash sizing", sensitive);
        emit log_named_uint("liquidatable states compared", states);
        assertGe(states, 20, "enough liquidatable states compared");
    }

    function testDifferential_BeginLiquidation_Long() public { _hfTable(false); }
    function testDifferential_BeginLiquidation_Short() public { _hfTable(true); }

    /// @dev End-to-end `liquidate()` (flash + swap) must leave the identical state under the legacy and the current engine.
    function _flashEndToEnd(bool short, uint256 bps, bool expectOk) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        _setAvaxBps(bps);
        assertTrue(riskEngine.isLiquidatable(account), "liquidatable");
        uint256 snap = vm.snapshotState();
        (bool okC, bytes memory retC) = _flashLiquidate(id);
        bytes32 dC = _digest(id);
        vm.revertToState(snap);
        _upgradeEngine(_legacyImpl());
        (bool okL, bytes memory retL) = _flashLiquidate(id);
        bytes32 dL = _digest(id);
        assertEq(okC, okL, "flash route success equal");
        assertEq(keccak256(retC), keccak256(retL), "flash route return/revert data equal");
        assertEq(dC, dL, "flash route end state identical under legacy and current engine");
        if (expectOk) assertTrue(okC, "the flash route completes in this state (pool at pin, oracle moved)");
        else assertFalse(okC, "oracle-only short shock hits the unfavourable swap leg: both engines revert identically");
    }

    function testDifferential_FlashLiquidate_Long_Partial() public { _flashEndToEnd(false, 6_300, true); }
    function testDifferential_FlashLiquidate_Long_Full() public { _flashEndToEnd(false, 5_400, true); }
    function testDifferential_FlashLiquidate_Short_OracleOnlyRevertsIdentically() public { _flashEndToEnd(true, 15_500, false); }

    // =================================================================== 3. thresholds, dust, funded <= flash escalation
    function _thresholdScan(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        IsolatedMarginTypes.Position memory p = _position(id);
        IsolatedMarginTypes.PairRiskConfig memory risk = mConfig.getPairRisk(p.marginPToken, p.positionPToken, p.debtPToken);
        uint256 debt = _debt(account, id);
        uint256 partialBoth; uint256 fullBoth; uint256 fundedPartialFlashFull;
        for (uint256 i; i < 120; ++i) {
            uint256 bps = short ? 14_500 + i * 140 : 7_000 - i * 55;
            _setAvaxBps(bps);
            if (!riskEngine.isLiquidatable(account)) continue;
            (Begin memory flash,) = _diff(account);
            Begin memory fund = _beginAndRollback(account, abi.encodeCall(IsolatedMarginRiskEngineUpgradeable.beginFundedLiquidation, (account)));
            assertTrue(flash.ok && fund.ok, "both begin");
            (uint256 fr,) = _decode(flash);
            (uint256 ur, uint256 uh) = _decode(fund);
            (, uint256 fh) = _decode(flash);
            assertEq(fh, uh, "same previous health");
            assertEq(uh, _hf(account), "previous health = current health");
            assertEq(fund.statusAfter, uint8(IsolatedMarginTypes.Status.LIQUIDATING), "funded start moves to LIQUIDATING like the flash start");
            if (uh <= risk.fullLiquidationHealthBps) {
                assertEq(fr, debt, "flash: full at or below the full-liquidation health");
                assertEq(ur, debt, "funded: full at or below the full-liquidation health (threshold shared)");
            }
            // funded requirement <= flash requirement and every escalation condition is monotone in it:
            // whenever the flash start stays partial, the funded start stays partial too (never more liquidation than the flash route).
            if (fr < debt) assertLt(ur, debt, "funded never escalates where the flash route does not");
            if (fr < debt && ur < debt) { assertEq(ur, fr, "same partial repay (maxLiquidationBps)"); ++partialBoth; }
            if (fr == debt && ur == debt) ++fullBoth;
            if (fr == debt && ur < debt) ++fundedPartialFlashFull;
        }
        emit log_named_uint("states partial/partial", partialBoth);
        emit log_named_uint("states full/full", fullBoth);
        emit log_named_uint("states funded partial where flash escalates to full", fundedPartialFlashFull);
        assertGt(partialBoth, 0, "partial region covered");
        assertGt(fullBoth, 0, "full region covered");
    }

    function testThresholds_Long_SharedAndMonotone() public { _thresholdScan(false); }
    function testThresholds_Short_SharedAndMonotone() public { _thresholdScan(true); }

    /// @dev Dust rule: debt value <= DUST_DEBT_VALUE_USD (10 USD) is always a FULL liquidation, on both routes, even when the
    ///      health is far above the full-liquidation health.
    function testDust_FullOnBothRoutes() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 7e6); // 7 USDC margin at 2x -> 7 USDC debt, below the 10 USD dust bound
        uint256 debt = _debt(account, id);
        assertLe(riskEngine.getMetrics(account).debtValueUsd, riskEngine.DUST_DEBT_VALUE_USD(), "position is dust-sized");
        uint256 bps = 10_000;
        for (uint256 i; i < 90 && !riskEngine.isLiquidatable(account); ++i) { bps -= 100; _setAvaxBps(bps); }
        assertTrue(riskEngine.isLiquidatable(account), "liquidatable");
        uint256 hf = _hf(account);
        (Begin memory flash, Begin memory old) = _diff(account);
        _same(flash, old, "dust: flash unchanged");
        Begin memory fund = _beginAndRollback(account, abi.encodeCall(IsolatedMarginRiskEngineUpgradeable.beginFundedLiquidation, (account)));
        (uint256 fr,) = _decode(flash);
        (uint256 ur,) = _decode(fund);
        assertEq(fr, debt, "flash: dust is full");
        assertEq(ur, debt, "funded: dust is full");
        emit log_named_uint("dust case health bps (informational; rule is independent of it)", hf);
    }

    // =================================================================== 4. the funded route no longer depends on the flash lender
    struct Out { bool ok; bytes ret; uint256 debtAfter; uint256 posGot; uint256 marginGot; bytes32 digest; uint8 status; }

    function _runFundedOutcome(uint256 id) internal returns (Out memory o) {
        IsolatedMarginTypes.Position memory p = _position(id);
        _fundFor(id);
        uint256 pos0 = PErc20(p.positionPToken).balanceOf(RECIPIENT);
        uint256 mar0 = PErc20(p.marginPToken).balanceOf(RECIPIENT);
        (o.ok, o.ret) = _funded(id);
        o.debtAfter = _debt(p.account, id);
        o.posGot = PErc20(p.positionPToken).balanceOf(RECIPIENT) - pos0;
        o.marginGot = p.marginPToken == p.positionPToken ? 0 : PErc20(p.marginPToken).balanceOf(RECIPIENT) - mar0;
        o.digest = _digest(id);
        o.status = _status(p.account);
    }

    function _lenderStates(bool short) internal {
        _boot();
        (uint256 id, address account) = _openSide(short, 5_000e6);
        uint256 bps = short ? 15_500 : 6_300;
        _setAvaxBps(bps);
        assertTrue(riskEngine.isLiquidatable(account), "liquidatable");
        uint256 debt = _debt(account, id);
        (Begin memory flashBase,) = _diff(account);
        (uint256 flashRepayBase,) = _decode(flashBase);
        assertLt(flashRepayBase, debt, "scenario is PARTIAL on the flash route with a healthy lender");

        uint256 snap = vm.snapshotState();
        Out memory base = _runFundedOutcome(id);
        assertTrue(base.ok, "baseline funded partial liquidation succeeds");
        assertLt(base.debtAfter, debt, "debt reduced");
        assertGt(base.debtAfter, 0, "partial: debt remains");
        vm.revertToState(snap);

        address lend = address(lender);
        address debtAsset = PErc20(_position(id).debtPToken).underlying();
        for (uint256 s; s < 7; ++s) {
            if (s == 0) vm.mockCall(address(mConfig), abi.encodeWithSignature("flashLoanProvider()"), abi.encode(address(0))); // unset
            if (s == 1) vm.mockCall(address(mConfig), abi.encodeWithSignature("flashLoanProvider()"), abi.encode(address(0xE0A))); // EOA / no code
            if (s == 2) vm.mockCallRevert(lend, abi.encodeWithSignature("flashFee(address,uint256)"), "fee view reverts"); // reverting lender
            if (s == 3) lender.setTokenAllowed(debtAsset, false); // token no longer allowed: real flashFee reverts
            if (s == 4) lender.setFeeBps(100); // 100 bps fee
            if (s == 5) vm.mockCall(lend, abi.encodeWithSignature("flashFee(address,uint256)"), abi.encode(type(uint128).max)); // absurd fee
            if (s == 6) mConfig.disableExecutionEndpoints(); // governance disabled router and lender
            // flash start in this state: identical to legacy (failure mode PRESERVED, not tolerated)
            (Begin memory cur, Begin memory old) = _diff(account);
            _same(cur, old, "flash start unchanged vs legacy in a broken-lender state");
            if (s <= 3 || s == 6) assertFalse(cur.ok, "flash start fails when the lender view is unavailable");
            // and the funded route behaves exactly as in the healthy state
            snap = vm.snapshotState();
            Out memory o = _runFundedOutcome(id);
            if (!o.ok) { emit log_named_uint("lender state that failed", s); emit log_named_bytes("revert data", o.ret); }
            assertTrue(o.ok, "funded partial liquidation succeeds without the lender");
            assertEq(o.debtAfter, base.debtAfter, "same repay");
            assertEq(o.posGot, base.posGot, "same position pTokens seized");
            assertEq(o.marginGot, base.marginGot, "same margin pTokens seized");
            assertEq(o.status, uint8(IsolatedMarginTypes.Status.ACTIVE), "back to ACTIVE after a partial");
            if (s != 6) {
                // the digest also covers the funder/recipient balances; endpoints disabled changes no balance either
                assertEq(o.digest, base.digest, "complete end state identical to the healthy-lender run");
            }
            vm.revertToState(snap);
            vm.clearMockedCalls(); // also removes the harness' Chainlink feed mocks: re-serve the pinned prices
            _setAvaxBps(bps);
            // restore the real lender for the next state
            lender.setTokenAllowed(debtAsset, true);
            lender.setFeeBps(0);
            if (s == 6) break;
        }
    }

    function testFunded_PartialIndependentOfLender_Long() public { _lenderStates(false); }
    function testFunded_PartialIndependentOfLender_Short() public { _lenderStates(true); }

    /// @dev Replaces the old FINDING test: with the execution endpoints disabled a funded PARTIAL now completes.
    function testAcceptance_PartialSizingIndependentOfFlashLender() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _setAvaxBps(6_300);
        mConfig.disableExecutionEndpoints();
        (bool fok,) = _flashLiquidate(id);
        assertFalse(fok, "flash route has no lender");
        Out memory o = _runFundedOutcome(id);
        assertTrue(o.ok, "funded partial completes with the lender disabled");
        assertGt(_debt(account, id), 0, "it was a partial");
    }

    // =================================================================== 5. escalation difference, borrower protection, conservation
    /// @dev A lender that charges a large fee makes the FLASH sizing escalate a partial to a full liquidation; the funded sizing
    ///      (no fee, no swap) stays partial. The borrower keeps collateral, no value is created or destroyed, and the funder's take
    ///      stays within repaid value x (1 + bonus) with the floored-bonus cap.
    function testFunded_StaysPartialWhereFlashEscalates_BorrowerBoundAndConservation() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        IsolatedMarginTypes.Position memory p = _position(id);
        _setAvaxBps(6_300);
        uint256 debt = _debt(account, id);
        vm.mockCall(address(lender), abi.encodeWithSignature("flashFee(address,uint256)"), abi.encode(debt)); // fee as large as the debt
        (Begin memory flash,) = _diff(account);
        (uint256 flashRepay,) = _decode(flash);
        assertEq(flashRepay, debt, "flash sizing escalates to FULL when the lender fee is large");

        int256 eq0 = riskEngine.getMetrics(account).equityUsd;
        uint256 pos0 = PErc20(p.positionPToken).balanceOf(account);
        Out memory o = _runFundedOutcome(id);
        assertTrue(o.ok, "funded call succeeds");
        uint256 repaid = debt - o.debtAfter;
        assertGt(o.debtAfter, 0, "funded stays PARTIAL");
        assertGt(PErc20(p.positionPToken).balanceOf(account), 0, "borrower keeps position pTokens");
        assertLt(o.posGot, pos0, "funder did not take the whole position");

        uint256 repaidUsd = riskEngine.underlyingValueUsd(p.debtPToken, repaid);
        uint256 cap = riskEngine.getFundedLiquidationQuote(account, repaid);
        uint256 seizedUsd = riskEngine.pTokenValueUsd(p.positionPToken, o.posGot);
        assertLe(seizedUsd, cap, "seized value <= repaid value + FLOORED bonus (borrower bound)");
        assertEq(cap, repaidUsd + (repaidUsd * 500) / 10_000, "cap uses the floored bonus");
        // conservation at oracle prices: the borrower's equity falls by exactly the funder's gain (seized - repaid), up to rounding
        int256 eq1 = riskEngine.getMetrics(account).equityUsd;
        int256 funderGain = int256(seizedUsd) - int256(repaidUsd);
        int256 borrowerLoss = eq0 - eq1;
        assertApproxEqAbs(borrowerLoss, funderGain, 1e12, "no value created or destroyed (1e-6 USD in 1e18 units)");
        assertGe(funderGain, 0, "funder is not paid below repaid value in a solvent position");
    }

    // =================================================================== 6. authorization
    function testAuthorization_BeginFundedLiquidation_OnlyLiquidator() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _setAvaxBps(6_300);
        bytes memory data = abi.encodeCall(IsolatedMarginRiskEngineUpgradeable.beginFundedLiquidation, (account));
        address[5] memory callers = [address(this), FUNDER, address(executor), riskEngine.owner(), address(0xBAD)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            (bool ok, bytes memory ret) = address(riskEngine).call(data);
            assertFalse(ok, "non-liquidator cannot start a funded liquidation");
            assertEq(keccak256(ret), keccak256(abi.encodeWithSignature("Error(string)", "RiskEngine: not liquidator")), "reason");
        }
        assertEq(_status(account), uint8(IsolatedMarginTypes.Status.ACTIVE), "status untouched by rejected calls");
        // the liquidator itself works, but only on an ACTIVE, unhealthy account
        Begin memory b = _beginAndRollback(account, data);
        assertTrue(b.ok);
        _setAvaxBps(10_000);
        Begin memory healthy = _beginAndRollback(account, data);
        assertFalse(healthy.ok, "healthy account");
        assertEq(keccak256(healthy.ret), keccak256(abi.encodeWithSignature("Error(string)", "RiskEngine: healthy")));
        // non-allowlisted funder cannot reach it through the liquidator either
        _setAvaxBps(6_300);
        _fundFor(id);
        vm.prank(address(0xBAD));
        (bool ok2,) = address(liquidator).call(abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.liquidateFunded, (_fp(id))));
        assertFalse(ok2, "only an allowlisted funder");
        // an account that is already LIQUIDATING cannot be started again
        vm.prank(address(liquidator));
        riskEngine.beginFundedLiquidation(account);
        Begin memory twice = _beginAndRollback(account, data);
        assertFalse(twice.ok);
        assertEq(keccak256(twice.ret), keccak256(abi.encodeWithSignature("Error(string)", "RiskEngine: not active")));
    }

    // =================================================================== 7. atomic rollback
    function testRollback_FundedCallRevertingAfterSizingLeavesNothing() public {
        _boot();
        (uint256 id, address account) = _openSide(false, 5_000e6);
        _setAvaxBps(6_300);
        _fundFor(id);
        bytes32 d0 = _digest(id);
        uint8 s0 = _status(account);
        // (a) caller floor not met: reverts AFTER beginFundedLiquidation moved the account to LIQUIDATING
        vm.prank(FUNDER);
        (bool ok, bytes memory ret) = address(liquidator).call(
            abi.encodeCall(
                IsolatedMarginLiquidatorUpgradeable.liquidateFunded,
                (IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, RECIPIENT, type(uint256).max, type(uint256).max, 0, 0))
            )
        );
        assertFalse(ok);
        assertEq(uint32(bytes4(ret)), uint32(IsolatedMarginLiquidatorUpgradeable.LiquidationError.selector), "LiquidationError(30)");
        assertEq(_digest(id), d0, "(a) no state change");
        assertEq(_status(account), s0, "(a) account back to ACTIVE, not stuck LIQUIDATING");
        // (b) max repay below the sized repay
        vm.prank(FUNDER);
        (ok,) = address(liquidator).call(
            abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.liquidateFunded, (IsolatedMarginLiquidatorUpgradeable.FundedLiquidationParams(id, RECIPIENT, 1, 0, 0, 0)))
        );
        assertFalse(ok);
        assertEq(_digest(id), d0, "(b) no state change");
        // (c) funder cannot pay
        vm.prank(FUNDER);
        IERC20(USDC).approve(address(liquidator), 0);
        vm.prank(FUNDER);
        (ok,) = address(liquidator).call(abi.encodeCall(IsolatedMarginLiquidatorUpgradeable.liquidateFunded, (_fp(id))));
        assertFalse(ok);
        assertEq(_status(account), s0, "(c) status ACTIVE");
        // (d) the same call then succeeds once the revert reason is removed
        vm.prank(FUNDER);
        IERC20(USDC).approve(address(liquidator), type(uint256).max);
        (ok,) = _funded(id);
        assertTrue(ok, "control: the call works when nothing blocks it");
    }

    // =================================================================== 8. upgrade order, upgrade rollback, storage compatibility
    function _engineSnapshot(address account) internal view returns (bytes32 h) {
        bytes32 base = keccak256(abi.encode(account, uint256(5))); // accounts mapping at slot 5
        for (uint256 i; i < 8; ++i) h = keccak256(abi.encode(h, vm.load(address(riskEngine), bytes32(uint256(base) + i))));
        h = keccak256(abi.encode(h, vm.load(address(riskEngine), keccak256(abi.encode(account, uint256(6)))))); // isIsolatedMarginAccount
    }

    function _rawSlots() internal view returns (bytes32 h) {
        for (uint256 i; i < 9; ++i) h = keccak256(abi.encode(h, vm.load(address(riskEngine), bytes32(i))));
    }

    function testUpgrade_OrderRollbackAndStorageCompatibility() public {
        _boot();
        address current = _impl();
        // positions opened under the CURRENT engine
        (uint256 id, address account) = _openSide(false, 5_000e6);
        (uint256 id2, address account2) = _openSide(true, 5_000e6);
        _setAvaxBps(6_300);
        bytes32 e0 = _engineSnapshot(account); bytes32 e0b = _engineSnapshot(account2); bytes32 raw0 = _rawSlots();

        // (1) risk engine rolled BACK to the pre-change implementation while the NEW liquidator is live: funded fails CLOSED
        _upgradeEngine(_legacyImpl());
        assertEq(_engineSnapshot(account), e0, "storage readable and identical through the legacy implementation");
        assertEq(_engineSnapshot(account2), e0b);
        assertEq(_rawSlots(), raw0, "raw fixed slots 0..8 unchanged by the downgrade");
        _fundFor(id);
        bytes32 d0 = _digest(id);
        (bool ok, ) = _funded(id);
        assertFalse(ok, "new liquidator + old engine: funded route reverts (missing function), fails closed");
        assertEq(_digest(id), d0, "and changes nothing");
        uint256 snapF = vm.snapshotState();
        (bool fok,) = _flashLiquidate(id); // the flash route on the old engine is unaffected
        assertTrue(fok, "flash route works on the old engine");
        vm.revertToState(snapF);
        id2; account2;

        // (2) roll FORWARD again: state preserved, funded works
        _upgradeEngine(current);
        assertEq(_engineSnapshot(account), e0, "state identical after rolling forward");
        assertEq(_rawSlots(), raw0, "raw slots identical after rolling forward");
        (ok,) = _funded(id);
        assertTrue(ok, "funded route works after the engine upgrade");
        assertGt(_debt(account, id), 0, "partial");
    }

    function testUpgrade_PositionOpenedUnderLegacyEngineIsLiquidatableAfterUpgrade() public {
        _boot();
        _upgradeEngine(_legacyImpl());
        (uint256 id, address account) = _openSide(false, 5_000e6); // opened, registered and locked under the OLD engine
        _setAvaxBps(6_300);
        bytes32 e0 = _engineSnapshot(account);
        uint256 current = uint256(uint160(address(new IsolatedMarginRiskEngineUpgradeable())));
        _upgradeEngine(address(uint160(current)));
        assertEq(_engineSnapshot(account), e0, "registered account state preserved across the upgrade");
        _fundFor(id);
        (bool ok,) = _funded(id);
        assertTrue(ok, "funded liquidation of a position that pre-dates the upgrade");
    }
}
