// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RobinhoodV4RouterAdapter} from "../contracts/margin/RobinhoodV4RouterAdapter.sol";

contract MockERC20 {
    string public name = "Mock";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPermit2 {
    mapping(bytes32 => uint160) public amounts;

    function approve(address token, address spender, uint160 amount, uint48) external {
        amounts[keccak256(abi.encode(msg.sender, token, spender))] = amount;
    }

    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160, uint48, uint48)
    {
        return (amounts[keccak256(abi.encode(user, token, spender))], 0, 0);
    }
}

/// @dev Captures what the adapter sends and pays out a configurable amount, so the encoding can
///      be inspected without a live Universal Router.
contract MockUniversalRouter {
    bytes public lastCommands;
    bytes public lastInput;
    uint256 public lastDeadline;

    MockERC20 public payout;
    uint256 public payoutAmount;
    address public payTo;

    function setPayout(MockERC20 token, uint256 amount, address to) external {
        payout = token;
        payoutAmount = amount;
        payTo = to;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable
    {
        lastCommands = commands;
        lastInput = inputs[0];
        lastDeadline = deadline;
        if (payoutAmount != 0) payout.mint(payTo, payoutAmount);
    }
}

contract RobinhoodV4RouterAdapterTest is Test {
    uint256 internal constant ROBINHOOD = 4663;

    RobinhoodV4RouterAdapter internal adapter;
    MockUniversalRouter internal router;
    MockPermit2 internal permit2;
    MockERC20 internal usdg;
    MockERC20 internal nvda;

    address internal owner = makeAddr("owner");
    address internal manager = makeAddr("manager");
    address internal account = makeAddr("marginAccount");

    function setUp() public {
        vm.chainId(ROBINHOOD);
        router = new MockUniversalRouter();
        permit2 = new MockPermit2();
        usdg = new MockERC20();
        nvda = new MockERC20();
        // currency0 must sort below currency1, matching the live pool's ordering.
        if (address(usdg) > address(nvda)) (usdg, nvda) = (nvda, usdg);

        adapter = new RobinhoodV4RouterAdapter(owner, address(router), address(permit2));
        vm.startPrank(owner);
        adapter.setManager(manager);
        adapter.registerPool(address(usdg), address(nvda), 3000, 60);
        vm.stopPrank();
    }

    function testRejectsDeploymentOffRobinhoodChain() public {
        vm.chainId(1);
        vm.expectRevert(bytes("RobinhoodAdapter: Robinhood only"));
        new RobinhoodV4RouterAdapter(owner, address(router), address(permit2));
    }

    function testOnlyOperatorCanSwap() public {
        vm.expectRevert(RobinhoodV4RouterAdapter.NotOperator.selector);
        adapter.swap(account, address(usdg), address(nvda), 1e18, 1, "");
    }

    function testUnregisteredPairIsRejected() public {
        MockERC20 other = new MockERC20();
        vm.prank(manager);
        vm.expectRevert(RobinhoodV4RouterAdapter.PairNotRegistered.selector);
        adapter.swap(account, address(usdg), address(other), 1e18, 1, "");
    }

    /**
     * @dev The encoding the deployed Universal Router expects carries `minHopPriceX36`, which a
     *      stock v4-periphery release predates. Pin the exact byte layout so a future edit that
     *      reorders or drops a field fails here rather than silently reverting every live swap.
     */
    function testSwapParamsMatchTheDeployedRouterEncoding() public {
        uint256 amountIn = 1e18;
        uint256 minOut = 5e17;
        _fund(amountIn, minOut);

        vm.prank(manager);
        adapter.swap(account, address(usdg), address(nvda), amountIn, minOut, "");

        (bytes memory actions, bytes[] memory params) =
            abi.decode(router.lastInput(), (bytes, bytes[]));

        assertEq(router.lastCommands(), hex"10", "command must be V4_SWAP");
        assertEq(actions, hex"060c0f", "SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL");
        assertEq(params.length, 3);

        uint256 expectedHopPrice = (minOut * 1e36) / amountIn;
        bytes memory expected = abi.encode(
            RobinhoodV4RouterAdapter.RouterExactInputSingleParams({
                poolKey: RobinhoodV4RouterAdapter.PoolKey({
                    currency0: address(usdg),
                    currency1: address(nvda),
                    fee: 3000,
                    tickSpacing: 60,
                    hooks: address(0)
                }),
                zeroForOne: true,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minOut),
                minHopPriceX36: expectedHopPrice,
                hookData: bytes("")
            })
        );
        assertEq(params[0], expected, "swap params encoding drifted");

        (address settleCurrency, uint256 settleMax) = abi.decode(params[1], (address, uint256));
        assertEq(settleCurrency, address(usdg));
        assertEq(settleMax, type(uint256).max, "SETTLE_ALL ceiling");

        (address takeCurrency, uint256 takeMin) = abi.decode(params[2], (address, uint256));
        assertEq(takeCurrency, address(nvda));
        assertEq(takeMin, minOut, "TAKE_ALL floor must be minAmountOut");
    }

    function testDirectionFlipsWhenSwappingTheOtherWay() public {
        uint256 amountIn = 1e18;
        uint256 minOut = 5e17;
        nvda.mint(account, amountIn);
        vm.prank(account);
        nvda.approve(address(adapter), type(uint256).max);
        router.setPayout(usdg, minOut, address(adapter));

        vm.prank(manager);
        adapter.swap(account, address(nvda), address(usdg), amountIn, minOut, "");

        (, bytes[] memory params) = abi.decode(router.lastInput(), (bytes, bytes[]));
        RobinhoodV4RouterAdapter.RouterExactInputSingleParams memory p =
            abi.decode(params[0], (RobinhoodV4RouterAdapter.RouterExactInputSingleParams));
        assertFalse(p.zeroForOne, "nvda is currency1, so this is one-for-zero");
    }

    function testOutputBelowFloorReverts() public {
        uint256 amountIn = 1e18;
        uint256 minOut = 5e17;
        // Router pays out less than the floor; the measured balance delta must catch it even
        // though the router itself reported no error.
        _fund(amountIn, minOut - 1);

        vm.prank(manager);
        vm.expectRevert(RobinhoodV4RouterAdapter.InsufficientOutput.selector);
        adapter.swap(account, address(usdg), address(nvda), amountIn, minOut, "");
    }

    function testAdapterRetainsNoBalanceOrAllowance() public {
        uint256 amountIn = 1e18;
        uint256 minOut = 5e17;
        _fund(amountIn, minOut);

        vm.prank(manager);
        uint256 out = adapter.swap(account, address(usdg), address(nvda), amountIn, minOut, "");

        assertEq(out, minOut);
        assertEq(nvda.balanceOf(account), minOut, "output forwarded to the account");
        assertEq(usdg.balanceOf(address(adapter)), 0, "no input retained");
        assertEq(nvda.balanceOf(address(adapter)), 0, "no output retained");
        assertEq(usdg.allowance(address(adapter), address(permit2)), 0, "erc20 allowance cleared");
        (uint160 remaining,,) = permit2.allowance(address(adapter), address(usdg), address(router));
        assertEq(remaining, 0, "permit2 allowance cleared");
    }

    function testCallerSuppliedDeadlineIsHonoured() public {
        uint256 amountIn = 1e18;
        uint256 minOut = 5e17;
        _fund(amountIn, minOut);

        uint256 deadline = block.timestamp + 42;
        vm.prank(manager);
        adapter.swap(account, address(usdg), address(nvda), amountIn, minOut, abi.encode(deadline));
        assertEq(router.lastDeadline(), deadline);
    }

    function _fund(uint256 amountIn, uint256 payout) private {
        usdg.mint(account, amountIn);
        vm.prank(account);
        usdg.approve(address(adapter), type(uint256).max);
        router.setPayout(nvda, payout, address(adapter));
    }
}
