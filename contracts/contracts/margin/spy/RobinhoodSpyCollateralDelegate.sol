// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {PErc20Delegate} from "../../PErc20Delegate.sol";

interface ISpySessionSource {
    function stockPrice() external view returns (uint256 priceE18, uint8 reason, uint256 updatedAt);
}

interface IIsolatedAccountRegistry {
    function isolatedMarginAccounts(address account) external view returns (bool);
    function getAssetsIn(address account) external view returns (address[] memory);
}

interface IBorrowBalanceView {
    function borrowBalanceStored(address account) external view returns (uint256);
}

/**
 * @title RobinhoodSpyCollateralDelegate
 * @notice pSPY implementation that lets pSPY serve as ordinary lending collateral with the SPY margin session policy.
 * @dev `RobinhoodPlainDelegate` (the October ZeroSharesMinted and round-up redeemUnderlying corrections) plus:
 *
 *      1. Session gate. While `spySource.stockPrice()` withholds the SPY price (reason != 0: weekend window, age above
 *         maxStaleness, SPY paused / oraclePaused, bad or incomplete round, lending-oracle mismatch), for every account
 *         that holds pSPY and is not an isolated-margin account:
 *           - with a borrow balance in ANY market of the controller (read as `getAssetsIn` + `borrowBalanceStored`;
 *             a borrow always enters its market, and a market with debt cannot be exited), `getAccountSnapshot`
 *             returns the reason as its error code. The controller's liquidity loop turns it into SNAPSHOT_ERROR, so
 *             borrow (any market), redeem and transfer (any entered market), exitMarket and liquidateBorrow all fail
 *             closed. Repay and mint read no snapshot and keep working.
 *           - debt-free, the snapshot is served with a zero exchange rate: pSPY counts as zero collateral and its
 *             redemption as zero effect. Redeem, transfer and exitMarket work (nothing is owed), while a new borrow can
 *             only be backed by the account's other collateral, never by SPY at a withheld price. A borrow taken that
 *             way makes the account indebted, and the first branch applies from then on.
 *         All reads are views (`borrowBalanceStored` has no lock), so the gate is safe inside another market's
 *         nonReentrant borrow or redeem. `seize` itself also reverts while SPY is withheld, which covers a holder who never entered
 *         pSPY: the controller's liquidity check then never reads pSPY, but `seizeAllowed` has no membership
 *         check, so another market's shortfall could otherwise seize pSPY at the cached lending price.
 *         Accounts without pSPY are untouched (a zero balance contributes nothing, whatever the price), and
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
    error SpySessionClosed(uint256 reason);

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
            if (reason != 0) {
                if (_hasDebt(account)) return (reason, 0, 0, 0);
                // Debt-free: SPY is worth nothing as collateral while withheld, so withdrawing it costs no liquidity.
                return (NO_ERROR, tokens, 0, 0);
            }
        }
        return (NO_ERROR, tokens, borrowBalanceStoredInternal(account), exchangeRateStoredInternal());
    }

    /// @notice No pSPY changes hands in a liquidation while SPY is closed or stale, whoever the borrower is.
    function seize(address liquidator, address borrower, uint256 seizeTokens)
        external
        override
        nonReentrant
        returns (uint256)
    {
        uint256 reason = sessionReason();
        if (reason != 0) revert SpySessionClosed(reason);
        seizeInternal(msg.sender, liquidator, borrower, seizeTokens);
        return NO_ERROR;
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

    /// @notice Whether `account` owes anything in any market it is in (the controller's view). Monitoring / frontend.
    function hasDebt(address account) external view returns (bool) {
        return _hasDebt(account);
    }

    function _hasDebt(address account) internal view returns (bool) {
        address[] memory assets = IIsolatedAccountRegistry(address(peridottroller)).getAssetsIn(account);
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 owed = assets[i] == address(this)
                ? borrowBalanceStoredInternal(account)
                : IBorrowBalanceView(assets[i]).borrowBalanceStored(account);
            if (owed != 0) return true;
        }
        return false;
    }

    function _isMarginAccount(address account) internal view returns (bool) {
        return IIsolatedAccountRegistry(address(peridottroller)).isolatedMarginAccounts(account);
    }
}
