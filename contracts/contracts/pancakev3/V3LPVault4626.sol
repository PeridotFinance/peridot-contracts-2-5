// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IPancakeV3MasterChef.sol";
import "./interfaces/IPancakeV3Pool.sol";
import "./libraries/FullMath.sol";
import "./libraries/FixedPoint96.sol";
import "./libraries/TickMath.sol";
import "./libraries/LiquidityAmounts.sol";
import "../margin/IMarginRouterAdapter.sol";

contract V3LPVault4626 is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct DepositParams {
        address receiver;
        address refundReceiver;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 minShares;
        uint256 deadline;
    }

    struct WithdrawParams {
        address receiver;
        address owner;
        uint256 shares;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct HarvestParams {
        uint256 rewardForToken0;
        uint256 rewardForToken1;
        uint256 minToken0Out;
        uint256 minToken1Out;
        bytes swapDataToken0;
        bytes swapDataToken1;
    }

    struct VaultConfig {
        INonfungiblePositionManager positionManager;
        IPancakeV3MasterChef masterChef;
        address pool;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 masterChefPid;
        bool stakeWithMasterChef;
        address routerAdapter;
        IERC20 rewardToken;
    }

    error SlippageExceeded();
    error InvalidConfiguration();
    error NotKeeperOrOwner();
    error SingleAssetNotSupported();

    IERC20 public immutable token0;
    IERC20 public immutable token1;
    IERC20 public immutable rewardToken;

    uint8 private immutable token0Decimals;
    uint8 private immutable token1Decimals;

    VaultConfig public config;
    uint256 public harvestMinToken0;
    uint256 public harvestMinToken1;
    uint256 public harvestThreshold;
    uint256 public lastHarvest;
    address public keeper;

    uint256 public totalManagedToken0;
    uint256 public totalManagedToken1;
    uint128 public totalLiquidity;
    uint256 public positionTokenId;

    event KeeperUpdated(address indexed newKeeper);
    event LiquidityAdded(
        address indexed caller,
        address indexed receiver,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1,
        uint128 liquidity,
        uint256 shares
    );
    event LiquidityRemoved(
        address indexed caller,
        address indexed owner,
        address indexed receiver,
        uint256 shares,
        uint256 amount0,
        uint256 amount1,
        uint128 liquidityBurned
    );
    event MasterChefStaked(uint256 indexed tokenId);
    event MasterChefUnstaked(uint256 indexed tokenId);
    event Harvested(uint256 rewardAmount, uint256 amount0, uint256 amount1);
    event HarvestConfigUpdated(
        uint256 minToken0,
        uint256 minToken1,
        uint256 threshold
    );
    event DustSwept(address indexed to, uint256 amount0, uint256 amount1);

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner() && msg.sender != keeper) {
            revert NotKeeperOrOwner();
        }
        _;
    }

    constructor(
        IERC20Metadata token0_,
        IERC20Metadata token1_,
        string memory name_,
        string memory symbol_,
        address owner_,
        VaultConfig memory config_
    ) ERC20(name_, symbol_) ERC4626(token0_) Ownable(owner_) {
        require(
            address(token0_) != address(0) && address(token1_) != address(0),
            "token zero"
        );
        if (
            address(config_.positionManager) == address(0) ||
            config_.pool == address(0)
        ) {
            revert InvalidConfiguration();
        }

        token0 = IERC20(address(token0_));
        token1 = IERC20(address(token1_));
        token0Decimals = token0_.decimals();
        token1Decimals = token1_.decimals();

        config = config_;
        if (config_.stakeWithMasterChef) {
            // Staking with MasterChef requires both masterChef and rewardToken
            if (
                address(config_.masterChef) == address(0) ||
                address(config_.rewardToken) == address(0)
            ) {
                revert InvalidConfiguration();
            }
        }
        // If there's a rewardToken but no staking, we need a routerAdapter to swap rewards
        // If there's no rewardToken, no routerAdapter is needed (no-rewards scenario like Monad)
        if (
            address(config_.rewardToken) != address(0) &&
            config_.routerAdapter == address(0)
        ) {
            revert InvalidConfiguration();
        }
        rewardToken = config_.rewardToken;
    }

    function previewDepositDual(
        uint256 amount0Desired,
        uint256 amount1Desired
    ) public view returns (uint256 shares) {
        if (amount0Desired == 0 && amount1Desired == 0) return 0;
        (uint160 sqrtPriceX96, ) = _currentSqrtPrice();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(config.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(config.tickUpper);

        uint128 liquidityAdded = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            amount0Desired,
            amount1Desired
        );
        if (liquidityAdded == 0) return 0;

        uint128 liquidityBefore = totalLiquidity;
        uint256 supply = totalSupply();
        if (supply == 0 || liquidityBefore == 0) {
            return uint256(liquidityAdded);
        }
        return (uint256(liquidityAdded) * supply) / liquidityBefore;
    }

    function previewWithdrawDual(
        uint256 shares
    ) public view returns (uint256 amount0, uint256 amount1) {
        uint256 supply = totalSupply();
        if (shares == 0 || supply == 0) {
            return (0, 0);
        }

        uint128 liquidityBurned = uint128(
            (uint256(totalLiquidity) * shares) / supply
        );
        if (liquidityBurned == 0) {
            return (0, 0);
        }

        (uint160 sqrtPriceX96, ) = _currentSqrtPrice();
        uint160 sqrtLower = TickMath.getSqrtRatioAtTick(config.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtRatioAtTick(config.tickUpper);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtLower,
            sqrtUpper,
            liquidityBurned
        );
    }

    function depositDual(
        DepositParams calldata params
    ) external nonReentrant whenNotPaused returns (uint256 shares) {
        address refundReceiver = params.refundReceiver == address(0)
            ? params.receiver
            : params.refundReceiver;

        token0.safeTransferFrom(
            msg.sender,
            address(this),
            params.amount0Desired
        );
        token1.safeTransferFrom(
            msg.sender,
            address(this),
            params.amount1Desired
        );

        uint128 liquidityBefore = totalLiquidity;
        (
            uint256 amount0Used,
            uint256 amount1Used,
            uint128 liquidityAdded
        ) = _addLiquidity(
                params.amount0Desired,
                params.amount1Desired,
                params.amount0Min,
                params.amount1Min,
                params.deadline
            );

        if (
            amount0Used < params.amount0Min || amount1Used < params.amount1Min
        ) {
            revert SlippageExceeded();
        }

        totalManagedToken0 += amount0Used;
        totalManagedToken1 += amount1Used;

        shares = _mintShares(
            params.receiver,
            liquidityAdded,
            liquidityBefore,
            params.minShares
        );
        totalLiquidity = liquidityBefore + liquidityAdded;

        _refundExcess(
            refundReceiver,
            params.amount0Desired,
            params.amount1Desired,
            amount0Used,
            amount1Used
        );

        emit LiquidityAdded(
            msg.sender,
            params.receiver,
            positionTokenId,
            amount0Used,
            amount1Used,
            liquidityAdded,
            shares
        );
    }

    function withdrawDual(
        WithdrawParams calldata params
    )
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amount0, uint256 amount1)
    {
        if (params.owner != msg.sender) {
            _spendAllowance(params.owner, msg.sender, params.shares);
        }

        uint128 liquidityBurned;
        (amount0, amount1, liquidityBurned) = _removeLiquidity(
            params.shares,
            params.amount0Min,
            params.amount1Min,
            params.deadline
        );

        _burn(params.owner, params.shares);

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert SlippageExceeded();
        }

        token0.safeTransfer(params.receiver, amount0);
        token1.safeTransfer(params.receiver, amount1);

        emit LiquidityRemoved(
            msg.sender,
            params.owner,
            params.receiver,
            params.shares,
            amount0,
            amount1,
            liquidityBurned
        );
    }

    /**
     * @notice Unstake NFT from MasterChef
     * @dev CRITICAL SECURITY: Always returns NFT to this vault (address(this)), not to an arbitrary address.
     *      Only owner can call (not keeper) to prevent NFT theft.
     */
    function unstakeFromMasterChef() external onlyOwner {
        require(config.stakeWithMasterChef, "staking disabled");
        require(positionTokenId != 0, "no position");

        // IMPORTANT: Always withdraw to address(this) to prevent NFT theft
        config.masterChef.withdraw(
            config.masterChefPid,
            positionTokenId,
            address(this)
        );
        config.stakeWithMasterChef = false;

        emit MasterChefUnstaked(positionTokenId);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    function configureHarvest(
        uint256 minToken0,
        uint256 minToken1,
        uint256 threshold
    ) external onlyOwner {
        harvestMinToken0 = minToken0;
        harvestMinToken1 = minToken1;
        harvestThreshold = threshold;
        emit HarvestConfigUpdated(minToken0, minToken1, threshold);
    }

    /**
     * @notice Sweep any leftover tokens that couldn't be added to liquidity.
     * @dev IMPORTANT: This should only sweep true "dust" - small amounts left over from rounding.
     *      To prevent abuse, we cap swept amounts to a maximum percentage of totalManagedTokens.
     *      Swept amounts are subtracted from totalManaged accounting to keep totalAssets() accurate.
     * @param to Address to send the dust tokens to.
     * @param maxAmount0 Maximum amount of token0 to sweep (safety check)
     * @param maxAmount1 Maximum amount of token1 to sweep (safety check)
     */
    function sweepDust(
        address to,
        uint256 maxAmount0,
        uint256 maxAmount1
    ) external onlyOwner {
        require(to != address(0), "zero address");

        uint256 dust0 = token0.balanceOf(address(this));
        uint256 dust1 = token1.balanceOf(address(this));

        // Safety: cap sweep to specified maximums
        if (dust0 > maxAmount0) dust0 = maxAmount0;
        if (dust1 > maxAmount1) dust1 = maxAmount1;

        // Safety: don't allow sweeping more than 1% of managed tokens
        uint256 maxSweep0 = totalManagedToken0 / 100;
        uint256 maxSweep1 = totalManagedToken1 / 100;
        if (dust0 > maxSweep0) dust0 = maxSweep0;
        if (dust1 > maxSweep1) dust1 = maxSweep1;

        if (dust0 > 0) {
            token0.safeTransfer(to, dust0);
            // Update accounting to reflect swept tokens
            totalManagedToken0 = totalManagedToken0 > dust0
                ? totalManagedToken0 - dust0
                : 0;
        }
        if (dust1 > 0) {
            token1.safeTransfer(to, dust1);
            // Update accounting to reflect swept tokens
            totalManagedToken1 = totalManagedToken1 > dust1
                ? totalManagedToken1 - dust1
                : 0;
        }

        emit DustSwept(to, dust0, dust1);
    }

    function harvestAndCompound(
        HarvestParams calldata params
    )
        external
        onlyKeeperOrOwner
        whenNotPaused
        returns (uint128 liquidityAdded)
    {
        require(positionTokenId != 0, "no position");

        if (address(config.masterChef) != address(0)) {
            config.masterChef.harvest(config.masterChefPid, address(this));
        }

        if (address(rewardToken) == address(0)) {
            return 0;
        }

        uint256 rewardBalance = rewardToken.balanceOf(address(this));
        require(rewardBalance >= harvestThreshold, "threshold");

        uint256 rewardForToken0 = params.rewardForToken0;
        uint256 rewardForToken1 = params.rewardForToken1;
        if (rewardForToken0 + rewardForToken1 == 0) {
            rewardForToken0 = rewardBalance / 2;
            rewardForToken1 = rewardBalance - rewardForToken0;
        } else {
            require(
                rewardForToken0 + rewardForToken1 <= rewardBalance,
                "reward excess"
            );
        }

        if (rewardForToken0 > 0) {
            _swapReward(
                address(token0),
                rewardForToken0,
                params.minToken0Out,
                params.swapDataToken0
            );
        }
        if (rewardForToken1 > 0) {
            _swapReward(
                address(token1),
                rewardForToken1,
                params.minToken1Out,
                params.swapDataToken1
            );
        }

        // Use ALL available tokens (including any leftover from previous harvests)
        // This prevents token dust from accumulating in the contract
        uint256 availableToken0 = token0.balanceOf(address(this));
        uint256 availableToken1 = token1.balanceOf(address(this));

        if (availableToken0 == 0 && availableToken1 == 0) {
            return 0;
        }

        (
            uint256 amount0Used,
            uint256 amount1Used,
            uint128 liquidity
        ) = _addLiquidity(
                availableToken0,
                availableToken1,
                harvestMinToken0,
                harvestMinToken1,
                block.timestamp
            );

        if (liquidity == 0) {
            return 0;
        }

        totalManagedToken0 += amount0Used;
        totalManagedToken1 += amount1Used;
        totalLiquidity += liquidity;
        lastHarvest = block.timestamp;

        emit Harvested(
            rewardForToken0 + rewardForToken1,
            amount0Used,
            amount1Used
        );
        return liquidity;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ========== ERC4626 SINGLE-ASSET OVERRIDES (DISABLED) ==========
    // V3 LP positions require dual-token deposits. Single-asset ERC4626
    // functions are disabled to prevent misuse. Use depositDual/withdrawDual.

    function deposit(uint256, address) public pure override returns (uint256) {
        revert SingleAssetNotSupported();
    }

    function mint(uint256, address) public pure override returns (uint256) {
        revert SingleAssetNotSupported();
    }

    function withdraw(
        uint256,
        address,
        address
    ) public pure override returns (uint256) {
        revert SingleAssetNotSupported();
    }

    function redeem(
        uint256,
        address,
        address
    ) public pure override returns (uint256) {
        revert SingleAssetNotSupported();
    }

    function maxDeposit(address) public pure override returns (uint256) {
        return 0; // Single-asset deposit not supported
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0; // Single-asset mint not supported
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        // Return the token0-equivalent value that can be withdrawn via withdrawDual
        uint256 shares = balanceOf(owner);
        if (shares == 0) return 0;
        (uint256 amount0, ) = previewWithdrawDual(shares);
        return amount0;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return balanceOf(owner);
    }

    function previewDeposit(uint256) public pure override returns (uint256) {
        return 0; // Single-asset deposit not supported
    }

    function previewMint(uint256) public pure override returns (uint256) {
        return 0; // Single-asset mint not supported
    }

    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256) {
        // Estimate shares needed to withdraw this amount of token0-equivalent value
        return convertToShares(assets);
    }

    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256) {
        return convertToAssets(shares);
    }

    function pool() external view returns (address) {
        return config.pool;
    }

    function totalAssets() public view override returns (uint256) {
        return _valueOf(totalManagedToken0, totalManagedToken1);
    }

    function convertToAssets(
        uint256 shares
    ) public view override returns (uint256 assets) {
        (uint256 amount0, uint256 amount1) = previewWithdrawDual(shares);
        assets = _valueOf(amount0, amount1);
    }

    function convertToShares(
        uint256 assets
    ) public view override returns (uint256 shares) {
        uint256 supply = totalSupply();
        if (supply == 0 || assets == 0) {
            return assets;
        }
        uint256 totalAssetValue = totalAssets();
        if (totalAssetValue == 0) {
            return 0;
        }
        return (assets * supply) / totalAssetValue;
    }

    function _mintShares(
        address receiver,
        uint128 liquidityAdded,
        uint128 liquidityBefore,
        uint256 minShares
    ) internal returns (uint256 shares) {
        uint256 supply = totalSupply();
        if (supply == 0 || liquidityBefore == 0) {
            shares = uint256(liquidityAdded);
        } else {
            shares = (uint256(liquidityAdded) * supply) / liquidityBefore;
        }
        if (shares < minShares) {
            revert SlippageExceeded();
        }
        _mint(receiver, shares);
    }

    function _refundExcess(
        address receiver,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Used,
        uint256 amount1Used
    ) internal {
        if (amount0Desired > amount0Used) {
            token0.safeTransfer(receiver, amount0Desired - amount0Used);
        }
        if (amount1Desired > amount1Used) {
            token1.safeTransfer(receiver, amount1Desired - amount1Used);
        }
    }

    function _swapReward(
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory data
    ) internal returns (uint256 amountOut) {
        if (amountIn == 0) {
            return 0;
        }

        if (address(rewardToken) == tokenOut) {
            require(amountIn >= minAmountOut, "reward min");
            return amountIn;
        }

        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        rewardToken.forceApprove(config.routerAdapter, amountIn);
        IMarginRouterAdapter(config.routerAdapter).swap(
            address(this),
            address(rewardToken),
            tokenOut,
            amountIn,
            minAmountOut,
            data
        );
        rewardToken.forceApprove(config.routerAdapter, 0);
        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        amountOut = balanceAfter - balanceBefore;
        require(amountOut >= minAmountOut, "swap output");
    }

    function _addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) internal returns (uint256 amount0, uint256 amount1, uint128 liquidity) {
        INonfungiblePositionManager positionManager = config.positionManager;
        token0.forceApprove(address(positionManager), amount0Desired);
        token1.forceApprove(address(positionManager), amount1Desired);

        if (positionTokenId == 0) {
            INonfungiblePositionManager.MintParams
                memory params = INonfungiblePositionManager.MintParams({
                    token0: address(token0),
                    token1: address(token1),
                    fee: config.fee,
                    tickLower: config.tickLower,
                    tickUpper: config.tickUpper,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    recipient: address(this),
                    deadline: deadline
                });

            uint256 tokenId;
            (tokenId, liquidity, amount0, amount1) = positionManager.mint(
                params
            );
            positionTokenId = tokenId;

            if (config.stakeWithMasterChef) {
                config.masterChef.deposit(
                    config.masterChefPid,
                    tokenId,
                    address(this)
                );
                emit MasterChefStaked(tokenId);
            }
        } else {
            INonfungiblePositionManager.IncreaseLiquidityParams
                memory paramsInc = INonfungiblePositionManager
                    .IncreaseLiquidityParams({
                        tokenId: positionTokenId,
                        amount0Desired: amount0Desired,
                        amount1Desired: amount1Desired,
                        amount0Min: amount0Min,
                        amount1Min: amount1Min,
                        deadline: deadline
                    });

            (liquidity, amount0, amount1) = positionManager.increaseLiquidity(
                paramsInc
            );
        }

        token0.forceApprove(address(positionManager), 0);
        token1.forceApprove(address(positionManager), 0);
    }

    function _removeLiquidity(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    )
        internal
        returns (uint256 amount0, uint256 amount1, uint128 liquidityBurned)
    {
        require(positionTokenId != 0, "no position");
        uint128 liquidityBefore = totalLiquidity;
        require(liquidityBefore > 0, "no liquidity");

        uint256 supply = totalSupply();
        liquidityBurned = uint128((uint256(liquidityBefore) * shares) / supply);
        require(liquidityBurned > 0, "zero liquidity burn");

        INonfungiblePositionManager positionManager = config.positionManager;

        // Record balances BEFORE decreaseLiquidity to correctly calculate fees
        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        INonfungiblePositionManager.DecreaseLiquidityParams
            memory params = INonfungiblePositionManager
                .DecreaseLiquidityParams({
                    tokenId: positionTokenId,
                    liquidity: liquidityBurned,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: deadline
                });

        (amount0, amount1) = positionManager.decreaseLiquidity(params);

        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // Calculate fees correctly: (balance after collect) - (balance before) - (burned liquidity amounts)
        // This excludes any pre-existing tokens that were sitting in the contract
        uint256 balance0After = token0.balanceOf(address(this));
        uint256 balance1After = token1.balanceOf(address(this));
        uint256 fee0 = (balance0After - balance0Before) - amount0;
        uint256 fee1 = (balance1After - balance1Before) - amount1;

        totalLiquidity = liquidityBefore - liquidityBurned;

        // Update managed tokens accounting correctly:
        // New managed = old managed - principal + fees
        // Handle underflow safely (shouldn't happen in normal operation but be defensive)
        if (amount0 <= totalManagedToken0) {
            totalManagedToken0 = (totalManagedToken0 - amount0) + fee0;
        } else {
            // Defensive: if amount0 > totalManagedToken0, just set to fees
            // This should not happen in normal operation
            totalManagedToken0 = fee0;
        }

        if (amount1 <= totalManagedToken1) {
            totalManagedToken1 = (totalManagedToken1 - amount1) + fee1;
        } else {
            // Defensive: if amount1 > totalManagedToken1, just set to fees
            // This should not happen in normal operation
            totalManagedToken1 = fee1;
        }
    }

    function _currentSqrtPrice()
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick)
    {
        (sqrtPriceX96, tick, , , , , ) = IPancakeV3Pool(config.pool).slot0();
    }

    function _valueOf(
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint256) {
        if (amount0 == 0 && amount1 == 0) return 0;
        (uint160 sqrtPriceX96, ) = _currentSqrtPrice();
        uint256 priceX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        uint256 token1InToken0 = amount1 == 0
            ? 0
            : FullMath.mulDiv(amount1, FixedPoint96.Q192, priceX192);
        uint256 totalToken0 = amount0 + token1InToken0;
        return _scaleTo1e18(totalToken0, token0Decimals);
    }

    function _scaleTo1e18(
        uint256 amount,
        uint8 decimals
    ) internal pure returns (uint256) {
        if (decimals == 18) {
            return amount;
        } else if (decimals > 18) {
            return amount / 10 ** (decimals - 18);
        } else {
            return amount * 10 ** (18 - decimals);
        }
    }
}
