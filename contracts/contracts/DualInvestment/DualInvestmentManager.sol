// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
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
 * @title DualInvestmentManager
 * @notice Main entry point for dual investment operations
 * @dev Handles position entry with collateral or borrow paths
 */
contract DualInvestmentManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Core contracts
    ERC1155DualPosition public immutable positionToken;
    VaultExecutor public immutable vaultExecutor;
    SettlementEngine public immutable settlementEngine;
    CompoundBorrowRouter public immutable borrowRouter;
    RiskGuard public immutable riskGuard;
    PeridottrollerInterface public immutable peridottroller;

    // Configuration
    uint256 public nextMarketId = 1;
    mapping(address => bool) public supportedCTokens;
    mapping(address => address) public cTokenToUnderlying;

    // Risk parameters
    uint256 public maxPositionSize = 1000000e18; // 1M tokens max
    uint256 public minPositionSize = 1e18; // 1 token min
    uint256 public maxExpiry = 30 days; // Max 30 days expiry
    uint256 public minExpiry = 1 hours; // Min 1 hour expiry

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

    event CTokenSupported(address indexed cToken, bool supported);
    event RiskParametersUpdated(uint256 maxPositionSize, uint256 minPositionSize, uint256 maxExpiry, uint256 minExpiry);

    constructor(
        address _positionToken,
        address _vaultExecutor,
        address _settlementEngine,
        address _borrowRouter,
        address _riskGuard,
        address _peridottroller
    ) Ownable(msg.sender) {
        require(_positionToken != address(0), "Invalid position token");
        require(_vaultExecutor != address(0), "Invalid vault executor");
        require(_settlementEngine != address(0), "Invalid settlement engine");
        require(_borrowRouter != address(0), "Invalid borrow router");
        require(_riskGuard != address(0), "Invalid risk guard");
        require(_peridottroller != address(0), "Invalid peridottroller");

        positionToken = ERC1155DualPosition(_positionToken);
        vaultExecutor = VaultExecutor(_vaultExecutor);
        settlementEngine = SettlementEngine(_settlementEngine);
        borrowRouter = CompoundBorrowRouter(_borrowRouter);
        riskGuard = RiskGuard(_riskGuard);
        peridottroller = PeridottrollerInterface(_peridottroller);
    }

    /**
     * @notice Enter a dual investment position
     * @param cTokenIn Input cToken (collateral)
     * @param cTokenOut Output cToken (settlement asset)
     * @param amount Amount of cTokens to use
     * @param direction Position direction (0=call, 1=put)
     * @param strike Strike price (18 decimals)
     * @param expiry Expiry timestamp
     * @param useCollateral True to use existing cTokens, false to borrow
     */
    function enterPosition(
        address cTokenIn,
        address cTokenOut,
        uint256 amount,
        uint8 direction,
        uint256 strike,
        uint256 expiry,
        bool useCollateral
    ) external nonReentrant returns (uint256 tokenId) {
        // Validate inputs
        _validatePositionParameters(cTokenIn, cTokenOut, amount, direction, strike, expiry);

        // Get position value in USD for risk checking
        uint256 positionValueUSD = _getPositionValueUSD(cTokenIn, amount);

        // Check risk constraints
        (bool riskAllowed, string memory riskReason) =
            riskGuard.checkPositionEntry(msg.sender, cTokenIn, positionValueUSD, useCollateral);
        require(riskAllowed, riskReason);

        // Generate token ID
        address underlying = cTokenToUnderlying[cTokenIn];
        tokenId = positionToken.generateTokenIdForUser(
            msg.sender, underlying, uint64(strike), uint64(expiry), direction, nextMarketId++
        );

        // Create position struct
        ERC1155DualPosition.Position memory position = ERC1155DualPosition.Position({
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
            // Collateral path: use existing cTokens
            _enterWithCollateral(cTokenIn, amount, tokenId, position);
        } else {
            // Borrow path: borrow and supply to protocol
            _enterWithBorrow(cTokenIn, amount, tokenId, position);
        }

        emit PositionEntered(tokenId, msg.sender, cTokenIn, cTokenOut, amount, strike, expiry, direction, useCollateral);

        return tokenId;
    }

    /**
     * @notice Enter position using existing cToken collateral
     * @param cToken cToken to use as collateral
     * @param amount Amount of cTokens
     * @param tokenId Generated token ID
     * @param position Position struct
     */
    function _enterWithCollateral(
        address cToken,
        uint256 amount,
        uint256 tokenId,
        ERC1155DualPosition.Position memory position
    ) internal {
        // Vault executor pulls user's cTokens, redeems, and supplies to protocol
        vaultExecutor.redeemAndSupplyToProtocol(msg.sender, cToken, amount);

        // Update risk tracking for collateral path too
        uint256 positionValueUSD = _getPositionValueUSD(cToken, amount);
        riskGuard.updateUserPositionValue(msg.sender, 0, positionValueUSD);
        riskGuard.updateMarketUtilization(cToken, positionValueUSD, true);

        // Mint position token to user
        positionToken.mintPosition(msg.sender, tokenId, amount, position);
    }

    /**
     * @notice Enter position by borrowing underlying asset
     * @param cToken cToken to borrow from
     * @param amount Amount to borrow (in cToken units)
     * @param tokenId Generated token ID
     * @param position Position struct
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
        (bool canBorrow, string memory borrowReason) = borrowRouter.canUserBorrow(msg.sender, cToken, underlyingAmount);
        require(canBorrow, borrowReason);

        // Use borrow router to borrow and route to vault executor
        bool borrowSuccess = borrowRouter.borrowAndRoute(cToken, underlyingAmount, address(vaultExecutor), msg.sender);
        require(borrowSuccess, "Borrow and route failed");

        // Vault executor supplies to protocol account
        vaultExecutor.mintCTokensTo(cToken, address(vaultExecutor), underlyingAmount);

        // Update risk tracking
        uint256 positionValueUSD = _getPositionValueUSD(cToken, amount);
        riskGuard.updateUserPositionValue(msg.sender, 0, positionValueUSD);
        riskGuard.updateMarketUtilization(cToken, positionValueUSD, true);

        // Mint position token to user
        positionToken.mintPosition(msg.sender, tokenId, amount, position);
    }

    /**
     * @notice Enter position after the user has borrowed underlying directly
     * @dev User must hold `underlyingAmount` of the underlying and approve VaultExecutor
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
        require(expiry > block.timestamp + minExpiry, "Expiry too soon");
        require(expiry <= block.timestamp + maxExpiry, "Expiry too far");

        uint256 exchangeRate = PErc20(cToken).exchangeRateStored();
        uint256 cTokenNotional = (underlyingAmount * 1e18) / exchangeRate;
        require(cTokenNotional >= minPositionSize, "Position size too small");
        require(cTokenNotional <= maxPositionSize, "Position size too large");

        uint256 pricePerToken = settlementEngine.priceOracle().getUnderlyingPrice(PToken(cToken));
        uint256 positionValueUSD = (underlyingAmount * pricePerToken) / 1e18;
        (bool riskAllowed, string memory riskReason) =
            riskGuard.checkPositionEntry(msg.sender, cToken, positionValueUSD, false);
        require(riskAllowed, riskReason);

        address underlying = cTokenToUnderlying[cToken];
        tokenId = positionToken.generateTokenIdForUser(
            msg.sender, underlying, uint64(strike), uint64(expiry), direction, nextMarketId++
        );

        uint256 cTokensMinted =
            vaultExecutor.pullUnderlyingAndMintTo(cToken, msg.sender, address(vaultExecutor), underlyingAmount);

        riskGuard.updateUserPositionValue(msg.sender, 0, positionValueUSD);
        riskGuard.updateMarketUtilization(cToken, positionValueUSD, true);

        ERC1155DualPosition.Position memory position = ERC1155DualPosition.Position({
            user: msg.sender,
            cTokenIn: cToken,
            cTokenOut: cTokenOut,
            notional: uint128(cTokensMinted),
            expiry: uint64(expiry),
            strike: uint64(strike),
            direction: direction,
            settled: false
        });

        positionToken.mintPosition(msg.sender, tokenId, cTokensMinted, position);

        emit PositionEntered(tokenId, msg.sender, cToken, cTokenOut, cTokensMinted, strike, expiry, direction, false);

        return tokenId;
    }

    /**
     * @notice Validate position parameters
     */
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
        require(expiry > block.timestamp + minExpiry, "Expiry too soon");
        require(expiry <= block.timestamp + maxExpiry, "Expiry too far");
    }

    /**
     * @notice Add or remove supported cToken
     * @param cToken cToken address
     * @param supported Whether to support this cToken
     */
    function setSupportedCToken(address cToken, bool supported) external onlyOwner {
        require(cToken != address(0), "Invalid cToken address");

        supportedCTokens[cToken] = supported;

        if (supported) {
            // Store underlying mapping for supported tokens
            try PErc20(cToken).underlying() returns (address underlying) {
                cTokenToUnderlying[cToken] = underlying;
            } catch {
                // Handle pETH case (no underlying() function)
                cTokenToUnderlying[cToken] = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
            }
        } else {
            delete cTokenToUnderlying[cToken];
        }

        emit CTokenSupported(cToken, supported);
    }

    /**
     * @notice Update risk parameters
     * @param _maxPositionSize Maximum position size
     * @param _minPositionSize Minimum position size
     * @param _maxExpiry Maximum expiry duration
     * @param _minExpiry Minimum expiry duration
     */
    function setRiskParameters(
        uint256 _maxPositionSize,
        uint256 _minPositionSize,
        uint256 _maxExpiry,
        uint256 _minExpiry
    ) external onlyOwner {
        require(_maxPositionSize > _minPositionSize, "Invalid position size range");
        require(_maxExpiry > _minExpiry, "Invalid expiry range");
        require(_minExpiry >= 1 minutes, "Expiry too short");

        maxPositionSize = _maxPositionSize;
        minPositionSize = _minPositionSize;
        maxExpiry = _maxExpiry;
        minExpiry = _minExpiry;

        emit RiskParametersUpdated(_maxPositionSize, _minPositionSize, _maxExpiry, _minExpiry);
    }

    /**
     * @notice Get position information including settlement status
     * @param tokenId Token ID to query
     * @return position Position struct
     * @return canSettle Whether position can be settled
     * @return isSettled Whether position is already settled
     */
    function getPositionInfo(uint256 tokenId)
        external
        view
        returns (ERC1155DualPosition.Position memory position, bool canSettle, bool isSettled)
    {
        position = positionToken.getPosition(tokenId);
        (canSettle,) = settlementEngine.canSettlePosition(tokenId);
        (isSettled,,) = settlementEngine.getSettlementInfo(tokenId);
    }

    /**
     * @notice Check if user can enter a position with given parameters
     * @param user User address
     * @param cTokenIn Input cToken
     * @param amount Amount to use
     * @param useCollateral Whether using collateral (vs borrowing)
     * @return canEnter Whether user can enter position
     * @return reason Reason if cannot enter
     */
    function canEnterPosition(address user, address cTokenIn, uint256 amount, bool useCollateral)
        external
        returns (bool canEnter, string memory reason)
    {
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
            // Check cToken balance
            uint256 balance = PErc20(cTokenIn).balanceOf(user);
            if (balance < amount) {
                return (false, "Insufficient cToken balance");
            }
        } else {
            // Check borrowing capacity
            (, uint256 liquidity,) = peridottroller.getAccountLiquidity(user);
            if (liquidity == 0) {
                return (false, "Insufficient liquidity to borrow");
            }
        }

        return (true, "");
    }

    /**
     * @notice Get position value in USD
     * @param cToken cToken address
     * @param amount Amount of cTokens
     * @return valueUSD Position value in USD (scaled to 1e18)
     */
    function _getPositionValueUSD(address cToken, uint256 amount) internal view returns (uint256 valueUSD) {
        // Get exchange rate to convert cTokens to underlying
        uint256 exchangeRate = PErc20(cToken).exchangeRateStored();
        uint256 underlyingAmount = (amount * exchangeRate) / 1e18;

        // Get price from our SimplePriceOracle via settlementEngine
        uint256 pricePerToken = settlementEngine.priceOracle().getUnderlyingPrice(PToken(cToken));

        return (underlyingAmount * pricePerToken) / 1e18;
    }

    /**
     * @notice Emergency pause function
     */
    function pause() external onlyOwner {
        // Implementation depends on specific pause requirements
        // Could integrate with OpenZeppelin Pausable if needed
    }
}
