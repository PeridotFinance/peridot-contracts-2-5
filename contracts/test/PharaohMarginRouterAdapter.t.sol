// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PharaohMarginRouterAdapter as Adapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";
import {IMarginRouterAdapter} from "../contracts/margin/IMarginRouterAdapter.sol";
import {PharaohTestAsset, PharaohTestVault} from "./mocks/PharaohBoostedMocks.sol";

contract MarginCapacityTestVault is PharaohTestVault {
    bool public depositsClosed;
    bool public redemptionsClosed;

    constructor(IERC20 asset_) PharaohTestVault(asset_, "Pharaoh test shares", "shares") {}

    function setLimits(bool depositClosed, bool redeemClosed) external {
        depositsClosed = depositClosed;
        redemptionsClosed = redeemClosed;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositsClosed ? 0 : type(uint256).max;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return redemptionsClosed ? 0 : balanceOf(owner);
    }
}

contract PharaohMarginBaseRouterMock is IMarginRouterAdapter {
    address public immutable usd;
    address public immutable wavax;
    uint256 public executionBps = 10_000;
    bool public lieAboutOutput;
    uint256 public calls;
    uint256 public priceUsd = 10e6;

    constructor(address usd_, address wavax_) {
        usd = usd_;
        wavax = wavax_;
    }

    function setExecution(uint256 bps, bool lie) external {
        executionBps = bps;
        lieAboutOutput = lie;
    }

    function setPrice(uint256 value) external {
        require(value > 0, "zero price");
        priceUsd = value;
    }

    function swap(address from, address tokenIn, address tokenOut, uint256 amount, uint256 minimum, bytes calldata)
        external
        returns (uint256 out)
    {
        require(from == msg.sender, "router caller");
        require((tokenIn == usd && tokenOut == wavax) || (tokenIn == wavax && tokenOut == usd), "router pair");
        ++calls;
        out = tokenIn == usd ? Math.mulDiv(amount, 1e18, priceUsd) : Math.mulDiv(amount, priceUsd, 1e18);
        out = Math.mulDiv(out, executionBps, 10_000);
        require(out >= minimum, "router slippage");
        require(IERC20(tokenIn).transferFrom(from, address(this), amount));
        require(IERC20(tokenOut).transfer(from, out));
        if (lieAboutOutput) ++out;
    }
}

contract PharaohMarginRouterAdapterTest is Test {
    PharaohTestAsset internal usd;
    PharaohTestAsset internal wavax;
    MarginCapacityTestVault internal uVault;
    MarginCapacityTestVault internal aVault;
    PharaohMarginBaseRouterMock internal router;
    Adapter internal adapter;

    function setUp() public {
        usd = new PharaohTestAsset("USDC", "USDC", 6);
        wavax = new PharaohTestAsset("WAVAX", "WAVAX", 18);
        uVault = new MarginCapacityTestVault(usd);
        aVault = new MarginCapacityTestVault(wavax);
        router = new PharaohMarginBaseRouterMock(address(usd), address(wavax));
        adapter = new Adapter(address(uVault), address(aVault), address(usd), address(wavax), address(router));
        usd.mint(address(this), 1_000_000e6);
        wavax.mint(address(this), 1_000_000e18);
        usd.mint(address(router), 1_000_000e6);
        wavax.mint(address(router), 1_000_000e18);
        usd.approve(address(uVault), 1000e6);
        wavax.approve(address(aVault), 1000e18);
        uVault.deposit(1000e6, address(this));
        aVault.deposit(1000e18, address(this));
    }

    function _swap(address input, address output, uint256 amount, uint256 minimum) internal returns (uint256) {
        IERC20(input).approve(address(adapter), amount);
        return adapter.swap(address(this), input, output, amount, minimum, "");
    }

    function _clean() internal view {
        address[4] memory tokens = [address(usd), address(wavax), address(uVault), address(aVault)];
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(address(adapter)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(adapter), address(router)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(adapter), address(uVault)), 0);
            assertEq(IERC20(tokens[i]).allowance(address(adapter), address(aVault)), 0);
        }
    }

    function testSharesRoundTripAcrossBothVaults() public {
        uint256 before = uVault.balanceOf(address(this));
        uint256 avaxShares = _swap(address(uVault), address(aVault), 100e6, 10e18);
        assertEq(avaxShares, 10e18);
        assertEq(_swap(address(aVault), address(uVault), avaxShares, 100e6), 100e6);
        assertEq(uVault.balanceOf(address(this)), before);
        assertEq(router.calls(), 2);
        _clean();
    }

    function testSameAssetShareEntryExitSkipsDex() public {
        uint256 shares = _swap(address(usd), address(uVault), 100e6, 100e6);
        assertEq(_swap(address(uVault), address(usd), shares, 100e6), 100e6);
        assertEq(router.calls(), 0);
        _clean();
    }

    function testBaseTradingStillUsesUnderlyingRouter() public {
        assertEq(_swap(address(usd), address(wavax), 100e6, 10e18), 10e18);
        _clean();
    }

    function testShareYieldIsIncludedInRedemption() public {
        usd.mint(address(uVault), 100e6);
        uint256 expected = uVault.previewRedeem(100e6);
        assertGt(expected, 100e6);
        assertEq(_swap(address(uVault), address(usd), 100e6, expected), expected);
        _clean();
    }

    function testCannotSpendAnotherAccountsApproval() public {
        usd.approve(address(adapter), 100e6);
        vm.prank(address(0xBAD));
        vm.expectRevert(Adapter.InvalidSwap.selector);
        adapter.swap(address(this), address(usd), address(wavax), 100e6, 1, "");
    }

    function testDepositClosureRevertsEntireConversion() public {
        aVault.setLimits(true, false);
        uVault.approve(address(adapter), 100e6);
        uint256 before = uVault.balanceOf(address(this));
        vm.expectRevert(Adapter.VaultCapacity.selector);
        adapter.swap(address(this), address(uVault), address(aVault), 100e6, 10e18, "");
        assertEq(uVault.balanceOf(address(this)), before);
        assertEq(router.calls(), 0);
        _clean();
    }

    function testRedemptionClosureDoesNotConsumeShares() public {
        uVault.setLimits(false, true);
        uVault.approve(address(adapter), 100e6);
        uint256 before = uVault.balanceOf(address(this));
        vm.expectRevert(Adapter.VaultCapacity.selector);
        adapter.swap(address(this), address(uVault), address(usd), 100e6, 100e6, "");
        assertEq(uVault.balanceOf(address(this)), before);
        _clean();
    }

    function testSharesOutputMinimumCannotBeBypassed() public {
        usd.approve(address(adapter), 100e6);
        uint256 before = usd.balanceOf(address(this));
        vm.expectRevert(Adapter.InsufficientOutput.selector);
        adapter.swap(address(this), address(usd), address(uVault), 100e6, 101e6, "");
        assertEq(usd.balanceOf(address(this)), before);
        _clean();
    }

    function testRouterSlippageDoesNotBurnCollateralShares() public {
        router.setExecution(9800, false);
        uVault.approve(address(adapter), 100e6);
        uint256 before = uVault.balanceOf(address(this));
        vm.expectRevert(bytes("router slippage"));
        adapter.swap(address(this), address(uVault), address(aVault), 100e6, 99e17, "");
        assertEq(uVault.balanceOf(address(this)), before);
        _clean();
    }

    function testMisreportedRouterOutputIsRejected() public {
        router.setExecution(10_000, true);
        usd.approve(address(adapter), 100e6);
        vm.expectRevert(Adapter.UnexpectedBalance.selector);
        adapter.swap(address(this), address(usd), address(wavax), 100e6, 10e18, "");
        _clean();
    }

    function testPreexistingDonationsAreNotSpentOrClaimed() public {
        usd.mint(address(adapter), 3e6);
        wavax.mint(address(adapter), 2e18);
        uVault.transfer(address(adapter), 5e6);
        aVault.transfer(address(adapter), 4e18);
        _swap(address(uVault), address(aVault), 100e6, 10e18);
        assertEq(usd.balanceOf(address(adapter)), 3e6);
        assertEq(wavax.balanceOf(address(adapter)), 2e18);
        assertEq(uVault.balanceOf(address(adapter)), 5e6);
        assertEq(aVault.balanceOf(address(adapter)), 4e18);
    }

    function testRejectsZeroMinimumAndUnknownToken() public {
        vm.expectRevert(Adapter.InvalidSwap.selector);
        adapter.swap(address(this), address(usd), address(wavax), 100e6, 0, "");
        vm.expectRevert(Adapter.UnsupportedToken.selector);
        adapter.swap(address(this), address(0xBAD), address(wavax), 100e6, 1, "");
    }

    function testRejectsMismatchedVaultAssets() public {
        vm.expectRevert(Adapter.InvalidConfiguration.selector);
        new Adapter(address(aVault), address(uVault), address(usd), address(wavax), address(router));
    }

    function testFuzzSameAssetRoundTripCannotCreateAssets(uint64 amount) public {
        amount = uint64(bound(amount, 1, 10_000e6));
        uint256 before = usd.balanceOf(address(this));
        uint256 shares = _swap(address(usd), address(uVault), amount, 1);
        _swap(address(uVault), address(usd), shares, 1);
        assertLe(usd.balanceOf(address(this)), before);
        _clean();
    }
}
