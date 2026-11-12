// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IPharaohFactory} from "./interfaces/pharaoh/IPharaohFactory.sol";
import {IPharaohPool} from "./interfaces/pharaoh/IPharaohPool.sol";
import {IPharaohPositionManager} from "./interfaces/pharaoh/IPharaohPositionManager.sol";
import {IPharaohSwapRouter} from "./interfaces/pharaoh/IPharaohSwapRouter.sol";
import {IPharaohVaultOracle} from "./interfaces/pharaoh/IPharaohVaultOracle.sol";
import {PharaohLiquidityAmounts} from "./libraries/PharaohLiquidityAmounts.sol";
import {PharaohOracleMath} from "./libraries/PharaohOracleMath.sol";
import {PharaohTickMath} from "./libraries/PharaohTickMath.sol";

/// @title PharaohLiquidityVault
/// @notice Pharaoh concentrated-liquidity strategy exposed as an ERC-4626 vault.
/// @dev One deployment manages one NFT position. The ERC-4626 asset must be one
///      side of the configured pool; the other side is valued by an independent
///      oracle. Intended vault shares can be used as lending-market collateral.
contract PharaohLiquidityVault is
    Initializable,
    ERC4626Upgradeable,
    OwnableUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant MIN_EXECUTION_BUFFER_BPS = 25;
    int24 private constant MIN_TICK = -887272;
    int24 private constant MAX_TICK = 887272;
    bytes32 private constant ERC1967_ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    struct InitParams {
        string name;
        string symbol;
        IERC20 asset;
        IPharaohFactory factory;
        IPharaohPool pool;
        IPharaohPositionManager positionManager;
        IPharaohSwapRouter swapRouter;
        IPharaohVaultOracle priceOracle;
        address owner;
        address rebalancer;
        uint256 depositCap;
        int24 tickRange;
        uint32 twapPeriod;
        uint24 maxTwapDeviationTicks;
        uint16 maxOracleDeviationBps;
        uint16 slippageBps;
        uint16 valuationHaircutBps;
    }

    error Vault__ZeroAddress();
    error Vault__ZeroAmount();
    error Vault__InvalidAsset();
    error Vault__InvalidPool();
    error Vault__InvalidOracle();
    error Vault__InvalidConfiguration();
    error Vault__NotRebalancer();
    error Vault__DepositCapExceeded(uint256 cap, uint256 attemptedTotal);
    error Vault__PriceDeviation(int24 spotTick, int24 twapTick);
    error Vault__OracleDeviation(uint256 poolQuote, uint256 oracleQuote);
    error Vault__PositionNeedsRebalance();
    error Vault__InsufficientShares(uint256 actual, uint256 minimum);
    error Vault__InsufficientAssets(uint256 available, uint256 required);
    error Vault__ExcessiveLoss(uint256 valueBefore, uint256 valueAfter);

    event Rebalanced(
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        int24 tickLower,
        int24 tickUpper,
        uint256 valueBefore,
        uint256 valueAfter
    );
    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);
    event DepositCapUpdated(uint256 oldCap, uint256 newCap);
    event EmergencyExited(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    IPharaohPool public pool;
    IPharaohPositionManager public positionManager;
    IPharaohSwapRouter public swapRouter;
    IPharaohVaultOracle public priceOracle;

    IERC20 public token0;
    IERC20 public token1;
    IERC20 public pairedToken;
    bool public assetIsToken0;
    int24 public tickSpacing;
    uint128 public pairedTokenUnit;

    uint256 public tokenId;
    int24 public positionTickLower;
    int24 public positionTickUpper;

    address public rebalancer;
    uint256 public depositCap;
    int24 public tickRange;
    uint32 public twapPeriod;
    uint24 public maxTwapDeviationTicks;
    uint16 public maxOracleDeviationBps;
    uint16 public slippageBps;
    uint16 public valuationHaircutBps;

    constructor() {
        _disableInitializers();
    }

    function initialize(InitParams calldata params) external initializer {
        if (
            address(params.asset) == address(0) || address(params.factory) == address(0)
                || address(params.pool) == address(0) || address(params.positionManager) == address(0)
                || address(params.swapRouter) == address(0) || address(params.priceOracle) == address(0)
                || params.owner == address(0) || params.rebalancer == address(0)
        ) revert Vault__ZeroAddress();

        __ERC20_init(params.name, params.symbol);
        __ERC4626_init(params.asset);
        __Ownable_init(params.owner);
        __Pausable_init();
        __ReentrancyGuard_init();

        address poolToken0 = params.pool.token0();
        address poolToken1 = params.pool.token1();
        if (poolToken0 == address(0) || poolToken1 == address(0) || poolToken0 == poolToken1) {
            revert Vault__InvalidPool();
        }
        if (address(params.asset) != poolToken0 && address(params.asset) != poolToken1) {
            revert Vault__InvalidAsset();
        }

        int24 poolTickSpacing = params.pool.tickSpacing();
        if (
            params.pool.factory() != address(params.factory)
                || params.factory.getPool(poolToken0, poolToken1, poolTickSpacing) != address(params.pool)
        ) revert Vault__InvalidPool();

        address poolDeployer = params.factory.ramsesV3PoolDeployer();
        if (
            poolDeployer == address(0) || params.positionManager.deployer() != poolDeployer
                || params.swapRouter.deployer() != poolDeployer
        ) revert Vault__InvalidPool();

        address pairToken = address(params.asset) == poolToken0 ? poolToken1 : poolToken0;
        if (params.priceOracle.asset() != address(params.asset) || params.priceOracle.pairedToken() != pairToken) {
            revert Vault__InvalidOracle();
        }

        uint8 pairDecimals = IERC20Metadata(pairToken).decimals();
        if (pairDecimals > 18) revert Vault__InvalidConfiguration();

        pool = params.pool;
        positionManager = params.positionManager;
        swapRouter = params.swapRouter;
        priceOracle = params.priceOracle;
        token0 = IERC20(poolToken0);
        token1 = IERC20(poolToken1);
        pairedToken = IERC20(pairToken);
        assetIsToken0 = address(params.asset) == poolToken0;
        tickSpacing = poolTickSpacing;
        pairedTokenUnit = uint128(10 ** pairDecimals);
        rebalancer = params.rebalancer;
        depositCap = params.depositCap;

        _setRiskParameters(
            params.tickRange,
            params.twapPeriod,
            params.maxTwapDeviationTicks,
            params.maxOracleDeviationBps,
            params.slippageBps,
            params.valuationHaircutBps
        );

        // Launches stay closed until the owner atomically unpauses and seeds
        // the vault after the Pharaoh TWAP buffer has warmed.
        _pause();
    }

    modifier onlyRebalancer() {
        if (msg.sender != rebalancer && msg.sender != owner()) revert Vault__NotRebalancer();
        _;
    }

    /// @dev Enables an atomic TransparentUpgradeableProxy migration. The
    ///      generated ProxyAdmin can reach the implementation only while
    ///      executing upgradeAndCall and is itself owned by governance.
    modifier onlyOwnerOrProxyAdmin() {
        address proxyAdmin = StorageSlot.getAddressSlot(ERC1967_ADMIN_SLOT).value;
        if (msg.sender != owner() && msg.sender != proxyAdmin) revert OwnableUnauthorizedAccount(msg.sender);
        _;
    }

    // ---------------------------------------------------------------------
    // ERC-4626 accounting and entry/exit
    // ---------------------------------------------------------------------

    /// @notice Conservative managed value. Accrued-but-uncollected fees and
    ///         non-pair reward tokens are deliberately excluded.
    function totalAssets() public view override returns (uint256) {
        (, int24 valuationTick,,) = _checkPrice();
        (uint256 amount0, uint256 amount1) = _managedTokenAmounts(valuationTick);
        uint256 assetAmount = assetIsToken0 ? amount0 : amount1;
        uint256 pairAmount = assetIsToken0 ? amount1 : amount0;
        if (pairAmount == 0) return assetAmount;

        uint256 pairedValue = priceOracle.quotePairToAsset(pairAmount);
        pairedValue = Math.mulDiv(pairedValue, BPS - valuationHaircutBps, BPS);
        return assetAmount + pairedValue;
    }

    function _managedTokenAmounts(int24 valuationTick) private view returns (uint256 amount0, uint256 amount1) {
        amount0 = token0.balanceOf(address(this));
        amount1 = token1.balanceOf(address(this));
        if (tokenId == 0) return (amount0, amount1);

        (int24 lower, int24 upper, uint128 liquidity) = _position();
        if (liquidity == 0) return (amount0, amount1);

        uint160 valuationSqrtPriceX96 = PharaohTickMath.getSqrtRatioAtTick(valuationTick);
        (uint256 principal0, uint256 principal1) = PharaohLiquidityAmounts.getAmountsForLiquidity(
            valuationSqrtPriceX96,
            PharaohTickMath.getSqrtRatioAtTick(lower),
            PharaohTickMath.getSqrtRatioAtTick(upper),
            liquidity
        );
        amount0 += principal0;
        amount1 += principal1;
    }

    function _position() private view returns (int24 lower, int24 upper, uint128 liquidity) {
        if (tokenId == 0) return (0, 0, 0);
        (,,, lower, upper, liquidity,,,,) = positionManager.positions(tokenId);
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused()) return 0;
        if (depositCap == 0) return type(uint256).max;
        uint256 managed = totalAssets();
        return managed >= depositCap ? 0 : depositCap - managed;
    }

    /// @dev Exact-share minting is disabled because strategy execution makes
    ///      the net contribution knowable only after the asset amount executes.
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev A sole remaining holder exits with redeem(), which can return the
    ///      complete realized portfolio. Keeping one share out of withdraw()
    ///      prevents paired-token dust from becoming ownerless after an exact
    ///      asset withdrawal.
    function maxWithdraw(address owner_) public view override returns (uint256) {
        uint256 ownerShares = balanceOf(owner_);
        if (ownerShares == 0) return 0;
        if (ownerShares == totalSupply()) {
            if (ownerShares == 1) return 0;
            return _convertToAssets(ownerShares - 1, Math.Rounding.Floor);
        }
        return _convertToAssets(ownerShares, Math.Rounding.Floor);
    }

    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return _convertToShares(_applyEntryLoss(assets), Math.Rounding.Floor);
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        if (assets == 0) revert Vault__ZeroAmount();
        _collectFees();

        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) revert Vault__DepositCapExceeded(depositCap, totalAssets() + assets);

        uint256 minimumShares = previewDeposit(assets);
        shares = _executeDeposit(assets, receiver, minimumShares);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert Vault__ZeroAmount();
        _collectFees();
        _checkPrice();

        uint256 maxAssets = maxWithdraw(owner_);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner_, assets, maxAssets);
        shares = _convertToShares(assets, Math.Rounding.Ceil);

        uint256 supply = totalSupply();
        _spendSharesAllowance(owner_, shares);
        _burn(owner_, shares);
        _freeLiquidity(shares, supply, Math.Rounding.Ceil);
        _ensureAssetBalance(assets);

        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner_)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        _collectFees();
        _checkPrice();
        if (shares > maxRedeem(owner_)) {
            revert ERC4626ExceededMaxRedeem(owner_, shares, maxRedeem(owner_));
        }

        uint256 supply = totalSupply();
        assets = _convertToAssets(shares, Math.Rounding.Floor);
        _spendSharesAllowance(owner_, shares);
        _burn(owner_, shares);
        _freeLiquidity(shares, supply, Math.Rounding.Ceil);

        if (shares == supply) {
            _swapAllPairedToAsset();
            assets = IERC20(asset()).balanceOf(address(this));
        } else {
            _ensureAssetBalance(assets);
        }

        IERC20(asset()).safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    /// @notice Burns shares for proportional amounts of both managed pool
    ///         tokens without relying on Pharaoh swap liquidity or price feeds.
    /// @dev This is the permissionless liveness escape hatch when a standard
    ///      ERC-4626 asset-only redemption cannot execute. ERC-20 Transfer
    ///      events identify both payout legs; this is not an ERC-4626 redeem.
    function redeemInKind(uint256 shares, address receiver, address owner_)
        external
        nonReentrant
        returns (uint256 assets, uint256 pairedAssets)
    {
        if (shares == 0) revert Vault__ZeroAmount();
        if (receiver == address(0)) revert Vault__ZeroAddress();

        uint256 ownerShares = balanceOf(owner_);
        if (shares > ownerShares) revert ERC4626ExceededMaxRedeem(owner_, shares, ownerShares);

        _collectFees();
        uint256 supply = totalSupply();
        IERC20 assetToken = IERC20(asset());
        uint256 idleAssetClaim = Math.mulDiv(assetToken.balanceOf(address(this)), shares, supply);
        uint256 idlePairClaim = Math.mulDiv(pairedToken.balanceOf(address(this)), shares, supply);

        _spendSharesAllowance(owner_, shares);
        _burn(owner_, shares);
        (uint256 amount0, uint256 amount1) = _freeLiquidity(shares, supply, Math.Rounding.Floor);

        assets = idleAssetClaim + (assetIsToken0 ? amount0 : amount1);
        pairedAssets = idlePairClaim + (assetIsToken0 ? amount1 : amount0);
        if (assets == 0 && pairedAssets == 0) revert Vault__InsufficientAssets(0, 1);

        if (assets != 0) assetToken.safeTransfer(receiver, assets);
        if (pairedAssets != 0) pairedToken.safeTransfer(receiver, pairedAssets);
    }

    function _executeDeposit(uint256 assets, address receiver, uint256 minimumShares)
        private
        returns (uint256 sharesIssued)
    {
        _checkPrice();
        if (tokenId != 0 && !_positionContainsSpot()) revert Vault__PositionNeedsRebalance();

        uint256 valueBefore = totalAssets();
        uint256 supplyBefore = totalSupply();
        if (depositCap != 0 && valueBefore + assets > depositCap) {
            revert Vault__DepositCapExceeded(depositCap, valueBefore + assets);
        }

        IERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);
        _deployIdle();

        uint256 valueAfter = totalAssets();
        if (valueAfter <= valueBefore) revert Vault__InsufficientAssets(valueAfter, valueBefore + 1);
        uint256 netContribution = valueAfter - valueBefore;
        uint256 actualShares = Math.mulDiv(netContribution, supplyBefore + 1, valueBefore + 1);
        if (actualShares < minimumShares) revert Vault__InsufficientShares(actualShares, minimumShares);

        sharesIssued = actualShares;
        _mint(receiver, sharesIssued);
        emit Deposit(msg.sender, receiver, assets, sharesIssued);
    }

    function _spendSharesAllowance(address owner_, uint256 shares) private {
        if (msg.sender != owner_) _spendAllowance(owner_, msg.sender, shares);
    }

    // ---------------------------------------------------------------------
    // Keeper operations
    // ---------------------------------------------------------------------

    function deployIdle() external onlyRebalancer nonReentrant whenNotPaused {
        _collectFees();
        _checkPrice();
        if (tokenId != 0 && !_positionContainsSpot()) revert Vault__PositionNeedsRebalance();
        _deployIdle();
    }

    function rebalance() external onlyRebalancer nonReentrant whenNotPaused {
        _collectFees();
        _checkPrice();

        uint256 valueBefore = totalAssets();
        uint256 oldTokenId = tokenId;
        _exitPosition();
        _deployIdle();
        uint256 valueAfter = totalAssets();

        if (valueAfter < _applyEntryLoss(valueBefore)) {
            revert Vault__ExcessiveLoss(valueBefore, valueAfter);
        }
        emit Rebalanced(oldTokenId, tokenId, positionTickLower, positionTickUpper, valueBefore, valueAfter);
    }

    /// @notice Removes the NFT liquidity without swapping either pool token.
    /// @dev Use during an incident; withdrawals remain available once the target
    ///      pool and oracle are safe enough to execute their required swap.
    function emergencyExit() external onlyOwner nonReentrant {
        if (!paused()) _pause();
        uint256 exitedTokenId = tokenId;
        (uint256 amount0, uint256 amount1) = _exitPosition();
        emit EmergencyExited(exitedTokenId, amount0, amount1);
    }

    // ---------------------------------------------------------------------
    // Price safety
    // ---------------------------------------------------------------------

    function _checkPrice()
        private
        view
        returns (int24 spotTick, int24 meanTick, uint256 twapPairInAsset, uint256 oraclePairInAsset)
    {
        (, spotTick,,,,,) = pool.slot0();
        meanTick = _twapTick();

        uint256 tickDifference = _absoluteTickDifference(spotTick, meanTick);
        if (tickDifference > maxTwapDeviationTicks) revert Vault__PriceDeviation(spotTick, meanTick);

        twapPairInAsset = PharaohOracleMath.getQuoteAtTick(meanTick, pairedTokenUnit, address(pairedToken), asset());
        oraclePairInAsset = priceOracle.quotePairToAsset(pairedTokenUnit);
        if (oraclePairInAsset == 0) revert Vault__InvalidOracle();

        uint256 difference = twapPairInAsset > oraclePairInAsset
            ? twapPairInAsset - oraclePairInAsset
            : oraclePairInAsset - twapPairInAsset;
        if (Math.mulDiv(difference, BPS, oraclePairInAsset) > maxOracleDeviationBps) {
            revert Vault__OracleDeviation(twapPairInAsset, oraclePairInAsset);
        }
    }

    function _twapTick() private view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapPeriod;
        secondsAgos[1] = 0;
        (int56[] memory cumulativeTicks,) = pool.observe(secondsAgos);
        return PharaohOracleMath.arithmeticMeanTick(cumulativeTicks[1] - cumulativeTicks[0], twapPeriod);
    }

    // ---------------------------------------------------------------------
    // Position management
    // ---------------------------------------------------------------------

    function _deployIdle() private {
        _balanceIdle();
        _addLiquidity();
    }

    function _balanceIdle() private {
        IERC20 assetToken = IERC20(asset());
        uint256 assetBalance = assetToken.balanceOf(address(this));
        uint256 pairBalance = pairedToken.balanceOf(address(this));
        uint256 pairValue = priceOracle.quotePairToAsset(pairBalance);

        if (assetBalance > pairValue + 1) {
            uint256 amountIn = (assetBalance - pairValue) / 2;
            if (amountIn > 0) {
                uint256 expectedOut = priceOracle.quoteAssetToPair(amountIn);
                _swapExactInput(assetToken, pairedToken, amountIn, _applySlippage(expectedOut));
            }
        } else if (pairValue > assetBalance + 1) {
            uint256 valueToSwap = (pairValue - assetBalance) / 2;
            uint256 amountIn = priceOracle.quoteAssetToPair(valueToSwap);
            if (amountIn > pairBalance) amountIn = pairBalance;
            if (amountIn > 0) {
                uint256 expectedOut = priceOracle.quotePairToAsset(amountIn);
                _swapExactInput(pairedToken, assetToken, amountIn, _applySlippage(expectedOut));
            }
        }
    }

    function _addLiquidity() private {
        (uint160 sqrtPriceX96, int24 spotTick,,,,,) = pool.slot0();
        uint256 amount0Desired = token0.balanceOf(address(this));
        uint256 amount1Desired = token1.balanceOf(address(this));
        if (amount0Desired == 0 && amount1Desired == 0) return;

        int24 lower = positionTickLower;
        int24 upper = positionTickUpper;
        if (tokenId == 0) {
            (lower, upper) = _newRange(_twapTick());
        } else if (spotTick <= lower || spotTick >= upper) {
            revert Vault__PositionNeedsRebalance();
        }

        uint160 sqrtLowerX96 = PharaohTickMath.getSqrtRatioAtTick(lower);
        uint160 sqrtUpperX96 = PharaohTickMath.getSqrtRatioAtTick(upper);
        uint128 expectedLiquidity = PharaohLiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, amount0Desired, amount1Desired
        );
        if (expectedLiquidity == 0) return;

        (uint256 expected0, uint256 expected1) =
            PharaohLiquidityAmounts.getAmountsForLiquidity(sqrtPriceX96, sqrtLowerX96, sqrtUpperX96, expectedLiquidity);
        uint256 amount0Min = _applySlippage(expected0);
        uint256 amount1Min = _applySlippage(expected1);

        token0.forceApprove(address(positionManager), amount0Desired);
        token1.forceApprove(address(positionManager), amount1Desired);

        if (tokenId == 0) {
            uint256 newTokenId;
            (newTokenId,,,) = positionManager.mint(
                IPharaohPositionManager.MintParams({
                    token0: address(token0),
                    token1: address(token1),
                    tickSpacing: tickSpacing,
                    tickLower: lower,
                    tickUpper: upper,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    recipient: address(this),
                    deadline: block.timestamp
                })
            );
            tokenId = newTokenId;
            positionTickLower = lower;
            positionTickUpper = upper;
        } else {
            positionManager.increaseLiquidity(
                IPharaohPositionManager.IncreaseLiquidityParams({
                    tokenId: tokenId,
                    amount0Desired: amount0Desired,
                    amount1Desired: amount1Desired,
                    amount0Min: amount0Min,
                    amount1Min: amount1Min,
                    deadline: block.timestamp
                })
            );
        }

        token0.forceApprove(address(positionManager), 0);
        token1.forceApprove(address(positionManager), 0);
    }

    function _freeLiquidity(uint256 shares, uint256 supply, Math.Rounding rounding)
        private
        returns (uint256 amount0, uint256 amount1)
    {
        if (tokenId == 0 || supply == 0) return (0, 0);
        (,, uint128 liquidity) = _position();
        if (liquidity == 0) return (0, 0);

        uint128 liquidityToRemove =
            shares == supply ? liquidity : uint128(Math.mulDiv(liquidity, shares, supply, rounding));
        if (liquidityToRemove > liquidity) liquidityToRemove = liquidity;
        if (liquidityToRemove == 0) return (0, 0);
        (amount0, amount1) = _decreaseAndCollect(liquidityToRemove);

        if (liquidityToRemove == liquidity) {
            uint256 oldTokenId = tokenId;
            positionManager.burn(oldTokenId);
            tokenId = 0;
            positionTickLower = 0;
            positionTickUpper = 0;
        }
    }

    function _exitPosition() private returns (uint256 amount0, uint256 amount1) {
        if (tokenId == 0) return (0, 0);
        (,, uint128 liquidity) = _position();
        if (liquidity > 0) {
            (amount0, amount1) = _decreaseAndCollect(liquidity);
        } else {
            (amount0, amount1) = _collectFees();
        }

        uint256 oldTokenId = tokenId;
        positionManager.burn(oldTokenId);
        tokenId = 0;
        positionTickLower = 0;
        positionTickUpper = 0;
    }

    function _decreaseAndCollect(uint128 liquidity) private returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
        (int24 lower, int24 upper,) = _position();
        (uint256 expected0, uint256 expected1) = PharaohLiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            PharaohTickMath.getSqrtRatioAtTick(lower),
            PharaohTickMath.getSqrtRatioAtTick(upper),
            liquidity
        );

        positionManager.decreaseLiquidity(
            IPharaohPositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: _applySlippage(expected0),
                amount1Min: _applySlippage(expected1),
                deadline: block.timestamp
            })
        );
        (amount0, amount1) = _collectFees();
    }

    function _collectFees() private returns (uint256 amount0, uint256 amount1) {
        if (tokenId == 0) return (0, 0);
        (amount0, amount1) = positionManager.collect(
            IPharaohPositionManager.CollectParams({
                tokenId: tokenId, recipient: address(this), amount0Max: type(uint128).max, amount1Max: type(uint128).max
            })
        );
    }

    // ---------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------

    function _ensureAssetBalance(uint256 requiredAssets) private {
        IERC20 assetToken = IERC20(asset());
        uint256 available = assetToken.balanceOf(address(this));
        if (available >= requiredAssets) return;

        uint256 shortfall = requiredAssets - available;
        uint256 expectedPairIn = priceOracle.quoteAssetToPair(shortfall);
        uint256 pairIn = _grossUpSlippage(expectedPairIn);
        uint256 pairBalance = pairedToken.balanceOf(address(this));
        if (pairIn > pairBalance) pairIn = pairBalance;
        if (pairIn == 0) revert Vault__InsufficientAssets(available, requiredAssets);

        // Pharaoh's deployed Ramses router constructs an invalid packed path
        // in exactOutputSingle. Use its working exact-input path instead. The
        // oracle-derived input is capped by the configured slippage allowance,
        // and the router must realize the complete withdrawal shortfall.
        _swapExactInput(pairedToken, assetToken, pairIn, shortfall);

        available = assetToken.balanceOf(address(this));
        if (available < requiredAssets) revert Vault__InsufficientAssets(available, requiredAssets);
    }

    function _swapAllPairedToAsset() private {
        uint256 amountIn = pairedToken.balanceOf(address(this));
        if (amountIn == 0) return;
        uint256 expectedOut = priceOracle.quotePairToAsset(amountIn);
        _swapExactInput(pairedToken, IERC20(asset()), amountIn, _applySlippage(expectedOut));
    }

    function _swapExactInput(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 minimumOut)
        private
        returns (uint256 amountOut)
    {
        tokenIn.forceApprove(address(swapRouter), amountIn);
        amountOut = swapRouter.exactInputSingle(
            IPharaohSwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                tickSpacing: tickSpacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minimumOut,
                sqrtPriceLimitX96: 0
            })
        );
        tokenIn.forceApprove(address(swapRouter), 0);
    }

    // ---------------------------------------------------------------------
    // Administration
    // ---------------------------------------------------------------------

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setRebalancer(address newRebalancer) external onlyOwner {
        if (newRebalancer == address(0)) revert Vault__ZeroAddress();
        emit RebalancerUpdated(rebalancer, newRebalancer);
        rebalancer = newRebalancer;
    }

    function setDepositCap(uint256 newCap) external onlyOwner {
        emit DepositCapUpdated(depositCap, newCap);
        depositCap = newCap;
    }

    /// @notice One-time authenticated migration for proxies deployed with the
    ///         original risk relationships. Use as upgradeAndCall calldata.
    function initializeV2RiskParameters(
        uint16 newMaxOracleDeviationBps,
        uint16 newSlippageBps,
        uint16 newValuationHaircutBps
    ) external reinitializer(2) onlyOwnerOrProxyAdmin {
        _setRiskParameters(
            tickRange,
            twapPeriod,
            maxTwapDeviationTicks,
            newMaxOracleDeviationBps,
            newSlippageBps,
            newValuationHaircutBps
        );
    }

    function _setRiskParameters(
        int24 newTickRange,
        uint32 newTwapPeriod,
        uint24 newMaxTwapDeviationTicks,
        uint16 newMaxOracleDeviationBps,
        uint16 newSlippageBps,
        uint16 newValuationHaircutBps
    ) private {
        uint256 minimumSlippageBps = uint256(newMaxOracleDeviationBps) + newMaxTwapDeviationTicks
            + MIN_EXECUTION_BUFFER_BPS;
        if (
            tickSpacing <= 0 || newTickRange <= tickSpacing || newTickRange % tickSpacing != 0 || newTickRange > 50_000
                || newTwapPeriod < 300 || newMaxTwapDeviationTicks == 0 || newMaxTwapDeviationTicks > 250
                || newMaxOracleDeviationBps == 0 || newMaxOracleDeviationBps > 2_000 || newSlippageBps > 1_000
                || newValuationHaircutBps > 2_000 || newSlippageBps < minimumSlippageBps
                || newValuationHaircutBps < newSlippageBps
        ) revert Vault__InvalidConfiguration();

        tickRange = newTickRange;
        twapPeriod = newTwapPeriod;
        maxTwapDeviationTicks = newMaxTwapDeviationTicks;
        maxOracleDeviationBps = newMaxOracleDeviationBps;
        slippageBps = newSlippageBps;
        valuationHaircutBps = newValuationHaircutBps;
    }

    // ---------------------------------------------------------------------
    // Pure/view helpers
    // ---------------------------------------------------------------------

    function _newRange(int24 centerTick) private view returns (int24 lower, int24 upper) {
        int24 alignedCenter = _floorToSpacing(centerTick);
        lower = alignedCenter - tickRange;
        upper = alignedCenter + tickRange;
        if (lower < MIN_TICK || upper > MAX_TICK) revert Vault__InvalidConfiguration();
    }

    function _floorToSpacing(int24 tick) private view returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _positionContainsSpot() private view returns (bool) {
        (, int24 spotTick,,,,,) = pool.slot0();
        return spotTick > positionTickLower && spotTick < positionTickUpper;
    }

    function _applySlippage(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, BPS - slippageBps, BPS);
    }

    function _grossUpSlippage(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, BPS, BPS - slippageBps, Math.Rounding.Ceil);
    }

    function _entryLossBps() private view returns (uint256) {
        uint256 loss = uint256(slippageBps) * 2 + valuationHaircutBps;
        return loss >= BPS ? BPS - 1 : loss;
    }

    function _applyEntryLoss(uint256 amount) private view returns (uint256) {
        return Math.mulDiv(amount, BPS - _entryLossBps(), BPS);
    }

    function _absoluteTickDifference(int24 a, int24 b) private pure returns (uint256) {
        int256 difference = int256(a) - int256(b);
        return uint256(difference < 0 ? -difference : difference);
    }

    uint256[40] private __gap;
}
