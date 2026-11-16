// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./Base.t.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";

/// @notice Share accounting and rounding (ownership NAV, entry fairness), role gating, pause, harvest.
contract SharesTest is Base {
    function setUp() public virtual {
        _setUpVault();
    }

    function _sp() internal view returns (uint256 num, uint256 den) {
        // share price as a fraction NAV / supply, for cross-multiplied comparisons (no rounding in the comparison itself)
        return (erc.totalAssets(), shares.totalSupply());
    }

    function _geq(uint256 n1, uint256 d1, uint256 n2, uint256 d2) internal pure returns (bool) {
        // n1/d1 >= n2/d2 (d may be 0 = empty vault: treat as equal)
        if (d1 == 0 || d2 == 0) return true;
        return n1 * d2 >= n2 * d1;
    }

    /// share price may fall by at most `tolWei` of NAV: the NAV is valued by floor over pair bins (pro-rata of bin reserves), so a partial burn by another holder
    /// re-floors the remaining valuation by up to one wei per band bin and leg
    function _geqTol(uint256 n1, uint256 d1, uint256 n0, uint256 d0, uint256 tolWei) internal pure returns (bool) {
        if (d1 == 0 || d0 == 0) return true;
        return (n1 + tolWei) * d0 >= n0 * d1;
    }

    // ------------------------------------------------------------------ basic
    function test_firstDepositIsOneToOne() public {
        uint256 s = _deposit(ALICE, 100e6);
        assertEq(s, 100e6);
        assertEq(shares.balanceOf(ALICE), 100e6);
        assertApproxEqAbs(erc.convertToAssets(1e6), 1e6, 1);
        assertEq(usdc.balanceOf(address(v)), 100e6);
    }

    function test_previewMatchesActualAtEntry() public {
        _deposit(ALICE, 100e6);
        _openBand();
        uint256 p = erc.previewDeposit(37e6);
        uint256 s = _deposit(BOB, 37e6);
        assertEq(s, p, "previewDeposit == shares minted");
        uint256 pm = erc.previewMint(5e6);
        uint256 before = usdc.balanceOf(BOB);
        vm.prank(BOB);
        uint256 paid = erc.mint(5e6, BOB);
        assertEq(before - usdc.balanceOf(BOB), paid);
        assertEq(paid, pm);
    }

    function test_zeroAmountsRevert() public {
        vm.prank(ALICE);
        vm.expectRevert();
        erc.deposit(0, ALICE);
        _deposit(ALICE, 10e6);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.redeem(0, ALICE, ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.withdraw(0, ALICE, ALICE);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.mint(0, ALICE);
    }

    // ------------------------------------------------------------------ rounding is in the vault's favour
    function test_depositRoundsDownMintRoundsUp() public {
        _deposit(ALICE, 100e6);
        _openBand();
        // make the share price non-trivial: bin income
        usdc.mint(address(pair), 777_777);
        if (usdcIsX) pair.addToBin(pair.getActiveId(), 777_777, 0);
        else pair.addToBin(pair.getActiveId(), 0, 777_777);
        for (uint256 i = 1; i <= 25; ++i) {
            uint256 assets = i * 1_000_003;
            uint256 s = erc.previewDeposit(assets);
            assertLe(erc.convertToAssets(s), assets, "shares for a deposit are worth at most the assets paid");
            uint256 mintShares = i * 999_983;
            uint256 a = erc.previewMint(mintShares);
            assertGe(a, erc.convertToAssets(mintShares), "mint charges at least the value of the shares");
        }
    }

    function test_sharePriceNeverDecreasesOnDepositAndRedeem() public {
        _deposit(ALICE, 100e6);
        _openBand();
        usdc.mint(address(pair), 1_234_567);
        if (usdcIsX) pair.addToBin(pair.getActiveId(), 1_234_567, 0);
        else pair.addToBin(pair.getActiveId(), 0, 1_234_567);
        uint256[7] memory amts = [uint256(1), 3, 999_999, 7_000_001, 13e6, 21_333_333, 40e6];
        for (uint256 i; i < amts.length; ++i) {
            (uint256 n0, uint256 d0) = _sp();
            _deposit(BOB, amts[i]);
            (uint256 n1, uint256 d1) = _sp();
            assertTrue(_geq(n1, d1, n0, d0), "deposit: share price did not fall");
        }
        for (uint256 i; i < 4; ++i) {
            (uint256 n0, uint256 d0) = _sp();
            uint256 s = shares.balanceOf(BOB) / 3;
            vm.prank(BOB);
            erc.redeem(s, BOB, BOB);
            (uint256 n1, uint256 d1) = _sp();
            emit log_named_uint("redeem step: NAV before", n0);
            emit log_named_uint("             supply before", d0);
            emit log_named_uint("             NAV after", n1);
            emit log_named_uint("             supply after", d1);
            assertTrue(_geqTol(n1, d1, n0, d0, 4), "redeem: share price fell by more than 4 wei of NAV (the redeemer bears the swap cost)");
        }
    }

    function test_withdrawBurnsCeilShares() public {
        _deposit(ALICE, 100e6);
        _openBand();
        uint256 want = 10e6 + 7;
        uint256 expectShares = erc.previewWithdraw(want);
        assertGe(erc.convertToAssets(expectShares), want - 1, "ceil: the burned shares cover the assets");
        (uint256 n0, uint256 d0) = _sp();
        vm.prank(ALICE);
        uint256 burned = erc.withdraw(want, ALICE, ALICE);
        assertEq(burned, expectShares);
        (uint256 n1, uint256 d1) = _sp();
        assertTrue(_geq(n1, d1, n0, d0));
    }

    // ------------------------------------------------------------------ entry fairness: late depositors do not buy past income, early ones keep it
    function test_binIncomeBelongsToExistingHolders() public {
        _deposit(ALICE, 100e6);
        _openBand();
        uint256 aliceBefore = erc.convertToAssets(shares.balanceOf(ALICE));
        usdc.mint(address(pair), 5e6);
        // the vault holds a minority of the active bin; make the income visible with a fee in every band bin
        for (uint24 id = pair.getActiveId() - 1; id <= pair.getActiveId() + 1; ++id) {
            if (id == pair.getActiveId() - 1) {
                if (usdcIsX) pair.addToBin(id, 0, 0);
            }
        }
        // credit through the active bin only
        uint24 a = pair.getActiveId();
        usdc.mint(address(pair), 20_000e6);
        if (usdcIsX) pair.addToBin(a, 20_000e6, 0);
        else pair.addToBin(a, 0, 20_000e6);
        uint256 aliceAfter = erc.convertToAssets(shares.balanceOf(ALICE));
        assertGt(aliceAfter, aliceBefore, "income raised Alice's value");
        uint256 s = _deposit(BOB, 50e6);
        assertLe(erc.convertToAssets(s), 50e6, "Bob gets no part of income earned before he joined");
        assertGe(erc.convertToAssets(s) + 2, 50e6 - 5, "and loses at most rounding");
        assertGe(erc.convertToAssets(shares.balanceOf(ALICE)), aliceAfter - 1, "Alice keeps it");
    }

    function test_firstDepositorInflationAttackIsRefused() public {
        // attacker: 1 wei deposit then a donation up to the cap; victim deposits next. The 1-wei seed is now refused outright (minimum supply 1e6).
        bytes memory ret = _assertReverts(ATTACKER, address(v), abi.encodeWithSignature("deposit(uint256,address)", 1, ATTACKER));
        assertEq(_sel(ret), MIN_SUPPLY_SEL);
        ret = _assertReverts(ATTACKER, address(v), abi.encodeWithSignature("deposit(uint256,address)", 4, ATTACKER));
        assertEq(_sel(ret), MIN_SUPPLY_SEL);
        ret = _assertReverts(ATTACKER, address(v), abi.encodeWithSignature("mint(uint256,address)", 4, ATTACKER));
        assertEq(_sel(ret), MIN_SUPPLY_SEL);
        // boundary: 999,999 refused, 1,000,000 accepted
        ret = _assertReverts(ATTACKER, address(v), abi.encodeWithSignature("deposit(uint256,address)", 999_999, ATTACKER));
        assertEq(_sel(ret), MIN_SUPPLY_SEL);
        assertEq(abi.decode(_tail(ret), (uint256)), 999_999);
        vm.prank(ATTACKER);
        erc.deposit(1e6, ATTACKER);
        assertEq(shares.totalSupply(), 1e6);
    }

    function _tail(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = ret[i + 4];
    }

    /// W10 F1 scenario, all routes: the attacker gets 4 share-wei through the only door that stays open (an EXIT down to 4 wei), donates, and the victim enters.
    function test_w10F1_attackerFourWeiSharesPlusDonation() public {
        vm.prank(ATTACKER);
        erc.deposit(5e6, ATTACKER);
        uint256 s = shares.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        erc.redeem(s - 4, ATTACKER, ATTACKER);
        assertEq(shares.totalSupply(), 4);
        usdc.mint(ATTACKER, 150e6);
        vm.prank(ATTACKER);
        usdc.transfer(address(v), 150e6); // the donation
        uint256[5] memory victimDeposits = [uint256(1), 1e3, 1e6, 20e6, 49e6]; // 49e6 is the whole remaining headroom
        for (uint256 i; i < victimDeposits.length; ++i) {
            uint256 snap = vm.snapshotState();
            usdc.mint(CAROL, victimDeposits[i]);
            uint256 before = usdc.balanceOf(CAROL);
            vm.prank(CAROL);
            (bool ok, bytes memory ret) = address(v).call(abi.encodeWithSignature("deposit(uint256,address)", victimDeposits[i], CAROL));
            if (!ok) {
                bytes4 sl = _sel(ret);
                assertTrue(sl == MIN_SUPPLY_SEL || sl == bytes4(keccak256("ZeroShares()")) || sl == bytes4(keccak256("CapExceeded(uint256,uint256)")), "refused by the vault");
                assertEq(usdc.balanceOf(CAROL), before, "nothing taken from the victim");
            } else {
                // if it ever passes, the victim must be whole to within rounding
                uint256 val = erc.convertToAssets(shares.balanceOf(CAROL));
                assertLe(victimDeposits[i] > val ? victimDeposits[i] - val : 0, 1000, "victim loss at most ~1000 wei");
            }
            vm.revertToState(snap);
        }
    }

    /// the seed the ceremony uses: supply of exactly 1e6 share-wei held by the seeder; a donation to the cap; the victim's rounding loss is at most ~1000 wei
    function test_w10F1_seedOf1e6SharesCostsTheVictimAtMost1000Wei() public {
        vm.prank(ATTACKER);
        erc.deposit(1e6, ATTACKER); // 1e6 shares
        usdc.mint(address(v), 150e6); // donation to near the cap
        for (uint256 k; k < 3; ++k) {
            uint256 snap = vm.snapshotState();
            uint256 amt = k == 0 ? 7_777_777 : k == 1 ? 40e6 : 48e6;
            usdc.mint(CAROL, amt);
            uint256 before = usdc.balanceOf(CAROL);
            vm.prank(CAROL);
            uint256 got = erc.deposit(amt, CAROL);
            uint256 val = erc.convertToAssets(got);
            uint256 paid = before - usdc.balanceOf(CAROL);
            assertEq(paid, amt);
            assertLe(paid > val ? paid - val : 0, 1000, "victim's loss at most ~1000 wei");
            vm.revertToState(snap);
        }
    }

    /// every exit path with the supply BELOW 1e6 (the minimum applies to entries only): in-kind, redeem, withdraw, partial and full, with a band and idle value
    function _dustSupplyFixture() internal returns (uint256 left) {
        _deposit(ALICE, 80e6);
        _openBand();
        _deposit(BOB, 20e6); // idle on top of the band
        uint256 bobS = shares.balanceOf(BOB);
        vm.prank(BOB);
        v.redeemInKind(bobS, BOB, BOB);
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        v.redeemInKind(s - 400_000, ALICE, ALICE); // ALICE keeps 400,000 share-wei (supply 0.4 USDC of shares)
        left = shares.totalSupply();
        assertEq(left, 400_000);
        assertLt(left, 1e6);
    }

    function test_exitsWorkWithSupplyBelowMinimum_inKind() public {
        _dustSupplyFixture();
        uint256 sh = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 a, uint256 b) = v.redeemInKind(sh / 2, ALICE, ALICE);
        assertGt(a + b, 0);
        sh = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        (a, b) = v.redeemInKind(sh, ALICE, ALICE);
        assertGt(a + b, 0);
        assertEq(shares.totalSupply(), 0);
    }

    function test_exitsWorkWithSupplyBelowMinimum_redeemAndWithdraw() public {
        _dustSupplyFixture();
        uint256 nav = erc.totalAssets();
        vm.prank(ALICE);
        uint256 w = erc.withdraw(nav / 4, ALICE, ALICE);
        assertGt(w, 0);
        uint256 half = shares.balanceOf(ALICE) / 2;
        vm.prank(ALICE);
        uint256 out = erc.redeem(half, ALICE, ALICE);
        assertGt(out, 0);
        uint256 rest = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        out = erc.redeem(rest, ALICE, ALICE);
        assertGt(out, 0);
        assertEq(shares.totalSupply(), 0);
    }

    function test_exitsWorkWithSupplyBelowMinimum_underEveryAdverseCondition() public {
        _dustSupplyFixture();
        vm.prank(SAFE);
        adm.pause();
        feedUsdc.setRevertAll(true);
        feedUsdt.setRevertAll(true);
        uint256 sh = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 a, uint256 b) = v.redeemInKind(sh, ALICE, ALICE);
        assertGt(a + b, 0);
    }

    function test_entryRefusedWhileSupplyIsBelowMinimum_butAllowedWhenItLandsAboveIt() public {
        _dustSupplyFixture();
        // an entry that leaves the supply still below 1e6 is refused; one that lifts it to >= 1e6 is accepted
        bytes memory ret = _assertReverts(BOB, address(v), abi.encodeWithSignature("deposit(uint256,address)", 100_000, BOB));
        assertEq(_sel(ret), MIN_SUPPLY_SEL);
        vm.prank(BOB);
        erc.deposit(5e6, BOB);
        assertGe(shares.totalSupply(), 1e6);
    }

    // ------------------------------------------------------------------ balance-delta payout of redeem / withdraw (3726773c)
    function test_redeemAndWithdrawPayExactlyTheReceiverBalanceDelta() public {
        _deposit(ALICE, 100e6);
        _openBand();
        uint256 s = shares.balanceOf(ALICE);
        uint256 before = usdc.balanceOf(CAROL);
        vm.prank(ALICE);
        uint256 out = erc.redeem(s / 2, CAROL, ALICE);
        assertEq(usdc.balanceOf(CAROL) - before, out, "redeem returns exactly what the receiver gained");
        before = usdc.balanceOf(CAROL);
        uint256 burnedBefore = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        erc.withdraw(10e6, CAROL, ALICE);
        assertGe(usdc.balanceOf(CAROL) - before, 10e6 * 99 / 100, "withdraw pays what the slice realised (about the requested amount)");
        assertLt(shares.balanceOf(ALICE), burnedBefore);
        // a stray USDC balance already in the vault is not paid to the redeemer
        usdc.mint(address(v), 7e6);
        before = usdc.balanceOf(ALICE);
        uint256 rest = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        out = erc.redeem(rest / 2, ALICE, ALICE);
        assertEq(usdc.balanceOf(ALICE) - before, out);
    }

    // ------------------------------------------------------------------ PharHarvested amount ignores donated PHAR (3726773c)
    bytes32 internal constant SIG_HARVEST = keccak256("PharHarvested(address,uint256,uint256,uint256)");

    function _harvestAmountFromLogs() internal returns (uint256 amount, uint256 count) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(v) && logs[i].topics[0] == SIG_HARVEST) {
                (amount,,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                count++;
            }
        }
    }

    function test_pharHarvestedAmountIgnoresDonatedPhar() public {
        _deposit(ALICE, 100e6);
        _openBand();
        phar.mint(address(rewarder), 10e18);
        rewarder.setPending(address(v), 4e18);
        phar.mint(address(v), 50e18); // a donation of PHAR straight to the vault
        vm.recordLogs();
        vm.prank(KEEPER);
        v.harvestRewards();
        (uint256 amount, uint256 n) = _harvestAmountFromLogs();
        assertEq(n, 1);
        assertEq(amount, 4e18, "the event reports the PHAR claimed in this call only");
        assertEq(phar.balanceOf(SAFE), 54e18, "the whole PHAR balance is still forwarded to the owner");
        assertEq(phar.balanceOf(address(v)), 0);
        // nothing pending: the event says zero even with a donation present
        phar.mint(address(v), 9e18);
        vm.recordLogs();
        vm.prank(SAFE);
        v.harvestRewards();
        (amount, n) = _harvestAmountFromLogs();
        assertEq(n, 1);
        assertEq(amount, 0);
        assertEq(phar.balanceOf(SAFE), 63e18);
    }

    // ------------------------------------------------------------------ renounceOwnership is disabled (3726773c)
    function test_renounceOwnershipDisabled() public {
        vm.prank(SAFE);
        vm.expectRevert(bytes4(keccak256("RenounceDisabled()")));
        IOwnableMin(address(v)).renounceOwnership();
        assertEq(adm.owner(), SAFE);
        // a non-owner still gets the Ownable error, not a state change
        vm.prank(ATTACKER);
        vm.expectRevert();
        IOwnableMin(address(v)).renounceOwnership();
        assertEq(adm.owner(), SAFE);
        // the owner can still pause, set params, rotate the keeper afterwards
        vm.prank(SAFE);
        adm.pause();
        // ownership transfer remains available (two-step handling is a ceremony matter)
        vm.prank(SAFE);
        IOwnableMin(address(v)).transferOwnership(BOB);
        assertEq(adm.owner(), BOB);
    }


    bytes4 internal constant MIN_SUPPLY_SEL = bytes4(keccak256("SupplyBelowMinimum(uint256)"));

    /// W4 finding 4 (dust supply with donated value) is now REFUSED by the vault (commit 3726773c, W10 F1): an entry may not leave the supply in (0, 1e6).
    /// Same scenario as before (Alice keeps ONE share-wei, a donation, then Bob enters): Bob's deposit must revert SupplyBelowMinimum and nothing moves.
    function test_dustSupplyEntryDilution_nowRefused() public {
        _deposit(ALICE, 100e6);
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(ALICE);
        erc.redeem(s - 1, ALICE, ALICE); // exits are never subject to the minimum: Alice keeps ONE share-wei
        assertEq(shares.totalSupply(), 1);
        usdc.mint(address(v), 50e6); // a donation
        uint256 aliceBefore = erc.convertToAssets(shares.balanceOf(ALICE));
        uint256 navBefore = erc.totalAssets();
        uint256 bobUsdc = usdc.balanceOf(BOB);
        bytes memory ret = _assertReverts(BOB, address(v), abi.encodeWithSignature("deposit(uint256,address)", 100e6, BOB));
        assertEq(_sel(ret), MIN_SUPPLY_SEL, "the entry that would leave a tiny supply is refused");
        assertEq(erc.convertToAssets(shares.balanceOf(ALICE)), aliceBefore, "the dust holder is untouched");
        assertEq(erc.totalAssets(), navBefore);
        assertEq(usdc.balanceOf(BOB), bobUsdc);
        assertEq(shares.balanceOf(BOB), 0);
    }

    /// ACTUAL (finding, low): the swap leg of redeem trades against the pool's active bin, which may hold part of the vault's own band at a bin price off the oracle;
    /// the remaining holders then bear (bin price - oracle) x swap x vault share of the bin. Measured here with the vault's band inside the active bin.
    function test_redeemSwapAgainstOwnBinsLeakIsTiny() public {
        _deposit(ALICE, 100e6);
        _deposit(BOB, 100e6);
        _openBand();
        (uint256 n0, uint256 d0) = _sp();
        uint256 bobShares = shares.balanceOf(BOB);
        vm.prank(BOB);
        erc.redeem(bobShares, BOB, BOB);
        (uint256 n1, uint256 d1) = _sp();
        // remaining holder's value per share, parts per million
        uint256 loss = n0 * d1 > n1 * d0 ? ((n0 * d1 - n1 * d0) * 1e6) / (n0 * d1) : 0;
        emit log_named_uint("remaining holders' share price loss from the other holder's redeem (ppm)", loss);
        assertLe(loss, 100, "bounded by 1 bp of the swapped amount (here at most 100 ppm)");
    }

    // ------------------------------------------------------------------ ERC-4626 plumbing
    function test_redeemOnBehalfNeedsAllowance() public {
        _deposit(ALICE, 100e6);
        uint256 s = shares.balanceOf(ALICE);
        vm.prank(BOB);
        vm.expectRevert();
        erc.redeem(s, BOB, ALICE);
        vm.prank(ALICE);
        shares.approve(BOB, s);
        vm.prank(BOB);
        uint256 out = erc.redeem(s, BOB, ALICE);
        assertApproxEqAbs(out, 100e6, 2);
        assertEq(usdc.balanceOf(BOB), 10_000e6 + out);
    }

    function test_depositForAnotherReceiver() public {
        vm.prank(ALICE);
        erc.deposit(10e6, BOB);
        assertEq(shares.balanceOf(BOB), 10e6);
        assertEq(shares.balanceOf(ALICE), 0);
    }

    function test_maxWithdrawMaxRedeemConsistent() public {
        _deposit(ALICE, 100e6);
        _openBand();
        uint256 mr = erc.maxRedeem(ALICE);
        assertEq(mr, shares.balanceOf(ALICE));
        uint256 mw = erc.maxWithdraw(ALICE);
        assertLe(mw, erc.convertToAssets(mr));
        vm.prank(ALICE);
        vm.expectRevert();
        erc.withdraw(mw + 1e6, ALICE, ALICE);
    }

    function test_sharesAreTransferable() public {
        _deposit(ALICE, 10e6);
        vm.prank(ALICE);
        shares.transfer(BOB, 4e6);
        assertEq(shares.balanceOf(BOB), 4e6);
    }

    function test_redeemWithBandPaysAboutTheNav() public {
        _deposit(ALICE, 100e6);
        _openBand();
        uint256 nav = erc.totalAssets();
        uint256 all = shares.balanceOf(ALICE);
        uint256 prev = erc.previewRedeem(all);
        vm.prank(ALICE);
        uint256 out = erc.redeem(all, ALICE, ALICE);
        assertLe(out, prev + 1, "pays at most the preview");
        assertGe(out * 10_000, nav * 9_950, "within 0.5 % of the NAV");
        assertEq(shares.totalSupply(), 0);
    }

    // ------------------------------------------------------------------ roles
    function test_pauseUnpauseOwnerOnly() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, ATTACKER));
        adm.pause();
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, KEEPER));
        adm.pause();
        vm.prank(SAFE);
        adm.pause();
        assertTrue(adm.paused());
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, KEEPER));
        adm.unpause();
        vm.prank(SAFE);
        adm.unpause();
        assertFalse(adm.paused());
    }

    function test_pauseBlocksEntriesNotExits() public {
        _deposit(ALICE, 100e6);
        _openBand();
        _deposit(BOB, 20e6);
        vm.prank(SAFE);
        adm.pause();
        assertEq(erc.maxDeposit(BOB), 0);
        assertEq(erc.maxMint(BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(ENFORCED_PAUSE);
        erc.deposit(1e6, BOB);
        vm.prank(BOB);
        vm.expectRevert(ENFORCED_PAUSE);
        erc.mint(1e6, BOB);
        _assertRevertsWith(KEEPER, address(v), _openBandArgs(), ENFORCED_PAUSE);
        // exits work
        vm.prank(BOB);
        erc.withdraw(5e6, BOB, BOB);
        uint256 bobHalf = shares.balanceOf(BOB) / 2;
        vm.prank(BOB);
        erc.redeem(bobHalf, BOB, BOB);
        _inKind(ALICE, shares.balanceOf(ALICE) / 2);
    }

    function test_setRebalancer() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, ATTACKER));
        v.setRebalancer(ATTACKER);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, KEEPER));
        v.setRebalancer(KEEPER);
        address k2 = address(0x4B33FE3);
        vm.prank(SAFE);
        v.setRebalancer(k2);
        assertEq(adm.rebalancer(), k2);
        _deposit(ALICE, 50e6);
        // the old keeper lost its rights, the new one has them
        _assertReverts(KEEPER, address(v), _openBandArgs());
        uint24 a = pair.getActiveId();
        vm.prank(k2);
        v.openBand(a, 1, 0, 0, 0, block.timestamp + 120);
        assertTrue(_hasBand());
        vm.prank(SAFE);
        (bool ok,) = address(v).call(abi.encodeCall(IPharaohDlmmVault.setRebalancer, (address(0))));
        emit log_named_string("ACTUAL setRebalancer(address(0))", ok ? "accepted" : "reverts");
    }

    function test_onlyTheKeeperCanOpenAndRebalance() public {
        _deposit(ALICE, 50e6);
        _assertReverts(SAFE, address(v), _openBandArgs()); // even the owner (W2 decision 1: not R3's owner-or-keeper)
        _assertReverts(ALICE, address(v), _openBandArgs());
        _openBand();
    }

    function test_harvestRewards() public {
        _deposit(ALICE, 100e6);
        _openBand();
        phar.mint(address(rewarder), 10e18);
        rewarder.setPending(address(v), 4e18);
        uint256 supply = shares.totalSupply();
        uint256 navBefore = erc.totalAssets();
        // permissions: keeper or owner only
        _assertReverts(ATTACKER, address(v), abi.encodeCall(IPharaohDlmmVault.harvestRewards, ()));
        vm.recordLogs();
        vm.prank(KEEPER);
        v.harvestRewards();
        assertEq(phar.balanceOf(SAFE), 4e18, "PHAR goes to the owner");
        assertEq(phar.balanceOf(address(v)), 0);
        assertEq(erc.totalAssets(), navBefore, "the share price does not include pending or harvested PHAR");
        assertEq(shares.totalSupply(), supply);
    }

    function test_harvestWorksWithDeadFeedsPausedAndLatched() public {
        _deposit(ALICE, 100e6);
        _openBand();
        phar.mint(address(rewarder), 10e18);
        rewarder.setPending(address(v), 4e18);
        feedUsdc.setRevertAll(true);
        feedUsdt.setRevertAll(true);
        vm.prank(SAFE);
        adm.pause();
        vm.prank(SAFE);
        v.harvestRewards();
        assertEq(phar.balanceOf(SAFE), 4e18, "a harvest does not depend on the feeds or on pause");
    }

    function test_harvestUnlinkedRewarderReverts() public {
        _deposit(ALICE, 100e6);
        _openBand();
        pair.setHook(address(0));
        vm.prank(KEEPER);
        vm.expectRevert(bytes("unlinked"));
        v.harvestRewards();
    }

    function test_donationsOfOtherTokensDoNotChangeNav() public {
        _deposit(ALICE, 100e6);
        uint256 n = erc.totalAssets();
        phar.mint(address(v), 1000e18);
        assertEq(erc.totalAssets(), n, "PHAR is not part of the NAV");
    }
}

interface IOwnableMin {
    function renounceOwnership() external;
    function transferOwnership(address) external;
}

contract SharesFlippedTest is SharesTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}
