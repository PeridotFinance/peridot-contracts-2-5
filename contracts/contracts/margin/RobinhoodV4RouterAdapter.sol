// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMarginRouterAdapter} from "./IMarginRouterAdapter.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline)
        external
        payable;
}

interface IPermit2Allowance {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/**
 * @title RobinhoodV4RouterAdapter
 * @notice Margin swap seam for Robinhood Chain, routing single-hop Uniswap v4 swaps through the
 *         deployed Universal Router.
 * @dev Types are declared locally rather than imported. This repository carries no Uniswap v4
 *      dependency, and pulling in v4-core, v4-periphery, permit2 and universal-router for one
 *      adapter would be disproportionate and would add cross-repo version-pinning risk. The
 *      QuickSwap adapter declares its Algebra types the same way.
 *
 *      The encoding below is deliberately copied from `UniswapV4PairedAdapter` in the vault
 *      repository, which is exercised against this exact router by a pinned fork test. Robinhood's
 *      deployed Universal Router uses the newer v4 swap ABI carrying `minHopPriceX36`, which the
 *      pinned PositionManager release predates; deriving the struct from a stock v4-periphery
 *      version instead produces a shape the router cannot decode and every swap reverts.
 *
 *      v4 identifies a pool by its full `PoolKey`, not by a token pair, so pools are registered
 *      explicitly rather than looked up from a factory.
 */
contract RobinhoodV4RouterAdapter is IMarginRouterAdapter, Ownable {
    using SafeERC20 for IERC20;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;

    uint8 private constant COMMAND_V4_SWAP = 0x10;
    uint8 private constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 private constant ACTION_SETTLE_ALL = 0x0c;
    uint8 private constant ACTION_TAKE_ALL = 0x0f;

    /// @dev Mirrors v4-core's PoolKey. `Currency` and `IHooks` are address-wrapped value types,
    ///      so plain addresses encode identically.
    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    /// @dev Mirrors the deployed router's exact swap-parameter encoding, including
    ///      `minHopPriceX36`. Do not reorder or drop fields.
    struct RouterExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint256 minHopPriceX36;
        bytes hookData;
    }

    uint256 private constant PRICE_X36 = 1e36;

    IUniversalRouter public router;
    IPermit2Allowance public permit2;
    address public manager;

    mapping(bytes32 => PoolKey) private _pools;
    mapping(bytes32 => bool) public pairRegistered;
    mapping(address => bool) public operators;
    uint256 public deadlineBuffer = 300;

    error NotOperator();
    error PairNotRegistered();
    error ZeroAmount();
    error InsufficientOutput();
    error InvalidConfiguration();
    error ResidualAllowance();

    event RouterUpdated(address indexed router, address indexed permit2);
    event ManagerUpdated(address indexed manager);
    event OperatorUpdated(address indexed operator, bool allowed);
    event PoolRegistered(address indexed token0, address indexed token1, uint24 fee, int24 tickSpacing);
    event PoolRemoved(address indexed token0, address indexed token1);
    event DeadlineBufferUpdated(uint256 buffer);

    modifier onlyOperator() {
        if (msg.sender != manager && !operators[msg.sender]) revert NotOperator();
        _;
    }

    constructor(address owner_, address router_, address permit2_) Ownable(owner_) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "RobinhoodAdapter: Robinhood only");
        if (owner_ == address(0) || router_.code.length == 0 || permit2_.code.length == 0) {
            revert InvalidConfiguration();
        }
        router = IUniversalRouter(router_);
        permit2 = IPermit2Allowance(permit2_);
        emit RouterUpdated(router_, permit2_);
    }

    function setRouter(address router_, address permit2_) external onlyOwner {
        if (router_.code.length == 0 || permit2_.code.length == 0) revert InvalidConfiguration();
        router = IUniversalRouter(router_);
        permit2 = IPermit2Allowance(permit2_);
        emit RouterUpdated(router_, permit2_);
    }

    function setManager(address manager_) external onlyOwner {
        manager = manager_;
        emit ManagerUpdated(manager_);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function setDeadlineBuffer(uint256 buffer) external onlyOwner {
        if (buffer == 0 || buffer > 1 hours) revert InvalidConfiguration();
        deadlineBuffer = buffer;
        emit DeadlineBufferUpdated(buffer);
    }

    /**
     * @notice Registers the pool a token pair swaps through.
     * @dev v4 pools are identified by the full key, so the fee, tick spacing and hooks must be
     *      pinned here rather than discovered. Only zero-hook pools are accepted: a hooked pool
     *      can reprice or reject a swap in ways this adapter's output floor does not model.
     */
    function registerPool(address currency0, address currency1, uint24 fee, int24 tickSpacing)
        external
        onlyOwner
    {
        if (currency0 >= currency1 || currency0 == address(0)) revert InvalidConfiguration();
        if (currency0.code.length == 0 || currency1.code.length == 0) revert InvalidConfiguration();
        bytes32 key = _pairKey(currency0, currency1);
        _pools[key] = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: address(0)
        });
        pairRegistered[key] = true;
        emit PoolRegistered(currency0, currency1, fee, tickSpacing);
    }

    function removePool(address tokenA, address tokenB) external onlyOwner {
        bytes32 key = _pairKey(tokenA, tokenB);
        delete _pools[key];
        delete pairRegistered[key];
        emit PoolRemoved(tokenA, tokenB);
    }

    function poolFor(address tokenA, address tokenB) external view returns (PoolKey memory) {
        return _pools[_pairKey(tokenA, tokenB)];
    }

    /**
     * @inheritdoc IMarginRouterAdapter
     * @dev `data` is an optional abi-encoded `uint256` deadline; zero or empty uses
     *      `block.timestamp + deadlineBuffer`.
     *
     *      `minAmountOut` is enforced three times over: as the router's `amountOutMinimum`, as an
     *      equivalent per-hop price floor via `minHopPriceX36`, and finally against the measured
     *      balance delta. The last check is the one that cannot be talked around by the router.
     */
    function swap(
        address fromAccount,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata data
    ) external override onlyOperator returns (uint256 amountOut) {
        if (amountIn == 0 || minAmountOut == 0) revert ZeroAmount();
        if (amountIn > type(uint128).max || minAmountOut > type(uint128).max) revert ZeroAmount();

        bytes32 key = _pairKey(tokenIn, tokenOut);
        if (!pairRegistered[key]) revert PairNotRegistered();
        PoolKey memory poolKey = _pools[key];

        uint256 deadline = data.length == 32 ? abi.decode(data, (uint256)) : 0;
        if (deadline == 0) deadline = block.timestamp + deadlineBuffer;

        uint256 minHopPriceX36 = (minAmountOut * PRICE_X36) / amountIn;
        if (minHopPriceX36 == 0) revert InvalidConfiguration();

        IERC20 inToken = IERC20(tokenIn);
        IERC20 outToken = IERC20(tokenOut);
        uint256 inStart = inToken.balanceOf(address(this));
        uint256 outStart = outToken.balanceOf(address(this));

        inToken.safeTransferFrom(fromAccount, address(this), amountIn);
        _approveExact(tokenIn, amountIn, deadline);

        _execute(poolKey, tokenIn, amountIn, minAmountOut, minHopPriceX36, deadline);

        _revokeExact(tokenIn);

        uint256 inAfter = inToken.balanceOf(address(this));
        uint256 outAfter = outToken.balanceOf(address(this));
        if (inAfter < inStart || outAfter < outStart) revert InsufficientOutput();
        amountOut = outAfter - outStart;
        if (amountOut < minAmountOut) revert InsufficientOutput();

        // Return the output and any unspent input; this adapter never retains balances.
        outToken.safeTransfer(fromAccount, amountOut);
        uint256 refund = inAfter - inStart;
        if (refund != 0) inToken.safeTransfer(fromAccount, refund);
    }

    function _execute(
        PoolKey memory poolKey,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 minHopPriceX36,
        uint256 deadline
    ) private {
        bool zeroForOne = tokenIn == poolKey.currency0;
        address outputCurrency = zeroForOne ? poolKey.currency1 : poolKey.currency0;
        address inputCurrency = zeroForOne ? poolKey.currency0 : poolKey.currency1;

        bytes memory commands = abi.encodePacked(COMMAND_V4_SWAP);
        bytes memory actions =
            abi.encodePacked(ACTION_SWAP_EXACT_IN_SINGLE, ACTION_SETTLE_ALL, ACTION_TAKE_ALL);

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            RouterExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                amountIn: uint128(amountIn),
                amountOutMinimum: uint128(minAmountOut),
                minHopPriceX36: minHopPriceX36,
                hookData: bytes("")
            })
        );
        // SETTLE_ALL treats its value as a ceiling on the open debt. An unbounded ceiling is safe
        // here because the exact-input action and the Permit2 allowance both cap what can be
        // pulled, and the balance delta above is checked afterwards regardless.
        params[1] = abi.encode(inputCurrency, type(uint256).max);
        params[2] = abi.encode(outputCurrency, minAmountOut);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        router.execute(commands, inputs, deadline);
    }

    /// @dev The Universal Router pulls through Permit2, so the ERC-20 allowance goes to Permit2
    ///      and Permit2 is granted a router allowance for exactly this amount.
    function _approveExact(address token, uint256 amount, uint256 deadline) private {
        IERC20(token).forceApprove(address(permit2), amount);
        permit2.approve(token, address(router), uint160(amount), uint48(deadline));
    }

    function _revokeExact(address token) private {
        permit2.approve(token, address(router), 0, 0);
        IERC20(token).forceApprove(address(permit2), 0);
        (uint160 remaining,,) = permit2.allowance(address(this), token, address(router));
        if (remaining != 0 || IERC20(token).allowance(address(this), address(permit2)) != 0) {
            revert ResidualAllowance();
        }
    }

    function _pairKey(address tokenA, address tokenB) private pure returns (bytes32) {
        return tokenA < tokenB ? keccak256(abi.encode(tokenA, tokenB)) : keccak256(abi.encode(tokenB, tokenA));
    }
}
