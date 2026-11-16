// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title MerkleRewardsDistributor
/// @notice Chain- and token-agnostic port of the Avalanche design A distributor (PharRewardsDistributor, branch
///         feat/dlmm-rewards-distributor). First use: the RAM gauge rewards of the Robinhood Chain Ramses SPY/USDG vault.
///         The vault holds the rewards in externalRewards[pair][RAM]; the timelock forwards an epoch's RAM straight to this
///         contract (RamsesBoostedVault.forwardExternalReward), the owner publishes the Merkle root of the
///         (epochId, account, amount) leaves computed off chain from public events, and holders claim after a challenge window.
///
///  ONE deliberate change against the Avalanche contract: FUNDING. publishEpoch does not pull from the owner; it reserves
///  `total` out of the UNALLOCATED balance (balance - reserved), i.e. tokens somebody already sent here (on Robinhood the
///  timelock's forwardExternalReward). Consequences, each tested:
///   - the only way tokens ever leave the contract is claim (to the account in a leaf). There is no refund, no rescue, no
///     owner withdrawal, no pause, no setter for the token, a root, the delay or the deadline.
///   - cancelEpoch (inside the challenge window) and sweepUnclaimed (after the claim deadline) do not move tokens: they
///     release the epoch's open amount back to the unallocated balance, where only a NEW published (and again challengeable)
///     epoch can commit it. The protocol's share is an ordinary leaf (for the protocol recipient), so nothing is stranded.
///   - tokens sent here directly are not lost (as they were on Avalanche): they are unallocated until an epoch commits them.
///   - no `toBlock <= block.number` check: on Arbitrum Orbit chains (Robinhood Chain) block.number is the L1-derived number,
///     while the epoch's block range is in L2 heights (eth_blockNumber / log block numbers). The range is informational.
///
///  Life of an epoch id:
///   publishEpoch (owner; reserves `total` of the unallocated balance)
///     -> [publishedAt, publishedAt + CLAIM_DELAY)                     challenge window: owner may cancelEpoch; nobody can claim
///     -> [publishedAt + CLAIM_DELAY, publishedAt + CLAIM_DEADLINE)     claims open; the epoch is IMMUTABLE
///     -> [publishedAt + CLAIM_DEADLINE, ...)                            claims closed; owner may sweepUnclaimed once
///   Cancelled and Swept are terminal; ids are never reused.
///
///  Invariant: REWARD_TOKEN.balanceOf(this) >= reserved == sum over Open epochs of (total - claimed).
///  Leaf: keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount)))) (double hash), OpenZeppelin MerkleProof.
contract MerkleRewardsDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None, // no such epoch
        Open, // committed; cancellable inside the window, claimable inside [claimOpensAt, claimDeadline)
        Cancelled, // terminal: released inside the window
        Swept // terminal: the unclaimed rest was released after the deadline
    }

    struct Epoch {
        bytes32 root;
        uint128 total; // tokens committed to this epoch
        uint128 claimed; // tokens paid out so far, <= total
        uint64 publishedAt;
        uint64 fromBlock; // the epoch covers (fromBlock, toBlock] in L2 block heights (see the generator); informational
        uint64 toBlock;
        Status status;
        bytes32 dataHash; // keccak256 of the generator's epoch.json: lets anyone fetch the file and recompute the root
    }

    /// @dev What `epochInfo` returns (plain uint256s for easy decoding by a front end).
    struct EpochView {
        bytes32 root;
        uint256 total;
        uint256 claimed;
        uint256 publishedAt;
        uint256 claimOpensAt;
        uint256 claimDeadline;
        uint256 fromBlock;
        uint256 toBlock;
        bytes32 dataHash;
        Status status;
    }

    struct Claim {
        uint256 epochId;
        address account;
        uint256 amount;
        bytes32[] proof;
    }

    /// @notice The claims window is at least this long (deployment sanity check).
    uint256 public constant MIN_CLAIM_WINDOW = 7 days;

    IERC20 public immutable REWARD_TOKEN;
    /// @notice Seconds after publication during which the owner can cancel and nobody can claim.
    uint256 public immutable CLAIM_DELAY;
    /// @notice Seconds after publication at which claims close and the owner may sweep what is left.
    uint256 public immutable CLAIM_DEADLINE;

    /// @notice Number of epochs ever published = the id the NEXT publishEpoch will get (ids start at 0, never reused).
    uint256 public epochCount;
    /// @notice Tokens committed to Open epochs and not yet claimed.
    uint256 public reserved;

    mapping(uint256 epochId => Epoch) private _epochs;
    mapping(uint256 epochId => mapping(address account => bool)) private _claimed;

    event EpochPublished(
        uint256 indexed epochId,
        bytes32 root,
        uint256 total,
        uint64 fromBlock,
        uint64 toBlock,
        bytes32 dataHash,
        uint256 publishedAt,
        uint256 claimOpensAt,
        uint256 claimDeadline
    );
    event EpochCancelled(uint256 indexed epochId, uint256 released);
    event Claimed(uint256 indexed epochId, address indexed account, uint256 amount);
    event EpochSwept(uint256 indexed epochId, uint256 released);

    error ZeroAddress();
    error NotAContract();
    error BadWindow();
    error ZeroRoot();
    error ZeroTotal();
    error ZeroDataHash();
    error BadBlockRange();
    error TotalTooLarge();
    error InsufficientUnallocated(uint256 unallocated, uint256 total);
    error EpochNotOpen(Status status);
    error WindowOver(); // cancel after the challenge window
    error ClaimsNotOpen(uint256 opensAt);
    error ClaimsClosed(uint256 deadline);
    error DeadlineNotReached(uint256 deadline);
    error AlreadyClaimed();
    error ZeroAmount();
    error InvalidProof();
    error ExceedsEpochTotal(uint256 claimedAfter, uint256 total);
    error RenounceDisabled();

    constructor(IERC20 rewardToken, address initialOwner, uint256 claimDelay, uint256 claimDeadline) Ownable(initialOwner) {
        if (address(rewardToken) == address(0)) revert ZeroAddress();
        if (address(rewardToken).code.length == 0) revert NotAContract();
        // delay > 0, and a claims window of at least MIN_CLAIM_WINDOW; the upper bound keeps every timestamp inside uint64
        if (claimDelay == 0 || claimDeadline < claimDelay + MIN_CLAIM_WINDOW || claimDeadline > 10 * 365 days) {
            revert BadWindow();
        }
        REWARD_TOKEN = rewardToken;
        CLAIM_DELAY = claimDelay;
        CLAIM_DEADLINE = claimDeadline;
    }

    // ------------------------------------------------------------------------------------------------------------ owner

    /// @notice Publishes epoch `epochCount`, committing `total` of the unallocated balance (send the tokens here first).
    ///         `total` must be the sum of the leaves of `root`. Starts the CLAIM_DELAY challenge window. `fromBlock`/`toBlock`
    ///         (L2 heights; the epoch is (fromBlock, toBlock]) and `dataHash` (keccak256 of the generator's epoch.json) are
    ///         recorded and emitted, not interpreted; ranges are not chained on chain (a cancelled epoch must be republishable).
    function publishEpoch(bytes32 root, uint256 total, uint64 fromBlock, uint64 toBlock, bytes32 dataHash)
        external
        onlyOwner
        nonReentrant
        returns (uint256 epochId)
    {
        if (root == bytes32(0)) revert ZeroRoot();
        if (total == 0) revert ZeroTotal();
        if (dataHash == bytes32(0)) revert ZeroDataHash();
        if (fromBlock >= toBlock) revert BadBlockRange();
        if (total > type(uint128).max) revert TotalTooLarge();
        uint256 free = unallocated();
        if (total > free) revert InsufficientUnallocated(free, total);

        reserved += total;
        epochId = epochCount++;
        _epochs[epochId] = Epoch({
            root: root,
            total: uint128(total),
            claimed: 0,
            publishedAt: uint64(block.timestamp),
            fromBlock: fromBlock,
            toBlock: toBlock,
            status: Status.Open,
            dataHash: dataHash
        });
        emit EpochPublished(
            epochId,
            root,
            total,
            fromBlock,
            toBlock,
            dataHash,
            block.timestamp,
            block.timestamp + CLAIM_DELAY,
            block.timestamp + CLAIM_DEADLINE
        );
    }

    /// @notice Inside the challenge window only (strictly before claimOpensAt): kills the epoch and releases its total to the
    ///         unallocated balance (no transfer). The id stays burnt; republish under the next id.
    function cancelEpoch(uint256 epochId) external onlyOwner nonReentrant {
        Epoch storage e = _epochs[epochId];
        if (e.status != Status.Open) revert EpochNotOpen(e.status);
        if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();
        uint256 released = uint256(e.total) - e.claimed; // claimed is 0: claims open only after the window
        e.status = Status.Cancelled;
        reserved -= released;
        emit EpochCancelled(epochId, released);
    }

    /// @notice From the claim deadline on: releases exactly total - claimed of this epoch to the unallocated balance, once.
    ///         Claims of the epoch are closed from the same instant.
    function sweepUnclaimed(uint256 epochId) external onlyOwner nonReentrant {
        Epoch storage e = _epochs[epochId];
        if (e.status != Status.Open) revert EpochNotOpen(e.status);
        uint256 deadline = uint256(e.publishedAt) + CLAIM_DEADLINE;
        if (block.timestamp < deadline) revert DeadlineNotReached(deadline);
        uint256 released = uint256(e.total) - e.claimed;
        e.status = Status.Swept;
        reserved -= released;
        emit EpochSwept(epochId, released);
    }

    /// @dev Disabled: an owner-less distributor could never cancel, sweep or publish again.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------------------------------------------------ claims

    /// @notice Pays `amount` of epoch `epochId` to `account` (never to the caller) if (epochId, account, amount) is a leaf.
    ///         Anyone may submit it. Reverts AlreadyClaimed on the second try.
    function claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        _claim(epochId, account, amount, proof, false);
    }

    /// @notice Several claims in one transaction. An entry whose (epoch, account) was already claimed is SKIPPED (a front-run
    ///         of one entry cannot fail the batch); any other problem (bad proof, window, ...) reverts the whole batch.
    function claimMany(Claim[] calldata claims) external nonReentrant {
        for (uint256 i = 0; i < claims.length; ++i) {
            Claim calldata c = claims[i];
            _claim(c.epochId, c.account, c.amount, c.proof, true);
        }
    }

    function _claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof, bool skipIfClaimed)
        private
    {
        Epoch storage e = _epochs[epochId];
        if (e.status != Status.Open) revert EpochNotOpen(e.status);
        uint256 opensAt = uint256(e.publishedAt) + CLAIM_DELAY;
        if (block.timestamp < opensAt) revert ClaimsNotOpen(opensAt);
        uint256 deadline = uint256(e.publishedAt) + CLAIM_DEADLINE;
        if (block.timestamp >= deadline) revert ClaimsClosed(deadline);
        if (_claimed[epochId][account]) {
            if (skipIfClaimed) return;
            revert AlreadyClaimed();
        }
        if (amount == 0) revert ZeroAmount();
        if (!MerkleProof.verifyCalldata(proof, e.root, _leaf(epochId, account, amount))) revert InvalidProof();

        uint256 claimedAfter = uint256(e.claimed) + amount;
        if (claimedAfter > e.total) revert ExceedsEpochTotal(claimedAfter, e.total);

        _claimed[epochId][account] = true;
        e.claimed = uint128(claimedAfter);
        reserved -= amount;
        REWARD_TOKEN.safeTransfer(account, amount);
        emit Claimed(epochId, account, amount);
    }

    function _leaf(uint256 epochId, address account, uint256 amount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));
    }

    // ------------------------------------------------------------------------------------------------------------ views

    /// @notice Tokens held here and not committed to an open epoch (what the next publishEpoch can commit at most).
    ///         Saturates at 0 if the token ever reported a balance below `reserved` (outside the guarantees: rebasing down).
    function unallocated() public view returns (uint256) {
        uint256 bal = REWARD_TOKEN.balanceOf(address(this));
        return bal > reserved ? bal - reserved : 0;
    }

    /// @notice True when `account` has already been paid in `epochId`.
    function isClaimed(uint256 epochId, address account) external view returns (bool) {
        return _claimed[epochId][account];
    }

    /// @notice Everything about an epoch. claimOpensAt / claimDeadline are 0 for an id that does not exist (status None).
    function epochInfo(uint256 epochId) external view returns (EpochView memory v) {
        Epoch storage e = _epochs[epochId];
        v.root = e.root;
        v.total = e.total;
        v.claimed = e.claimed;
        v.publishedAt = e.publishedAt;
        v.fromBlock = e.fromBlock;
        v.toBlock = e.toBlock;
        v.dataHash = e.dataHash;
        v.status = e.status;
        if (e.status != Status.None) {
            v.claimOpensAt = uint256(e.publishedAt) + CLAIM_DELAY;
            v.claimDeadline = uint256(e.publishedAt) + CLAIM_DEADLINE;
        }
    }

    /// @notice True when the epoch is open and `now` is inside its claim window.
    function isClaimWindowOpen(uint256 epochId) external view returns (bool) {
        Epoch storage e = _epochs[epochId];
        if (e.status != Status.Open) return false;
        return block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY
            && block.timestamp < uint256(e.publishedAt) + CLAIM_DEADLINE;
    }

    /// @notice Front-end helper: does (epochId, account, amount, proof) verify against the epoch's root? Ignores the window
    ///         and isClaimed.
    function verifyLeaf(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof)
        external
        view
        returns (bool)
    {
        Epoch storage e = _epochs[epochId];
        if (e.status == Status.None) return false;
        return MerkleProof.verifyCalldata(proof, e.root, _leaf(epochId, account, amount));
    }

    /// @notice The leaf hash, for off-chain cross-checks.
    function leafOf(uint256 epochId, address account, uint256 amount) external pure returns (bytes32) {
        return _leaf(epochId, account, amount);
    }
}
