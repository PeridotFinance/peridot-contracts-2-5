// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import {Peridottroller} from "./Peridottroller.sol";
import {PToken} from "./PToken.sol";

/**
 * @notice Avalanche C-Chain mainnet Peridottroller implementation with an explicit PERIDOT token (or an explicit, opt-in choice of NO
 *         reward token, see the constructor) and an optional per-market BORROW CASH FLOOR.
 * @dev Mirror of `PeridottrollerAvalancheFuji` with the mainnet chain id. The token address is immutable bytecode so it is
 *      available behind Unitroller through delegatecall. Added for the handoff-09 fork checkpoint; it is NOT a deployment
 *      authorization.
 *
 *      BORROW CASH FLOOR (handoff 09 section 3b "local borrowing reserve"). `borrowCashFloor(pToken)` is the minimum cash (underlying
 *      units held by the market) that must REMAIN after a new borrow. 0 disables it for that market. It is checked only in
 *      `borrowAllowed`, after every original check passed, so:
 *        - with the floor at 0 the behaviour (return codes, revert reasons, state changes) is that of the base `Peridottroller`;
 *        - it can only turn an otherwise allowed new borrow into a revert ("borrow cash floor"); it never changes another
 *          rejection, so "borrow is paused" and every error code keep precedence;
 *        - repayment, redemption, ordinary liquidation/seize, flash loans of the margin flash vault and in-kind recovery never call
 *          `borrowAllowed`, so the floor cannot block them. Margin opens do borrow through this function and are subject to it.
 *      This is NOT an accounting reserve (`totalReserves`) and NOT liquidator funding; it is only a limit on how much cash new
 *      borrows may remove from the market.
 *
 *      STORAGE. The mapping lives in a namespaced (ERC-7201 style) slot derived from a hash, NOT in the linear layout, so a future
 *      base `Peridottroller` that appends storage (as the V1..V8 storage contracts did) cannot collide with it, and this contract
 *      adds no linear variable behind the proxy (checked by tools/check-controller-storage-layout.sh).
 */
contract PeridottrollerAvalanche is Peridottroller {
    uint256 private constant AVALANCHE_CHAIN_ID = 43_114;

    /// @dev keccak256(abi.encode(uint256(keccak256("peridot.avalanche.PeridottrollerAvalanche.borrowCashFloor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant BORROW_CASH_FLOOR_SLOT = 0x1a18fbf2c2efc70401f059ee649e0a490312ca5742901c0d3822d1c511dca500;

    address public immutable peridotToken;

    /// @notice Emitted when the borrow cash floor of a market changes.
    event NewBorrowCashFloor(PToken indexed pToken, uint256 oldFloor, uint256 newFloor);

    /// @param peridotToken_ the reward token: must be an existing contract, EXCEPT as below.
    /// @param allowNoRewardToken_ explicit OPT-IN to deploy WITHOUT a reward token. Only with `peridotToken_ == address(0)` AND this flag
    ///        set is a missing token accepted; `address(0)` without the flag reverts exactly as before (same revert string), and the flag
    ///        never excuses a non-zero address without code. With no token `getPeridotAddress()` is `address(0)`: `claimPeridot` and
    ///        the admin `_grantPeridot` (the only token-touching entry points) revert, while no lending path reads the token.
    constructor(address peridotToken_, bool allowNoRewardToken_) {
        require(block.chainid == AVALANCHE_CHAIN_ID, "AvalancheController: Avalanche only");
        require(
            peridotToken_.code.length > 0 || (peridotToken_ == address(0) && allowNoRewardToken_),
            "AvalancheController: token not contract"
        );
        peridotToken = peridotToken_;
    }

    function getPeridotAddress() public view override returns (address) {
        return peridotToken;
    }

    /// @notice Minimum cash (underlying units) that must remain in `pToken` after a new borrow; 0 = disabled.
    function borrowCashFloor(address pToken) public view returns (uint256) {
        return _floors()[pToken];
    }

    /// @notice Admin: set the borrow cash floor of a LISTED market. Loosening (lowering) is as privileged as tightening; the intended
    ///         deployment puts the admin behind a timelock.
    function _setBorrowCashFloor(PToken pToken, uint256 newFloor) external returns (uint256) {
        require(msg.sender == admin, "only admin can set borrow cash floor");
        if (!markets[address(pToken)].isListed) return uint256(Error.MARKET_NOT_LISTED);
        uint256 oldFloor = _floors()[address(pToken)];
        _floors()[address(pToken)] = newFloor;
        emit NewBorrowCashFloor(pToken, oldFloor, newFloor);
        return uint256(Error.NO_ERROR);
    }

    function borrowAllowed(address pToken, address borrower, uint256 borrowAmount) public override returns (uint256) {
        // Every original check (pause, listing, price, cap, liquidity, margin hook) and its state changes first.
        uint256 code = super.borrowAllowed(pToken, borrower, borrowAmount);
        if (code != 0) return code;
        uint256 floor = _floors()[pToken];
        if (floor != 0) {
            uint256 cash = PToken(pToken).getCash();
            require(cash >= borrowAmount && cash - borrowAmount >= floor, "borrow cash floor");
        }
        return 0;
    }

    function _floors() private pure returns (mapping(address => uint256) storage m) {
        bytes32 slot = BORROW_CASH_FLOOR_SLOT;
        assembly {
            m.slot := slot
        }
    }
}
