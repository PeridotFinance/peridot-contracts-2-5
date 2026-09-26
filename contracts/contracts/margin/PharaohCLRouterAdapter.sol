// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";

interface IPharaohCLRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function deployer() external view returns (address);
    function WETH9() external view returns (address);
    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256);
}

interface IPharaohCLFactory {
    function ramsesV3PoolDeployer() external view returns (address);
    function getPool(address, address, int24) external view returns (address);
}

interface IPharaohCLPool {
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function tickSpacing() external view returns (int24);
}

/// @notice Caller-funded, one-pool Pharaoh CL swaps for WAVAX/native USDC margin.
/// @dev Pins the router/factory/pool/tick spacing at deployment; no arbitrary paths,
/// recipient, callbacks, token approvals, or admin rescue. Router ABI uses int24
/// tick spacing, NOT Uniswap's uint24 fee tier. All oracle/slippage bounds remain
/// enforced by the upstream margin swap module. Changing venue requires a fresh
/// adapter and the existing margin configuration timelock.
contract PharaohCLRouterAdapter is IMarginRouterAdapter, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IPharaohCLRouter public immutable router;
    IPharaohCLFactory public immutable factory;
    address public immutable pool;
    address public immutable wavax;
    address public immutable usdc;
    address public immutable poolDeployer;
    int24 public immutable tickSpacing;

    error InvalidConfiguration();
    error InvalidSwap();
    error UnexpectedBalance();
    error InsufficientOutput();

    constructor(address router_, address factory_, address pool_, address wavax_, address usdc_, int24 spacing_) {
        if (
            router_.code.length == 0 || factory_.code.length == 0 || pool_.code.length == 0 || wavax_.code.length == 0
                || usdc_.code.length == 0 || wavax_ == usdc_ || spacing_ <= 0
        ) {
            revert InvalidConfiguration();
        }
        router = IPharaohCLRouter(router_);
        factory = IPharaohCLFactory(factory_);
        pool = pool_;
        wavax = wavax_;
        usdc = usdc_;
        tickSpacing = spacing_;
        poolDeployer = router.deployer();
        if (poolDeployer.code.length == 0) revert InvalidConfiguration();
        _checkBindings();
    }

    function swap(address from, address tokenIn, address tokenOut, uint256 amount, uint256 minimum, bytes calldata data)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (
            from != msg.sender || amount == 0 || minimum == 0 || data.length != 0
                || !((tokenIn == wavax && tokenOut == usdc) || (tokenIn == usdc && tokenOut == wavax))
        ) {
            revert InvalidSwap();
        }
        _checkBindings();
        IERC20 input = IERC20(tokenIn);
        IERC20 output = IERC20(tokenOut);
        uint256 inputBefore = input.balanceOf(address(this));
        uint256 outputBefore = output.balanceOf(from);
        input.safeTransferFrom(from, address(this), amount);
        if (input.balanceOf(address(this)) != inputBefore + amount) revert UnexpectedBalance();
        input.forceApprove(address(router), amount);
        uint256 reported = router.exactInputSingle(
            IPharaohCLRouter.ExactInputSingleParams(
                tokenIn, tokenOut, tickSpacing, from, block.timestamp + 5 minutes, amount, minimum, 0
            )
        );
        input.forceApprove(address(router), 0);
        out = output.balanceOf(from) - outputBefore;
        if (out < minimum) revert InsufficientOutput();
        // A partial-fill price-limit result must not strand input or use donations.
        if (out != reported || input.balanceOf(address(this)) != inputBefore) revert UnexpectedBalance();
    }

    function _checkBindings() private view {
        IPharaohCLPool p = IPharaohCLPool(pool);
        (address t0, address t1) = wavax < usdc ? (wavax, usdc) : (usdc, wavax);
        if (
            router.deployer() != poolDeployer || router.WETH9() != wavax
                || factory.ramsesV3PoolDeployer() != poolDeployer || factory.getPool(wavax, usdc, tickSpacing) != pool
                || p.factory() != address(factory) || p.token0() != t0 || p.token1() != t1
                || p.tickSpacing() != tickSpacing
        ) {
            revert InvalidConfiguration();
        }
    }
}
