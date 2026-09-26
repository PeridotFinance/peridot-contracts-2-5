// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IPharaohCLRouter} from "../PharaohCLRouterAdapter.sol";
import {FujiMockToken} from "./FujiMockAssets.sol";
import {FujiMockSwapAdapter} from "./FujiMockSwapAdapter.sol";

/// @notice TEST shares only: no Pharaoh LP, yield strategy, USDt or sAVAX exposure.
contract FujiMockPharaohVault is ERC4626, Ownable {
    bool public constant IS_FUJI_MOCK = true;
    bool public depositsClosed;
    bool public redemptionsClosed;

    constructor(address owner_, FujiMockToken asset_)
        ERC20("MOCK Pharaoh collateral - Fuji only", "mockPHAR")
        ERC4626(IERC20(address(asset_)))
        Ownable(owner_)
    {
        require(block.chainid == 43_113 && asset_.IS_FUJI_MOCK(), "FujiPharaoh: mock Fuji only");
    }

    function setLimits(bool deposits, bool redemptions) external onlyOwner {
        depositsClosed = deposits;
        redemptionsClosed = redemptions;
    }

    function maxDeposit(address) public view override returns (uint256) {
        return depositsClosed ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return depositsClosed ? 0 : type(uint256).max;
    }

    function maxWithdraw(address holder) public view override returns (uint256) {
        return redemptionsClosed ? 0 : super.maxWithdraw(holder);
    }

    function maxRedeem(address holder) public view override returns (uint256) {
        return redemptionsClosed ? 0 : balanceOf(holder);
    }
}

/// @notice Immutable TEST factory/pool binding for the production CL adapter.
contract FujiMockPharaohBinding {
    bool public constant IS_FUJI_MOCK = true;
    address public immutable token0;
    address public immutable token1;
    int24 public constant tickSpacing = 10;

    constructor(address a, address b) {
        require(block.chainid == 43_113 && a != b, "FujiPharaoh: mock Fuji only");
        require(FujiMockToken(a).IS_FUJI_MOCK() && FujiMockToken(b).IS_FUJI_MOCK(), "FujiPharaoh: assets");
        (token0, token1) = a < b ? (a, b) : (b, a);
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function ramsesV3PoolDeployer() external view returns (address) {
        return address(this);
    }

    function getPool(address a, address b, int24 spacing) external view returns (address) {
        return spacing == tickSpacing && ((a == token0 && b == token1) || (a == token1 && b == token0))
            ? address(this)
            : address(0);
    }
}

/// @notice TEST CL-ABI bridge, not a concentrated-liquidity pool or real Pharaoh router.
/// @dev Uses the funded, owner-controlled mock feed venue. Both production adapters
/// remain in the execution path. Only the once-pinned CL adapter can call this bridge.
contract FujiMockPharaohRouter is IPharaohCLRouter, Ownable {
    using SafeERC20 for IERC20;
    bool public constant IS_FUJI_MOCK = true;
    address public immutable deployer;
    address public immutable WETH9;
    FujiMockSwapAdapter public immutable venue;
    address public operator;

    constructor(address owner_, address binding, FujiMockSwapAdapter venue_) Ownable(owner_) {
        require(block.chainid == 43_113 && venue_.IS_FUJI_MOCK(), "FujiPharaoh: mock Fuji only");
        require(FujiMockPharaohBinding(binding).IS_FUJI_MOCK() && venue_.owner() == owner_, "FujiPharaoh: bindings");
        deployer = binding;
        WETH9 = address(venue_.mockAvax());
        venue = venue_;
    }

    function setOperator(address value) external onlyOwner {
        require(operator == address(0) && value.code.length > 0, "FujiPharaoh: operator");
        operator = value;
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256 out) {
        require(msg.sender == operator && msg.value == 0, "FujiPharaoh: caller");
        require(p.tickSpacing == 10 && p.sqrtPriceLimitX96 == 0 && p.deadline >= block.timestamp, "FujiPharaoh: path");
        require(p.recipient != address(0) && p.amountIn > 0 && p.amountOutMinimum > 0, "FujiPharaoh: amounts");
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenIn).forceApprove(address(venue), p.amountIn);
        out = venue.swap(address(this), p.tokenIn, p.tokenOut, p.amountIn, p.amountOutMinimum, "");
        IERC20(p.tokenIn).forceApprove(address(venue), 0);
        IERC20(p.tokenOut).safeTransfer(p.recipient, out);
    }
}
