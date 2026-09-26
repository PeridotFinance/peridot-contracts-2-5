// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PharaohTestAsset} from "./mocks/PharaohBoostedMocks.sol";
import {PharaohCLRouterAdapter as Adapter, IPharaohCLRouter} from "../contracts/margin/PharaohCLRouterAdapter.sol";

contract PharaohCLBindingMock {
    address public factory;
    address public token0;
    address public token1;
    int24 public tickSpacing = 10;
    address public pool;
    address public ramsesV3PoolDeployer;

    constructor(address a, address b) {
        factory = address(this);
        (token0, token1) = a < b ? (a, b) : (b, a);
        pool = address(this);
        ramsesV3PoolDeployer = address(this);
    }

    function getPool(address, address, int24) external view returns (address) {
        return pool;
    }

    function setPool(address p) external {
        pool = p;
    }
}

contract PharaohCLRouterMock is IPharaohCLRouter {
    address public immutable deployer;
    address public immutable WETH9;
    uint256 public fillBps = 10_000;
    uint256 public outputBps = 10_000;
    bool public lie;

    constructor(address d, address w) {
        deployer = d;
        WETH9 = w;
    }

    function setExecution(uint256 fill, uint256 output, bool lie_) external {
        fillBps = fill;
        outputBps = output;
        lie = lie_;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(p.tickSpacing == 10 && p.sqrtPriceLimitX96 == 0 && p.deadline >= block.timestamp, "bad params");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn * fillBps / 10_000);
        out = p.amountIn * outputBps / 10_000;
        IERC20(p.tokenOut).transfer(p.recipient, out);
        if (lie) ++out;
    }
}

contract PharaohCLRouterAdapterTest is Test {
    PharaohTestAsset a;
    PharaohTestAsset u;
    PharaohCLBindingMock binding;
    PharaohCLRouterMock router;
    Adapter adapter;

    function setUp() public {
        a = new PharaohTestAsset("A", "A", 18);
        u = new PharaohTestAsset("U", "U", 18);
        binding = new PharaohCLBindingMock(address(a), address(u));
        router = new PharaohCLRouterMock(address(binding), address(a));
        adapter = new Adapter(address(router), address(binding), address(binding), address(a), address(u), 10);
        a.mint(address(this), 100e18);
        u.mint(address(this), 100e18);
        a.mint(address(router), 1000e18);
        u.mint(address(router), 1000e18);
        a.approve(address(adapter), type(uint256).max);
        u.approve(address(adapter), type(uint256).max);
    }

    function _swap() internal returns (uint256) {
        return adapter.swap(address(this), address(a), address(u), 10e18, 9e18, "");
    }

    function testBothDirectionsAndApprovalCleanup() public {
        assertEq(_swap(), 10e18);
        assertEq(adapter.swap(address(this), address(u), address(a), 10e18, 9e18, ""), 10e18);
        assertEq(a.allowance(address(adapter), address(router)), 0);
        assertEq(u.allowance(address(adapter), address(router)), 0);
        assertEq(a.balanceOf(address(adapter)), 0);
        assertEq(u.balanceOf(address(adapter)), 0);
    }

    function testDonationsPreserved() public {
        a.mint(address(adapter), 3);
        u.mint(address(adapter), 7);
        _swap();
        assertEq(a.balanceOf(address(adapter)), 3);
        assertEq(u.balanceOf(address(adapter)), 7);
    }

    function testForeignCallerCannotSpendApproval() public {
        vm.prank(address(99));
        vm.expectRevert(Adapter.InvalidSwap.selector);
        adapter.swap(address(this), address(a), address(u), 1, 1, "");
    }

    function testRejectsArbitraryDataAndWrongPair() public {
        vm.expectRevert(Adapter.InvalidSwap.selector);
        adapter.swap(address(this), address(a), address(u), 1, 1, hex"00");
        vm.expectRevert(Adapter.InvalidSwap.selector);
        adapter.swap(address(this), address(a), address(a), 1, 1, "");
        vm.expectRevert(Adapter.InvalidSwap.selector);
        adapter.swap(address(this), address(a), address(99), 1, 1, "");
    }

    function testRejectsZeroAmountOrMinimum() public {
        vm.expectRevert(Adapter.InvalidSwap.selector);
        adapter.swap(address(this), address(a), address(u), 0, 1, "");
        vm.expectRevert(Adapter.InvalidSwap.selector);
        adapter.swap(address(this), address(a), address(u), 1, 0, "");
    }

    function testPartialFillRevertsAtomically() public {
        router.setExecution(5000, 10_000, false);
        vm.expectRevert(Adapter.UnexpectedBalance.selector);
        _swap();
        assertEq(a.balanceOf(address(this)), 100e18);
        assertEq(u.balanceOf(address(this)), 100e18);
    }

    function testFalseOutputReportRejected() public {
        router.setExecution(10_000, 10_000, true);
        vm.expectRevert(Adapter.UnexpectedBalance.selector);
        _swap();
    }

    function testMinimumCheckedEvenIfRouterIgnoresIt() public {
        router.setExecution(10_000, 8000, false);
        vm.expectRevert(Adapter.InsufficientOutput.selector);
        _swap();
    }

    function testChangedPoolBindingRejectsSwap() public {
        binding.setPool(address(99));
        vm.expectRevert(Adapter.InvalidConfiguration.selector);
        _swap();
    }

    function testConstructorRejectsWrongTickOrAssets() public {
        vm.expectRevert(Adapter.InvalidConfiguration.selector);
        new Adapter(address(router), address(binding), address(binding), address(a), address(u), 20);
        vm.expectRevert(Adapter.InvalidConfiguration.selector);
        new Adapter(address(router), address(binding), address(binding), address(u), address(a), 10);
    }

    function testFuzzExactBalanceConservation(uint96 amount) public {
        uint256 n = bound(uint256(amount), 1, 100e18);
        uint256 beforeA = a.balanceOf(address(this));
        uint256 beforeU = u.balanceOf(address(this));
        assertEq(adapter.swap(address(this), address(a), address(u), n, n, ""), n);
        assertEq(a.balanceOf(address(this)), beforeA - n);
        assertEq(u.balanceOf(address(this)), beforeU + n);
        assertEq(a.allowance(address(adapter), address(router)), 0);
    }
}
