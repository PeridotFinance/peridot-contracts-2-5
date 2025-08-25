// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PToken.sol";
import "./ErrorReporter.sol";
import "./PriceOracle.sol";
import "./PeridottrollerInterface.sol";
import "./PeridottrollerStorage.sol";
import "./Unitroller.sol";
import "./Governance/Peridot.sol";

/**
 * @title Peridot's Peridottroller Contract
 * @author Peridot
 */
contract Peridottroller is
    PeridottrollerV7Storage,
    PeridottrollerInterface,
    PeridottrollerErrorReporter,
    ExponentialNoError
{
    /// @notice Emitted when an admin supports a market
    event MarketListed(PToken pToken);

    /// @notice Emitted when an account enters a market
    event MarketEntered(PToken pToken, address account);

    /// @notice Emitted when an account exits a market
    event MarketExited(PToken pToken, address account);

    /// @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint256 oldCloseFactorMantissa, uint256 newCloseFactorMantissa);

    /// @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(PToken pToken, uint256 oldCollateralFactorMantissa, uint256 newCollateralFactorMantissa);

    /// @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint256 oldLiquidationIncentiveMantissa, uint256 newLiquidationIncentiveMantissa);

    /// @notice Emitted when price oracle is changed
    event NewPriceOracle(PriceOracle oldPriceOracle, PriceOracle newPriceOracle);

    /// @notice Emitted when pause guardian is changed
    event NewPauseGuardian(address oldPauseGuardian, address newPauseGuardian);

    /// @notice Emitted when an action is paused globally
    event ActionPaused(string action, bool pauseState);

    /// @notice Emitted when an action is paused on a market
    event ActionPaused(PToken pToken, string action, bool pauseState);

    /// @notice Emitted when a new borrow-side PERIDOT speed is calculated for a market
    event PeridotBorrowSpeedUpdated(PToken indexed pToken, uint256 newSpeed);

    /// @notice Emitted when a new supply-side PERIDOT speed is calculated for a market
    event PeridotSupplySpeedUpdated(PToken indexed pToken, uint256 newSpeed);

    /// @notice Emitted when a new PERIDOT speed is set for a contributor
    event ContributorPeridotSpeedUpdated(address indexed contributor, uint256 newSpeed);

    /// @notice Emitted when PERIDOT is distributed to a supplier
    event DistributedSupplierPeridot(
        PToken indexed pToken, address indexed supplier, uint256 peridotDelta, uint256 peridotSupplyIndex
    );

    /// @notice Emitted when PERIDOT is distributed to a borrower
    event DistributedBorrowerPeridot(
        PToken indexed pToken, address indexed borrower, uint256 peridotDelta, uint256 peridotBorrowIndex
    );

    /// @notice Emitted when borrow cap for a pToken is changed
    event NewBorrowCap(PToken indexed pToken, uint256 newBorrowCap);

    /// @notice Emitted when borrow cap guardian is changed
    event NewBorrowCapGuardian(address oldBorrowCapGuardian, address newBorrowCapGuardian);

    /// @notice Emitted when PERIDOT is granted by admin
    event PeridotGranted(address recipient, uint256 amount);

    /// @notice Emitted when PERIDOT accrued for a user has been manually adjusted.
    event PeridotAccruedAdjusted(address indexed user, uint256 oldPeridotAccrued, uint256 newPeridotAccrued);

    /// @notice Emitted when PERIDOT receivable for a user has been updated.
    event PeridotReceivableUpdated(address indexed user, uint256 oldPeridotReceivable, uint256 newPeridotReceivable);

    /// @notice The initial PERIDOT index for a market
    uint224 public constant peridotInitialIndex = 1e36;

    // closeFactorMantissa must be strictly greater than this value
    uint256 internal constant closeFactorMinMantissa = 0.05e18; // 0.05

    // closeFactorMantissa must not exceed this value
    uint256 internal constant closeFactorMaxMantissa = 0.9e18; // 0.9

    // No collateralFactorMantissa may exceed this value
    uint256 internal constant collateralFactorMaxMantissa = 0.9e18; // 0.9

    constructor() {
        admin = msg.sender;
    }

    /**
     * Assets You Are In **
     */

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (PToken[] memory) {
        PToken[] memory assetsIn = accountAssets[account];

        return assetsIn;
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param pToken The pToken to check
     * @return True if the account is in the asset, otherwise false.
     */
    function checkMembership(address account, PToken pToken) external view returns (bool) {
        return markets[address(pToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param pTokens The list of addresses of the pToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] memory pTokens) public override returns (uint256[] memory) {
        uint256 len = pTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            PToken pToken = PToken(pTokens[i]);

            results[i] = uint256(addToMarketInternal(pToken, msg.sender));
        }

        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param pToken The market to enter
     * @param borrower The address of the account to modify
     * @return Success indicator for whether the market was entered
     */
    function addToMarketInternal(PToken pToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(pToken)];

        if (!marketToJoin.isListed) {
            // market is not listed, cannot join
            return Error.MARKET_NOT_LISTED;
        }

        if (marketToJoin.accountMembership[borrower] == true) {
            // already joined
            return Error.NO_ERROR;
        }

        // survived the gauntlet, add to list
        // NOTE: we store these somewhat redundantly as a significant optimization
        //  this avoids having to iterate through the list for the most common use cases
        //  that is, only when we need to perform liquidity checks
        //  and not whenever we want to check if an account is in a particular market
        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(pToken);

        emit MarketEntered(pToken, borrower);

        return Error.NO_ERROR;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow.
     * @param pTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address pTokenAddress) external override returns (uint256) {
        PToken pToken = PToken(pTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the pToken */
        (uint256 oErr, uint256 tokensHeld, uint256 amountOwed,) = pToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint256 allowed = redeemAllowedInternal(pTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(pToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint256(Error.NO_ERROR);
        }

        /* Set pToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete pToken from the account’s list of assets */
        // load into memory for faster iteration
        PToken[] memory userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 assetIndex = len;
        for (uint256 i = 0; i < len; i++) {
            if (userAssetList[i] == pToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        PToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(pToken, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /**
     * Policy Hooks **
     */

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param pToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address pToken, address minter, uint256 mintAmount) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!mintGuardianPaused[pToken], "mint is paused");

        // Shh - currently unused
        minter;
        mintAmount;

        if (!markets[pToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        updatePeridotSupplyIndex(pToken);
        distributeSupplierPeridot(pToken, minter);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param pToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address pToken, address minter, uint256 actualMintAmount, uint256 mintTokens)
        external
        override
    {
        // Shh - currently unused
        pToken;
        minter;
        actualMintAmount;
        mintTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param pToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of pTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address pToken, address redeemer, uint256 redeemTokens)
        external
        override
        returns (uint256)
    {
        uint256 allowed = redeemAllowedInternal(pToken, redeemer, redeemTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updatePeridotSupplyIndex(pToken);
        distributeSupplierPeridot(pToken, redeemer);

        return uint256(Error.NO_ERROR);
    }

    function redeemAllowedInternal(address pToken, address redeemer, uint256 redeemTokens)
        internal
        view
        returns (uint256)
    {
        if (!markets[pToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[pToken].accountMembership[redeemer]) {
            return uint256(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err,, uint256 shortfall) =
            getHypotheticalAccountLiquidityInternal(redeemer, PToken(pToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit logs.
     * @param pToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    function redeemVerify(address pToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens)
        external
        override
    {
        // Shh - currently unused
        pToken;
        redeemer;

        // Require tokens is zero or amount is also zero
        if (redeemTokens == 0 && redeemAmount > 0) {
            revert("redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param pToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address pToken, address borrower, uint256 borrowAmount)
        external
        override
        returns (uint256)
    {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!borrowGuardianPaused[pToken], "borrow is paused");

        if (!markets[pToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (!markets[pToken].accountMembership[borrower]) {
            // only pTokens may call borrowAllowed if borrower not in market
            require(msg.sender == pToken, "sender must be pToken");

            // attempt to add borrower to the market
            Error addMarketErr = addToMarketInternal(PToken(msg.sender), borrower);
            if (addMarketErr != Error.NO_ERROR) {
                return uint256(addMarketErr);
            }

            // it should be impossible to break the important invariant
            assert(markets[pToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(PToken(pToken)) == 0) {
            return uint256(Error.PRICE_ERROR);
        }

        uint256 borrowCap = borrowCaps[pToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 totalBorrows = PToken(pToken).totalBorrows();
            uint256 nextTotalBorrows = add_(totalBorrows, borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err,, uint256 shortfall) =
            getHypotheticalAccountLiquidityInternal(borrower, PToken(pToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall > 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: PToken(pToken).borrowIndex()});
        updatePeridotBorrowIndex(pToken, borrowIndex);
        distributeBorrowerPeridot(pToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit logs.
     * @param pToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    function borrowVerify(address pToken, address borrower, uint256 borrowAmount) external override {
        // Shh - currently unused
        pToken;
        borrower;
        borrowAmount;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param pToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which would borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(address pToken, address payer, address borrower, uint256 repayAmount)
        external
        override
        returns (uint256)
    {
        // Shh - currently unused
        payer;
        borrower;
        repayAmount;

        if (!markets[pToken].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({mantissa: PToken(pToken).borrowIndex()});
        updatePeridotBorrowIndex(pToken, borrowIndex);
        distributeBorrowerPeridot(pToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit logs.
     * @param pToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address pToken,
        address payer,
        address borrower,
        uint256 actualRepayAmount,
        uint256 borrowerIndex
    ) external override {
        // Shh - currently unused
        pToken;
        payer;
        borrower;
        actualRepayAmount;
        borrowerIndex;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external override returns (uint256) {
        // Shh - currently unused
        liquidator;

        if (!markets[pTokenBorrowed].isListed || !markets[pTokenCollateral].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        uint256 borrowBalance = PToken(pTokenBorrowed).borrowBalanceStored(borrower);

        /* allow accounts to be liquidated if the market is deprecated */
        if (isDeprecated(PToken(pTokenBorrowed))) {
            require(borrowBalance >= repayAmount, "Can not repay more than the total borrow");
        } else {
            /* The borrower must have shortfall in order to be liquidatable */
            (Error err,, uint256 shortfall) = getAccountLiquidityInternal(borrower);
            if (err != Error.NO_ERROR) {
                return uint256(err);
            }

            if (shortfall == 0) {
                return uint256(Error.INSUFFICIENT_SHORTFALL);
            }

            /* The liquidator may not repay more than what is allowed by the closeFactor */
            uint256 maxClose = mul_ScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
            if (repayAmount > maxClose) {
                return uint256(Error.TOO_MUCH_REPAY);
            }
        }
        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function liquidateBorrowVerify(
        address pTokenBorrowed,
        address pTokenCollateral,
        address liquidator,
        address borrower,
        uint256 actualRepayAmount,
        uint256 seizeTokens
    ) external override {
        // Shh - currently unused
        pTokenBorrowed;
        pTokenCollateral;
        liquidator;
        borrower;
        actualRepayAmount;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external override returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizeGuardianPaused, "seize is paused");

        // Shh - currently unused
        seizeTokens;

        if (!markets[pTokenCollateral].isListed || !markets[pTokenBorrowed].isListed) {
            return uint256(Error.MARKET_NOT_LISTED);
        }

        if (PToken(pTokenCollateral).peridottroller() != PToken(pTokenBorrowed).peridottroller()) {
            return uint256(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updatePeridotSupplyIndex(pTokenCollateral);
        distributeSupplierPeridot(pTokenCollateral, borrower);
        distributeSupplierPeridot(pTokenCollateral, liquidator);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit logs.
     * @param pTokenCollateral Asset which was used as collateral and will be seized
     * @param pTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeVerify(
        address pTokenCollateral,
        address pTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external override {
        // Shh - currently unused
        pTokenCollateral;
        pTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param pToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of pTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(address pToken, address src, address dst, uint256 transferTokens)
        external
        override
        returns (uint256)
    {
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferGuardianPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint256 allowed = redeemAllowedInternal(pToken, src, transferTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updatePeridotSupplyIndex(pToken);
        distributeSupplierPeridot(pToken, src);
        distributeSupplierPeridot(pToken, dst);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit logs.
     * @param pToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of pTokens to transfer
     */
    function transferVerify(address pToken, address src, address dst, uint256 transferTokens) external override {
        // Shh - currently unused
        pToken;
        src;
        dst;
        transferTokens;

        // Shh - we don't ever want this hook to be marked pure
        if (false) {
            maxAssets = maxAssets;
        }
    }

    /**
     * Liquidity/Liquidation Calculations **
     */

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `pTokenBalance` is the number of pTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint256 sumCollateral;
        uint256 sumBorrowPlusEffects;
        uint256 pTokenBalance;
        uint256 borrowBalance;
        uint256 exchangeRateMantissa;
        uint256 oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
     *             account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) public view override returns (uint256, uint256, uint256) {
        (Error err, uint256 liquidity, uint256 shortfall) =
            getHypotheticalAccountLiquidityInternal(account, PToken(address(0)), 0, 0);

        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code,
     *             account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidityInternal(address account) internal view returns (Error, uint256, uint256) {
        return getHypotheticalAccountLiquidityInternal(account, PToken(address(0)), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
     *             hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address pTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) public view returns (uint256, uint256, uint256) {
        (Error err, uint256 liquidity, uint256 shortfall) =
            getHypotheticalAccountLiquidityInternal(account, PToken(pTokenModify), redeemTokens, borrowAmount);
        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param pTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @dev Note that we calculate the exchangeRateStored for each collateral pToken using stored data,
     *  without calculating accumulated interest.
     * @return (possible error code,
     *             hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidityInternal(
        address account,
        PToken pTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) internal view returns (Error, uint256, uint256) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint256 oErr;

        // For each asset the account is in
        PToken[] memory assets = accountAssets[account];
        for (uint256 i = 0; i < assets.length; i++) {
            PToken asset = assets[i];

            // Read the balances and exchange rate from the pToken
            (oErr, vars.pTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) =
                asset.getAccountSnapshot(account);
            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            // Pre-peridotute a conversion factor from tokens -> ether (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * pTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.pTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects =
                mul_ScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);

            // Calculate effects of interacting with pTokenModify
            if (asset == pTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects =
                    mul_ScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects =
                    mul_ScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in pToken.liquidateBorrowFresh)
     * @param pTokenBorrowed The address of the borrowed pToken
     * @param pTokenCollateral The address of the collateral pToken
     * @param actualRepayAmount The amount of pTokenBorrowed underlying to convert into pTokenCollateral tokens
     * @return (errorCode, number of pTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(address pTokenBorrowed, address pTokenCollateral, uint256 actualRepayAmount)
        external
        view
        override
        returns (uint256, uint256)
    {
        /* Read oracle prices for borrowed and collateral markets */
        uint256 priceBorrowedMantissa = oracle.getUnderlyingPrice(PToken(pTokenBorrowed));
        uint256 priceCollateralMantissa = oracle.getUnderlyingPrice(PToken(pTokenCollateral));
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint256(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint256 exchangeRateMantissa = PToken(pTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint256 seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(Exp({mantissa: liquidationIncentiveMantissa}), Exp({mantissa: priceBorrowedMantissa}));
        denominator = mul_(Exp({mantissa: priceCollateralMantissa}), Exp({mantissa: exchangeRateMantissa}));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint256(Error.NO_ERROR), seizeTokens);
    }

    /**
     * Admin Functions **
     */

    /**
     * @notice Sets a new price oracle for the peridottroller
     * @dev Admin function to set a new price oracle
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setPriceOracle(PriceOracle newOracle) public returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PRICE_ORACLE_OWNER_CHECK);
        }

        // Track the old oracle for the peridottroller
        PriceOracle oldOracle = oracle;

        // Set peridottroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @dev Admin function to set closeFactor
     * @param newCloseFactorMantissa New close factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure
     */
    function _setCloseFactor(uint256 newCloseFactorMantissa) external returns (uint256) {
        // Check caller is admin
        require(msg.sender == admin, "only admin can set close factor");

        uint256 oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @dev Admin function to set per-market collateralFactor
     * @param pToken The market to set the factor on
     * @param newCollateralFactorMantissa The new collateral factor, scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setCollateralFactor(PToken pToken, uint256 newCollateralFactorMantissa) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COLLATERAL_FACTOR_OWNER_CHECK);
        }

        // Verify market is listed
        Market storage market = markets[address(pToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa: newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(pToken) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint256 oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(pToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Sets liquidationIncentive
     * @dev Admin function to set liquidationIncentive
     * @param newLiquidationIncentiveMantissa New liquidationIncentive scaled by 1e18
     * @return uint 0=success, otherwise a failure. (See ErrorReporter for details)
     */
    function _setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa) external returns (uint256) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_LIQUIDATION_INCENTIVE_OWNER_CHECK);
        }

        // Save current value for use in log
        uint256 oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Admin function to set isListed and add support for the market
     * @param pToken The address of the market (token) to list
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(PToken pToken) external returns (uint256) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SUPPORT_MARKET_OWNER_CHECK);
        }

        if (markets[address(pToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        pToken.isPToken(); // Sanity check to make sure its really a PToken

        // Note that isPeridoted is not in active use anymore
        Market storage newMarket = markets[address(pToken)];
        newMarket.isListed = true;
        newMarket.isPeridoted = false;
        newMarket.collateralFactorMantissa = 0;

        _addMarketInternal(address(pToken));
        _initializeMarket(address(pToken));

        emit MarketListed(pToken);

        return uint256(Error.NO_ERROR);
    }

    function _addMarketInternal(address pToken) internal {
        for (uint256 i = 0; i < allMarkets.length; i++) {
            require(allMarkets[i] != PToken(pToken), "market already added");
        }
        allMarkets.push(PToken(pToken));
    }

    function _initializeMarket(address pToken) internal {
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");

        PeridotMarketState storage supplyState = peridotSupplyState[pToken];
        PeridotMarketState storage borrowState = peridotBorrowState[pToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = peridotInitialIndex;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = peridotInitialIndex;
        }

        /*
         * Update market state block numbers
         */
        supplyState.block = borrowState.block = blockNumber;
    }

    /**
     * @notice Set the given borrow caps for the given pToken markets. Borrowing that brings total borrows to or above borrow cap will revert.
     * @dev Admin or borrowCapGuardian function to set the borrow caps. A borrow cap of 0 corresponds to unlimited borrowing.
     * @param pTokens The addresses of the markets (tokens) to change the borrow caps for
     * @param newBorrowCaps The new borrow cap values in underlying to be set. A value of 0 corresponds to unlimited borrowing.
     */
    function _setMarketBorrowCaps(PToken[] calldata pTokens, uint256[] calldata newBorrowCaps) external {
        require(
            msg.sender == admin || msg.sender == borrowCapGuardian,
            "only admin or borrow cap guardian can set borrow caps"
        );

        uint256 numMarkets = pTokens.length;
        uint256 numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for (uint256 i = 0; i < numMarkets; i++) {
            borrowCaps[address(pTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(pTokens[i], newBorrowCaps[i]);
        }
    }

    /**
     * @notice Admin function to change the Borrow Cap Guardian
     * @param newBorrowCapGuardian The address of the new Borrow Cap Guardian
     */
    function _setBorrowCapGuardian(address newBorrowCapGuardian) external {
        require(msg.sender == admin, "only admin can set borrow cap guardian");

        // Save current value for inclusion in log
        address oldBorrowCapGuardian = borrowCapGuardian;

        // Store borrowCapGuardian with value newBorrowCapGuardian
        borrowCapGuardian = newBorrowCapGuardian;

        // Emit NewBorrowCapGuardian(OldBorrowCapGuardian, NewBorrowCapGuardian)
        emit NewBorrowCapGuardian(oldBorrowCapGuardian, newBorrowCapGuardian);
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param newPauseGuardian The address of the new Pause Guardian
     * @return uint 0=success, otherwise a failure. (See enum Error for details)
     */
    function _setPauseGuardian(address newPauseGuardian) public returns (uint256) {
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_PAUSE_GUARDIAN_OWNER_CHECK);
        }

        // Save current value for inclusion in log
        address oldPauseGuardian = pauseGuardian;

        // Store pauseGuardian with value newPauseGuardian
        pauseGuardian = newPauseGuardian;

        // Emit NewPauseGuardian(OldPauseGuardian, NewPauseGuardian)
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);

        return uint256(Error.NO_ERROR);
    }

    function _setMintPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        mintGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(PToken pToken, bool state) public returns (bool) {
        require(markets[address(pToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        borrowGuardianPaused[address(pToken)] = state;
        emit ActionPaused(pToken, "Borrow", state);
        return state;
    }

    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        transferGuardianPaused = state;
        emit ActionPaused("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || state == true, "only admin can unpause");

        seizeGuardianPaused = state;
        emit ActionPaused("Seize", state);
        return state;
    }

    function _become(Unitroller unitroller) public {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /// @notice Delete this function after proposal 65 is executed
    function fixBadAccruals(address[] calldata affectedUsers, uint256[] calldata amounts) external {
        require(msg.sender == admin, "Only admin can call this function"); // Only the timelock can call this function
        require(!proposal65FixExecuted, "Already executed this one-off function"); // Require that this function is only called once
        require(affectedUsers.length == amounts.length, "Invalid input");

        // Loop variables
        address user;
        uint256 currentAccrual;
        uint256 amountToSubtract;
        uint256 newAccrual;

        // Iterate through all affected users
        for (uint256 i = 0; i < affectedUsers.length; ++i) {
            user = affectedUsers[i];
            currentAccrual = peridotAccrued[user];

            amountToSubtract = amounts[i];

            // The case where the user has claimed and received an incorrect amount of PERIDOT.
            // The user has less currently accrued than the amount they incorrectly received.
            if (amountToSubtract > currentAccrual) {
                // Amount of PERIDOT the user owes the protocol
                uint256 accountReceivable = amountToSubtract - currentAccrual; // Underflow safe since amountToSubtract > currentAccrual

                uint256 oldReceivable = peridotReceivable[user];
                uint256 newReceivable = add_(oldReceivable, accountReceivable);

                // Accounting: record the PERIDOT debt for the user
                peridotReceivable[user] = newReceivable;

                emit PeridotReceivableUpdated(user, oldReceivable, newReceivable);

                amountToSubtract = currentAccrual;
            }

            if (amountToSubtract > 0) {
                // Subtract the bad accrual amount from what they have accrued.
                // Users will keep whatever they have correctly accrued.
                peridotAccrued[user] = newAccrual = sub_(currentAccrual, amountToSubtract);

                emit PeridotAccruedAdjusted(user, currentAccrual, newAccrual);
            }
        }

        proposal65FixExecuted = true; // Makes it so that this function cannot be called again
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == peridottrollerImplementation;
    }

    /**
     * Peridot Distribution **
     */

    /**
     * @notice Set PERIDOT speed for a single market
     * @param pToken The market whose PERIDOT speed to update
     * @param supplySpeed New supply-side PERIDOT speed for market
     * @param borrowSpeed New borrow-side PERIDOT speed for market
     */
    function setPeridotSpeedInternal(PToken pToken, uint256 supplySpeed, uint256 borrowSpeed) internal {
        Market storage market = markets[address(pToken)];
        require(market.isListed, "peridot market is not listed");

        if (peridotSupplySpeeds[address(pToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. PERIDOT accrued properly for the old speed, and
            //  2. PERIDOT accrued at the new speed starts after this block.
            updatePeridotSupplyIndex(address(pToken));

            // Update speed and emit event
            peridotSupplySpeeds[address(pToken)] = supplySpeed;
            emit PeridotSupplySpeedUpdated(pToken, supplySpeed);
        }

        if (peridotBorrowSpeeds[address(pToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. PERIDOT accrued properly for the old speed, and
            //  2. PERIDOT accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({mantissa: pToken.borrowIndex()});
            updatePeridotBorrowIndex(address(pToken), borrowIndex);

            // Update speed and emit event
            peridotBorrowSpeeds[address(pToken)] = borrowSpeed;
            emit PeridotBorrowSpeedUpdated(pToken, borrowSpeed);
        }
    }

    /**
     * @notice Accrue PERIDOT to the market by updating the supply index
     * @param pToken The market whose supply index to update
     * @dev Index is a cumulative sum of the PERIDOT per pToken accrued.
     */
    function updatePeridotSupplyIndex(address pToken) internal {
        PeridotMarketState storage supplyState = peridotSupplyState[pToken];
        uint256 supplySpeed = peridotSupplySpeeds[pToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint256 deltaBlocks = sub_(uint256(blockNumber), uint256(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = PToken(pToken).totalSupply();
            uint256 peridotAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(peridotAccrued, supplyTokens) : Double({mantissa: 0});
            supplyState.index =
                safe224(add_(Double({mantissa: supplyState.index}), ratio).mantissa, "new index exceeds 224 bits");
            supplyState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice Accrue PERIDOT to the market by updating the borrow index
     * @param pToken The market whose borrow index to update
     * @dev Index is a cumulative sum of the PERIDOT per pToken accrued.
     */
    function updatePeridotBorrowIndex(address pToken, Exp memory marketBorrowIndex) internal {
        PeridotMarketState storage borrowState = peridotBorrowState[pToken];
        uint256 borrowSpeed = peridotBorrowSpeeds[pToken];
        uint32 blockNumber = safe32(getBlockNumber(), "block number exceeds 32 bits");
        uint256 deltaBlocks = sub_(uint256(blockNumber), uint256(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint256 borrowAmount = div_(PToken(pToken).totalBorrows(), marketBorrowIndex);
            uint256 peridotAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(peridotAccrued, borrowAmount) : Double({mantissa: 0});
            borrowState.index =
                safe224(add_(Double({mantissa: borrowState.index}), ratio).mantissa, "new index exceeds 224 bits");
            borrowState.block = blockNumber;
        } else if (deltaBlocks > 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice Calculate PERIDOT accrued by a supplier and possibly transfer it to them
     * @param pToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute PERIDOT to
     */
    function distributeSupplierPeridot(address pToken, address supplier) internal {
        // TODO: Don't distribute supplier PERIDOT if the user is not in the supplier market.
        // This check should be as gas efficient as possible as distributeSupplierPeridot is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        PeridotMarketState storage supplyState = peridotSupplyState[pToken];
        uint256 supplyIndex = supplyState.index;
        uint256 supplierIndex = peridotSupplierIndex[pToken][supplier];

        // Update supplier's index to the current index since we are distributing accrued PERIDOT
        peridotSupplierIndex[pToken][supplier] = supplyIndex;

        if (supplierIndex == 0 && supplyIndex >= peridotInitialIndex) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with PERIDOT accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = peridotInitialIndex;
        }

        // Calculate change in the cumulative sum of the PERIDOT per pToken accrued
        Double memory deltaIndex = Double({mantissa: sub_(supplyIndex, supplierIndex)});

        uint256 supplierTokens = PToken(pToken).balanceOf(supplier);

        // Calculate PERIDOT accrued: pTokenAmount * accruedPerPToken
        uint256 supplierDelta = mul_(supplierTokens, deltaIndex);

        uint256 supplierAccrued = add_(peridotAccrued[supplier], supplierDelta);
        peridotAccrued[supplier] = supplierAccrued;

        emit DistributedSupplierPeridot(PToken(pToken), supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice Calculate PERIDOT accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol.
     * @param pToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute PERIDOT to
     */
    function distributeBorrowerPeridot(address pToken, address borrower, Exp memory marketBorrowIndex) internal {
        // TODO: Don't distribute supplier PERIDOT if the user is not in the borrower market.
        // This check should be as gas efficient as possible as distributeBorrowerPeridot is called in many places.
        // - We really don't want to call an external contract as that's quite expensive.

        PeridotMarketState storage borrowState = peridotBorrowState[pToken];
        uint256 borrowIndex = borrowState.index;
        uint256 borrowerIndex = peridotBorrowerIndex[pToken][borrower];

        // Update borrowers's index to the current index since we are distributing accrued PERIDOT
        peridotBorrowerIndex[pToken][borrower] = borrowIndex;

        if (borrowerIndex == 0 && borrowIndex >= peridotInitialIndex) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with PERIDOT accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = peridotInitialIndex;
        }

        // Calculate change in the cumulative sum of the PERIDOT per borrowed unit accrued
        Double memory deltaIndex = Double({mantissa: sub_(borrowIndex, borrowerIndex)});

        uint256 borrowerAmount = div_(PToken(pToken).borrowBalanceStored(borrower), marketBorrowIndex);

        // Calculate PERIDOT accrued: pTokenAmount * accruedPerBorrowedUnit
        uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);

        uint256 borrowerAccrued = add_(peridotAccrued[borrower], borrowerDelta);
        peridotAccrued[borrower] = borrowerAccrued;

        emit DistributedBorrowerPeridot(PToken(pToken), borrower, borrowerDelta, borrowIndex);
    }

    /**
     * @notice Calculate additional accrued PERIDOT for a contributor since last accrual
     * @param contributor The address to calculate contributor rewards for
     */
    function updateContributorRewards(address contributor) public {
        uint256 peridotSpeed = peridotContributorSpeeds[contributor];
        uint256 blockNumber = getBlockNumber();
        uint256 deltaBlocks = sub_(blockNumber, lastContributorBlock[contributor]);
        if (deltaBlocks > 0 && peridotSpeed > 0) {
            uint256 newAccrued = mul_(deltaBlocks, peridotSpeed);
            uint256 contributorAccrued = add_(peridotAccrued[contributor], newAccrued);

            peridotAccrued[contributor] = contributorAccrued;
            lastContributorBlock[contributor] = blockNumber;
        }
    }

    /**
     * @notice Claim all the peridot accrued by holder in all markets
     * @param holder The address to claim PERIDOT for
     */
    function claimPeridot(address holder) public {
        return claimPeridot(holder, allMarkets);
    }

    /**
     * @notice Claim all the peridot accrued by holder in the specified markets
     * @param holder The address to claim PERIDOT for
     * @param pTokens The list of markets to claim PERIDOT in
     */
    function claimPeridot(address holder, PToken[] memory pTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimPeridot(holders, pTokens, true, true);
    }

    /**
     * @notice Claim all peridot accrued by the holders
     * @param holders The addresses to claim PERIDOT for
     * @param pTokens The list of markets to claim PERIDOT in
     * @param borrowers Whether or not to claim PERIDOT earned by borrowing
     * @param suppliers Whether or not to claim PERIDOT earned by supplying
     */
    function claimPeridot(address[] memory holders, PToken[] memory pTokens, bool borrowers, bool suppliers) public {
        for (uint256 i = 0; i < pTokens.length; i++) {
            PToken pToken = pTokens[i];
            require(markets[address(pToken)].isListed, "market must be listed");
            if (borrowers == true) {
                Exp memory borrowIndex = Exp({mantissa: pToken.borrowIndex()});
                updatePeridotBorrowIndex(address(pToken), borrowIndex);
                for (uint256 j = 0; j < holders.length; j++) {
                    distributeBorrowerPeridot(address(pToken), holders[j], borrowIndex);
                }
            }
            if (suppliers == true) {
                updatePeridotSupplyIndex(address(pToken));
                for (uint256 j = 0; j < holders.length; j++) {
                    distributeSupplierPeridot(address(pToken), holders[j]);
                }
            }
        }
        for (uint256 j = 0; j < holders.length; j++) {
            peridotAccrued[holders[j]] = grantPeridotInternal(holders[j], peridotAccrued[holders[j]]);
        }
    }

    /**
     * @notice Transfer PERIDOT to the user
     * @dev Note: If there is not enough PERIDOT, we do not perform the transfer all.
     * @param user The address of the user to transfer PERIDOT to
     * @param amount The amount of PERIDOT to (possibly) transfer
     * @return The amount of PERIDOT which was NOT transferred to the user
     */
    function grantPeridotInternal(address user, uint256 amount) internal returns (uint256) {
        Peridot peridot = Peridot(getPeridotAddress());
        uint256 peridotRemaining = peridot.balanceOf(address(this));
        if (amount > 0 && amount <= peridotRemaining) {
            peridot.transfer(user, amount);
            return 0;
        }
        return amount;
    }

    /**
     * Peridot Distribution Admin **
     */

    /**
     * @notice Transfer PERIDOT to the recipient
     * @dev Note: If there is not enough PERIDOT, we do not perform the transfer all.
     * @param recipient The address of the recipient to transfer PERIDOT to
     * @param amount The amount of PERIDOT to (possibly) transfer
     */
    function _grantPeridot(address recipient, uint256 amount) public {
        require(adminOrInitializing(), "only admin can grant peridot");
        uint256 amountLeft = grantPeridotInternal(recipient, amount);
        require(amountLeft == 0, "insufficient peridot for grant");
        emit PeridotGranted(recipient, amount);
    }

    /**
     * @notice Set PERIDOT borrow and supply speeds for the specified markets.
     * @param pTokens The markets whose PERIDOT speed to update.
     * @param supplySpeeds New supply-side PERIDOT speed for the corresponding market.
     * @param borrowSpeeds New borrow-side PERIDOT speed for the corresponding market.
     */
    function _setPeridotSpeeds(PToken[] memory pTokens, uint256[] memory supplySpeeds, uint256[] memory borrowSpeeds)
        public
    {
        require(adminOrInitializing(), "only admin can set peridot speed");

        uint256 numTokens = pTokens.length;
        require(
            numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length,
            "Peridottroller::_setPeridotSpeeds invalid input"
        );

        for (uint256 i = 0; i < numTokens; ++i) {
            setPeridotSpeedInternal(pTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    /**
     * @notice Set PERIDOT speed for a single contributor
     * @param contributor The contributor whose PERIDOT speed to update
     * @param peridotSpeed New PERIDOT speed for contributor
     */
    function _setContributorPeridotSpeed(address contributor, uint256 peridotSpeed) public {
        require(adminOrInitializing(), "only admin can set peridot speed");

        // note that PERIDOT speed could be set to 0 to halt liquidity rewards for a contributor
        updateContributorRewards(contributor);
        if (peridotSpeed == 0) {
            // release storage
            delete lastContributorBlock[contributor];
        } else {
            lastContributorBlock[contributor] = getBlockNumber();
        }
        peridotContributorSpeeds[contributor] = peridotSpeed;

        emit ContributorPeridotSpeedUpdated(contributor, peridotSpeed);
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market.
     * @return The list of market addresses
     */
    function getAllMarkets() public view override returns (PToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Returns true if the given pToken market has been deprecated
     * @dev All borrows in a deprecated pToken market can be immediately liquidated
     * @param pToken The market to check if deprecated
     */
    function isDeprecated(PToken pToken) public view returns (bool) {
        return markets[address(pToken)].collateralFactorMantissa == 0 && borrowGuardianPaused[address(pToken)] == true
            && pToken.reserveFactorMantissa() == 1e18;
    }

    function getBlockNumber() public view virtual returns (uint256) {
        return block.number;
    }

    /**
     * @notice Return the address of the PERIDOT token
     * @return The address of PERIDOT
     */
    function getPeridotAddress() public view virtual returns (address) {
        return 0x507f0F5E58d21f07d133722e038067248fe4ecBE;
    }
}
