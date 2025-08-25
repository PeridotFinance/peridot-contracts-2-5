// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PErc20} from "./PErc20.sol";
import {EIP20Interface} from "./EIP20Interface.sol";
import {PeridottrollerInterface} from "./PeridottrollerInterface.sol";
import {InterestRateModel} from "./InterestRateModel.sol";

/**
 * @title PErc20CrossChain
 * @author Peridot
 * @notice This contract extends PErc20 to add cross-chain functionality.
 * It introduces mintFor and borrowFor functions that can only be called by the authorized PeridotHubHandler.
 */
contract PErc20CrossChain is PErc20 {
    address public hubHandler;

    event HubHandlerUpdated(address indexed oldHubHandler, address indexed newHubHandler);

    // Constructor sets the deployer as initial admin and the hub handler.
    constructor(address _hubHandler) {
        admin = payable(msg.sender);
        hubHandler = _hubHandler;
    }

    modifier onlyHubHandler() {
        require(msg.sender == hubHandler, "Caller is not the hub handler");
        _;
    }

    /**
     * @notice Mints pTokens for a user on the hub chain.
     * @param user The address of the user to mint for.
     * @param mintAmount The amount of the underlying asset to supply.
     */
    function mintFor(address user, uint256 mintAmount) external onlyHubHandler returns (uint256) {
        accrueInterest();

        // Ensure mint is allowed by Peridottroller
        uint256 allowed = peridottroller.mintAllowed(address(this), user, mintAmount);
        require(allowed == 0, "Mint not allowed");
        require(accrualBlockNumber == getBlockNumber(), "Stale block");

        // Pull the underlying tokens from the HubHandler (msg.sender)
        uint256 actualMintAmount = doTransferIn(msg.sender, mintAmount);

        // Calculate number of pTokens to mint
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});
        uint256 mintTokens = div_(actualMintAmount, exchangeRate);

        // Update accounting
        totalSupply = totalSupply + mintTokens;
        accountTokens[user] = accountTokens[user] + mintTokens;

        emit Mint(user, actualMintAmount, mintTokens);
        emit Transfer(address(this), user, mintTokens);

        return NO_ERROR;
    }

    /**
     * @notice Borrows an asset for a user on the hub chain.
     * @param user The address of the user to borrow for.
     * @param borrowAmount The amount of the underlying asset to borrow.
     */
    function borrowFor(address user, uint256 borrowAmount) external onlyHubHandler returns (uint256) {
        accrueInterest();

        // Check if borrow is allowed
        uint256 allowed = peridottroller.borrowAllowed(address(this), user, borrowAmount);
        require(allowed == 0, "Borrow not allowed");
        require(accrualBlockNumber == getBlockNumber(), "Stale block");

        // Update borrow accounting for the user
        uint256 accountBorrowsPrev = borrowBalanceStoredInternal(user);
        uint256 accountBorrowsNew = accountBorrowsPrev + borrowAmount;
        uint256 totalBorrowsNew = totalBorrows + borrowAmount;

        accountBorrows[user].principal = accountBorrowsNew;
        accountBorrows[user].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;

        // Transfer tokens from this contract to the HubHandler for cross-chain delivery
        doTransferOut(payable(msg.sender), borrowAmount);

        emit Borrow(user, borrowAmount, accountBorrowsNew, totalBorrowsNew);

        return NO_ERROR;
    }

    /**
     * @notice Admin function to update the authorized hub handler.
     * @param newHubHandler The address of the new hub handler contract.
     * @return uint 0=success, otherwise a failure
     */
    function setHubHandler(address newHubHandler) external returns (uint256) {
        require(msg.sender == admin, "Only admin");
        require(newHubHandler != address(0), "Invalid hub handler");
        address oldHubHandler = hubHandler;
        hubHandler = newHubHandler;
        emit HubHandlerUpdated(oldHubHandler, newHubHandler);
        return NO_ERROR;
    }
}
