// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./Base.t.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";

/// @notice Stateless fuzz tests of the spec's properties (section 2 cap, section 3 exits, section 4 guard arithmetic, section 5 NAV bound).
contract FuzzTest is Base {
    function setUp() public virtual {
        _setUpVault();
    }

    // ------------------------------------------------------------------ cap: no sequence of deposit, mint, openBand, gains, losses and donations lets an entry pass above the cap
    /// ops: 0 deposit, 1 mint, 2 openBand, 3 donation of USDC, 4 donation of USDt, 5 bin income, 6 market swap (moves composition)
    function testFuzz_noSequencePassesTheCap(uint256[12] memory seeds) public {
        for (uint256 i; i < seeds.length; ++i) {
            uint256 op = seeds[i] % 7;
            uint256 amt = ((seeds[i] >> 8) % 120e6) + 1;
            address who = i % 2 == 0 ? ALICE : BOB;
            if (op == 0) {
                vm.prank(who);
                try erc.deposit(amt, who) returns (uint256) {
                    assertLe(erc.totalAssets(), CAP, "deposit succeeded above the cap");
                } catch {}
            } else if (op == 1) {
                uint256 sh = (amt * erc.totalSupply() / (erc.totalAssets() + 1)) + 1;
                vm.prank(who);
                try erc.mint(sh, who) returns (uint256) {
                    assertLe(erc.totalAssets(), CAP, "mint succeeded above the cap");
                } catch {}
            } else if (op == 2) {
                if (!_hasBand()) {
                    uint24 a = pair.getActiveId();
                    uint256 navB = erc.totalAssets();
                    vm.prank(KEEPER);
                    try v.openBand(a, 1, 0, 0, 0, block.timestamp + 120) {
                        // D6: openBand is not cap-bound; it must not CREATE value beyond its swap/entry loss accounting, and entries stay closed above the cap
                        assertLe(erc.totalAssets(), navB + navB / 100 + 2, "openBand does not create value");
                    } catch {}
                }
            } else if (op == 3) {
                usdc.mint(address(v), amt / 4); // a donation can only reduce headroom
            } else if (op == 4) {
                usdt.mint(address(v), amt / 4);
            } else if (op == 5 && _hasBand()) {
                uint24 a = pair.getActiveId();
                uint128 x = uint128(amt / 8);
                if (usdcIsX) {
                    usdc.mint(address(pair), x);
                    pair.addToBin(a, x, 0);
                } else {
                    usdc.mint(address(pair), x);
                    pair.addToBin(a, 0, x);
                }
            } else if (op == 6) {
                _marketSwap(seeds[i] % 2 == 0, (amt % 20e6) + 1e6);
            }
            // the headroom promise: maxDeposit never exceeds what the cap allows
            uint256 md = erc.maxDeposit(ALICE);
            assertLe(md + erc.totalAssets(), md == 0 ? type(uint256).max : CAP, "maxDeposit respects the cap");
        }
    }

    function testFuzz_depositNeverExceedsMaxDeposit(uint256 prior, uint256 amt) public {
        prior = bound(prior, 0, 250e6);
        amt = bound(amt, 1, 400e6);
        if (prior >= 1e6) {
            uint256 p = prior > CAP ? CAP : prior;
            _deposit(ALICE, p);
        }
        uint256 md = erc.maxDeposit(BOB);
        usdc.mint(BOB, amt);
        uint256 newSupply = shares.totalSupply() + erc.previewDeposit(amt);
        vm.prank(BOB);
        if (amt <= md && newSupply >= 1e6) {
            erc.deposit(amt, BOB);
            assertLe(erc.totalAssets(), CAP);
        } else if (amt <= md) {
            // minimum-supply rule (W10 F1): an entry may not leave the supply in (0, 1e6)
            vm.expectRevert();
            erc.deposit(amt, BOB);
        } else {
            vm.expectRevert();
            erc.deposit(amt, BOB);
        }
    }

    // ------------------------------------------------------------------ share price: rounding favours the vault
    function testFuzz_depositShareValueNeverExceedsAssets(uint256 first, uint256 income, uint256 amt) public {
        first = bound(first, 1e6, 100e6);
        income = bound(income, 0, 40e6);
        amt = bound(amt, 1, 90e6);
        _deposit(ALICE, first);
        _openBand();
        if (income != 0) {
            uint24 a = pair.getActiveId();
            usdc.mint(address(pair), income);
            if (usdcIsX) pair.addToBin(a, uint128(income), 0);
            else pair.addToBin(a, 0, uint128(income));
        }
        if (amt > erc.maxDeposit(BOB)) return;
        if (erc.previewDeposit(amt) == 0) return; // a deposit worth zero shares reverts ZeroShares (checked in Shares.t.sol)
        (uint256 n0, uint256 d0) = (erc.totalAssets(), shares.totalSupply());
        uint256 s = _deposit(BOB, amt);
        assertLe(erc.convertToAssets(s), amt, "minted shares are worth at most the assets paid");
        (uint256 n1, uint256 d1) = (erc.totalAssets(), shares.totalSupply());
        // the price can dip only by rounding, only above par, and by at most D <= a*(N-S)/(N+1) (OZ virtual offset 1; W7 verdict 16 Nov)
        if (n0 * s > amt * d0) {
            assertGt(n0, d0, "a price dip is possible only above par");
            assertLe((n0 * s - amt * d0) * (n0 + 1), amt * (n0 - d0), "price dip within the virtual-offset rounding bound");
        }
        n1; d1;
    }

    function testFuzz_roundTripNeverProfits(uint256 amt, bool withBand) public {
        amt = bound(amt, 1e6, 150e6);
        _deposit(CAROL, 20e6); // a second holder, so the redeem is partial
        if (withBand) _openBand();
        uint256 s = _deposit(ALICE, amt);
        uint256 before = usdc.balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 out = erc.redeem(s, ALICE, ALICE);
        assertEq(usdc.balanceOf(ALICE), before + out);
        assertLe(out, amt, "no profit from a deposit and an immediate redeem");
    }

    function testFuzz_withdrawBurnsAtLeastTheValue(uint256 amt, uint256 w) public {
        amt = bound(amt, 5e6, 120e6);
        _deposit(ALICE, amt);
        _openBand();
        w = bound(w, 1, amt / 2);
        uint256 s0 = shares.balanceOf(ALICE);
        (uint256 n0, uint256 d0) = (erc.totalAssets(), shares.totalSupply());
        vm.prank(ALICE);
        (bool wok, bytes memory wret) = address(v).call(abi.encodeWithSignature("withdraw(uint256,address,address)", w, ALICE, ALICE));
        if (!wok) {
            // FINDING (low): a dust withdraw whose USDt part swaps to zero USDC reverts with the pair's LBPair__InsufficientAmountOut; only dust may do so
            assertLt(w, 1e3, "only dust withdrawals may fail");
            bytes4 sl = _sel(wret);
            assertTrue(sl == bytes4(keccak256("LBPair__InsufficientAmountOut()")) || sl == bytes4(keccak256("ExitFailed()")), "dust failure is the pair's or ExitFailed");
            return;
        }
        uint256 burned = s0 - shares.balanceOf(ALICE);
        assertGe(burned * (n0 + 1), w * d0 - d0, "burned shares cover the assets (ceil)");
        (uint256 n1, uint256 d1) = (erc.totalAssets(), shares.totalSupply());
        assertGe((n1 + 4) * d0, n0 * d1, "share price fell by more than 4 wei of NAV");
    }

    // ------------------------------------------------------------------ redeemInKind conservation
    function testFuzz_inKindProRataConservation(uint256 a, uint256 b, uint256 frac, uint8 how) public {
        a = bound(a, 2e6, 100e6);
        b = bound(b, 2e6, 80e6);
        _deposit(ALICE, a);
        _deposit(BOB, b);
        if (how % 3 != 0) _openBand();
        if (how % 3 == 2) _pushOut(how % 2 == 0);
        if (how % 7 == 0) {
            feedUsdc.setRevertAll(true);
            feedUsdt.setRevertAll(true);
        }
        if (how % 5 == 0) {
            vm.prank(SAFE);
            adm.pause();
        }
        (uint256 c0, uint256 t0) = _holdings();
        uint256 supply = shares.totalSupply();
        uint256 s = bound(frac, 1e3, shares.balanceOf(ALICE));
        vm.prank(ALICE);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.redeemInKind, (s, ALICE, ALICE)));
        if (!ok) {
            // only an empty slice may fail
            assertLt(s, 1e5, "a non-dust in-kind exit must never fail");
            return;
        }
        (uint256 ax, uint256 ay) = abi.decode(ret, (uint256, uint256));
        (uint256 gc, uint256 gt) = usdcIsX ? (ax, ay) : (ay, ax);
        assertLe(gc, c0 * s / supply + 4, "USDC leg: at most the pro-rata share");
        assertLe(gt, t0 * s / supply + 4, "USDt leg: at most the pro-rata share");
        (uint256 c1, uint256 t1) = _holdings();
        // conservation: what left the vault equals what was paid, up to the re-flooring of bin valuations
        assertApproxEqAbs(c0, c1 + gc, 8, "USDC conserved");
        assertApproxEqAbs(t0, t1 + gt, 8, "USDt conserved");
        // the other holder is not diluted: his claim on each leg did not shrink
        uint256 bobS = shares.balanceOf(BOB);
        assertGe((c1 + 16) * supply, c0 * (supply - s), "the remaining holders keep their USDC claim");
        assertGe((t1 + 16) * supply, t0 * (supply - s), "the remaining holders keep their USDt claim");
        assertEq(shares.balanceOf(BOB), bobS);
    }

    // ------------------------------------------------------------------ rebalance conserves the oracle NAV within the loss bound
    function testFuzz_rebalanceConservesNav(uint256 amt, bool up, uint256 feeWad, uint256 lossBps, int256 usdtDriftBps) public {
        amt = bound(amt, 5e6, 150e6);
        feeWad = bound(feeWad, 0, 6e15); // up to 0.6 % pool fee
        lossBps = bound(lossBps, 5, 300);
        usdtDriftBps = bound(usdtDriftBps, -45, 45);
        _deposit(ALICE, amt);
        _openBand();
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        g.maxRebalanceLossBps = uint16(lossBps);
        vm.prank(SAFE);
        v.setGuardParams(g);
        _pushOut(up);
        feedUsdt.setAnswer(int256(1e8) + usdtDriftBps * 1e4);
        pair.setFee(feeWad);
        uint256 navB = _oracleNav();
        bytes memory cd = _rebalanceCall();
        vm.prank(KEEPER);
        (bool ok,) = address(v).call(cd);
        uint256 navA = _oracleNav();
        if (ok) {
            assertGe(navA * 10_000, navB * (10_000 - lossBps), "rebalance succeeded: oracle NAV within the loss bound");
            (,,, bool has, bool oor) = v.bandState();
            assertTrue(has);
            assertFalse(oor);
        } else {
            assertEq(navA, navB, "rebalance reverted: nothing moved");
        }
    }

    // ------------------------------------------------------------------ guard arithmetic (differential: independent model of bits 1,2,4,8)
    function _model(int256 ans, uint256 age, uint256 maxAge, uint256 bandBps) internal pure returns (uint256 badBit, uint256 legBit) {
        // the two conditions are independent (spec section 4): a stale feed whose last answer is out of band sets BOTH the staleness and the leg bit
        if (ans <= 0) return (1, 0);
        badBit = age > maxAge ? 1 : 0;
        uint256 a = uint256(ans);
        uint256 diff = a > 1e8 ? a - 1e8 : 1e8 - a;
        legBit = diff * 10_000 > bandBps * 1e8 ? 1 : 0;
    }

    function testFuzz_guardBitsMatchTheModel(int256 ansC, int256 ansT, uint256 ageC, uint256 ageT) public {
        ansC = bound(ansC, -2e8, 2e8);
        ansT = bound(ansT, -2e8, 2e8);
        ageC = bound(ageC, 0, 200_000);
        ageT = bound(ageT, 0, 200_000);
        feedUsdc.setAnswerAt(ansC, block.timestamp - ageC);
        feedUsdt.setAnswerAt(ansT, block.timestamp - ageT);
        (uint256 bc, uint256 lc) = _model(ansC, ageC, 93_600, 50);
        (uint256 bt, uint256 lt) = _model(ansT, ageT, 93_600, 50);
        uint256 expected = bc | (bt << 1) | (lc << 2) | (lt << 3);
        (, , uint256 r) = v.guardState();
        assertEq(r & 15, expected, "feed bits 1,2,4,8 match the independent model");
    }

    function testFuzz_guardNeverRevertsAndLatchableMaskHolds(uint256 seed) public {
        if (seed % 2 == 0) feedUsdc.setRevertAll(true);
        if (seed % 3 == 0) feedUsdt.setRevertLatest(true);
        if (seed % 5 == 0) pair.forceActiveId(uint24(ID0 + (seed >> 8) % 300));
        if (seed % 7 == 0) pair.setHook(address(0));
        if (seed % 11 == 0) beacon.setImplementation(address(implB));
        (bool unsafe,, uint256 r) = v.guardState();
        assertEq(unsafe, r != 0);
        assertLt(r, 64, "only the six defined bits");
        v.rebalanceAllowed();
        v.bandState();
        vm.prank(ATTACKER);
        (bool ok,) = address(v).call(abi.encodeCall(IPharaohDlmmVault.tripGuard, ()));
        assertEq(ok, r & 15 != 0, "tripGuard succeeds iff a latchable bit holds");
        (, bool latched,) = v.guardState();
        assertEq(latched, ok);
    }

    // ------------------------------------------------------------------ setGuardParams accepts exactly the documented bounds
    function testFuzz_guardParamsBounds(uint16 leg, uint32 age, uint16 dev, uint32 cd, uint16 perDay, uint16 swapBps, uint16 loss) public {
        // squeeze about half of the draws into the valid ranges so both outcomes are exercised
        if (leg % 2 == 0) leg = uint16(10 + leg % 191);
        if (age % 2 == 0) age = uint32(3_600 + age % 169_201);
        if (dev % 2 == 0) dev = uint16(20 + dev % 281);
        if (cd % 2 == 0) cd = uint32(112 + cd % 3_489);
        if (perDay % 2 == 0) perDay = uint16(4 + perDay % 93);
        if (swapBps % 2 == 0) swapBps = uint16(1 + swapBps % 10_000);
        if (loss % 2 == 0) loss = uint16(5 + loss % 296);
        bool valid = leg >= 10 && leg <= 200 && age >= 3_600 && age <= 172_800 && dev >= 20 && dev <= 300 && cd >= 112 && cd <= 3_600 && perDay >= 4
            && perDay <= 96 && swapBps >= 1 && swapBps <= 10_000 && loss >= 5 && loss <= 300;
        IPharaohDlmmVault.GuardParams memory g = IPharaohDlmmVault.GuardParams(leg, age, dev, cd, perDay, swapBps, loss);
        vm.prank(SAFE);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeCall(IPharaohDlmmVault.setGuardParams, (g)));
        assertEq(ok, valid, "accepted iff every field is inside its bounds");
        if (!ok) assertEq(_sel(ret), IPharaohDlmmVault.ParamOutOfBounds.selector);
    }
}

contract FuzzFlippedTest is FuzzTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}
