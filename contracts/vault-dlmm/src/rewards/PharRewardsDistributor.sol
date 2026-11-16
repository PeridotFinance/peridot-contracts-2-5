// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title PharRewardsDistributor
/// @notice Design A of the PHAR distribution of the Peridot Pharaoh DLMM USDC/USDt vault. The vault (frozen) claims PHAR and forwards ALL of it to its owner, the
///         Safe. Per epoch the Safe computes OFF CHAIN, from the public ERC-20 Transfer events of the vault shares, how much of that PHAR each share holder
///         earned, publishes the Merkle root of the (epochId, account, amount) leaves here and funds exactly the sum of the leaves. Holders (or anyone on their
///         behalf) then claim; the PHAR always goes to the account in the leaf. The vault is not touched by this contract.
///
///  Life of an epoch id:
///   publishEpoch (owner; pulls `total` PHAR from the owner)
///     -> [publishedAt, publishedAt + CLAIM_DELAY)            challenge window: the owner may cancelEpoch and get all the PHAR back; nobody can claim
///     -> [publishedAt + CLAIM_DELAY, publishedAt + CLAIM_DEADLINE)   claims open; the epoch is IMMUTABLE (no cancel, no new root, no change of total)
///     -> [publishedAt + CLAIM_DEADLINE, ...)                  claims closed; the owner may sweepUnclaimed (total - claimed) once
///   Cancelled and Swept are terminal.
///
///  Guarantees (each one is a tested property):
///   - the only ways PHAR leaves the contract are claim (to the leaf's account), cancelEpoch (to the owner, inside the window, nothing claimed yet) and
///     sweepUnclaimed (to the owner, only after the claim deadline, exactly total - claimed). There is no pause, no rescue, no setter for the token, the root,
///     the delay or the deadline. Ownership is two step and cannot be renounced.
///   - epochs are isolated: every epoch has its own `claimed` counter and a claim reverts when claimed + amount > total, so a wrong root (or an owner that funds
///     less than the leaves add up to) can only make late claimers of THAT epoch fail; it can never draw on the PHAR of another epoch.
///   - one claim per (epochId, account): a per-account flag (see `_claimed`), not a bit index, because the leaf format fixed by the spec has no index.
///   - the contract accounts for PHAR by `total`/`claimed`, never by its balance: PHAR sent to it directly is not claimable and not sweepable (it is lost).
///   - the token must move exactly what it is asked to move: publishEpoch reverts for a fee-on-transfer token (received != total).
///     Rebasing tokens, and tokens that can freeze an account, are outside the guarantees (a frozen account cannot be paid; the others are unaffected).
///
///  Leaf: keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount)))) (double hash), OpenZeppelin MerkleProof (sorted pairs).
contract PharRewardsDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        None, // no such epoch
        Open, // funded; cancellable inside the window, claimable inside [claimOpensAt, claimDeadline)
        Cancelled, // terminal: the owner took the PHAR back inside the window
        Swept // terminal: the owner swept the unclaimed rest after the deadline
    }

    struct Epoch {
        bytes32 root;
        uint128 total; // PHAR funded and claimable in this epoch
        uint128 claimed; // PHAR paid out so far, <= total
        uint64 publishedAt;
        uint64 fromBlock; // the epoch covers the half-open block range (fromBlock, toBlock] (both are harvest blocks, see the off-chain generator); informational
        uint64 toBlock;
        Status status;
        bytes32 dataHash; // keccak256 of the generator's final output file for this epoch (holders, amounts, exclusions, inputs, proofs): informational, lets anyone check the file
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

    IERC20 public immutable PHAR;
    /// @notice Seconds after publication during which the owner can cancel and nobody can claim.
    uint256 public immutable CLAIM_DELAY;
    /// @notice Seconds after publication at which claims close and the owner may sweep what is left.
    uint256 public immutable CLAIM_DEADLINE;

    /// @notice Number of epochs ever published = the id the NEXT publishEpoch will get (ids start at 0 and are never reused; a cancelled id stays burnt).
    uint256 public epochCount;

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
    event EpochCancelled(uint256 indexed epochId, address indexed to, uint256 refunded);
    event Claimed(uint256 indexed epochId, address indexed account, uint256 amount);
    event EpochSwept(uint256 indexed epochId, address indexed to, uint256 amount);

    error ZeroAddress();
    error NotAContract();
    error BadWindow();
    error ZeroRoot();
    error ZeroTotal();
    error ZeroDataHash();
    error BadBlockRange();
    error TotalTooLarge();
    error TransferAmountMismatch(uint256 expected, uint256 received);
    error NoSuchEpoch();
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

    constructor(IERC20 phar, address initialOwner, uint256 claimDelay, uint256 claimDeadline) Ownable(initialOwner) {
        if (address(phar) == address(0)) revert ZeroAddress();
        if (address(phar).code.length == 0) revert NotAContract();
        // delay > 0, and a claims window of at least MIN_CLAIM_WINDOW; the upper bound keeps every timestamp inside uint64
        if (claimDelay == 0 || claimDeadline < claimDelay + MIN_CLAIM_WINDOW || claimDeadline > 10 * 365 days) revert BadWindow();
        PHAR = phar;
        CLAIM_DELAY = claimDelay;
        CLAIM_DEADLINE = claimDeadline;
    }

    // ------------------------------------------------------------------------------------------------------------------------------ owner

    /// @notice Publishes epoch `epochCount` and pulls `total` PHAR from the owner (the Safe approves this contract for at least `total` first). `total` must be
    ///         the sum of the leaves of `root`. Starts the CLAIM_DELAY challenge window. `fromBlock`/`toBlock` (the epoch is the block range (fromBlock, toBlock]) and
    ///         `dataHash` (keccak256 of the generator's output file) are recorded and emitted so that anyone can fetch the file and recompute the root; the contract
    ///         does not interpret them (no chaining of ranges is enforced on chain: a cancelled epoch must be republishable with the same range). Only sanity is
    ///         checked: fromBlock < toBlock <= the current block, dataHash != 0.
    function publishEpoch(bytes32 root, uint256 total, uint64 fromBlock, uint64 toBlock, bytes32 dataHash)
        external
        onlyOwner
        nonReentrant
        returns (uint256 epochId)
    {
        if (root == bytes32(0)) revert ZeroRoot();
        if (total == 0) revert ZeroTotal();
        if (dataHash == bytes32(0)) revert ZeroDataHash();
        if (fromBlock >= toBlock || toBlock > block.number) revert BadBlockRange();
        if (total > type(uint128).max) revert TotalTooLarge();

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

        uint256 balBefore = PHAR.balanceOf(address(this));
        PHAR.safeTransferFrom(msg.sender, address(this), total);
        uint256 received = PHAR.balanceOf(address(this)) - balBefore;
        if (received != total) revert TransferAmountMismatch(total, received);

        emit EpochPublished(
            epochId, root, total, fromBlock, toBlock, dataHash, block.timestamp, block.timestamp + CLAIM_DELAY, block.timestamp + CLAIM_DEADLINE
        );
    }

    /// @notice Inside the challenge window only (strictly before claimOpensAt): kills the epoch and returns all its PHAR to the owner. The id stays burnt.
    function cancelEpoch(uint256 epochId) external onlyOwner nonReentrant {
        Epoch storage e = _epochs[epochId];
        if (e.status != Status.Open) revert EpochNotOpen(e.status);
        if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();
        uint256 refund = e.total; // nothing can have been claimed yet: claims open only after the window
        e.status = Status.Cancelled;
        PHAR.safeTransfer(msg.sender, refund);
        emit EpochCancelled(epochId, msg.sender, refund);
    }

    /// @notice From the claim deadline on: sends exactly total - claimed of this epoch to the owner, once. Claims of the epoch are closed from the same instant.
    function sweepUnclaimed(uint256 epochId) external onlyOwner nonReentrant {
        Epoch storage e = _epochs[epochId];
        if (e.status != Status.Open) revert EpochNotOpen(e.status);
        uint256 deadline = uint256(e.publishedAt) + CLAIM_DEADLINE;
        if (block.timestamp < deadline) revert DeadlineNotReached(deadline);
        uint256 rest = uint256(e.total) - e.claimed;
        e.status = Status.Swept;
        if (rest != 0) PHAR.safeTransfer(msg.sender, rest);
        emit EpochSwept(epochId, msg.sender, rest);
    }

    /// @dev Disabled: an owner-less distributor could never cancel, sweep or publish again.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ------------------------------------------------------------------------------------------------------------------------------ claims

    /// @notice Pays `amount` PHAR of epoch `epochId` to `account` (never to the caller) if (epochId, account, amount) is a leaf of the epoch's root. Anyone may
    ///         submit it. Reverts AlreadyClaimed on the second try.
    function claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        _claim(epochId, account, amount, proof, false);
    }

    /// @notice Several claims in one transaction (for several epochs and/or accounts). An entry whose (epoch, account) was already claimed is SKIPPED (so that
    ///         someone claiming one entry first cannot make the whole batch fail); any other problem (bad proof, window, ...) reverts the whole batch.
    function claimMany(Claim[] calldata claims) external nonReentrant {
        for (uint256 i = 0; i < claims.length; ++i) {
            Claim calldata c = claims[i];
            _claim(c.epochId, c.account, c.amount, c.proof, true);
        }
    }

    function _claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof, bool skipIfClaimed) private {
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
        PHAR.safeTransfer(account, amount);
        emit Claimed(epochId, account, amount);
    }

    function _leaf(uint256 epochId, address account, uint256 amount) private pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));
    }

    // ------------------------------------------------------------------------------------------------------------------------------ views

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
        return block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY && block.timestamp < uint256(e.publishedAt) + CLAIM_DEADLINE;
    }

    /// @notice Front-end helper: does (epochId, account, amount, proof) verify against the epoch's root? Does NOT look at the window or at isClaimed.
    function verifyLeaf(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof) external view returns (bool) {
        Epoch storage e = _epochs[epochId];
        if (e.status == Status.None) return false;
        return MerkleProof.verifyCalldata(proof, e.root, _leaf(epochId, account, amount));
    }

    /// @notice The leaf hash of the spec, for off-chain cross-checks.
    function leafOf(uint256 epochId, address account, uint256 amount) external pure returns (bytes32) {
        return _leaf(epochId, account, amount);
    }
}
