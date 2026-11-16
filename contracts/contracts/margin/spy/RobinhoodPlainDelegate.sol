// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {PErc20Delegate} from "../../PErc20Delegate.sol";

/**
 * @title RobinhoodPlainDelegate
 * @notice Plain (vault-less) pToken implementation for a Robinhood margin position market such as pSPY.
 * @dev `PErc20Delegate` plus the two October 2026 lending-rounding corrections that the live boosted markets carry in
 *      `RobinhoodBoostedDelegateV2` (delegate 0x0C6F…8FF1), and nothing else: no storage, no new ABI beyond the error.
 *        1. A mint that credits zero pTokens reverts `ZeroSharesMinted` (a donation-inflated exchange rate cannot
 *           swallow a deposit).
 *        2. `redeemUnderlying` burns a share count rounded UP at the current rate, so an exact output is never paid
 *           for with less than its value in pTokens.
 *      Borrower-share accounting is the base `PToken` one, enabled by `PToken.initialize` for every new market.
 */
contract RobinhoodPlainDelegate is PErc20Delegate {
    error ZeroSharesMinted();

    function mint(uint256 mintAmount) external override returns (uint256) {
        uint256 sharesBefore = accountTokens[msg.sender];
        mintInternal(mintAmount);
        // mintInternal holds the shared nonReentrant lock, so this delta is exactly the pTokens minted by this call.
        if (accountTokens[msg.sender] == sharesBefore) revert ZeroSharesMinted();
        return NO_ERROR;
    }

    function redeemUnderlying(uint256 redeemAmount) external override nonReentrant returns (uint256) {
        accrueInterest();
        if (accrualBlockNumber != getBlockNumber()) revert RedeemFreshnessCheck();
        if (getCashPrior() < redeemAmount) revert RedeemTransferOutNotPossible();

        uint256 rate = exchangeRateStoredInternal();
        uint256 redeemTokens = (redeemAmount * expScale + rate - 1) / rate;
        uint256 allowed = peridottroller.redeemAllowed(address(this), msg.sender, redeemTokens);
        if (allowed != 0) revert RedeemPeridottrollerRejection(allowed);

        totalSupply = totalSupply - redeemTokens;
        accountTokens[msg.sender] = accountTokens[msg.sender] - redeemTokens;
        doTransferOut(payable(msg.sender), redeemAmount);

        emit Transfer(msg.sender, address(this), redeemTokens);
        emit Redeem(msg.sender, redeemAmount, redeemTokens);
        peridottroller.redeemVerify(address(this), msg.sender, redeemAmount, redeemTokens);
        return NO_ERROR;
    }
}
