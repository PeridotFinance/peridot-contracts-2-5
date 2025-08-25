// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../PErc20.sol";
import "../PeridottrollerInterface.sol";
import "../SimplePriceOracle.sol";

/**
 * @title CompoundBorrowRouter
 * @notice Handles borrowing operations and routing borrowed assets to destination contracts
 * @dev Integrates with Compound-style money markets for dual investment funding
 */
contract CompoundBorrowRouter is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Core contracts
    PeridottrollerInterface public immutable peridottroller;
    SimplePriceOracle public immutable priceOracle;

    // Authorized destinations that can receive routed funds
    mapping(address => bool) public authorizedDestinations;

    // Minimum health factor required after borrowing (e.g., 1.25 = 125%)
    uint256 public minHealthFactorAfterBorrow = 1.25e18;

    // Maximum LTV allowed for borrowing (e.g., 0.75 = 75%)
    uint256 public maxLTVForBorrow = 0.75e18;

    // Events
    event BorrowAndRoute(
        address indexed user,
        address indexed cToken,
        address indexed destination,
        uint256 borrowAmount,
        uint256 healthFactorBefore,
        uint256 healthFactorAfter
    );

    event AuthorizedDestinationUpdated(
        address indexed destination,
        bool authorized
    );
    event MinHealthFactorUpdated(uint256 oldFactor, uint256 newFactor);
    event MaxLTVUpdated(uint256 oldLTV, uint256 newLTV);

    modifier onlyAuthorizedDestination(address destination) {
        require(
            authorizedDestinations[destination],
            "Destination not authorized"
        );
        _;
    }

    constructor(
        address _peridottroller,
        address _priceOracle
    ) Ownable(msg.sender) {
        require(_peridottroller != address(0), "Invalid peridottroller");
        require(_priceOracle != address(0), "Invalid price oracle");
        peridottroller = PeridottrollerInterface(_peridottroller);
        priceOracle = SimplePriceOracle(_priceOracle);
    }

    /**
     * @notice Borrow assets and route them to authorized destination
     * @param cToken cToken to borrow from
     * @param borrowAmount Amount of underlying to borrow
     * @param destination Authorized destination to receive funds
     * @param user User initiating the borrow (for accounting)
     * @return success Whether the operation succeeded
     */
    function borrowAndRoute(
        address cToken,
        uint256 borrowAmount,
        address destination,
        address user
    )
        external
        onlyAuthorizedDestination(destination)
        nonReentrant
        returns (bool success)
    {
        require(cToken != address(0), "Invalid cToken");
        require(borrowAmount > 0, "Invalid borrow amount");
        require(user != address(0), "Invalid user");

        // Get user's current account liquidity and health factor
        (, uint256 liquidityBefore, uint256 shortfallBefore) = peridottroller
            .getAccountLiquidity(user);
        require(shortfallBefore == 0, "User has existing shortfall");
        require(liquidityBefore > 0, "User has no liquidity");

        // Calculate health factor before borrowing
        uint256 healthFactorBefore = _calculateHealthFactor(user);

        // Perform borrow operation
        PErc20 pToken = PErc20(cToken);
        uint256 borrowResult = pToken.borrow(borrowAmount);
        require(borrowResult == 0, "Borrow failed");

        // Verify health factor after borrowing
        uint256 healthFactorAfter = _calculateHealthFactor(user);
        require(
            healthFactorAfter >= minHealthFactorAfterBorrow,
            "Health factor too low after borrow"
        );

        // Route borrowed funds to destination. Some implementations may credit the user instead of this router.
        IERC20 underlying = IERC20(pToken.underlying());
        uint256 routerBal = underlying.balanceOf(address(this));
        if (routerBal >= borrowAmount) {
            underlying.safeTransfer(destination, borrowAmount);
        } else {
            // Fallback: pull from user if underlying was sent to the user. Requires prior approval.
            underlying.safeTransferFrom(user, destination, borrowAmount);
        }

        emit BorrowAndRoute(
            user,
            cToken,
            destination,
            borrowAmount,
            healthFactorBefore,
            healthFactorAfter
        );

        return true;
    }

    /**
     * @notice Check if user can safely borrow given amount
     * @param user User address
     * @param cToken cToken to borrow from
     * @param borrowAmount Amount to borrow
     * @return canBorrow Whether user can safely borrow
     * @return reason Reason if cannot borrow
     */
    function canUserBorrow(
        address user,
        address cToken,
        uint256 borrowAmount
    ) external returns (bool canBorrow, string memory reason) {
        // Check if market is listed and borrowing is enabled
        uint256 allowed = peridottroller.borrowAllowed(
            cToken,
            user,
            borrowAmount
        );
        if (allowed != 0) {
            return (false, "Borrow not allowed by peridottroller");
        }

        // Check user's current liquidity
        (, uint256 liquidity, uint256 shortfall) = peridottroller
            .getAccountLiquidity(user);
        if (shortfall > 0) {
            return (false, "User has existing shortfall");
        }

        if (liquidity == 0) {
            return (false, "User has no liquidity");
        }

        // Calculate required collateral for this borrow
        uint256 borrowValueUSD = _getBorrowValueInUSD(cToken, borrowAmount);
        if (borrowValueUSD > liquidity) {
            return (false, "Insufficient liquidity for borrow amount");
        }

        // Check if resulting health factor would be acceptable
        uint256 projectedHealthFactor = _projectHealthFactorAfterBorrow(
            user,
            cToken,
            borrowAmount
        );

        if (projectedHealthFactor < minHealthFactorAfterBorrow) {
            return (false, "Health factor would be too low");
        }

        return (true, "");
    }

    /**
     * @notice Get user's current health factor
     * @param user User address
     * @return healthFactor Health factor (1e18 = 100%)
     */
    function getUserHealthFactor(
        address user
    ) external view returns (uint256 healthFactor) {
        return _calculateHealthFactor(user);
    }

    /**
     * @notice Calculate health factor for user
     * @param user User address
     * @return healthFactor Health factor (0 if no borrows, >1e18 if healthy)
     */
    function _calculateHealthFactor(
        address user
    ) internal view returns (uint256 healthFactor) {
        (, uint256 liquidity, uint256 shortfall) = peridottroller
            .getAccountLiquidity(user);

        if (shortfall > 0) {
            return 0; // Liquidatable
        }

        // If no shortfall but also no liquidity, user might have no borrows
        if (liquidity == 0) {
            return type(uint256).max; // No borrows = infinite health factor
        }

        // Estimate total borrow value
        // This is a simplified calculation - in production, you'd want to iterate through all markets
        uint256 totalBorrowValue = _estimateTotalBorrowValue(user);
        if (totalBorrowValue == 0) {
            return type(uint256).max; // No borrows
        }

        uint256 totalCollateralValue = liquidity + totalBorrowValue;
        return (totalCollateralValue * 1e18) / totalBorrowValue;
    }

    /**
     * @notice Estimate total borrow value for user (simplified)
     * @param user User address
     * @return totalBorrowValue Estimated total borrow value in USD
     */
    function _estimateTotalBorrowValue(
        address user
    ) internal view returns (uint256 totalBorrowValue) {
        // In a production system, this would iterate through all markets
        // For now, we'll use the liquidity calculation as a proxy
        (, uint256 liquidity, ) = peridottroller.getAccountLiquidity(user);

        // This is a simplified approximation
        // Real implementation would sum up borrows across all markets
        return liquidity > 0 ? liquidity / 4 : 0; // Assume 25% utilization as rough estimate
    }

    /**
     * @notice Project health factor after a hypothetical borrow
     * @param user User address
     * @param cToken cToken to borrow from
     * @param borrowAmount Amount to borrow
     * @return projectedHealthFactor Projected health factor after borrow
     */
    function _projectHealthFactorAfterBorrow(
        address user,
        address cToken,
        uint256 borrowAmount
    ) internal view returns (uint256 projectedHealthFactor) {
        uint256 currentHealthFactor = _calculateHealthFactor(user);
        uint256 borrowValueUSD = _getBorrowValueInUSD(cToken, borrowAmount);
        (, uint256 liquidity, ) = peridottroller.getAccountLiquidity(user);

        if (currentHealthFactor == type(uint256).max) {
            // No existing borrows, calculate fresh
            return (liquidity * 1e18) / borrowValueUSD;
        }

        // Simplified projection - in production, would need more sophisticated calculation
        uint256 currentBorrowValue = _estimateTotalBorrowValue(user);
        uint256 newTotalBorrowValue = currentBorrowValue + borrowValueUSD;
        uint256 totalCollateralValue = liquidity + currentBorrowValue;

        return (totalCollateralValue * 1e18) / newTotalBorrowValue;
    }

    /**
     * @notice Get borrow value in USD
     * @param cToken cToken address
     * @param amount Amount of underlying tokens
     * @return valueUSD Value in USD (scaled to 1e18)
     */
    function _getBorrowValueInUSD(
        address cToken,
        uint256 amount
    ) internal view returns (uint256 valueUSD) {
        PErc20 pToken = PErc20(cToken);

        // Get price from our SimplePriceOracle
        uint256 pricePerToken = priceOracle.getUnderlyingPrice(pToken);

        return (amount * pricePerToken) / 1e18;
    }

    /**
     * @notice Set authorized destination
     * @param destination Destination address
     * @param authorized Whether destination is authorized
     */
    function setAuthorizedDestination(
        address destination,
        bool authorized
    ) external onlyOwner {
        require(destination != address(0), "Invalid destination");
        authorizedDestinations[destination] = authorized;
        emit AuthorizedDestinationUpdated(destination, authorized);
    }

    /**
     * @notice Update minimum health factor requirement
     * @param newMinHealthFactor New minimum health factor (1e18 = 100%)
     */
    function setMinHealthFactor(uint256 newMinHealthFactor) external onlyOwner {
        require(newMinHealthFactor >= 1e18, "Health factor must be >= 100%");
        require(newMinHealthFactor <= 3e18, "Health factor too high");

        uint256 oldFactor = minHealthFactorAfterBorrow;
        minHealthFactorAfterBorrow = newMinHealthFactor;
        emit MinHealthFactorUpdated(oldFactor, newMinHealthFactor);
    }

    /**
     * @notice Update maximum LTV for borrowing
     * @param newMaxLTV New maximum LTV (1e18 = 100%)
     */
    function setMaxLTV(uint256 newMaxLTV) external onlyOwner {
        require(newMaxLTV > 0 && newMaxLTV < 1e18, "Invalid LTV range");

        uint256 oldLTV = maxLTVForBorrow;
        maxLTVForBorrow = newMaxLTV;
        emit MaxLTVUpdated(oldLTV, newMaxLTV);
    }

    /**
     * @notice Emergency repay function (for admin use)
     * @param cToken cToken to repay to
     * @param repayAmount Amount to repay
     */
    function emergencyRepay(
        address cToken,
        uint256 repayAmount
    ) external onlyOwner {
        PErc20 pToken = PErc20(cToken);
        IERC20 underlying = IERC20(pToken.underlying());

        underlying.forceApprove(cToken, repayAmount);
        pToken.repayBorrow(repayAmount);
    }

    /**
     * @notice Emergency withdraw function
     * @param token Token to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(to != address(0), "Invalid recipient");
        IERC20(token).safeTransfer(to, amount);
    }
}
