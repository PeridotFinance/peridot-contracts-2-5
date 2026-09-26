// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CollateralPreservingLifecycleTest} from "./CollateralPreservingLifecycle.t.sol";
import {PharaohCLBindingMock} from "./PharaohCLRouterAdapter.t.sol";
import {PharaohMarginBaseRouterMock} from "./PharaohMarginRouterAdapter.t.sol";
import {PharaohCLRouterAdapter, IPharaohCLRouter} from "../contracts/margin/PharaohCLRouterAdapter.sol";
import {PharaohMarginRouterAdapter} from "../contracts/margin/PharaohMarginRouterAdapter.sol";

/// @dev Local ABI bridge to the existing price-controlled mock venue, NOT a real
/// Pharaoh pool. Preserves decimal conversion, price shocks and execution knobs.
contract PharaohCLLifecycleRouterMock is IPharaohCLRouter {
    address public immutable deployer;
    address public immutable WETH9;
    PharaohMarginBaseRouterMock public immutable venue;

    constructor(address d, address w, PharaohMarginBaseRouterMock v) {
        deployer = d;
        WETH9 = w;
        venue = v;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(p.tickSpacing == 10 && p.sqrtPriceLimitX96 == 0 && p.deadline >= block.timestamp, "bad params");
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn));
        require(IERC20(p.tokenIn).approve(address(venue), p.amountIn));
        out = venue.swap(address(this), p.tokenIn, p.tokenOut, p.amountIn, p.amountOutMinimum, "");
        require(IERC20(p.tokenIn).approve(address(venue), 0));
        require(IERC20(p.tokenOut).transfer(p.recipient, out));
    }
}

/// @dev Runs the inherited 26 lifecycle tests through BOTH production adapters:
/// margin swap -> Pharaoh vault-share adapter -> Pharaoh CL adapter -> mock CL ABI.
/// Strategies, prices, bindings and terminal venue remain local mocks. This is
/// composability evidence, not proof of real Pharaoh liquidity/router behavior.
contract PharaohCLMarginLifecycleTest is CollateralPreservingLifecycleTest {
    PharaohCLRouterAdapter internal clAdapter;
    PharaohCLLifecycleRouterMock internal clRouter;

    function setUp() public override {
        super.setUp();
        PharaohCLBindingMock binding = new PharaohCLBindingMock(address(avax), address(usd));
        clRouter = new PharaohCLLifecycleRouterMock(address(binding), address(avax), router);
        clAdapter = new PharaohCLRouterAdapter(
            address(clRouter), address(binding), address(binding), address(avax), address(usd), 10
        );
        adapter = new PharaohMarginRouterAdapter(
            address(uVault), address(aVault), address(usd), address(avax), address(clAdapter)
        );
        config.queueExecutionEndpoints(address(adapter), config.flashLoanProvider());
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        config.setExecutionEndpoints(address(adapter), config.flashLoanProvider());
    }

    function testLifecyclePharaohAdapterCustodyAndApprovalCleanup() public {
        _enableStack();
        for (uint256 c; c < 2; ++c) {
            for (uint256 side; side < 2; ++side) {
                uint256 id = _openLife(c == 1, side == 1, 500);
                _closeLife(id, 5000);
                _closeLife(id, 10_000);
                address[2] memory tokens = [address(avax), address(usd)];
                for (uint256 i; i < 2; ++i) {
                    IERC20 token = IERC20(tokens[i]);
                    assertEq(token.balanceOf(address(clAdapter)), 0);
                    assertEq(token.balanceOf(address(clRouter)), 0);
                    assertEq(token.allowance(address(adapter), address(clAdapter)), 0);
                    assertEq(token.allowance(address(clAdapter), address(clRouter)), 0);
                    assertEq(token.allowance(address(clRouter), address(router)), 0);
                }
            }
        }
    }
}
