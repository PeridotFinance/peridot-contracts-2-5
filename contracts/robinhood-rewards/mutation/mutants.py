#!/usr/bin/env python3
"""Hand-mutant round on src/MerkleRewardsDistributor.sol (method of the Avalanche round mutation/rewards-mutants.py: one textual
change per mutant, applied to a scratch copy of this project, never the worktree; forge test with fixed fuzz seed 0x2a).
usage (from contracts/robinhood-rewards):  python3 mutation/mutants.py [--jobs 6] [--only M07,M08]
KILLED = forge test fails; INVALID = does not compile; EQUIVALENT mutants are argued below and excluded from the score."""
import argparse, concurrent.futures as cf, os, re, shutil, subprocess, sys, tempfile

SRC = "src/MerkleRewardsDistributor.sol"
PUB = "        onlyOwner\n        nonReentrant\n        returns (uint256 epochId)"
LEAF = "return keccak256(bytes.concat(keccak256(abi.encode(epochId, account, amount))));"
M = [
 ("M01", "publishEpoch without onlyOwner", PUB, "        nonReentrant\n        returns (uint256 epochId)", None),
 ("M02", "zero root accepted", "if (root == bytes32(0)) revert ZeroRoot();", "", None),
 ("M03", "zero total accepted", "if (total == 0) revert ZeroTotal();", "", None),
 ("M04", "zero dataHash accepted", "if (dataHash == bytes32(0)) revert ZeroDataHash();", "", None),
 ("M05", "block range check removed", "if (fromBlock >= toBlock) revert BadBlockRange();", "", None),
 ("M06", "empty block range accepted (>= to >)", "if (fromBlock >= toBlock) revert BadBlockRange();", "if (fromBlock > toBlock) revert BadBlockRange();", None),
 ("M07", "the Avalanche toBlock <= block.number check re-added", "if (fromBlock >= toBlock) revert BadBlockRange();", "if (fromBlock >= toBlock || toBlock > block.number) revert BadBlockRange();", None),
 ("M08", "uint128 bound removed", "if (total > type(uint128).max) revert TotalTooLarge();", "", None),
 ("M09", "unallocated check removed", "if (total > free) revert InsufficientUnallocated(free, total);", "", None),
 ("M10", "unallocated check off by one (> to >=)", "if (total > free) revert InsufficientUnallocated", "if (total >= free) revert InsufficientUnallocated", None),
 ("M11", "publish commits against the whole balance (ignores reserved)", "uint256 free = unallocated();", "uint256 free = REWARD_TOKEN.balanceOf(address(this));", None),
 ("M12", "publish does not reserve", "        reserved += total;\n        epochId", "        epochId", None),
 ("M13", "epoch id pre-incremented", "epochId = epochCount++;", "epochId = ++epochCount;", None),
 ("M14", "epoch recorded with claimed = 1", "claimed: 0,\n            publishedAt", "claimed: 1,\n            publishedAt", None),
 ("M15", "epoch recorded Cancelled", "status: Status.Open,\n            dataHash: dataHash", "status: Status.Cancelled,\n            dataHash: dataHash", None),
 ("M16", "fromBlock and toBlock swapped in storage", "fromBlock: fromBlock,\n            toBlock: toBlock,", "fromBlock: toBlock,\n            toBlock: fromBlock,", None),
 ("M17", "event claimOpensAt uses the deadline", "            block.timestamp + CLAIM_DELAY,\n            block.timestamp + CLAIM_DEADLINE", "            block.timestamp + CLAIM_DEADLINE,\n            block.timestamp + CLAIM_DEADLINE", None),
 ("M18", "publishEpoch without the reentrancy guard", PUB, "        onlyOwner\n        returns (uint256 epochId)", None),
 ("M19", "cancelEpoch without onlyOwner", "function cancelEpoch(uint256 epochId) external onlyOwner nonReentrant", "function cancelEpoch(uint256 epochId) external nonReentrant", None),
 ("M20", "cancel window one second too long", "if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", "if (block.timestamp > uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", None),
 ("M21", "cancel window check removed", "if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", "", None),
 ("M22", "cancel does not mark Cancelled", "e.status = Status.Cancelled;", "", None),
 ("M23", "cancel marks Swept", "e.status = Status.Cancelled;", "e.status = Status.Swept;", None),
 ("M24", "cancel does not release the reservation", "        e.status = Status.Cancelled;\n        reserved -= released;", "        e.status = Status.Cancelled;", None),
 ("M25", "cancel status check removed", "        if (e.status != Status.Open) revert EpochNotOpen(e.status);\n        if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", "        if (block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY) revert WindowOver();", None),
 ("M26", "cancel releases total instead of total - claimed", "uint256 released = uint256(e.total) - e.claimed; // claimed is 0", "uint256 released = uint256(e.total); // claimed is 0", "equivalent: claimed is always 0 while cancel is possible (claims open only when the cancel window has closed), as in the Avalanche round (M71)"),
 ("M27", "cancel also pays the owner (Avalanche refund)", "        reserved -= released;\n        emit EpochCancelled", "        reserved -= released;\n        REWARD_TOKEN.transfer(msg.sender, released);\n        emit EpochCancelled", None),
 ("M28", "sweepUnclaimed without onlyOwner", "function sweepUnclaimed(uint256 epochId) external onlyOwner nonReentrant", "function sweepUnclaimed(uint256 epochId) external nonReentrant", None),
 ("M29", "sweep one second early", "if (block.timestamp < deadline) revert DeadlineNotReached(deadline);", "if (block.timestamp + 1 < deadline) revert DeadlineNotReached(deadline);", None),
 ("M30", "sweep deadline check removed", "if (block.timestamp < deadline) revert DeadlineNotReached(deadline);", "", None),
 ("M31", "sweep releases the whole total", "        uint256 released = uint256(e.total) - e.claimed;\n        e.status = Status.Swept;", "        uint256 released = uint256(e.total);\n        e.status = Status.Swept;", None),
 ("M32", "sweep does not mark Swept", "e.status = Status.Swept;", "", None),
 ("M33", "sweep status check removed", "        if (e.status != Status.Open) revert EpochNotOpen(e.status);\n        uint256 deadline", "        uint256 deadline", None),
 ("M34", "sweep deadline measured from CLAIM_DELAY", "uint256 deadline = uint256(e.publishedAt) + CLAIM_DEADLINE;\n        if (block.timestamp < deadline) revert DeadlineNotReached", "uint256 deadline = uint256(e.publishedAt) + CLAIM_DELAY;\n        if (block.timestamp < deadline) revert DeadlineNotReached", None),
 ("M35", "sweep does not release the reservation", "        e.status = Status.Swept;\n        reserved -= released;", "        e.status = Status.Swept;", None),
 ("M36", "sweep pays the owner (Avalanche behaviour)", "        reserved -= released;\n        emit EpochSwept", "        reserved -= released;\n        if (released != 0) REWARD_TOKEN.transfer(msg.sender, released);\n        emit EpochSwept", None),
 ("M37", "renounce enabled", "        revert RenounceDisabled();", "        _transferOwnership(address(0));", None),
 ("M38", "claim without the reentrancy guard", "function claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant", "function claim(uint256 epochId, address account, uint256 amount, bytes32[] calldata proof) external", None),
 ("M39", "claimMany without the reentrancy guard", "function claimMany(Claim[] calldata claims) external nonReentrant", "function claimMany(Claim[] calldata claims) external", None),
 ("M40", "claim opens one second early (< to <=) [inverted: late]", "if (block.timestamp < opensAt) revert ClaimsNotOpen(opensAt);", "if (block.timestamp <= opensAt) revert ClaimsNotOpen(opensAt);", None),
 ("M41", "claim opens one second early", "if (block.timestamp < opensAt) revert ClaimsNotOpen(opensAt);", "if (block.timestamp + 1 < opensAt) revert ClaimsNotOpen(opensAt);", None),
 ("M42", "claim window check removed", "if (block.timestamp < opensAt) revert ClaimsNotOpen(opensAt);", "", None),
 ("M43", "claim open one second after the deadline", "if (block.timestamp >= deadline) revert ClaimsClosed(deadline);", "if (block.timestamp > deadline) revert ClaimsClosed(deadline);", None),
 ("M44", "claim deadline check removed", "if (block.timestamp >= deadline) revert ClaimsClosed(deadline);", "", None),
 ("M45", "claim status check removed", "        if (e.status != Status.Open) revert EpochNotOpen(e.status);\n        uint256 opensAt", "        uint256 opensAt", None),
 ("M46", "double claim allowed", "        if (_claimed[epochId][account]) {\n            if (skipIfClaimed) return;\n            revert AlreadyClaimed();\n        }\n", "", None),
 ("M47", "claimed flag never set", "_claimed[epochId][account] = true;", "", None),
 ("M48", "claimMany reverts instead of skipping", "if (skipIfClaimed) return;", "if (skipIfClaimed) revert AlreadyClaimed();", None),
 ("M49", "single claim skips silently", "revert AlreadyClaimed();\n        }", "return;\n        }", None),
 ("M50", "zero amount accepted", "if (amount == 0) revert ZeroAmount();", "", None),
 ("M51", "proof not verified", "if (!MerkleProof.verifyCalldata(proof, e.root, _leaf(epochId, account, amount))) revert InvalidProof();", "", None),
 ("M52", "proof checked against epoch 0's root", "if (!MerkleProof.verifyCalldata(proof, e.root, _leaf(epochId, account, amount))) revert InvalidProof();", "if (!MerkleProof.verifyCalldata(proof, _epochs[0].root, _leaf(epochId, account, amount))) revert InvalidProof();", None),
 ("M53", "over-commit check removed", "if (claimedAfter > e.total) revert ExceedsEpochTotal(claimedAfter, e.total);", "", None),
 ("M54", "over-commit check off by one", "if (claimedAfter > e.total) revert", "if (claimedAfter >= e.total) revert", None),
 ("M55", "claimed counter not updated", "e.claimed = uint128(claimedAfter);", "", None),
 ("M56", "claim does not reduce reserved", "        reserved -= amount;\n        REWARD_TOKEN.safeTransfer(account, amount);", "        REWARD_TOKEN.safeTransfer(account, amount);", None),
 ("M57", "claim pays the caller", "REWARD_TOKEN.safeTransfer(account, amount);", "REWARD_TOKEN.safeTransfer(msg.sender, amount);", None),
 ("M58", "claim pays before the effects (guard still there)", "        _claimed[epochId][account] = true;\n        e.claimed = uint128(claimedAfter);\n        reserved -= amount;\n        REWARD_TOKEN.safeTransfer(account, amount);", "        REWARD_TOKEN.safeTransfer(account, amount);\n        _claimed[epochId][account] = true;\n        e.claimed = uint128(claimedAfter);\n        reserved -= amount;", "equivalent while claim/claimMany hold the reentrancy guard (M38/M39 show the guard is what protects); as Avalanche M45"),
 ("M59", "claim uses unchecked transfer", "REWARD_TOKEN.safeTransfer(account, amount);", "REWARD_TOKEN.transfer(account, amount);", None),
 ("M60", "leaf single hashed", LEAF, "return keccak256(abi.encode(epochId, account, amount));", None),
 ("M61", "leaf without the epoch id", LEAF, "return keccak256(bytes.concat(keccak256(abi.encode(uint256(0), account, amount))));", None),
 ("M62", "leaf fields swapped", LEAF, "return keccak256(bytes.concat(keccak256(abi.encode(epochId, amount, account))));", None),
 ("M63", "leaf packed encoding", LEAF, "return keccak256(bytes.concat(keccak256(abi.encodePacked(epochId, account, amount))));", None),
 ("M64", "unallocated does not subtract reserved", "return bal > reserved ? bal - reserved : 0;", "return bal;", None),
 ("M65", "unallocated reverts instead of saturating", "return bal > reserved ? bal - reserved : 0;", "return bal - reserved;", None),
 ("M66", "unallocated saturation at >= (equal case)", "return bal > reserved ? bal - reserved : 0;", "return bal >= reserved ? bal - reserved : 0;", "equivalent: at bal == reserved both branches return 0"),
 ("M67", "isClaimWindowOpen ignores the status", "        if (e.status != Status.Open) return false;\n        return block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY", "        return block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY", None),
 ("M68", "isClaimWindowOpen open at the deadline", "&& block.timestamp < uint256(e.publishedAt) + CLAIM_DEADLINE;", "&& block.timestamp <= uint256(e.publishedAt) + CLAIM_DEADLINE;", None),
 ("M69", "isClaimWindowOpen open one second early", "        return block.timestamp >= uint256(e.publishedAt) + CLAIM_DELAY", "        return block.timestamp + 1 >= uint256(e.publishedAt) + CLAIM_DELAY", None),
 ("M70", "epochInfo hides claimOpensAt", "            v.claimOpensAt = uint256(e.publishedAt) + CLAIM_DELAY;\n", "", None),
 ("M71", "epochInfo deadline = delay", "v.claimDeadline = uint256(e.publishedAt) + CLAIM_DEADLINE;", "v.claimDeadline = uint256(e.publishedAt) + CLAIM_DELAY;", None),
 ("M72", "epochInfo drops claimed", "        v.claimed = e.claimed;\n", "", None),
 ("M73", "verifyLeaf true for unknown epochs", "        if (e.status == Status.None) return false;\n        return MerkleProof", "        return MerkleProof", "equivalent: an unknown epoch has root 0; a proof verifying to root 0 needs a keccak preimage of 0 (as Avalanche M66)"),
 ("M74", "constructor allows a zero delay", "if (claimDelay == 0 || claimDeadline", "if (claimDeadline", None),
 ("M75", "constructor window minimum off by one", "claimDeadline < claimDelay + MIN_CLAIM_WINDOW", "claimDeadline <= claimDelay + MIN_CLAIM_WINDOW", None),
 ("M76", "constructor accepts > 10 years", " || claimDeadline > 10 * 365 days", "", None),
 ("M77", "constructor accepts a codeless token", "if (address(rewardToken).code.length == 0) revert NotAContract();", "", None),
 ("M78", "constructor accepts the zero token", "if (address(rewardToken) == address(0)) revert ZeroAddress();", "", None),
]

def run_one(args):
    mid, desc, old, new, eq, scratch, base = args
    d = os.path.join(scratch, mid)
    shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    shutil.copy(os.path.join(base, "foundry.toml"), d)
    os.symlink(os.path.join(base, "lib"), os.path.join(d, "lib"))
    for sub in ("src", "test", "script"): shutil.copytree(os.path.join(base, sub), os.path.join(d, sub))
    os.makedirs(os.path.join(d, "deployments"))
    p = os.path.join(d, SRC); s = open(p).read()
    if s.count(old) != 1: return (mid, desc, "BADSPEC", f"old text occurs {s.count(old)} times", eq)
    open(p, "w").write(s.replace(old, new))
    env = dict(os.environ, FOUNDRY_FUZZ_SEED="0x2a")
    r = subprocess.run(["forge", "test"], cwd=d, env=env, capture_output=True, text=True)
    out = r.stdout + r.stderr
    if r.returncode == 0: res, who = "SURVIVED", ""
    elif "Compiler run failed" in out or "Compilation failed" in out or "Error (" in out and "[FAIL" not in out: res, who = "INVALID", out.strip().splitlines()[-1][:120]
    else:
        res = "KILLED"; who = ", ".join(sorted(set(re.findall(r"\[FAIL[^\]]*\]\s+((?:test|invariant)\w*)\(", out))))[:200]
    shutil.rmtree(d, ignore_errors=True)
    return (mid, desc, res, who, eq)

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--jobs", type=int, default=6); ap.add_argument("--only", default="")
    a = ap.parse_args(); base = os.path.realpath(os.getcwd())
    if not os.path.exists(os.path.join(base, SRC)): sys.exit("run from contracts/robinhood-rewards")
    scratch = tempfile.mkdtemp(prefix="ram-mut-")
    only = set(filter(None, a.only.split(",")))
    work = [(m[0], m[1], m[2], m[3], m[4], scratch, base) for m in M if not only or m[0] in only]
    res = []
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for r in ex.map(run_one, work):
            print(f"{r[0]} {r[2]:9} {r[1]}  {r[3]}", flush=True); res.append(r)
    killed = [r for r in res if r[2] == "KILLED"]; surv = [r for r in res if r[2] == "SURVIVED"]; inv = [r for r in res if r[2] in ("INVALID", "BADSPEC")]
    eq = [r for r in surv if r[4]]; real = [r for r in surv if not r[4]]
    print(f"\nmutants {len(res)}: killed {len(killed)}, survived-equivalent {len(eq)}, survived-UNEXPLAINED {len(real)}, invalid/badspec {len(inv)}")
    for r in real + inv: print("  ", r[0], r[2], r[1], r[3])
