// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {PharaohMarginRouterAdapter as Adapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";
import {PharaohMarginBaseRouterMock} from "./PharaohMarginRouterAdapter.t.sol";

/// @notice Actual Pharaoh code on a pinned LOCAL Avalanche fork. No live transactions.
/// Covers share/base conversion, not DEX routing or the complete new margin lifecycle.
contract PharaohMarginConversionForkTest is Test {
    address constant USD = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
    address constant SAFE = 0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12;
    IERC4626 constant U_VAULT = IERC4626(0x855bF832f26a294d28500db59eE941dE3d654129);
    IERC4626 constant A_VAULT = IERC4626(0xe9a53f0077f9cf767a95Ce75Da483E906eE190E8);
    Adapter internal adapter;
    PharaohMarginBaseRouterMock internal unusedRouter;

    function setUp() public {
        string memory rpc = vm.envOr("AVALANCHE_MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc, 95_834_867);
        assertEq(block.chainid, 43_114);
        unusedRouter = new PharaohMarginBaseRouterMock(USD, WAVAX);
        adapter = new Adapter(address(U_VAULT), address(A_VAULT), USD, WAVAX, address(unusedRouter));
    }

    function testRealUsdcVaultSharesRedeemWithoutDex() public {
        _redeem(U_VAULT, USD);
    }

    function testRealWavaxVaultSharesRedeemWithoutDex() public {
        _redeem(A_VAULT, WAVAX);
    }

    function _redeem(IERC4626 vault, address asset) private {
        uint256 shares = vault.balanceOf(SAFE) / 10;
        assertGt(shares, 0);
        vm.prank(SAFE);
        assertTrue(vault.transfer(address(this), shares));
        vault.approve(address(adapter), shares);
        uint256 beforeAssets = IERC20(asset).balanceOf(address(this));
        uint256 minimum = vault.previewRedeem(shares) * 9900 / 10_000;
        assertGt(minimum, 0);
        uint256 out = adapter.swap(address(this), address(vault), asset, shares, minimum, "");
        assertGe(out, minimum);
        assertEq(IERC20(asset).balanceOf(address(this)) - beforeAssets, out);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.balanceOf(address(adapter)), 0);
        assertEq(IERC20(asset).balanceOf(address(adapter)), 0);
        assertEq(unusedRouter.calls(), 0);
    }

    function testRealClosedUsdcVaultRejectsEntryWithoutSpending() public {
        _closed(U_VAULT, USD, 1e6);
    }

    function testRealClosedWavaxVaultRejectsEntryWithoutSpending() public {
        _closed(A_VAULT, WAVAX, 0.01e18);
    }

    function _closed(IERC4626 vault, address asset, uint256 amount) private {
        assertEq(vault.maxDeposit(address(this)), 0);
        deal(asset, address(this), amount);
        IERC20(asset).approve(address(adapter), amount);
        vm.expectRevert(Adapter.VaultCapacity.selector);
        adapter.swap(address(this), asset, address(vault), amount, 1, "");
        assertEq(IERC20(asset).balanceOf(address(this)), amount);
        assertEq(IERC20(asset).balanceOf(address(adapter)), 0);
        assertEq(unusedRouter.calls(), 0);
    }
}
