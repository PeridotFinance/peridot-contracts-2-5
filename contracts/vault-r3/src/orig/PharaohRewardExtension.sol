// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IPharaohPositionManager} from "./interfaces/pharaoh/IPharaohPositionManager.sol";
import {IXPhar} from "./interfaces/pharaoh/IXPhar.sol";

interface IPharaohRewardState {
    function tokenId() external view returns (uint256);
    function positionManager() external view returns (IPharaohPositionManager);
}

/// @title PharaohRewardExtension
/// @notice Adds PHAR/xPHAR recovery while delegating the existing vault API to
///         the exact reviewed implementation already active on Avalanche.
/// @dev This contract is installed directly as the Transparent Proxy
///      implementation. Calls other than this extension's selectors are
///      delegatecalled to BASE_IMPLEMENTATION, preserving proxy storage,
///      msg.sender, msg.value, return data, and revert data.
contract PharaohRewardExtension is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    address private constant BASE_IMPLEMENTATION = 0x37E28a2C9FA3bBdab81efA69D5D480f5107a3770;
    bytes32 private constant BASE_IMPLEMENTATION_CODEHASH =
        0x416f2a818693b20948fc44e9955ec7a370be051599b1eef6ca1fad932f3626ef;

    IERC20 private constant PHAR = IERC20(0x13A466998Ce03Db73aBc2d4DF3bBD845Ed1f28E7);
    IERC20 private constant XPHAR = IERC20(0xE8164Ea89665DAb7a553e667F81F30CfDA736B9A);

    error RewardExtension__InvalidBaseImplementation(bytes32 actualCodehash);
    error RewardExtension__NoXPhar();
    error RewardExtension__InsufficientXPharExit(uint256 actualPhar, uint256 minimumPhar);

    event RewardsHarvested(uint256 pharForwarded, uint256 xPharExited, uint256 pharFromXPhar);

    constructor() {
        bytes32 actualCodehash = BASE_IMPLEMENTATION.codehash;
        if (actualCodehash != BASE_IMPLEMENTATION_CODEHASH) {
            revert RewardExtension__InvalidBaseImplementation(actualCodehash);
        }
        _disableInitializers();
    }

    /// @notice Claims fixed Pharaoh incentives and forwards liquid PHAR to the
    ///         current vault owner for an atomic swap-and-donation Safe batch.
    /// @param claimPosition Whether to call the position manager for the
    ///        position's PHAR and xPHAR before forwarding existing balances.
    /// @param minimumPharFromXPhar Zero retains xPHAR. A nonzero value opts
    ///        into exiting the complete xPHAR balance and bounds the irreversible
    ///        conversion, which currently applies a protocol-level penalty.
    function harvestRewards(bool claimPosition, uint256 minimumPharFromXPhar)
        external
        onlyOwner
        nonReentrant
        returns (uint256 pharForwarded, uint256 xPharExited)
    {
        IPharaohRewardState vault = IPharaohRewardState(address(this));
        if (claimPosition) {
            uint256 positionId = vault.tokenId();
            if (positionId != 0) {
                address[] memory rewards = new address[](2);
                rewards[0] = address(PHAR);
                rewards[1] = address(XPHAR);
                vault.positionManager().getReward(positionId, rewards);
            }
        }

        uint256 pharFromXPhar;
        if (minimumPharFromXPhar != 0) {
            xPharExited = XPHAR.balanceOf(address(this));
            if (xPharExited == 0) revert RewardExtension__NoXPhar();

            uint256 pharBefore = PHAR.balanceOf(address(this));
            IXPhar(address(XPHAR)).exit(xPharExited);
            pharFromXPhar = PHAR.balanceOf(address(this)) - pharBefore;
            if (pharFromXPhar < minimumPharFromXPhar) {
                revert RewardExtension__InsufficientXPharExit(pharFromXPhar, minimumPharFromXPhar);
            }
        }

        pharForwarded = PHAR.balanceOf(address(this));
        if (pharForwarded != 0) PHAR.safeTransfer(owner(), pharForwarded);
        emit RewardsHarvested(pharForwarded, xPharExited, pharFromXPhar);
    }

    fallback() external payable {
        address implementation = BASE_IMPLEMENTATION;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(success) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
