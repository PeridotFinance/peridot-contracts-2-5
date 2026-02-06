// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {QuickSwapV3RouterAdapter} from "../contracts/margin/QuickSwapV3RouterAdapter.sol";
import {IMarginRouterAdapter} from "../contracts/margin/IMarginRouterAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockErc20} from "./MockErc20.sol";

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract MockAlgebraRouter {

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    uint256 public amountOutToReturn;
    ExactInputParams public lastParams;
    bool public revertCall;

    function setAmountOut(uint256 out_) external {
        amountOutToReturn = out_;
    }

    function setRevertCall(bool state) external {
        revertCall = state;
    }

    function exactInput(
        ExactInputParams calldata params
    ) external returns (uint256 amountOut) {
        if (revertCall) revert("router fail");
        lastParams = params;
        // mint output token to recipient for testing
        address tokenOut = _lastToken(params.path);
        IMintable(tokenOut).mint(params.recipient, amountOutToReturn);
        return amountOutToReturn;
    }

    function _lastToken(bytes calldata path) internal pure returns (address token) {
        // last 20 bytes
        assembly {
            token := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
    }

    // helper getters for tests
    function lastAmountIn() external view returns (uint256) {
        return lastParams.amountIn;
    }

    function lastAmountOutMin() external view returns (uint256) {
        return lastParams.amountOutMinimum;
    }

    function lastRecipient() external view returns (address) {
        return lastParams.recipient;
    }
}

contract QuickSwapV3RouterAdapterTest is Test {
    QuickSwapV3RouterAdapter adapter;
    MockAlgebraRouter router;
    MockErc20 tokenIn;
    MockErc20 tokenOut;
    address operator = address(0xABCD);
    address fromAccount = address(this);

    function setUp() public {
        router = new MockAlgebraRouter();
        adapter = new QuickSwapV3RouterAdapter(address(this), address(router));
        adapter.setOperator(operator, true);
        adapter.setWhitelistEnforced(true);

        tokenIn = new MockErc20("TokenIn", "TIN", 18);
        tokenOut = new MockErc20("TokenOut", "TOUT", 18);

        // allow pool
        adapter.setPoolWhitelist(address(tokenIn), address(tokenOut), 300, true);

        // fund fromAccount
        tokenIn.mint(fromAccount, 1_000 ether);
    }

    function _pathSingle() internal view returns (bytes memory) {
        return abi.encodePacked(address(tokenIn), uint16(300), address(tokenOut));
    }

    function testSwapSuccess() public {
        uint256 amountIn = 100 ether;
        uint256 minOut = 90 ether;
        router.setAmountOut(120 ether);

        vm.prank(fromAccount);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(operator);
        uint256 out = adapter.swap(
            fromAccount,
            address(tokenIn),
            address(tokenOut),
            amountIn,
            minOut,
            abi.encode(_pathSingle(), uint256(0))
        );

        assertEq(out, 120 ether, "amountOut");
        assertEq(tokenOut.balanceOf(fromAccount), 120 ether, "recipient received");
        // check router params
        assertEq(router.lastAmountIn(), amountIn);
        assertEq(router.lastAmountOutMin(), minOut);
        assertEq(router.lastRecipient(), fromAccount);

        // allowance cleared
        assertEq(IERC20(address(tokenIn)).allowance(address(adapter), address(router)), 0);
        // no leftover tokenIn on adapter
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
    }

    function testRevertOnSlippage() public {
        uint256 amountIn = 100 ether;
        uint256 minOut = 90 ether;
        router.setAmountOut(80 ether);
        vm.prank(fromAccount);
        tokenIn.approve(address(adapter), amountIn);

        vm.prank(operator);
        vm.expectRevert(bytes("Adapter: slippage"));
        adapter.swap(
            fromAccount,
            address(tokenIn),
            address(tokenOut),
            amountIn,
            minOut,
            abi.encode(_pathSingle(), uint256(0))
        );
    }

    function testInvalidPathStrideReverts() public {
        bytes memory badPath = abi.encodePacked(address(tokenIn), uint16(300), address(tokenOut), bytes1(0x01));
        vm.prank(operator);
        vm.expectRevert(bytes("Adapter: path tokenOut mismatch"));
        adapter.swap(
            fromAccount,
            address(tokenIn),
            address(tokenOut),
            1 ether,
            1,
            abi.encode(badPath, uint256(0))
        );
    }

    function testWhitelistBlocksPoolWhenEnforced() public {
        // turn off whitelist for one pool
        adapter.setPoolWhitelist(address(tokenIn), address(tokenOut), 300, false);

        vm.prank(operator);
        vm.expectRevert(bytes("Adapter: pool not allowed"));
        adapter.swap(
            fromAccount,
            address(tokenIn),
            address(tokenOut),
            1 ether,
            1,
            abi.encode(_pathSingle(), uint256(0))
        );
    }

    function testOnlyOperatorCanCall() public {
        vm.expectRevert(bytes("Adapter: not authorized"));
        adapter.swap(
            fromAccount,
            address(tokenIn),
            address(tokenOut),
            1 ether,
            1,
            abi.encode(_pathSingle(), uint256(0))
        );
    }
}
