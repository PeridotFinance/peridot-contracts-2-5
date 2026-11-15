// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Base, IVaultAdmin} from "./Base.t.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

/// @notice Spec section 2: cap 200 USDC set inside initialize, ceiling 200 as an implementation immutable, enforced in deposit / mint / maxDeposit / maxMint / openBand.
contract CapTest is Base {
    function setUp() public virtual {
        _setUpVault();
    }

    function _tryInit(IPharaohDlmmVault.InitParams memory p) internal returns (bool ok) {
        bytes memory code = _findCode();
        address i = _deployImpl(code);
        try new TransparentUpgradeableProxy(i, SAFE, abi.encodeCall(IVaultAdmin.initialize, (p))) returns (TransparentUpgradeableProxy) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    // ------------------------------------------------------------------ init read-backs
    function test_initReadBacks() public view {
        assertEq(v.depositCap(), 200_000_000, "cap set in initialize");
        assertEq(v.DEPOSIT_CAP_CEILING(), 200_000_000, "ceiling");
        assertLe(erc.maxDeposit(ALICE), v.depositCap());
        assertEq(adm.owner(), SAFE);
        assertEq(adm.rebalancer(), KEEPER);
        assertEq(erc.asset(), address(usdc));
        assertFalse(adm.paused());
        assertEq(erc.totalAssets(), 0);
        IPharaohDlmmVault.GuardParams memory g = v.guardParams();
        assertEq(g.legBandBps, 50);
        assertEq(g.maxFeedAge, 93_600);
        assertEq(g.maxPoolOracleDevBps, 60);
        assertEq(g.rebalanceCooldown, 120);
        assertEq(g.maxRebalancesPerDay, 48);
        assertEq(g.maxSwapBps, 6000);
        assertEq(g.maxRebalanceLossBps, 50);
        (bool unsafe, bool latched, uint256 reasons) = v.guardState();
        assertFalse(unsafe);
        assertFalse(latched);
        assertEq(reasons, 0);
        (,,, bool has,) = v.bandState();
        assertFalse(has);
        assertEq(v.rebalancesToday(), 0);
    }

    function test_cannotInitializeTwiceNorTheImplementation() public {
        vm.expectRevert();
        adm.initialize(_initParams());
        vm.expectRevert();
        IVaultAdmin(impl).initialize(_initParams());
    }

    function test_initCapAboveCeilingReverts() public {
        initCap = CAP + 1;
        assertFalse(_tryInit(_initParams()), "init with cap 201 must revert");
    }

    function test_initZeroCapIsNeverUnlimited() public {
        initCap = 0;
        IPharaohDlmmVault.InitParams memory p = _initParams();
        bytes memory code = _findCode();
        address i = _deployImpl(code);
        try new TransparentUpgradeableProxy(i, SAFE, abi.encodeCall(IVaultAdmin.initialize, (p))) returns (TransparentUpgradeableProxy px) {
            // init accepted a zero cap: it must not mean "unlimited" (the R3 meaning), otherwise there is a window with no cap
            IPharaohDlmmVault z = IPharaohDlmmVault(address(px));
            assertEq(z.depositCap(), 0);
            assertEq(IVaultAdminERC(address(px)).maxDeposit(ALICE), 0, "zero cap must not be unlimited");
        } catch {}
    }

    function test_initValidationFailures() public {
        // each broken fixture must make initialize revert (the frozen interface names PairValidationFailed(check))
        factory.setPair(pair.tokenX(), pair.tokenY(), BIN_STEP, address(0));
        assertFalse(_tryInit(_initParams()), "pair not in factory");
        factory.setPair(pair.tokenX(), pair.tokenY(), BIN_STEP, address(pair));
        assertTrue(_tryInit(_initParams()), "control: healthy world initialises");

        voter.setManager(address(router), false);
        assertFalse(_tryInit(_initParams()), "router not an authorised manager");
        voter.setManager(address(router), true);

        pair.setHook(address(0));
        assertFalse(_tryInit(_initParams()), "rewarder not the pair hook");
        pair.setHook(address(rewarder));

        beacon.setImplementation(address(implB));
        assertFalse(_tryInit(_initParams()), "rewarder implementation codehash differs from the pin");
        beacon.setImplementation(address(implA));

        feedUsdc.setDecimals(6);
        assertFalse(_tryInit(_initParams()), "feed with 6 decimals");
        feedUsdc.setDecimals(8);
        assertTrue(_tryInit(_initParams()), "control again");
    }

    // ------------------------------------------------------------------ setDepositCap
    function test_setDepositCapBounds() public {
        vm.prank(SAFE);
        v.setDepositCap(100e6);
        assertEq(v.depositCap(), 100e6);
        assertLe(erc.maxDeposit(ALICE), 100e6);
        vm.prank(SAFE);
        vm.expectEmit(address(v));
        emit IPharaohDlmmVault.DepositCapSet(100e6, 200e6);
        v.setDepositCap(200e6);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapAboveCeiling.selector, 200e6 + 1, 200e6));
        v.setDepositCap(200e6 + 1);
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.CapAboveCeiling.selector, type(uint256).max, 200e6));
        v.setDepositCap(type(uint256).max);
        // only the owner
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, ATTACKER));
        v.setDepositCap(1);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(OWNABLE_UNAUTH, KEEPER));
        v.setDepositCap(1);
    }

    // ------------------------------------------------------------------ deposit
    function test_depositUpToCapExactly() public {
        _deposit(ALICE, 200e6);
        assertLe(erc.totalAssets(), CAP);
        assertGe(erc.totalAssets(), CAP - 1);
        assertEq(erc.maxDeposit(ALICE), 0);
        vm.prank(BOB);
        vm.expectRevert();
        erc.deposit(1, BOB);
    }

    function test_depositOverCapReverts() public {
        _assertCapRevert(201e6);
        _assertCapRevert(200e6 + 1);
        _deposit(ALICE, 150e6);
        _assertCapRevert(51e6);
        _deposit(BOB, 50e6 - 2); // headroom edge still works (within rounding)
    }

    function _assertCapRevert(uint256 amt) internal {
        bytes memory ret = _assertReverts(BOB, address(v), abi.encodeCall(IERC4626Min.deposit, (amt, BOB)));
        assertEq(_sel(ret), IPharaohDlmmVault.CapExceeded.selector, "deposit above the cap must revert CapExceeded");
        // arguments: (cap, totalAssetsAfter)
        (uint256 c, uint256 after_) = abi.decode(_tail(ret), (uint256, uint256));
        assertEq(c, 200e6);
        assertGt(after_, 200e6);
    }

    function _tail(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i; i < out.length; ++i) out[i] = ret[i + 4];
    }

    function test_maxDepositTracksHeadroom() public {
        assertEq(erc.maxDeposit(ALICE), 200e6);
        _deposit(ALICE, 60e6);
        uint256 ta = erc.totalAssets();
        assertEq(erc.maxDeposit(BOB), 200e6 - ta);
        // a direct donation can only reduce the headroom
        usdc.mint(address(v), 30e6);
        assertEq(erc.maxDeposit(BOB), 200e6 - erc.totalAssets());
        assertLe(erc.maxDeposit(BOB), 110e6);
        // donation beyond the cap: zero headroom and every deposit fails
        usdc.mint(address(v), 200e6);
        assertEq(erc.maxDeposit(BOB), 0);
        vm.prank(BOB);
        vm.expectRevert();
        erc.deposit(1e6, BOB);
    }

    // ------------------------------------------------------------------ mint
    function test_mintCapEnforcedAndMaxMintBounded() public {
        uint256 mm = erc.maxMint(ALICE);
        // maxMint can never promise more than the headroom allows
        assertLe(erc.previewMint(mm), 200e6 + 1, "maxMint must respect the cap");
        // a mint worth more than the cap must revert, whatever the reason
        uint256 big = erc.convertToShares(201e6);
        vm.prank(ALICE);
        vm.expectRevert();
        erc.mint(big, ALICE);
        if (mm == 0) {
            emit log("ACTUAL: maxMint == 0 (mint disabled, as in R3)");
            return;
        }
        // within the cap it works
        uint256 s = erc.convertToShares(10e6);
        vm.prank(ALICE);
        erc.mint(s, ALICE);
        assertLe(erc.totalAssets(), 200e6);
        // and a mint that would cross the cap reverts CapExceeded or ExceededMaxMint
        uint256 over = erc.convertToShares(195e6);
        bytes memory ret = _assertReverts(ALICE, address(v), abi.encodeCall(IERC4626Min.mint, (over, ALICE)));
        emit log_named_bytes32("ACTUAL mint-over-cap selector", bytes32(_sel(ret)));
    }

    // ------------------------------------------------------------------ openBand funding path
    function test_openBandOverCapReverts() public {
        _deposit(ALICE, 100e6);
        usdc.mint(address(v), 101e6); // donation: totalAssets 201 > cap
        assertGt(erc.totalAssets(), 200e6);
        bytes memory ret = _assertReverts(KEEPER, address(v), _openBandArgs());
        assertEq(_sel(ret), IPharaohDlmmVault.CapExceeded.selector, "openBand funding path is cap-bound");
    }

    function test_openBandAtCapWorks() public {
        _deposit(ALICE, 200e6);
        _openBand();
        assertTrue(_hasBand());
        assertLe(erc.totalAssets(), 200e6 + 1e5, "NAV after opening stays about 200 (entry fee/rounding only)");
    }
}

interface IERC4626Min {
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function mint(uint256 shares, address receiver) external returns (uint256);
}

interface IVaultAdminERC {
    function maxDeposit(address) external view returns (uint256);
}

contract CapFlippedTest is CapTest {
    function _flipped() internal pure override returns (bool) {
        return true;
    }
}
