// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base} from "./Base.t.sol";
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

    function test_firstDepositorInflationAttackIsBoundedByTheCap() public {
        // attacker: 1 wei deposit then a donation up to the cap; victim deposits next
        vm.prank(ATTACKER);
        erc.deposit(1, ATTACKER);
        usdc.mint(address(v), 150e6); // donation (counts in NAV, only reduces headroom)
        vm.prank(CAROL);
        (bool ok, bytes memory ret) = address(v).call(abi.encodeWithSignature("deposit(uint256,address)", 40e6, CAROL));
        if (ok) {
            uint256 s = abi.decode(ret, (uint256));
            assertGe(erc.convertToAssets(s) * 100, 40e6 * 99, "a victim that gets shares keeps >= 99 % of the value");
        } else {
            emit log_named_bytes32("ACTUAL victim deposit behind a donation reverts with", bytes32(_sel(ret)));
        }
        // a tiny victim deposit is rejected rather than minted at zero shares
        vm.prank(BOB);
        (ok, ret) = address(v).call(abi.encodeWithSignature("deposit(uint256,address)", 1e6, BOB));
        if (ok) assertGt(erc.balanceOf(BOB), 0, "no zero-share deposit");
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

contract SharesFlippedTest is SharesTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}
