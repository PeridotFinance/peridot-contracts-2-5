// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface IAtomicMarginExecutorEntry {
    function getAccount(address user) external view returns (address sma, bool withdrawalsLocked, uint64 lastHealthRecalc);
    function enableBorrowingFor(address user) external returns (address sma);
    function openLeveragedPositionAtomicFor(
        address user,
        address quoteAsset,
        address baseAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minBaseReceived,
        bytes calldata routerData
    ) external returns (uint256 baseAcquired);
    function openShortPositionAtomicFor(
        address user,
        address baseAsset,
        address quoteAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minQuoteReceived,
        bytes calldata routerData
    ) external returns (uint256 quoteReceived);
    function closeLeveragedPositionFor(
        address user,
        address collateralAsset,
        address repayAsset,
        uint256 collateralToRedeem,
        uint256 repayAmount,
        uint256 minRepayAmount,
        bytes calldata routerData
    ) external returns (uint256 repaidAmount);
}

interface IMarginCollateralVaultEntry {
    function moveToMarginFor(address user, address pToken, uint256 amount) external;
    function moveToEarningFor(address user, address pToken, uint256 amount, address to) external;
}

contract MarginEntryRouter is Ownable {
    IAtomicMarginExecutorEntry public immutable executor;
    IMarginCollateralVaultEntry public immutable collateralVault;

    event MarginAccountPrepared(address indexed user, address sma);
    event MoveToMarginAndOpenLong(
        address indexed user,
        address indexed marginPToken,
        uint256 marginPTokenAmount,
        address indexed quoteAsset,
        address baseAsset,
        uint256 userCollateral,
        uint256 baseAcquired
    );
    event MoveToMarginAndOpenShort(
        address indexed user,
        address indexed marginPToken,
        uint256 marginPTokenAmount,
        address indexed baseAsset,
        address quoteAsset,
        uint256 userCollateral,
        uint256 quoteReceived
    );
    event CloseLeveragedPosition(
        address indexed user,
        address indexed collateralAsset,
        address indexed repayAsset,
        uint256 collateralToRedeem,
        uint256 repaidAmount
    );
    event CloseLeveragedPositionAndMoveToEarning(
        address indexed user,
        address indexed marginPToken,
        uint256 marginPTokenAmount,
        address indexed collateralAsset,
        address repayAsset,
        uint256 repaidAmount
    );

    constructor(address executor_, address collateralVault_, address owner_) Ownable(owner_) {
        require(executor_ != address(0), "EntryRouter: invalid executor");
        require(collateralVault_ != address(0), "EntryRouter: invalid vault");
        executor = IAtomicMarginExecutorEntry(executor_);
        collateralVault = IMarginCollateralVaultEntry(collateralVault_);
    }

    function ensureMarginAccount() external returns (address sma) {
        (sma,,) = executor.getAccount(msg.sender);
        if (sma == address(0)) {
            sma = executor.enableBorrowingFor(msg.sender);
            emit MarginAccountPrepared(msg.sender, sma);
        }
    }

    function moveToMarginAndOpenLong(
        address marginPToken,
        uint256 marginPTokenAmount,
        address quoteAsset,
        address baseAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minBaseReceived,
        bytes calldata routerData
    ) external returns (uint256 baseAcquired) {
        _ensureMarginAccount(msg.sender);

        if (marginPTokenAmount > 0) {
            collateralVault.moveToMarginFor(msg.sender, marginPToken, marginPTokenAmount);
        }

        baseAcquired = executor.openLeveragedPositionAtomicFor(
            msg.sender,
            quoteAsset,
            baseAsset,
            userCollateral,
            leverageX100,
            minBaseReceived,
            routerData
        );

        emit MoveToMarginAndOpenLong(
            msg.sender,
            marginPToken,
            marginPTokenAmount,
            quoteAsset,
            baseAsset,
            userCollateral,
            baseAcquired
        );
    }

    function moveToMarginAndOpenShort(
        address marginPToken,
        uint256 marginPTokenAmount,
        address baseAsset,
        address quoteAsset,
        uint256 userCollateral,
        uint16 leverageX100,
        uint256 minQuoteReceived,
        bytes calldata routerData
    ) external returns (uint256 quoteReceived) {
        _ensureMarginAccount(msg.sender);

        if (marginPTokenAmount > 0) {
            collateralVault.moveToMarginFor(msg.sender, marginPToken, marginPTokenAmount);
        }

        quoteReceived = executor.openShortPositionAtomicFor(
            msg.sender,
            baseAsset,
            quoteAsset,
            userCollateral,
            leverageX100,
            minQuoteReceived,
            routerData
        );

        emit MoveToMarginAndOpenShort(
            msg.sender,
            marginPToken,
            marginPTokenAmount,
            baseAsset,
            quoteAsset,
            userCollateral,
            quoteReceived
        );
    }

    function closeLeveragedPosition(
        address collateralAsset,
        address repayAsset,
        uint256 collateralToRedeem,
        uint256 repayAmount,
        uint256 minRepayAmount,
        bytes calldata routerData
    ) external returns (uint256 repaidAmount) {
        repaidAmount = executor.closeLeveragedPositionFor(
            msg.sender,
            collateralAsset,
            repayAsset,
            collateralToRedeem,
            repayAmount,
            minRepayAmount,
            routerData
        );

        emit CloseLeveragedPosition(
            msg.sender,
            collateralAsset,
            repayAsset,
            collateralToRedeem,
            repaidAmount
        );
    }

    function closeLeveragedPositionAndMoveToEarning(
        address marginPToken,
        uint256 marginPTokenAmount,
        address collateralAsset,
        address repayAsset,
        uint256 collateralToRedeem,
        uint256 repayAmount,
        uint256 minRepayAmount,
        bytes calldata routerData
    ) external returns (uint256 repaidAmount) {
        repaidAmount = executor.closeLeveragedPositionFor(
            msg.sender,
            collateralAsset,
            repayAsset,
            collateralToRedeem,
            repayAmount,
            minRepayAmount,
            routerData
        );

        if (marginPTokenAmount > 0) {
            collateralVault.moveToEarningFor(msg.sender, marginPToken, marginPTokenAmount, msg.sender);
        }

        emit CloseLeveragedPositionAndMoveToEarning(
            msg.sender,
            marginPToken,
            marginPTokenAmount,
            collateralAsset,
            repayAsset,
            repaidAmount
        );
    }

    function _ensureMarginAccount(address user) internal returns (address sma) {
        (sma,,) = executor.getAccount(user);
        if (sma == address(0)) {
            sma = executor.enableBorrowingFor(user);
            emit MarginAccountPrepared(user, sma);
        }
    }
}
