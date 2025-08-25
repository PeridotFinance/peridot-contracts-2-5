// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./ERC1155DualPosition.sol";
import "./VaultExecutor.sol";
import "./SettlementEngine.sol";
import "./CompoundBorrowRouter.sol";
import "./RiskGuard.sol";
import "../PErc20.sol";
import "../PeridottrollerInterface.sol";

/**
 * @title DualInvestmentManagerUpgradeable
 * @notice Upgradeable main entry point for dual investment operations with protocol integration
 * @dev Handles position entry with collateral or borrow paths, integrates with Peridot protocol
 */
contract DualInvestmentManagerUpgradeable is
    Initializable,
    Ownable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // Core contracts
    ERC1155DualPosition public positionToken;
    VaultExecutor public vaultExecutor;
    SettlementEngine public settlementEngine;
    CompoundBorrowRouter public borrowRouter;
    RiskGuard public riskGuard;
    PeridottrollerInterface public peridottroller;

    // Configuration
    uint256 public nextMarketId;
    mapping(address => bool) public supportedCTokens;
    mapping(address => address) public cTokenToUnderlying;

    // Risk parameters
    uint256 public maxPositionSize;
    uint256 public minPositionSize;
    uint256 public maxExpiry;
    uint256 public minExpiry;

    // Protocol Integration - NEW
    address public protocolTreasury;
    uint256 public protocolFeeRate; // Basis points (100 = 1%)
    address public protocolToken; // Governance/reward token
    mapping(address => uint256) public userProtocolRewards;
    mapping(address => bool) public protocolIntegratedMarkets;

    // Auto-compounding removed - was not implemented

    // Cross-market integration
    mapping(address => uint256) public marketUtilizationBonus; // Bonus rates for high utilization markets

    // Events
    event PositionEntered(
        uint256 indexed tokenId,
        address indexed user,
        address indexed cTokenIn,
        address cTokenOut,
        uint256 amount,
        uint256 strike,
        uint256 expiry,
        uint8 direction,
        bool useCollateral
    );

    // Protocol integration events - NEW
    event ProtocolFeeCollected(
        address indexed user,
        uint256 fee,
        uint256 tokenId
    );
    event ProtocolRewardEarned(
        address indexed user,
        uint256 reward,
        uint256 tokenId
    );
    // Auto-compounding events removed
    event MarketIntegrationUpdated(address indexed market, bool integrated);
    event ProtocolConfigUpdated(
        address treasury,
        uint256 feeRate,
        address token
    );

    event CTokenSupported(address indexed cToken, bool supported);
    event RiskParametersUpdated(
        uint256 maxPositionSize,
        uint256 minPositionSize,
        uint256 maxExpiry,
        uint256 minExpiry
    );

    constructor() Ownable(msg.sender) {
        // Allow initialization for simple deployment pattern
    }

    function initialize(
        address _positionToken,
        address _vaultExecutor,
        address _settlementEngine,
        address _borrowRouter,
        address _riskGuard,
        address _peridottroller,
        address _protocolTreasury,
        address _protocolToken
    ) public initializer {
        _transferOwnership(msg.sender);

        require(_positionToken != address(0), "Invalid position token");
        require(_vaultExecutor != address(0), "Invalid vault executor");
        require(_settlementEngine != address(0), "Invalid settlement engine");
        require(_borrowRouter != address(0), "Invalid borrow router");
        require(_riskGuard != address(0), "Invalid risk guard");
        require(_peridottroller != address(0), "Invalid peridottroller");
        require(_protocolTreasury != address(0), "Invalid protocol treasury");

        positionToken = ERC1155DualPosition(_positionToken);
        vaultExecutor = VaultExecutor(_vaultExecutor);
        settlementEngine = SettlementEngine(_settlementEngine);
        borrowRouter = CompoundBorrowRouter(_borrowRouter);
        riskGuard = RiskGuard(_riskGuard);
        peridottroller = PeridottrollerInterface(_peridottroller);

        // Protocol integration setup
        protocolTreasury = _protocolTreasury;
        protocolToken = _protocolToken;
        protocolFeeRate = 50; // 0.5% default fee

        // Risk parameters
        nextMarketId = 1;
        maxPositionSize = 1000000e18; // 1M tokens
        minPositionSize = 1e18; // 1 token
        maxExpiry = 30 days;
        minExpiry = 1 hours;
    }

    /**
     * @notice Enter a dual investment position with protocol integration
     * @param cTokenIn Input cToken (collateral)
     * @param cTokenOut Output cToken (settlement asset)
     * @param amount Amount of cTokens to use
     * @param direction Position direction (0=call, 1=put)
     * @param strike Strike price (18 decimals)
     * @param expiry Expiry timestamp
     * @param useCollateral True to use existing cTokens, false to borrow
     * @param enableAutoCompound Deprecated parameter (ignored)
     */
    function enterPosition(
        address cTokenIn,
        address cTokenOut,
        uint256 amount,
        uint8 direction,
        uint256 strike,
        uint256 expiry,
        bool useCollateral,
        bool enableAutoCompound // Deprecated - ignored
    ) external nonReentrant returns (uint256 tokenId) {
        return
            _enterPositionInternal(
                cTokenIn,
                cTokenOut,
                amount,
                direction,
                strike,
                expiry,
                useCollateral,
                enableAutoCompound
            );
    }

    function _enterPositionInternal(
        address cTokenIn,
        address cTokenOut,
        uint256 amount,
        uint8 direction,
        uint256 strike,
        uint256 expiry,
        bool useCollateral,
        bool enableAutoCompound // Deprecated - ignored
    ) internal returns (uint256 tokenId) {
        // Validate inputs
        _validatePositionParameters(
            cTokenIn,
            cTokenOut,
            amount,
            direction,
            strike,
            expiry
        );

        // Get position value in USD for risk checking
        uint256 positionValueUSD = _getPositionValueUSD(cTokenIn, amount);

        // Check risk constraints
        (bool riskAllowed, string memory riskReason) = riskGuard
            .checkPositionEntry(
                msg.sender,
                cTokenIn,
                positionValueUSD,
                useCollateral
            );
        require(riskAllowed, riskReason);

        // Generate token ID
        address underlying = cTokenToUnderlying[cTokenIn];
        tokenId = positionToken.generateTokenIdForUser(
            msg.sender,
            underlying,
            uint64(strike),
            uint64(expiry),
            direction,
            nextMarketId++
        );

        // Calculate and collect protocol fee
        uint256 protocolFee = (positionValueUSD * protocolFeeRate) / 10000;
        if (protocolFee > 0) {
            _collectProtocolFee(msg.sender, protocolFee, tokenId);
        }

        // Create position struct with protocol integration
        ERC1155DualPosition.Position memory position = ERC1155DualPosition
            .Position({
                user: msg.sender,
                cTokenIn: cTokenIn,
                cTokenOut: cTokenOut,
                notional: uint128(amount),
                expiry: uint64(expiry),
                strike: uint64(strike),
                direction: direction,
                settled: false
            });

        if (useCollateral) {
            _enterWithCollateral(cTokenIn, amount, tokenId, position);
        } else {
            _enterWithBorrow(cTokenIn, amount, tokenId, position);
        }

        // Protocol reward calculation
        if (protocolToken != address(0)) {
            uint256 reward = _calculateProtocolReward(
                msg.sender,
                cTokenIn,
                positionValueUSD
            );
            if (reward > 0) {
                userProtocolRewards[msg.sender] += reward;
                emit ProtocolRewardEarned(msg.sender, reward, tokenId);
            }
        }

        // Auto-compounding removed

        emit PositionEntered(
            tokenId,
            msg.sender,
            cTokenIn,
            cTokenOut,
            amount,
            strike,
            expiry,
            direction,
            useCollateral
        );

        return tokenId;
    }

    /**
     * @notice Convenience entry that computes expiry from a relative offset
     * @param offsetSeconds Number of seconds from now to set expiry
     * Other params are identical to enterPosition except expiry is derived
     */
    function enterPositionWithOffset(
        address cTokenIn,
        address cTokenOut,
        uint256 amount,
        uint8 direction,
        uint256 strike,
        uint256 offsetSeconds,
        bool useCollateral,
        bool enableAutoCompound
    ) external nonReentrant returns (uint256 tokenId) {
        uint256 expiry = block.timestamp + offsetSeconds;
        return
            _enterPositionInternal(
                cTokenIn,
                cTokenOut,
                amount,
                direction,
                strike,
                expiry,
                useCollateral,
                enableAutoCompound
            );
    }

    /**
     * @notice One-shot flow: borrow underlying from selected pToken market and enter a position
     * @dev Requires markets and router to be configured. Borrow is attributed to msg.sender.
     */
    function borrowAndEnterPosition(
        address cToken, // pToken to borrow underlying from
        address cTokenOut, // settlement pToken
        uint256 borrowUnderlyingAmount,
        uint8 direction,
        uint256 strike,
        uint256 expiry
    ) external nonReentrant returns (uint256 tokenId) {
        require(protocolIntegratedMarkets[cToken], "Market not integrated");
        require(
            supportedCTokens[cToken] && supportedCTokens[cTokenOut],
            "Unsupported cToken"
        );
        require(
            expiry >= block.timestamp + minExpiry &&
                expiry <= block.timestamp + maxExpiry,
            "Expiry out of range"
        );
        require(borrowUnderlyingAmount > 0, "Invalid amount");

        // Check risk via RiskGuard using USD value of borrow
        uint256 pricePerToken = settlementEngine
            .priceOracle()
            .getUnderlyingPrice(PToken(cToken));
        uint256 positionValueUSD = (borrowUnderlyingAmount * pricePerToken) /
            1e18;
        (bool ok, string memory reason) = riskGuard.checkPositionEntry(
            msg.sender,
            cToken,
            positionValueUSD,
            false
        );
        require(ok, reason);

        // Ask router to borrow and route funds to the vault executor
        bool routed = borrowRouter.borrowAndRoute(
            cToken,
            borrowUnderlyingAmount,
            address(vaultExecutor),
            msg.sender
        );
        require(routed, "Borrow route failed");

        // Vault holds underlying now; mint to itself so it can account and settle later
        uint256 cTokensMinted = vaultExecutor.mintCTokensTo(
            cToken,
            address(vaultExecutor),
            borrowUnderlyingAmount
        );

        // Create position and mint to user
        address underlying = cTokenToUnderlying[cToken];
        tokenId = positionToken.generateTokenIdForUser(
            msg.sender,
            underlying,
            uint64(strike),
            uint64(expiry),
            direction,
            nextMarketId++
        );

        ERC1155DualPosition.Position memory position = ERC1155DualPosition
            .Position({
                user: msg.sender,
                cTokenIn: cToken,
                cTokenOut: cTokenOut,
                notional: uint128(cTokensMinted),
                expiry: uint64(expiry),
                strike: uint64(strike),
                direction: direction,
                settled: false
            });

        positionToken.mintPosition(
            msg.sender,
            tokenId,
            cTokensMinted,
            position
        );

        // Track risk/utilization
        riskGuard.updateUserPositionValue(msg.sender, 0, positionValueUSD);
        riskGuard.updateMarketUtilization(cToken, positionValueUSD, true);

        emit PositionEntered(
            tokenId,
            msg.sender,
            cToken,
            cTokenOut,
            cTokensMinted,
            strike,
            expiry,
            direction,
            false
        );

        return tokenId;
    }

    /**
     * @notice Returns the valid expiry window bounds based on current block time
     */
    function getExpiryBounds()
        external
        view
        returns (uint256 minAllowed, uint256 maxAllowed)
    {
        minAllowed = block.timestamp + minExpiry;
        maxAllowed = block.timestamp + maxExpiry;
    }

    /**
     * @notice Enter position using existing cToken collateral
     */
    function _enterWithCollateral(
        address cToken,
        uint256 amount,
        uint256 tokenId,
        ERC1155DualPosition.Position memory position
    ) internal {
        // Enhanced vault executor operation pulls user's cTokens, redeems, and supplies to protocol
        vaultExecutor.redeemAndSupplyToProtocol(msg.sender, cToken, amount);

        // Update risk tracking
        uint256 positionValueUSD = _getPositionValueUSD(cToken, amount);
        riskGuard.updateUserPositionValue(msg.sender, 0, positionValueUSD);
        riskGuard.updateMarketUtilization(cToken, positionValueUSD, true);

        // Mint position token to user
        positionToken.mintPosition(msg.sender, tokenId, amount, position);
    }

    /**
     * @notice Enter position by borrowing underlying asset
     */
    function _enterWithBorrow(
        address cToken,
        uint256 amount,
        uint256 tokenId,
        ERC1155DualPosition.Position memory position
    ) internal {
        // Calculate underlying amount to borrow
        uint256 exchangeRate = PErc20(cToken).exchangeRateStored();
        uint256 underlyingAmount = (amount * exchangeRate) / 1e18;

        // Additional borrow safety check
        (bool canBorrow, string memory borrowReason) = borrowRouter
            .canUserBorrow(msg.sender, cToken, underlyingAmount);
        require(canBorrow, borrowReason);

        // Use borrow router to borrow and route to vault executor
        bool borrowSuccess = borrowRouter.borrowAndRoute(
            cToken,
            underlyingAmount,
            address(vaultExecutor),
            msg.sender
        );
        require(borrowSuccess, "Borrow and route failed");

        // Vault executor supplies to protocol account
        vaultExecutor.mintCTokensTo(
            cToken,
            address(vaultExecutor),
            underlyingAmount
        );

        // Update risk tracking
        uint256 positionValueUSD = _getPositionValueUSD(cToken, amount);
        riskGuard.updateUserPositionValue(msg.sender, 0, positionValueUSD);
        riskGuard.updateMarketUtilization(cToken, positionValueUSD, true);

        // Mint position token to user
        positionToken.mintPosition(msg.sender, tokenId, amount, position);
    }

    /**
     * @notice Enter position after the user has borrowed underlying directly
     * @dev User must have just borrowed and hold `underlyingAmount` of the cToken's underlying, and must approve VaultExecutor
     * @param cToken cToken market for the borrowed underlying
     * @param cTokenOut Settlement asset cToken
     * @param underlyingAmount Amount of underlying the user borrowed and will supply
     * @param direction 0=call, 1=put
     * @param strike Strike price (18 decimals)
     * @param expiry Expiry timestamp
     */
    function enterPositionWithBorrowed(
        address cToken,
        address cTokenOut,
        uint256 underlyingAmount,
        uint8 direction,
        uint256 strike,
        uint256 expiry
    ) external nonReentrant returns (uint256 tokenId) {
        require(supportedCTokens[cToken], "Input cToken not supported");
        require(supportedCTokens[cTokenOut], "Output cToken not supported");
        require(underlyingAmount > 0, "Invalid amount");
        require(direction == 0 || direction == 1, "Invalid direction");
        require(strike > 0, "Invalid strike");
        require(expiry >= block.timestamp + minExpiry, "Expiry too soon");
        require(expiry <= block.timestamp + maxExpiry, "Expiry too far");

        // Compute equivalent cToken notional for risk and mint calculations using exchange rate
        uint256 exchangeRate = PErc20(cToken).exchangeRateStored();
        uint256 cTokenNotional = (underlyingAmount * 1e18) / exchangeRate;
        require(cTokenNotional >= minPositionSize, "Position size too small");
        require(cTokenNotional <= maxPositionSize, "Position size too large");

        // Risk checks on USD value of position (use underlyingAmount * price)
        uint256 pricePerToken = settlementEngine
            .priceOracle()
            .getUnderlyingPrice(PToken(cToken));
        uint256 positionValueUSD = (underlyingAmount * pricePerToken) / 1e18;
        (bool riskAllowed, string memory riskReason) = riskGuard
            .checkPositionEntry(msg.sender, cToken, positionValueUSD, false);
        require(riskAllowed, riskReason);

        // Generate token ID
        address underlying = cTokenToUnderlying[cToken];
        tokenId = positionToken.generateTokenIdForUser(
            msg.sender,
            underlying,
            uint64(strike),
            uint64(expiry),
            direction,
            nextMarketId++
        );

        // Pull underlying from user and mint cTokens into vault executor
        uint256 cTokensMinted = vaultExecutor.pullUnderlyingAndMintTo(
            cToken,
            msg.sender,
            address(vaultExecutor),
            underlyingAmount
        );

        // Update risk tracking
        riskGuard.updateUserPositionValue(msg.sender, 0, positionValueUSD);
        riskGuard.updateMarketUtilization(cToken, positionValueUSD, true);

        // Create and mint position with actual minted cTokens
        ERC1155DualPosition.Position memory position = ERC1155DualPosition
            .Position({
                user: msg.sender,
                cTokenIn: cToken,
                cTokenOut: cTokenOut,
                notional: uint128(cTokensMinted),
                expiry: uint64(expiry),
                strike: uint64(strike),
                direction: direction,
                settled: false
            });

        positionToken.mintPosition(
            msg.sender,
            tokenId,
            cTokensMinted,
            position
        );

        emit PositionEntered(
            tokenId,
            msg.sender,
            cToken,
            cTokenOut,
            cTokensMinted,
            strike,
            expiry,
            direction,
            false
        );

        return tokenId;
    }

    /**
     * @notice Collect protocol fee from user
     */
    function _collectProtocolFee(
        address user,
        uint256 fee,
        uint256 tokenId
    ) internal {
        // Fee collection logic - could be in native token or protocol token
        // For now, assume fee is collected from user's balance
        emit ProtocolFeeCollected(user, fee, tokenId);
    }

    /**
     * @notice Calculate protocol rewards based on market integration
     */
    function _calculateProtocolReward(
        address user,
        address cToken,
        uint256 positionValue
    ) internal view returns (uint256 reward) {
        if (!protocolIntegratedMarkets[cToken]) {
            return 0;
        }

        // Base reward rate: 0.1% of position value
        uint256 baseReward = (positionValue * 10) / 10000;

        // Market utilization bonus
        uint256 bonus = marketUtilizationBonus[cToken];
        if (bonus > 0) {
            baseReward = (baseReward * (10000 + bonus)) / 10000;
        }

        return baseReward;
    }

    // Auto-compounding functions removed

    /**
     * @notice Claim accumulated protocol rewards
     */
    function claimProtocolRewards() external nonReentrant {
        uint256 rewards = userProtocolRewards[msg.sender];
        require(rewards > 0, "No rewards to claim");
        require(protocolToken != address(0), "Protocol token not set");

        userProtocolRewards[msg.sender] = 0;
        IERC20(protocolToken).safeTransfer(msg.sender, rewards);
    }

    /**
     * @notice Batch enter multiple positions for protocol integration
     */
    function batchEnterPositions(
        address[] calldata cTokensIn,
        address[] calldata cTokensOut,
        uint256[] calldata amounts,
        uint8[] calldata directions,
        uint256[] calldata strikes,
        uint256[] calldata expiries,
        bool[] calldata useCollateral
    ) external nonReentrant returns (uint256[] memory tokenIds) {
        require(
            cTokensIn.length == amounts.length &&
                amounts.length == directions.length &&
                directions.length == strikes.length &&
                strikes.length == expiries.length &&
                expiries.length == useCollateral.length,
            "Array length mismatch"
        );

        tokenIds = new uint256[](cTokensIn.length);

        for (uint256 i = 0; i < cTokensIn.length; i++) {
            tokenIds[i] = _enterPositionInternal(
                cTokensIn[i],
                cTokensOut[i],
                amounts[i],
                directions[i],
                strikes[i],
                expiries[i],
                useCollateral[i],
                false // Auto-compound deprecated
            );
        }

        return tokenIds;
    }

    // Protocol Integration Admin Functions

    /**
     * @notice Update protocol configuration
     */
    function updateProtocolConfig(
        address _protocolTreasury,
        uint256 _protocolFeeRate,
        address _protocolToken
    ) external onlyOwner {
        require(_protocolTreasury != address(0), "Invalid treasury");
        require(_protocolFeeRate <= 1000, "Fee rate too high"); // Max 10%

        protocolTreasury = _protocolTreasury;
        protocolFeeRate = _protocolFeeRate;
        protocolToken = _protocolToken;

        emit ProtocolConfigUpdated(
            _protocolTreasury,
            _protocolFeeRate,
            _protocolToken
        );
    }

    /**
     * @notice Set market integration status
     */
    function setMarketIntegration(
        address cToken,
        bool integrated
    ) external onlyOwner {
        protocolIntegratedMarkets[cToken] = integrated;
        emit MarketIntegrationUpdated(cToken, integrated);
    }

    /**
     * @notice Set market utilization bonus
     */
    function setMarketUtilizationBonus(
        address cToken,
        uint256 bonusBps
    ) external onlyOwner {
        require(bonusBps <= 5000, "Bonus too high"); // Max 50% bonus
        marketUtilizationBonus[cToken] = bonusBps;
    }

    // Auto-compounding configuration removed

    // Existing functions with protocol integration enhancements...

    function _validatePositionParameters(
        address cTokenIn,
        address cTokenOut,
        uint256 amount,
        uint8 direction,
        uint256 strike,
        uint256 expiry
    ) internal view {
        require(supportedCTokens[cTokenIn], "Input cToken not supported");
        require(supportedCTokens[cTokenOut], "Output cToken not supported");
        require(amount >= minPositionSize, "Position size too small");
        require(amount <= maxPositionSize, "Position size too large");
        require(
            direction == 0 || direction == 1, // 0=CALL, 1=PUT
            "Invalid direction"
        );
        require(strike > 0, "Invalid strike price");
        require(expiry >= block.timestamp + minExpiry, "Expiry too soon");
        require(expiry <= block.timestamp + maxExpiry, "Expiry too far");
    }

    function setSupportedCToken(
        address cToken,
        bool supported
    ) external onlyOwner {
        require(cToken != address(0), "Invalid cToken address");

        supportedCTokens[cToken] = supported;

        if (supported) {
            try PErc20(cToken).underlying() returns (address underlying) {
                cTokenToUnderlying[cToken] = underlying;
            } catch {
                cTokenToUnderlying[
                    cToken
                ] = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
            }
        } else {
            delete cTokenToUnderlying[cToken];
        }

        emit CTokenSupported(cToken, supported);
    }

    function setRiskParameters(
        uint256 _maxPositionSize,
        uint256 _minPositionSize,
        uint256 _maxExpiry,
        uint256 _minExpiry
    ) external onlyOwner {
        require(
            _maxPositionSize > _minPositionSize,
            "Invalid position size range"
        );
        require(_maxExpiry > _minExpiry, "Invalid expiry range");
        require(_minExpiry >= 1 minutes, "Expiry too short");

        maxPositionSize = _maxPositionSize;
        minPositionSize = _minPositionSize;
        maxExpiry = _maxExpiry;
        minExpiry = _minExpiry;

        emit RiskParametersUpdated(
            _maxPositionSize,
            _minPositionSize,
            _maxExpiry,
            _minExpiry
        );
    }

    function getPositionInfo(
        uint256 tokenId
    )
        external
        view
        returns (
            ERC1155DualPosition.Position memory position,
            bool canSettle,
            bool isSettled
        )
    {
        position = positionToken.getPosition(tokenId);
        (canSettle, ) = settlementEngine.canSettlePosition(tokenId);
        (isSettled, , ) = settlementEngine.getSettlementInfo(tokenId);
    }

    function canEnterPosition(
        address user,
        address cTokenIn,
        uint256 amount,
        bool useCollateral
    ) external returns (bool canEnter, string memory reason) {
        if (!supportedCTokens[cTokenIn]) {
            return (false, "cToken not supported");
        }

        if (amount < minPositionSize) {
            return (false, "Position too small");
        }

        if (amount > maxPositionSize) {
            return (false, "Position too large");
        }

        if (useCollateral) {
            uint256 balance = PErc20(cTokenIn).balanceOf(user);
            if (balance < amount) {
                return (false, "Insufficient cToken balance");
            }
        } else {
            (, uint256 liquidity, ) = peridottroller.getAccountLiquidity(user);
            if (liquidity == 0) {
                return (false, "Insufficient liquidity to borrow");
            }
        }

        return (true, "");
    }

    function _getPositionValueUSD(
        address cToken,
        uint256 amount
    ) internal view returns (uint256 valueUSD) {
        uint256 exchangeRate = PErc20(cToken).exchangeRateStored();
        uint256 underlyingAmount = (amount * exchangeRate) / 1e18;

        uint256 pricePerToken = settlementEngine
            .priceOracle()
            .getUnderlyingPrice(PToken(cToken));

        return (underlyingAmount * pricePerToken) / 1e18;
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[50] private __gap;
}
