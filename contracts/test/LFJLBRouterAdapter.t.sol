// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILFJLBRouter, LFJLBRouterAdapter} from "../contracts/margin/LFJLBRouterAdapter.sol";
import {MockErc20} from "./MockErc20.sol";

contract MockLFJLBRouter is ILFJLBRouter {
    uint256 public amountOut;
    bool public lieAboutOutput;
    uint256 public lastBinStep;
    Version public lastVersion;
    address public lastTokenIn;
    address public lastTokenOut;
    address public lastRecipient;
    uint256 public lastDeadline;

    function getWNATIVE() external pure returns (address) {
        return address(0);
    }

    function setSwapResult(uint256 amountOut_, bool lieAboutOutput_) external {
        amountOut = amountOut_;
        lieAboutOutput = lieAboutOutput_;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256, Path memory path, address to, uint256 deadline)
        external
        returns (uint256)
    {
        require(path.pairBinSteps.length == 1 && path.versions.length == 1 && path.tokenPath.length == 2);
        lastBinStep = path.pairBinSteps[0];
        lastVersion = path.versions[0];
        lastTokenIn = address(path.tokenPath[0]);
        lastTokenOut = address(path.tokenPath[1]);
        lastRecipient = to;
        lastDeadline = deadline;

        path.tokenPath[0].transferFrom(msg.sender, address(this), amountIn);
        MockErc20(address(path.tokenPath[1])).mint(to, lieAboutOutput ? amountOut - 1 : amountOut);
        return amountOut;
    }
}

contract LFJLBRouterAdapterTest is Test {
    uint256 internal constant ACTION_DELAY = 1 hours;
    uint256 internal constant BIN_STEP = 20;
    uint8 internal constant VERSION_V2_1 = 2;

    MockLFJLBRouter internal router;
    LFJLBRouterAdapter internal adapter;
    MockErc20 internal tokenIn;
    MockErc20 internal tokenOut;
    address internal operator = address(0xBEEF);

    function setUp() public {
        router = new MockLFJLBRouter();
        adapter = new LFJLBRouterAdapter(address(this), address(router), ACTION_DELAY);
        tokenIn = new MockErc20("Token In", "TIN", 18);
        tokenOut = new MockErc20("Token Out", "TOUT", 18);

        adapter.queueOperator(operator, true);
        adapter.queueRoute(address(tokenIn), address(tokenOut), BIN_STEP, VERSION_V2_1, true);
        vm.warp(block.timestamp + ACTION_DELAY);
        adapter.setOperator(operator, true);
        adapter.setRoute(address(tokenIn), address(tokenOut), BIN_STEP, VERSION_V2_1, true);

        tokenIn.mint(address(this), 1_000e18);
        tokenIn.approve(address(adapter), type(uint256).max);
    }

    function testSwapUsesOneHopWhitelistedRouteAndClearsAllowance() public {
        router.setSwapResult(49e18, false);

        vm.prank(operator);
        uint256 amountOut = adapter.swap(
            address(this), address(tokenIn), address(tokenOut), 50e18, 48e18, abi.encode(BIN_STEP, VERSION_V2_1)
        );

        assertEq(amountOut, 49e18);
        assertEq(tokenOut.balanceOf(address(this)), 49e18);
        assertEq(router.lastBinStep(), BIN_STEP);
        assertEq(uint8(router.lastVersion()), VERSION_V2_1);
        assertEq(router.lastTokenIn(), address(tokenIn));
        assertEq(router.lastTokenOut(), address(tokenOut));
        assertEq(router.lastRecipient(), address(this));
        assertEq(router.lastDeadline(), block.timestamp + adapter.SWAP_DEADLINE_BUFFER());
        assertEq(tokenIn.allowance(address(adapter), address(router)), 0);
        assertEq(tokenIn.balanceOf(address(adapter)), 0);
    }

    function testReverseDirectionUsesSameRouteApproval() public {
        tokenOut.mint(address(this), 10e18);
        tokenOut.approve(address(adapter), type(uint256).max);
        router.setSwapResult(11e18, false);

        vm.prank(operator);
        uint256 amountOut = adapter.swap(
            address(this), address(tokenOut), address(tokenIn), 10e18, 10e18, abi.encode(BIN_STEP, VERSION_V2_1)
        );

        assertEq(amountOut, 11e18);
    }

    function testOnlyTimelockedOperatorCanSwap() public {
        vm.expectRevert(bytes("LFJAdapter: not operator"));
        adapter.swap(address(this), address(tokenIn), address(tokenOut), 1e18, 1, abi.encode(BIN_STEP, VERSION_V2_1));
    }

    function testUnapprovedRouteReverts() public {
        vm.prank(operator);
        vm.expectRevert(bytes("LFJAdapter: route not allowed"));
        adapter.swap(address(this), address(tokenIn), address(tokenOut), 1e18, 1, abi.encode(uint256(25), VERSION_V2_1));
    }

    function testRouterOutputMismatchReverts() public {
        router.setSwapResult(2e18, true);

        vm.prank(operator);
        vm.expectRevert(bytes("LFJAdapter: output mismatch"));
        adapter.swap(address(this), address(tokenIn), address(tokenOut), 1e18, 1e18, abi.encode(BIN_STEP, VERSION_V2_1));
    }

    function testRouteConfigurationRequiresDelay() public {
        adapter.queueRoute(address(tokenIn), address(tokenOut), 25, VERSION_V2_1, true);

        vm.expectRevert(bytes("LFJAdapter: action not ready"));
        adapter.setRoute(address(tokenIn), address(tokenOut), 25, VERSION_V2_1, true);
    }

    function testLegacyVersionsAreRejected() public {
        vm.expectRevert(bytes("LFJAdapter: unsupported version"));
        adapter.queueRoute(address(tokenIn), address(tokenOut), BIN_STEP, uint8(ILFJLBRouter.Version.V2), true);
    }

    function testConstructorRejectsShortDelay() public {
        vm.expectRevert(bytes("LFJAdapter: delay too short"));
        new LFJLBRouterAdapter(address(this), address(router), ACTION_DELAY - 1);
    }
}

contract LFJLBRouterAdapterFujiForkTest is Test {
    address internal constant FUJI_LFJ_ROUTER = 0x18556DA13313f3532c54711497A8FedAC273220E;
    address internal constant FUJI_WAVAX = 0xd00ae08403B9bbb9124bB305C09058E32C39A48c;
    address internal constant FUJI_LFJ_USDC = 0xB6076C93701D6a07266c31066B298AeC6dd65c2d;
    uint256 internal constant BIN_STEP = 20;
    uint8 internal constant VERSION_V2_1 = 2;

    function testFujiLiveLFJRoundTrip() public {
        string memory rpcUrl = vm.envOr("AVALANCHE_FUJI_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) return;
        vm.createSelectFork(rpcUrl);

        LFJLBRouterAdapter adapter = new LFJLBRouterAdapter(address(this), FUJI_LFJ_ROUTER, 1 hours);
        adapter.queueOperator(address(this), true);
        adapter.queueRoute(FUJI_WAVAX, FUJI_LFJ_USDC, BIN_STEP, VERSION_V2_1, true);
        vm.warp(block.timestamp + 1 hours);
        adapter.setOperator(address(this), true);
        adapter.setRoute(FUJI_WAVAX, FUJI_LFJ_USDC, BIN_STEP, VERSION_V2_1, true);

        deal(FUJI_LFJ_USDC, address(this), 10e6);
        IERC20(FUJI_LFJ_USDC).approve(address(adapter), type(uint256).max);
        uint256 wavaxOut =
            adapter.swap(address(this), FUJI_LFJ_USDC, FUJI_WAVAX, 1e6, 1, abi.encode(BIN_STEP, VERSION_V2_1));
        assertGt(wavaxOut, 0);

        IERC20(FUJI_WAVAX).approve(address(adapter), type(uint256).max);
        uint256 usdcOut =
            adapter.swap(address(this), FUJI_WAVAX, FUJI_LFJ_USDC, wavaxOut, 1, abi.encode(BIN_STEP, VERSION_V2_1));
        assertGt(usdcOut, 0);
    }
}
