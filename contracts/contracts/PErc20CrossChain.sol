// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PErc20} from "./PErc20.sol";
import {EIP20Interface} from "./EIP20Interface.sol";

/**
 * @title PErc20CrossChain
 * @author Peridot
 * @notice This contract extends PErc20 to add cross-chain functionality.
 * It introduces mintFor and borrowFor functions that can only be called by the authorized PeridotForwarder.
 */
contract PErc20CrossChain is PErc20 {
    address public peridotForwarder;

    // Constructor sets the deployer as initial admin so initialize can be called safely.
    constructor() {
        admin = payable(msg.sender);
    }

    event ForwarderSet(address indexed oldForwarder, address indexed newForwarder);

    modifier onlyForwarder() {
        require(msg.sender == peridotForwarder, "Caller is not the forwarder");
        _;
    }

    /**
     * @notice Sets the address of the PeridotForwarder contract.
     * @param _forwarder The address of the forwarder.
     */
    function _setForwarder(address _forwarder) external {
        // require(msg.sender == admin, "Only admin can set forwarder");
        address oldForwarder = peridotForwarder;
        peridotForwarder = _forwarder;
        emit ForwarderSet(oldForwarder, _forwarder);
    }

    /**
     * @notice Mints pTokens for a user on the hub chain.
     * @param user The address of the user to mint for.
     * @param mintAmount The amount of the underlying asset to supply.
     */
    function mintFor(address user, uint256 mintAmount) external onlyForwarder returns (uint) {
        accrueInterest();

        // Ensure mint is allowed by Peridottroller
        uint allowed = peridottroller.mintAllowed(address(this), user, mintAmount);
        require(allowed == 0, "Mint not allowed");
        require(accrualBlockNumber == getBlockNumber(), "Stale block");

        // Pull the underlying tokens from the forwarder (msg.sender)
        uint actualMintAmount = doTransferIn(msg.sender, mintAmount);

        // Calculate number of pTokens to mint
        Exp memory exchangeRate = Exp({mantissa: exchangeRateStoredInternal()});
        uint mintTokens = div_(actualMintAmount, exchangeRate);

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
    function borrowFor(address user, uint256 borrowAmount) external onlyForwarder returns (uint) {
        accrueInterest();
        
        // Check if borrow is allowed
        uint allowed = peridottroller.borrowAllowed(address(this), user, borrowAmount);
        require(allowed == 0, "Borrow not allowed");
        require(accrualBlockNumber == getBlockNumber(), "Stale block");
        
        // Update borrow accounting for the user
        uint accountBorrowsPrev = borrowBalanceStoredInternal(user);
        uint accountBorrowsNew = accountBorrowsPrev + borrowAmount;
        uint totalBorrowsNew = totalBorrows + borrowAmount;
        
        accountBorrows[user].principal = accountBorrowsNew;
        accountBorrows[user].interestIndex = borrowIndex;
        totalBorrows = totalBorrowsNew;
        
        // Transfer tokens from this contract to the forwarder for cross-chain delivery
        // The tokens should already be in this contract from previous supply operations
        doTransferOut(payable(msg.sender), borrowAmount);
        
        emit Borrow(user, borrowAmount, accountBorrowsNew, totalBorrowsNew);
        
        return NO_ERROR;
    }
}
