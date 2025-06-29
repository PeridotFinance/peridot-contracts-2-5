// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.10;

import "./PEther.sol";

/**
 * @title Peridot's Maximillion Contract
 * @author Peridot
 */
contract Maximillion {
    /**
     * @notice The default pEther market to repay in
     */
    PEther public pEther;

    /**
     * @notice Construct a Maximillion to repay max in a PEther market
     */
    constructor(PEther cEther_) {
        pEther = cEther_;
    }

    /**
     * @notice msg.sender sends Ether to repay an account's borrow in the pEther market
     * @dev The provided Ether is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     */
    function repayBehalf(address borrower) public payable {
        repayBehalfExplicit(borrower, pEther);
    }

    /**
     * @notice msg.sender sends Ether to repay an account's borrow in a pEther market
     * @dev The provided Ether is applied towards the borrow balance, any excess is refunded
     * @param borrower The address of the borrower account to repay on behalf of
     * @param cEther_ The address of the pEther contract to repay in
     */
    function repayBehalfExplicit(
        address borrower,
        PEther cEther_
    ) public payable {
        uint received = msg.value;
        uint borrows = cEther_.borrowBalanceCurrent(borrower);
        if (received > borrows) {
            cEther_.repayBorrowBehalf{value: borrows}(borrower);
            payable(msg.sender).transfer(received - borrows);
        } else {
            cEther_.repayBorrowBehalf{value: received}(borrower);
        }
    }
}
