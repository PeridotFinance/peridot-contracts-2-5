#!/usr/bin/env python3
"""Hand-mutant round on src/rewards/PharRewardsDistributor.sol (same method as MUTANTS.md of the vault: one textual change per mutant, scratch copies, never the worktree).
usage (from contracts/vault-dlmm):   python3 mutation/rewards-mutants.py [--jobs 6] [--only M07,M08] [--scratch DIR]
Each mutant is applied to its own scratch project (foundry.toml + lib link + src/rewards + test/rewards only, so no via-IR compile of the vault), the rewards tests are
run with a fixed fuzz seed and an emptied cache, and the mutant is KILLED when forge test fails. A mutant that does not compile is reported INVALID.
EQUIVALENT mutants are argued in the table below and excluded from the score."""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys, tempfile

SRC = "src/rewards/PharRewardsDistributor.sol"
# (id, description, old, new, equivalent_reason or None)
M = [
 ("M01", "publishEpoch without onlyOwner", "        onlyOwner\n        nonReentrant\n        returns (uint256 epochId)", "        nonReentrant\n        returns (uint256 epochId)", None),
 ("M02", "publishEpoch accepts a zero root", "if (root == bytes32(0)) revert ZeroRoot();", "", None),
 ("M03", "publishEpoch accepts a zero total", "if (total == 0) revert ZeroTotal();", "", None),
 ("M04", "publishEpoch does not bound total to uint128", "if (total > type(uint128).max) revert TotalTooLarge();", "", None),
 ("M05", "epoch id pre-incremented (id off by one)", "epochId = epochCount++;", "epochId = ++epochCount;", None),
 ("M06", "no balance-delta check at publish", "if (received != total) revert TransferAmountMismatch(total, received);", "", None),
 ("M07", "balance-delta check only for under-delivery", "if (received != total) revert", "if (received < total) revert", None),
 ("M08", "epoch recorded with claimed = 1", "claimed: 0,\n            publishedAt", "claimed: 1,\n            publishedAt", None),
 ("M09", "epoch recorded Cancelled instead of Open", "status: Status.Open,\n            dataHash: dataHash", "status: Status.Cancelled,\n            dataHash: dataHash", None),
 ("M10", "event claimOpensAt uses the deadline", "dataHash, block.timestamp, block.timestamp + CLAIM_DELAY, block.timestamp + CLAIM_DEADLINE", "dataHash, block.timestamp, block.timestamp + CLAIM_DEADLINE, block.timestamp + CLAIM_DEADLINE", None),
 ("M11", "cancelEpoch without onlyOwner", "function cancelEpoch(uint256 epochId) external onlyOwner nonReentrant", "function cancelEpoch(uint256 epochId) external nonReentrant", None),
 ("M12", "cancel window one second too long (> instead of >=)", "if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", "if (block.timestamp > uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", None),
 ("M13", "cancel allowed after the window (window check always passes)", "if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", "if (block.timestamp >= type(uint256).max) revert WindowOver();", None),
 ("M14", "cancel does not mark the epoch Cancelled", "e.status = Status.Cancelled;", "", None),
 ("M15", "cancel refunds nothing", "PHAR.safeTransfer(msg.sender, refund);", "", None),
 ("M16", "cancel marks the epoch Swept", "e.status = Status.Cancelled;", "e.status = Status.Swept;", None),
 ("M17", "cancel status check removed", "        Epoch storage e = _epochs[epochId];\n        if (e.status != Status.Open) revert EpochNotOpen(e.status);\n        if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", "        Epoch storage e = _epochs[epochId];\n        if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", None),
 ("M18", "sweepUnclaimed without onlyOwner", "function sweepUnclaimed(uint256 epochId) external onlyOwner nonReentrant", "function sweepUnclaimed(uint256 epochId) external nonReentrant", None),
 ("M19", "sweep allowed one second early (< to <=)", "if (block.timestamp < deadline) revert DeadlineNotReached(deadline);", "if (block.timestamp <= deadline) revert DeadlineNotReached(deadline);", None),
 ("M20", "sweep deadline check removed", "if (block.timestamp < deadline) revert DeadlineNotReached(deadline);", "", None),
 ("M21", "sweep pays the whole total, not total - claimed", "uint256 rest = uint256(e.total) - e.claimed;", "uint256 rest = uint256(e.total);", None),
 ("M22", "sweep does not mark Swept (can be repeated)", "e.status = Status.Swept;", "", None),
 ("M23", "sweep status check removed", "        if (e.status != Status.Open) revert EpochNotOpen(e.status);\n        uint256 deadline", "        uint256 deadline", None),
 ("M24", "sweep deadline measured from CLAIM_DELAY", "uint256 deadline = uint256(e.publishedAt) + CLAIM_DEADLINE;\n        if (block.timestamp < deadline) revert DeadlineNotReached", "uint256 deadline = uint256(e.publishedAt) + CLAIM_DELAY;\n        if (block.timestamp < deadline) revert DeadlineNotReached", None),
 ("M25", "claim without the reentrancy guard", "function claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant", "function claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof) external", None),
 ("M26", "claimMany without the reentrancy guard", "function claimMany(Claim[] calldata claims) external nonReentrant", "function claimMany(Claim[] calldata claims) external", None),
 ("M27", "publishEpoch without the reentrancy guard", "        onlyOwner\n        nonReentrant\n        returns (uint256 epochId)", "        onlyOwner\n        returns (uint256 epochId)", "equivalent: the only external call of publishEpoch is transferFrom on the PHAR token; every function it could re-enter is onlyOwner (msg.sender would be the token) or claim, which needs the epoch to be Open and claim-window-open: impossible in the same transaction (the new epoch is in its delay window). Not killable with an honest model."),
 ("M28", "claim opens one second early (< to <=)", "if (block.timestamp < opensAt) revert ClaimsNotOpen(opensAt);", "if (block.timestamp <= opensAt) revert ClaimsNotOpen(opensAt);", None),
 ("M29", "claim opens one second early (cut at opensAt - 1)", "if (block.timestamp < opensAt) revert ClaimsNotOpen(opensAt);", "if (block.timestamp + 1 < opensAt) revert ClaimsNotOpen(opensAt);", None),
 ("M30", "claim window check removed", "if (block.timestamp < opensAt) revert ClaimsNotOpen(opensAt);", "", None),
 ("M31", "claim stays open one second after the deadline", "if (block.timestamp >= deadline) revert ClaimsClosed(deadline);", "if (block.timestamp > deadline) revert ClaimsClosed(deadline);", None),
 ("M32", "claim deadline check removed", "if (block.timestamp >= deadline) revert ClaimsClosed(deadline);", "", None),
 ("M33", "claim status check removed", "        Epoch storage e = _epochs[epochId];\n        if (e.status != Status.Open) revert EpochNotOpen(e.status);\n        uint256 opensAt", "        Epoch storage e = _epochs[epochId];\n        uint256 opensAt", None),
 ("M34", "double claim allowed (claimed flag not checked)", "        if (_claimed[epochId][account]) {\n            if (skipIfClaimed) return;\n            revert AlreadyClaimed();\n        }\n", "", None),
 ("M35", "claimed flag never set", "_claimed[epochId][account] = true;", "", None),
 ("M36", "claimMany reverts instead of skipping", "if (skipIfClaimed) return;", "if (skipIfClaimed) revert AlreadyClaimed();", None),
 ("M37", "claim reverts also in claimMany skip path inverted (skip on single claim)", "revert AlreadyClaimed();\n        }", "return;\n        }", None),
 ("M38", "zero amount accepted", "if (amount == 0) revert ZeroAmount();", "", None),
 ("M39", "merkle proof not verified", "if (!MerkleProof.verifyCalldata(proof, e.root, _leaf(epochId, account, amount))) revert InvalidProof();", "", None),
 ("M40", "merkle proof verified against the epoch id 0 root", "if (!MerkleProof.verifyCalldata(proof, e.root, _leaf(", "if (!MerkleProof.verifyCalldata(proof, _epochs[0].root, _leaf(", None),
 ("M41", "over-commit check removed", "if (claimedAfter > e.total) revert ExceedsEpochTotal(claimedAfter, e.total);", "", None),
 ("M42", "over-commit check off by one (>= instead of >)", "if (claimedAfter > e.total) revert", "if (claimedAfter >= e.total) revert", None),
 ("M43", "claimed counter not updated", "e.claimed = uint128(claimedAfter);", "", None),
 ("M44", "claim pays the caller instead of the account", "PHAR.safeTransfer(account, amount);", "PHAR.safeTransfer(msg.sender, amount);", None),
 ("M45", "claim pays before marking (CEI broken, guard still there)", "        _claimed[epochId][account] = true;\n        e.claimed = uint128(claimedAfter);\n        PHAR.safeTransfer(account, amount);", "        PHAR.safeTransfer(account, amount);\n        _claimed[epochId][account] = true;\n        e.claimed = uint128(claimedAfter);", "equivalent while claim/claimMany hold the reentrancy guard (M25/M26 prove the guard is what protects); the order of effects and the transfer is not observable by a re-entrant caller."),
 ("M46", "leaf is single hashed", "return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));", "return keccak256(abi.encode(epochId, account, amount));", None),
 ("M47", "leaf without the epoch id", "return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));", "return keccak256(bytes.concat(keccak256(abi.encode(uint256(0), account, amount))));", None),
 ("M48", "leaf fields swapped (amount, account)", "return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));", "return keccak256(bytes.concat(keccak256(abi.encode(epochId, amount, account))));", None),
 ("M49", "leaf uses packed encoding", "return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));", "return keccak256(bytes.concat(keccak256(abi.encodePacked(epochId, account, amount))));", None),
 ("M50", "renounceOwnership allowed (no-op body)", "        revert RenounceDisabled();\n    }", "    }", None),
 ("M51", "constructor accepts a zero delay", "claimDelay == 0 || ", "", None),
 ("M52", "constructor window boundary (< to <=)", "claimDeadline < claimDelay + MIN_CLAIM_WINDOW", "claimDeadline <= claimDelay + MIN_CLAIM_WINDOW", None),
 ("M53", "constructor accepts any deadline above the 10 year bound", "|| claimDeadline > 10 * 365 days", "", None),
 ("M54", "constructor does not check the token has code", "if (address(phar).code.length == 0) revert NotAContract();", "", None),
 ("M55", "constructor does not check the zero token", "if (address(phar) == address(0)) revert ZeroAddress();", "", "equivalent: a zero token has no code, so the next check (NotAContract) reverts anyway; only the error name differs and no behaviour is lost."),
 ("M56", "immutable CLAIM_DELAY set from the deadline", "CLAIM_DELAY = claimDelay;", "CLAIM_DELAY = claimDeadline;", None),
 ("M57", "immutable CLAIM_DEADLINE set from the delay", "CLAIM_DEADLINE = claimDeadline;", "CLAIM_DEADLINE = claimDelay;", None),
 ("M58", "MIN_CLAIM_WINDOW lowered to 1 day", "MIN_CLAIM_WINDOW = 7 days;", "MIN_CLAIM_WINDOW = 1 days;", None),
 ("M59", "isClaimed always false", "return _claimed[epochId][account];\n    }\n\n    /// @notice Everything", "return false;\n    }\n\n    /// @notice Everything", None),
 ("M60", "epochInfo claimOpensAt uses the deadline", "v.claimOpensAt = uint256(e.publishedAt) + CLAIM_DELAY;", "v.claimOpensAt = uint256(e.publishedAt) + CLAIM_DEADLINE;", None),
 ("M61", "epochInfo reports claimed as 0", "v.claimed = e.claimed;", "", None),
 ("M62", "isClaimWindowOpen deadline inclusive", "block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY && block.timestamp < uint256(e.publishedAt) + CLAIM_DEADLINE;", "block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY && block.timestamp <= uint256(e.publishedAt) + CLAIM_DEADLINE;", None),
 ("M63", "isClaimWindowOpen start exclusive", "block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY && block.timestamp < uint256(e.publishedAt) + CLAIM_DEADLINE;", "block.timestamp > uint256(e.publishedAt) + CLAIM_DELAY && block.timestamp < uint256(e.publishedAt) + CLAIM_DEADLINE;", None),
 ("M64", "isClaimWindowOpen ignores the status", "if (e.status != Status.Open) return false;\n        return block", "return block", None),
 ("M65", "verifyLeaf always true for existing epochs", "return MerkleProof.verifyCalldata(proof, e.root, _leaf(epochId, account, amount));\n    }\n\n    /// @notice The leaf hash", "return true;\n    }\n\n    /// @notice The leaf hash", None),
 ("M66", "verifyLeaf true for an unknown epoch (check removed)", "if (e.status == Status.None) return false;\n        return MerkleProof", "return MerkleProof", "equivalent: an unknown epoch has root 0 and a keccak leaf never hashes up to 0, so verifyLeaf is false either way."),
 ("M67", "claim does not honour the epoch id in the status lookup (uses epoch 0)", "    function _claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof, bool skipIfClaimed) private {\n        Epoch storage e = _epochs[epochId];", "    function _claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof, bool skipIfClaimed) private {\n        Epoch storage e = _epochs[0];", None),
 ("M68", "claimed flag shared across epochs (keyed by 0)", "_claimed[epochId][account] = true;", "_claimed[0][account] = true;", None),
 ("M69", "claimMany stops after the first entry", "for (uint256 i = 0; i < claims.length; ++i) {", "for (uint256 i = 0; i < claims.length && i < 1; ++i) {", None),
 ("M70", "cancel allowed for any status (only None excluded)", "        Epoch storage e = _epochs[epochId];\n        if (e.status != Status.Open) revert EpochNotOpen(e.status);\n        if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();\n        uint256 refund = e.total;", "        Epoch storage e = _epochs[epochId];\n        if (e.status == Status.None) revert EpochNotOpen(e.status);\n        if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();\n        uint256 refund = e.total;", None),
 ("M71", "cancel refund = total - claimed", "uint256 refund = e.total; // nothing can have been claimed yet: claims open only after the window", "uint256 refund = uint256(e.total) - e.claimed;", "equivalent: claimed is always 0 inside the challenge window (claims open only at claimOpensAt, and cancel is only allowed before it)."),
 ("M72", "sweep sends only when rest != 0 -> always", "if (rest != 0) PHAR.safeTransfer(msg.sender, rest);", "PHAR.safeTransfer(msg.sender, rest);", "equivalent for the PHAR token: a zero-value transfer succeeds; only a token that rejects zero transfers would differ."),
 ("M73", "publishEpoch accepts a zero data hash", "if (dataHash == bytes32(0)) revert ZeroDataHash();", "", None),
 ("M74", "publishEpoch accepts an empty block range (>= to >)", "if (fromBlock >= toBlock || toBlock > block.number) revert BadBlockRange();", "if (fromBlock > toBlock || toBlock > block.number) revert BadBlockRange();", None),
 ("M75", "publishEpoch accepts a toBlock in the future", "if (fromBlock >= toBlock || toBlock > block.number) revert BadBlockRange();", "if (fromBlock >= toBlock) revert BadBlockRange();", None),
 ("M76", "publishEpoch accepts a toBlock one beyond the current block", "toBlock > block.number) revert BadBlockRange();", "toBlock > block.number + 1) revert BadBlockRange();", None),
 ("M77", "publishEpoch accepts a reversed range", "if (fromBlock >= toBlock || toBlock > block.number)", "if (toBlock > block.number)", None),
 ("M78", "epoch stores fromBlock as toBlock", "fromBlock: fromBlock,\n            toBlock: toBlock,", "fromBlock: toBlock,\n            toBlock: toBlock,", None),
 ("M79", "epoch stores toBlock as fromBlock", "fromBlock: fromBlock,\n            toBlock: toBlock,", "fromBlock: fromBlock,\n            toBlock: fromBlock,", None),
 ("M80", "epoch does not store the data hash", "status: Status.Open,\n            dataHash: dataHash", "status: Status.Open,\n            dataHash: bytes32(0)", None),
 ("M81", "epochInfo does not return the data hash", "v.dataHash = e.dataHash;", "", None),
 ("M82", "epochInfo returns toBlock as the block range start", "v.fromBlock = e.fromBlock;\n        v.toBlock = e.toBlock;", "v.fromBlock = e.toBlock;\n        v.toBlock = e.fromBlock;", None),
 ("M83", "event emits the data hash as zero", "epochId, root, total, fromBlock, toBlock, dataHash, block.timestamp", "epochId, root, total, fromBlock, toBlock, bytes32(0), block.timestamp", None),
 ("M84", "event emits fromBlock twice", "epochId, root, total, fromBlock, toBlock, dataHash, block.timestamp", "epochId, root, total, fromBlock, fromBlock, dataHash, block.timestamp", None),]

def run_one(args):
    mid, desc, old, new, eq, scratch_root, base = args
    d = os.path.join(scratch_root, mid)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    for f in ("foundry.toml",): shutil.copy(os.path.join(base, f), d)
    os.symlink(os.path.join(base, "lib"), os.path.join(d, "lib"))
    shutil.copytree(os.path.join(base, "src/rewards"), os.path.join(d, "src/rewards"))
    shutil.copytree(os.path.join(base, "test/rewards"), os.path.join(d, "test/rewards"))
    p = os.path.join(d, SRC); s = open(p).read()
    if s.count(old) != 1: return (mid, desc, "BADSPEC", f"old text occurs {s.count(old)} times", eq)
    open(p, "w").write(s.replace(old, new))
    env = dict(os.environ, FOUNDRY_FUZZ_SEED="0x2a")
    r = subprocess.run(["forge", "test", "--match-path", "test/rewards/*", "-q"], cwd=d, env=env, capture_output=True, text=True)
    out = r.stdout + r.stderr
    if r.returncode == 0: res = "SURVIVED"; who = ""
    elif "Compiler run failed" in out or "Error (" in out or "error[" in out: res = "INVALID"; who = out.strip().splitlines()[-1][:120] if out.strip() else ""
    else:
        res = "KILLED"; who = ", ".join(sorted(set(re.findall(r"\]\s+((?:test|invariant)\w*)\(", "\n".join(l for l in out.splitlines() if "FAIL" in l)))))[:160]
    shutil.rmtree(d, ignore_errors=True)
    return (mid, desc, res, who, eq)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--jobs", type=int, default=6); ap.add_argument("--only", default=""); ap.add_argument("--scratch", default="")
    a = ap.parse_args(); base = os.getcwd()
    if not os.path.exists(os.path.join(base, SRC)): sys.exit("run from contracts/vault-dlmm")
    scratch = a.scratch or tempfile.mkdtemp(prefix="rewards-mut-")
    only = set(filter(None, a.only.split(",")))
    work = [(m[0], m[1], m[2], m[3], m[4], scratch, os.path.realpath(base)) for m in M if not only or m[0] in only]
    res = []
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for r in ex.map(run_one, work):
            print(f"{r[0]} {r[2]:9} {r[1]}  {r[3]}", flush=True); res.append(r)
    killed = [r for r in res if r[2] == "KILLED"]; surv = [r for r in res if r[2] == "SURVIVED"]; inv = [r for r in res if r[2] in ("INVALID", "BADSPEC")]
    eq = [r for r in surv if r[4]]; real = [r for r in surv if not r[4]]
    print(f"\nmutants {len(res)}: killed {len(killed)}, survived-equivalent {len(eq)}, survived-UNEXPLAINED {len(real)}, invalid/badspec {len(inv)}")
    for r in real + inv: print("  ", r[0], r[2], r[1], r[3])
