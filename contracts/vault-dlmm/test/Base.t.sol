// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IPharaohDlmmVault} from "../src/IPharaohDlmmVault.sol";
import {World} from "./World.sol";

/// @dev surface the interface leaves to R3 (pause, owner, rebalancer, initialize)
interface IVaultAdmin {
    function initialize(IPharaohDlmmVault.InitParams calldata p) external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    function owner() external view returns (address);
    function rebalancer() external view returns (address);
    function asset() external view returns (address);
}

/// @notice THE ONE PLACE to adapt to the real vault: artifact names, constructor arguments, the init-params builder and the band / rebalance helpers.
///         Everything else in the suites talks to `IPharaohDlmmVault`, `IERC4626` and `IVaultAdmin`. The vault contract is NOT imported: it is deployed from its compiled
///         artifact, so the suites compile with or without the vault source in the tree; with no artifact every test is skipped (vm.skip), never silently passed.
abstract contract Base is World {
    uint256 internal constant CAP = 200_000_000;
    uint256 internal constant U = 1e6;

    // ---- adaptation point 1: artifact names tried in order
    function _artifactNames() internal pure virtual returns (string[4] memory n) {
        n[0] = "PharaohDlmmVault.sol:PharaohDlmmVault";
        n[1] = "PharaohLiquidityVaultDlmm.sol:PharaohLiquidityVaultDlmm";
        n[2] = "PharaohDlmmVaultV1.sol:PharaohDlmmVaultV1";
        n[3] = "DlmmVault.sol:DlmmVault";
    }

    IPharaohDlmmVault internal v;
    IERC4626 internal erc;
    IVaultAdmin internal adm;
    IERC20 internal shares;
    address internal impl;
    address internal proxyAdmin;
    uint256 internal initCap = CAP;
    bytes32 internal rewarderCodehash;
    bool internal startedPaused;

    // ------------------------------------------------------------------ errors from other libraries
    bytes4 internal constant ENFORCED_PAUSE = bytes4(keccak256("EnforcedPause()"));
    bytes4 internal constant OWNABLE_UNAUTH = bytes4(keccak256("OwnableUnauthorizedAccount(address)"));

    function _code(string calldata name) external view returns (bytes memory) {
        return vm.getCode(name);
    }

    /// returns the creation code of the vault or empty
    function _findCode() internal view returns (bytes memory code) {
        string[4] memory names = _artifactNames();
        for (uint256 i; i < names.length; ++i) {
            try this._code(names[i]) returns (bytes memory c) {
                if (c.length != 0) return c;
            } catch {}
        }
    }

    // ---- adaptation point 2: constructor-arg attempts (the ceiling is an implementation immutable; try with it, then without)
    function _deployImpl(bytes memory code) internal virtual returns (address a) {
        bytes memory withCeiling = abi.encodePacked(code, abi.encode(CAP));
        assembly {
            a := create(0, add(withCeiling, 32), mload(withCeiling))
        }
        if (a == address(0)) {
            assembly {
                a := create(0, add(code, 32), mload(code))
            }
        }
        require(a != address(0), "vault impl deployment failed: adapt Base._deployImpl");
    }

    // ---- adaptation point 3: initialisation parameters
    function _initParams() internal view virtual returns (IPharaohDlmmVault.InitParams memory p) {
        p = IPharaohDlmmVault.InitParams({
            asset: address(usdc),
            pairToken: address(usdt),
            pair: address(pair),
            router: address(router),
            factory: address(factory),
            rewarder: address(rewarder),
            rewarderImplCodehash: address(implA).codehash,
            feedAsset: address(feedUsdc),
            feedPair: address(feedUsdt),
            binStep: BIN_STEP,
            owner: SAFE,
            rebalancer: KEEPER,
            depositCap: initCap,
            name: "Peridot Pharaoh DLMM USDC/USDt",
            symbol: "pDLMM"
        });
    }

    function _deployVaultWith(IPharaohDlmmVault.InitParams memory p) internal returns (address proxy) {
        bytes memory code = _findCode();
        if (code.length == 0) {
            vm.skip(true);
            return address(0);
        }
        impl = _deployImpl(code);
        bytes memory data = abi.encodeCall(IVaultAdmin.initialize, (p));
        proxy = address(new TransparentUpgradeableProxy(impl, SAFE, data));
    }

    function _setUpVault() internal {
        _deployWorld();
        address proxy = _deployVaultWith(_initParams());
        if (proxy == address(0)) return;
        v = IPharaohDlmmVault(proxy);
        erc = IERC4626(proxy);
        adm = IVaultAdmin(proxy);
        shares = IERC20(proxy);
        // the vault may start PAUSED (ceremony: the owner unpauses after the read-backs). Record it and unpause as the Safe.
        startedPaused = adm.paused();
        if (startedPaused) {
            vm.prank(SAFE);
            adm.unpause();
        }
        _mintTokens(ALICE, 10_000e6, 0);
        _mintTokens(BOB, 10_000e6, 0);
        _mintTokens(CAROL, 10_000e6, 0);
        _mintTokens(ATTACKER, 10_000e6, 0);
        _mintTokens(SAFE, 10_000e6, 0);
        address[5] memory us = [ALICE, BOB, CAROL, ATTACKER, SAFE];
        for (uint256 i; i < us.length; ++i) {
            vm.prank(us[i]);
            usdc.approve(proxy, type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ user actions
    function _deposit(address u, uint256 assets) internal returns (uint256 sh) {
        if (usdc.balanceOf(u) < assets) usdc.mint(u, assets - usdc.balanceOf(u));
        vm.prank(u);
        sh = erc.deposit(assets, u);
    }

    function _redeemAll(address u) internal returns (uint256 assets) {
        uint256 s = shares.balanceOf(u);
        vm.prank(u);
        assets = erc.redeem(s, u, u);
    }

    function _inKind(address u, uint256 sh) internal returns (uint256 a, uint256 b) {
        vm.prank(u);
        return v.redeemInKind(sh, u, u);
    }

    // ------------------------------------------------------------------ keeper actions
    function _hasBand() internal view returns (bool h) {
        (,,, h,) = v.bandState();
    }

    function _band() internal view returns (uint24 lo, uint24 hi, uint24 act, bool has, bool oor) {
        return v.bandState();
    }

    function _openBandArgs() internal view returns (bytes memory) {
        return abi.encodeCall(IPharaohDlmmVault.openBand, (pair.getActiveId(), 1, 0, 0, 0, block.timestamp + 120));
    }

    function _openBand() internal {
        uint24 a = pair.getActiveId(); // read BEFORE the prank: a call in the argument list would consume it
        vm.prank(KEEPER);
        v.openBand(a, 1, 0, 0, 0, block.timestamp + 120);
    }

    /// deposit by ALICE of `amt` USDC then the keeper opens the first band
    function _fundAndOpen(uint256 amt) internal {
        _deposit(ALICE, amt);
        if (!_hasBand()) _openBand();
    }

    // -- the vault's token holdings by independent arithmetic (idle + pro-rata bins over a window around the start id)
    function _holdings() internal view returns (uint256 usdcAmt, uint256 usdtAmt) {
        usdcAmt = usdc.balanceOf(address(v));
        usdtAmt = usdt.balanceOf(address(v));
        for (uint24 id = ID0 - 400; id <= ID0 + 400; ++id) {
            uint256 sh = pair.balanceOf(address(v), id);
            if (sh == 0) continue;
            uint256 sup = pair.totalSupply(id);
            (uint128 bx, uint128 by) = pair.getBin(id);
            uint256 ox = (sh * bx) / sup;
            uint256 oy = (sh * by) / sup;
            if (usdcIsX) {
                usdcAmt += ox;
                usdtAmt += oy;
            } else {
                usdtAmt += ox;
                usdcAmt += oy;
            }
        }
    }

    /// oracle value in USDC (6 dec) with the two feeds: usdc + usdt * (usdtUSD / usdcUSD)
    function _oracleNav() internal view returns (uint256) {
        (uint256 c, uint256 t) = _holdings();
        (, int256 pc,,,) = feedUsdc.latestRoundData();
        (, int256 pt,,,) = feedUsdt.latestRoundData();
        return c + (t * uint256(pt)) / uint256(pc);
    }

    /// rebalance arguments for a band that is out of range: swap half of the over-held leg, accept the vault's own oracle floor
    function _rebalanceCall() internal view returns (bytes memory) {
        (uint256 c, uint256 t) = _holdings();
        // the over-held leg is whichever token is the bulk of the holdings (a band out of range is one-sided)
        bool overUsdc = c >= t;
        uint256 bulk = overUsdc ? c : t;
        bool swapXForY = overUsdc ? usdcIsX : !usdcIsX; // selling X for Y?
        uint256 swapIn = bulk / 2;
        uint256 minOut = (swapIn * 9_900) / 10_000;
        return abi.encodeCall(IPharaohDlmmVault.rebalance, (pair.getActiveId(), 1, swapXForY, swapIn, minOut, 0, 0, block.timestamp + 120));
    }

    function _rebalance() internal {
        bytes memory cd = _rebalanceCall();
        vm.prank(KEEPER);
        (bool ok, bytes memory ret) = address(v).call(cd);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    /// pushes the active bin out of the vault's band with third-party swaps (up = true: the active id rises)
    function _pushOut(bool up) internal {
        (uint24 lo, uint24 hi,,,) = v.bandState();
        // the id rises when X is bought with Y: sell Y, i.e. USDC when USDC is Y; the direction flips with the token order
        bool sellUsdc = up ? !usdcIsX : usdcIsX;
        uint256 guard;
        while (guard++ < 40) {
            uint24 a = pair.getActiveId();
            if (a > hi || a < lo) return;
            _marketSwap(sellUsdc, 60_000e6);
        }
        revert("pushOut: band not left");
    }

    function _warp(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        _refreshFeeds();
    }

    // ------------------------------------------------------------------ guard helpers
    function _guard() internal view returns (bool unsafe, bool latched, uint256 reasons) {
        return v.guardState();
    }

    function _expectGuardUnsafe(uint256 reasons) internal {
        vm.expectRevert(abi.encodeWithSelector(IPharaohDlmmVault.GuardUnsafe.selector, reasons));
    }

    /// low-level call that must revert with exactly `sel` as the first four bytes
    function _assertRevertsWith(address caller, address target, bytes memory cd, bytes4 sel) internal {
        vm.prank(caller);
        (bool ok, bytes memory ret) = target.call(cd);
        assertFalse(ok, "expected a revert");
        bytes4 got;
        if (ret.length >= 4) {
            assembly {
                got := mload(add(ret, 32))
            }
        }
        assertEq(got, sel, "unexpected revert selector");
    }

    function _assertReverts(address caller, address target, bytes memory cd) internal returns (bytes memory ret) {
        vm.prank(caller);
        bool ok;
        (ok, ret) = target.call(cd);
        assertFalse(ok, "expected a revert");
    }

    function _assertOk(address caller, address target, bytes memory cd) internal returns (bytes memory ret) {
        vm.prank(caller);
        bool ok;
        (ok, ret) = target.call(cd);
        if (!ok) {
            assertTrue(ok, "call unexpectedly reverted");
        }
    }

    function _sel(bytes memory ret) internal pure returns (bytes4 got) {
        if (ret.length >= 4) {
            assembly {
                got := mload(add(ret, 32))
            }
        }
    }
}
