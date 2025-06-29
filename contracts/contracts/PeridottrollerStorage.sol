// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PToken.sol";
import "./PriceOracle.sol";

contract UnitrollerAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of Unitroller
     */
    address public peridottrollerImplementation;

    /**
     * @notice Pending brains of Unitroller
     */
    address public pendingPeridottrollerImplementation;
}

contract PeridottrollerV1Storage is UnitrollerAdminStorage {
    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => PToken[]) public accountAssets;
}

contract PeridottrollerV2Storage is PeridottrollerV1Storage {
    struct Market {
        // Whether or not this market is listed
        bool isListed;
        //  Multiplier representing the most one can borrow against their collateral in this market.
        //  For instance, 0.9 to allow borrowing 90% of collateral value.
        //  Must be between 0 and 1, and stored as a mantissa.
        uint collateralFactorMantissa;
        // Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;
        // Whether or not this market receives PERIDOT
        bool isPeridoted;
    }

    /**
     * @notice Official mapping of pTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    address public pauseGuardian;
    bool public _mintGuardianPaused;
    bool public _borrowGuardianPaused;
    bool public transferGuardianPaused;
    bool public seizeGuardianPaused;
    mapping(address => bool) public mintGuardianPaused;
    mapping(address => bool) public borrowGuardianPaused;
}

contract PeridottrollerV3Storage is PeridottrollerV2Storage {
    struct PeridotMarketState {
        // The market's last updated peridotBorrowIndex or peridotSupplyIndex
        uint224 index;
        // The block number the index was last updated at
        uint32 block;
    }

    /// @notice A list of all markets
    PToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes PERIDOT, per block
    uint public peridotRate;

    /// @notice The portion of peridotRate that each market currently receives
    mapping(address => uint) public peridotSpeeds;

    /// @notice The PERIDOT market supply state for each market
    mapping(address => PeridotMarketState) public peridotSupplyState;

    /// @notice The PERIDOT market borrow state for each market
    mapping(address => PeridotMarketState) public peridotBorrowState;

    /// @notice The PERIDOT borrow index for each market for each supplier as of the last time they accrued PERIDOT
    mapping(address => mapping(address => uint)) public peridotSupplierIndex;

    /// @notice The PERIDOT borrow index for each market for each borrower as of the last time they accrued PERIDOT
    mapping(address => mapping(address => uint)) public peridotBorrowerIndex;

    /// @notice The PERIDOT accrued but not yet transferred to each user
    mapping(address => uint) public peridotAccrued;
}

contract PeridottrollerV4Storage is PeridottrollerV3Storage {
    // @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    // @notice Borrow caps enforced by borrowAllowed for each pToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint) public borrowCaps;
}

contract PeridottrollerV5Storage is PeridottrollerV4Storage {
    /// @notice The portion of PERIDOT that each contributor receives per block
    mapping(address => uint) public peridotContributorSpeeds;

    /// @notice Last block at which a contributor's PERIDOT rewards have been allocated
    mapping(address => uint) public lastContributorBlock;
}

contract PeridottrollerV6Storage is PeridottrollerV5Storage {
    /// @notice The rate at which peridot is distributed to the corresponding borrow market (per block)
    mapping(address => uint) public peridotBorrowSpeeds;

    /// @notice The rate at which peridot is distributed to the corresponding supply market (per block)
    mapping(address => uint) public peridotSupplySpeeds;
}

contract PeridottrollerV7Storage is PeridottrollerV6Storage {
    /// @notice Flag indicating whether the function to fix PERIDOT accruals has been executed (RE: proposal 62 bug)
    bool public proposal65FixExecuted;

    /// @notice Accounting storage mapping account addresses to how much PERIDOT they owe the protocol.
    mapping(address => uint) public peridotReceivable;
}
