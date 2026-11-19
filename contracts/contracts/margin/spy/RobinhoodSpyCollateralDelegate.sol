// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {PErc20Delegate} from "../../PErc20Delegate.sol";

interface ISpySessionSource {
    function stockPrice() external view returns (uint256 priceE18, uint8 reason, uint256 updatedAt);
}

interface IIsolatedAccountRegistry {
    function isolatedMarginAccounts(address account) external view returns (bool);
}

/**
 * @title RobinhoodSpyCollateralDelegate
 * @notice pSPY implementation that lets pSPY serve as ordinary lending collateral with the SPY margin session policy.
 * @dev `RobinhoodPlainDelegate` (the October ZeroSharesMinted and round-up redeemUnderlying corrections) plus:
 *
 *      1. Session gate. While `spySource.stockPrice()` withholds the SPY price (reason != 0: weekend window, age above
 *         maxStaleness, SPY paused / oraclePaused, bad or incomplete round, lending-oracle mismatch),
 *         `getAccountSnapshot` returns that reason as its error code for every account that holds pSPY and is not an
 *         isolated-margin account. The controller's liquidity loop turns a nonzero snapshot error into SNAPSHOT_ERROR,
 *         so for such accounts every liquidity-checked action fails closed: borrow (any market), redeem and transfer
 *         (any market the account is in), exitMarket and liquidateBorrow. Repay and mint read no snapshot and keep
 *         working. Accounts without pSPY are untouched (a zero balance contributes nothing, whatever the price), and
 *         isolated-margin accounts never reach the controller's liquidity path (they are routed to the margin risk
 *         hook) and are exempted here so that external readers see them unchanged.
 *
 *      2. Lending supply cap. A mint by a minter that is not an isolated-margin account reverts when, after the mint,
 *         total pSPY supply valued in SPY (`totalSupply * exchangeRateStored / 1e18`) exceeds `lendingSupplyCap`.
 *         Margin opens (the margin account is the minter) are never blocked, so lending suppliers cannot block SPY
 *         margin. Margin-held pSPY does count against the cap, which therefore bounds SPY collateral from below.
 *         A cap of 0 closes lending mints. Redeem, transfer, seize and repay are never cap-checked.
 *
 *      Storage: one appended slot (`lendingSupplyCap`) after `CDelegationStorage.implementation`. The plain delegate
 *      that precedes this one declares no storage. `spySource` is an immutable of this implementation.
 */
contract RobinhoodSpyCollateralDelegate is PErc20Delegate {
    /// @notice Lending mint ceiling, in SPY base units (18 decimals), against total pSPY supply. 0 = lending mints closed.
    uint256 public lendingSupplyCap;

    ISpySessionSource public immutable spySource;

    /// @notice Snapshot error code when the session source itself is unreadable.
    uint256 public constant SOURCE_UNREADABLE = 255;

    error ZeroSharesMinted();
    error LendingSupplyCapExceeded(uint256 totalUnderlying, uint256 cap);
    error InvalidConfiguration();
    error OnlyAdmin();

    event LendingSupplyCapSet(uint256 oldCap, uint256 newCap);

    constructor(address spySource_) {
        if (spySource_.code.length == 0) revert InvalidConfiguration();
        spySource = ISpySessionSource(spySource_);
    }

    /// @notice Delegator hook. `data` must be `abi.encode(uint256 lendingSupplyCap)`; borrower accounting is already
    ///         enabled on pSPY by `PToken.initialize`, so the base class's migration payload is not accepted here.
    function _becomeImplementation(bytes memory data) public override {
        if (msg.sender != admin) revert OnlyAdmin();
        if (data.length != 32) revert InvalidConfiguration();
        _setCap(abi.decode(data, (uint256)));
    }

    function _setLendingSupplyCap(uint256 newCap) external {
        if (msg.sender != admin) revert OnlyAdmin();
        _setCap(newCap);
    }

    function _setCap(uint256 newCap) internal {
        emit LendingSupplyCapSet(lendingSupplyCap, newCap);
        lendingSupplyCap = newCap;
    }

    /// @notice Current pSPY supply valued in SPY base units at the stored exchange rate.
    function totalUnderlyingSupply() public view returns (uint256) {
        return totalSupply * exchangeRateStoredInternal() / expScale;
    }

    /// @notice The session reason the gate would apply now (0 = open). Monitoring / frontend.
    function sessionReason() public view returns (uint256) {
        try spySource.stockPrice() returns (uint256, uint8 reason, uint256) {
            return reason;
        } catch {
            return SOURCE_UNREADABLE;
        }
    }

    function getAccountSnapshot(address account) external view override returns (uint256, uint256, uint256, uint256) {
        uint256 tokens = accountTokens[account];
        if (tokens != 0 && !_isMarginAccount(account)) {
            uint256 reason = sessionReason();
            if (reason != 0) return (reason, 0, 0, 0);
        }
        return (NO_ERROR, tokens, borrowBalanceStoredInternal(account), exchangeRateStoredInternal());
    }

    function mint(uint256 mintAmount) external override returns (uint256) {
        uint256 sharesBefore = accountTokens[msg.sender];
        mintInternal(mintAmount);
        // mintInternal holds the shared nonReentrant lock, so this delta is exactly the pTokens minted by this call.
        if (accountTokens[msg.sender] == sharesBefore) revert ZeroSharesMinted();
        if (!_isMarginAccount(msg.sender)) {
            uint256 total = totalUnderlyingSupply();
            if (total > lendingSupplyCap) revert LendingSupplyCapExceeded(total, lendingSupplyCap);
        }
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

    function _isMarginAccount(address account) internal view returns (bool) {
        return IIsolatedAccountRegistry(address(peridottroller)).isolatedMarginAccounts(account);
    }
}
