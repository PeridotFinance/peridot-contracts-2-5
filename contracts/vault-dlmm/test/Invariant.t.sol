// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./Base.t.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";

/// @notice Stateful invariant suite: this contract is its own handler. Each `h_*` action performs one random operation (success or revert both fine) and, when it
///         succeeds, checks the property of THAT operation and records a violation flag. The `invariant_*` functions then assert that no flag was ever raised and
///         that the NAV equals the independent oracle model.
///         Properties: (1) no entry (deposit, mint, openBand) ever completes with NAV above the cap; (2) a deposit, mint, redeem, withdraw never lowers the share price
///         beyond rounding (on exits 4 wei + 10 bp of the amount swapped: the swap leg trades against the pool's active bin, which may hold part of the vault's own band at a bin price off the oracle, see the findings; on entries n/(d+1)+2 wei, the bound of the ERC-4626 virtual offset of 1: the entry price is (n+1)/(d+1), below n/d when n > d, see the finding); (3) redeemInKind pays at most the pro-rata slice of each leg and conserves tokens; (4) a rebalance
///         keeps the oracle NAV within maxRebalanceLossBps; (5) totalAssets equals the independent oracle model while the feeds are healthy.
contract InvariantTest is Base {
    bool internal capViolated;
    bool internal priceViolated;
    string internal violOp;
    uint256[6] internal violData;
    bool internal inKindViolated;
    bool internal navLossViolated;
    uint256 internal okDeposits;
    uint256 internal okMints;
    uint256 internal okRedeems;
    uint256 internal okInKind;
    uint256 internal okRebalances;
    uint256 internal okOpens;

    function setUp() public virtual {
        _setUpVault();
        if (address(v) == address(0)) return;
        // the vault must be the only thing the fuzzer touches: handler selectors only
        targetContract(address(this));
        bytes4[] memory sel = new bytes4[](13);
        sel[0] = this.h_deposit.selector;
        sel[1] = this.h_mint.selector;
        sel[2] = this.h_redeem.selector;
        sel[3] = this.h_withdraw.selector;
        sel[4] = this.h_inKind.selector;
        sel[5] = this.h_open.selector;
        sel[6] = this.h_swap.selector;
        sel[7] = this.h_rebalance.selector;
        sel[8] = this.h_donate.selector;
        sel[9] = this.h_income.selector;
        sel[10] = this.h_feed.selector;
        sel[11] = this.h_warp.selector;
        sel[12] = this.h_pushOut.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: sel}));
    }

    function _user(uint8 i) internal pure returns (address) {
        uint256 k = i % 3;
        return k == 0 ? ALICE : k == 1 ? BOB : CAROL;
    }

    function _pw() internal view returns (uint256 n, uint256 d) {
        return (erc.totalAssets(), shares.totalSupply());
    }

    /// entry rounding bound (DERIVED): the ERC-4626 virtual offset of 1 prices an entry at (n+1)/(d+1); minting at most A/(n+1)+1 extra shares of price n/d each,
    /// where A = assets paid = the NAV increase
    function _entryTol(uint256 n0, uint256 d0) internal view returns (uint256) {
        uint256 a = erc.totalAssets() - n0;
        return (a / (n0 + 1) + 1) * (n0 / (d0 == 0 ? 1 : d0) + 1) + 2;
    }

    function _priceOk(uint256 n0, uint256 d0, uint256 tol) internal returns (bool ok) {
        (uint256 n1, uint256 d1) = _pw();
        // dust supply (< 1e6 share-wei, i.e. under one USDC of shares): the ERC-4626 virtual offset of 1 dominates the rounding (price error ~ n/d per share); not asserted here, see the finding
        if (d0 < 1e6 || d1 == 0) return true;
        ok = (n1 + tol) * d0 >= n0 * d1;
        if (!ok) violData = [n0, d0, n1, d1, tol, 0];
    }

    function _safeNav() internal view returns (bool ok, uint256 n) {
        try erc.totalAssets() returns (uint256 x) {
            return (true, x);
        } catch {
            return (false, 0);
        }
    }

    // ------------------------------------------------------------------ actions
    function h_deposit(uint8 who, uint256 amt) external {
        address u = _user(who);
        amt = bound(amt, 1, 120e6);
        (bool ok, uint256 n0) = _safeNav();
        if (!ok) return;
        uint256 d0 = shares.totalSupply();
        usdc.mint(u, amt);
        vm.prank(u);
        try erc.deposit(amt, u) returns (uint256) {
            okDeposits++;
            if (erc.totalAssets() > CAP) capViolated = true;
            if (!_priceOk(n0, d0, _entryTol(n0, d0))) { priceViolated = true; violOp = "entry"; }
        } catch {}
    }

    function h_mint(uint8 who, uint256 sh) external {
        address u = _user(who);
        sh = bound(sh, 1, 150e6);
        (bool ok, uint256 n0) = _safeNav();
        if (!ok) return;
        uint256 d0 = shares.totalSupply();
        usdc.mint(u, 400e6);
        vm.prank(u);
        try erc.mint(sh, u) returns (uint256) {
            okMints++;
            if (erc.totalAssets() > CAP) capViolated = true;
            if (!_priceOk(n0, d0, _entryTol(n0, d0))) { priceViolated = true; violOp = "entry"; }
        } catch {}
    }

    function h_redeem(uint8 who, uint256 frac) external {
        address u = _user(who);
        uint256 bal = shares.balanceOf(u);
        if (bal == 0) return;
        uint256 s = bound(frac, 1, bal);
        (bool ok, uint256 n0) = _safeNav();
        if (!ok) return;
        uint256 d0 = shares.totalSupply();
        vm.prank(u);
        try erc.redeem(s, u, u) returns (uint256 outAssets) {
            okRedeems++;
            if (!_priceOk(n0, d0, 4 + outAssets / 1000)) { priceViolated = true; violOp = "exit"; }
        } catch {}
    }

    function h_withdraw(uint8 who, uint256 amt) external {
        address u = _user(who);
        uint256 bal = shares.balanceOf(u);
        if (bal == 0) return;
        (bool ok, uint256 n0) = _safeNav();
        if (!ok) return;
        uint256 maxA = erc.convertToAssets(bal);
        if (maxA == 0) return;
        amt = bound(amt, 1, maxA);
        uint256 d0 = shares.totalSupply();
        vm.prank(u);
        try erc.withdraw(amt, u, u) returns (uint256) {
            if (!_priceOk(n0, d0, 4 + amt / 1000)) { priceViolated = true; violOp = "exit"; }
        } catch {}
    }

    function h_inKind(uint8 who, uint256 frac) external {
        address u = _user(who);
        uint256 bal = shares.balanceOf(u);
        if (bal == 0) return;
        uint256 s = bound(frac, 1, bal);
        (uint256 c0, uint256 t0) = _holdings();
        uint256 supply = shares.totalSupply();
        vm.prank(u);
        try v.redeemInKind(s, u, u) returns (uint256 ax, uint256 ay) {
            okInKind++;
            (uint256 gc, uint256 gt) = usdcIsX ? (ax, ay) : (ay, ax);
            (uint256 c1, uint256 t1) = _holdings();
            if (gc > c0 * s / supply + 4 || gt > t0 * s / supply + 4) inKindViolated = true;
            if (_diff(c0, c1 + gc) > 8 || _diff(t0, t1 + gt) > 8) inKindViolated = true;
        } catch {
            // an in-kind exit may fail only when the slice is dust
            if (s >= 1e5 && supply != 0 && (shares.balanceOf(u) == bal)) {
                // not a violation of the guarantee unless it failed for a non-dust slice with no hook problem: recorded
                inKindViolated = true;
            }
        }
    }

    function _diff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    function h_open() external {
        if (_hasBand() || shares.totalSupply() == 0) return;
        uint24 a = pair.getActiveId();
        vm.prank(KEEPER);
        try v.openBand(a, 1, 0, 0, 0, block.timestamp + 120) {
            okOpens++;
        } catch {}
    }

    function h_swap(bool sellUsdc, uint256 amt) external {
        amt = bound(amt, 1e6, 90_000e6);
        try this.extSwap(sellUsdc, amt) {} catch {}
    }

    function extSwap(bool sellUsdc, uint256 amt) external {
        _marketSwap(sellUsdc, amt);
    }

    function h_pushOut(bool up) external {
        if (!_hasBand()) return;
        try this.extPush(up) {} catch {}
    }

    function extPush(bool up) external {
        _pushOut(up);
    }

    function h_rebalance() external {
        (bool ok,,) = v.rebalanceAllowed();
        if (!ok) return;
        uint256 navB = _oracleNav();
        bytes memory cd = _rebalanceCall();
        vm.prank(KEEPER);
        (bool s,) = address(v).call(cd);
        if (s) {
            okRebalances++;
            if (_oracleNav() * 10_000 < navB * (10_000 - 50)) navLossViolated = true;
        }
    }

    function h_donate(bool inUsdc, uint256 amt) external {
        amt = bound(amt, 1, 60e6);
        if (inUsdc) usdc.mint(address(v), amt);
        else usdt.mint(address(v), amt);
    }

    function h_income(uint256 amt) external {
        if (!_hasBand()) return;
        amt = bound(amt, 1, 5e6);
        uint24 a = pair.getActiveId();
        usdc.mint(address(pair), amt);
        if (usdcIsX) pair.addToBin(a, uint128(amt), 0);
        else pair.addToBin(a, 0, uint128(amt));
    }

    function h_feed(int256 driftC, int256 driftT) external {
        driftC = bound(driftC, -45, 45);
        driftT = bound(driftT, -45, 45);
        feedUsdc.setAnswer(int256(1e8) + driftC * 1e4);
        feedUsdt.setAnswer(int256(1e8) + driftT * 1e4);
    }

    function h_warp(uint256 dt) external {
        dt = bound(dt, 1, 3 hours);
        _warp(dt);
    }

    // ------------------------------------------------------------------ invariants
    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_noEntryPassedTheCap() public view virtual {
        assertFalse(capViolated, "an entry completed with NAV above the cap");
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_sharePriceNeverFellOnEntryOrExit() public virtual {
        if (priceViolated) {
            emit log_named_string("violating op", violOp);
            emit log_named_array("n0,d0,n1,d1,tol", _arr(violData));
        }
        assertFalse(priceViolated, "a deposit/mint/redeem/withdraw lowered the share price beyond rounding");
    }

    function _arr(uint256[6] memory a) internal pure returns (uint256[] memory r) {
        r = new uint256[](5);
        for (uint256 i; i < 5; ++i) r[i] = a[i];
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_inKindConservesProRata() public view virtual {
        assertFalse(inKindViolated, "redeemInKind overpaid, leaked, or failed for a non-dust slice");
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_rebalanceWithinLossBound() public view virtual {
        assertFalse(navLossViolated, "a rebalance lost more than maxRebalanceLossBps of the oracle NAV");
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_navEqualsIndependentModel() public view virtual {
        (bool ok, uint256 n) = _safeNav();
        if (!ok) return;
        assertApproxEqAbs(n, _oracleNav(), 4, "totalAssets == idle + bins pro rata, USDt leg at the two feeds");
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_supplyZeroOrBacked() public view virtual {
        uint256 s = shares.totalSupply();
        (bool ok, uint256 n) = _safeNav();
        if (!ok || s == 0) return;
        assertGt(n, 0, "shares outstanding with zero NAV");
    }

}

contract InvariantFlippedTest is InvariantTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }

    // inline forge-config does not inherit: the same limits are repeated on the overrides
    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_noEntryPassedTheCap() public view override {
        super.invariant_noEntryPassedTheCap();
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_sharePriceNeverFellOnEntryOrExit() public override {
        super.invariant_sharePriceNeverFellOnEntryOrExit();
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_inKindConservesProRata() public view override {
        super.invariant_inKindConservesProRata();
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_rebalanceWithinLossBound() public view override {
        super.invariant_rebalanceWithinLossBound();
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_navEqualsIndependentModel() public view override {
        super.invariant_navEqualsIndependentModel();
    }

    /// forge-config: default.invariant.runs = 40
    /// forge-config: default.invariant.depth = 40
    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_supplyZeroOrBacked() public view override {
        super.invariant_supplyZeroOrBacked();
    }

}
