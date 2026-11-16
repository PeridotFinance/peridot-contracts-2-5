# RAM distribution: ceremony list (Robinhood Chain 4663)

**NOT RUN.** The main thread reruns `tools/rehearse_ram_epoch.sh` as the gate before this list is sent.

The operator runs only what is sent, in order, in the next market-hours window. Market hours matter only because the
keeper's harvest checkpoint needs a fresh SPY feed; the distributor calls themselves need no feed.

| | |
| --- | --- |
| Signer for every live step | the Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`. Type it from this file, NEVER from tx history: an address poisoner imitates it. |
| Never | `0x94696d767e65a75581145646960FA0eC886cE5d2` (old signer). It is never a deployer, owner, recipient or role. |
| Ledger signatures | **3**: timelock schedule, timelock execute, publishEpoch. Collecting the protocol leaf needs none (anyone can submit it). |
| Waits | 3,600 s between schedule and execute; 86,400 s between publish and the first claim |
| Throwaway deployer | 1 creation, about 0.0002 ETH of gas. It is funded by the Ledger (1 more Ledger send, optional) or from any gas wallet. |

Run everything from `contracts/robinhood-rewards` on branch `feat/robinhood-ram-distributor`. `ETH_RPC_URL` is the
operator's endpoint, set in the environment and never passed as an argument.

```bash
export V=0x67e7742922f4CC88C545e5aB5Df402b22DB4830b T=0x6797FB8Ce049B42C5BC2b42Bf76c6d15C7B12498
export L=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD RAM=0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802
export PAIR=0x8f81f5d84aa85b29b5114b8ca1a75266c4dc18785b703e8257ca66ecb4ba5435
export ETHERS_DIR=/Users/joshua/Peridot/peridot-contracts-2-5/contracts/node_modules/ethers
```

## 0. Pre-flight reads (no signature)

```bash
cast chain-id                                                               # 4663
cast call $V 'externalRewards(bytes32,address)(uint256)' $PAIR $RAM          # >= the epoch's heldSum (96799596213810175 at L2 115932843)
cast call $V 'hasRole(bytes32,address)(bool)' $(cast keccak CONFIG_ROLE) $T  # true
cast call $T 'getMinDelay()(uint256)'                                        # 3600
cast call $T 'hasRole(bytes32,address)(bool)' $(cast keccak PROPOSER_ROLE) $L  # true
cast call $T 'hasRole(bytes32,address)(bool)' $(cast keccak EXECUTOR_ROLE) $L  # true
cast call $RAM 'decimals()(uint8)'                                           # 18
cast balance $L                                                              # gas for 3 sends
```

## 1. Throwaway deploy (no Ledger signature)

`D` is the throwaway account: a new Foundry keystore with gas only. It is never the Ledger and never the old signer.

```bash
RAM_DEPLOYER=$D forge script script/DeployRamRewardsDistributor.s.sol:DeployRamRewardsDistributor --rpc-url $ETH_RPC_URL --sender $D            # simulate
RAM_DEPLOYER=$D forge script script/DeployRamRewardsDistributor.s.sol:DeployRamRewardsDistributor --rpc-url $ETH_RPC_URL --sender $D \
  --account <throwaway-keystore> --broadcast --slow                                                                                           # ONE creation
forge script script/DeployRamRewardsDistributor.s.sol:DeployRamRewardsDistributor --sig 'verify(string)' deployments/ram-distributor-mainnet.json --rpc-url $ETH_RPC_URL
export DIST=$(jq -r .distributor deployments/ram-distributor-mainnet.json)
cast call $DIST 'owner()(address)'          # the Ledger
cast call $DIST 'epochCount()(uint256)'     # 0
```

The pre-flight refuses:
- a chain other than 4663 (`WRONG_CHAIN`);
- the old signer (`OLD_SIGNER_REFUSED`) or the Ledger (`LEDGER_IS_NOT_THE_DEPLOYER`) as deployer;
- a contract deployer;
- RAM not being 18 decimals;
- the timelock without `CONFIG_ROLE`;
- the old signer holding `CONFIG_ROLE`.

Commit the journal and add a detached sha256.

## 2. Root generation (no signature; anyone, and a second machine compares)

```bash
node tools/robinhood-ram-root.mjs --epoch-id $(cast call $DIST 'epochCount()(uint256)') --first-epoch --to-harvest last --out-dir epochs/0
# later epochs: --previous-manifest epochs/<last published, not cancelled>/manifest.json --epoch-id <epochCount>
sha256sum epochs/0/epoch.json            # second machine: identical
```

Read the printed summary:
- held sum;
- market split;
- per-market pools;
- the protocol leaf and its parts;
- the exclusion list;
- all checks `=true`;
- `forwardExternalReward(...)` and `publishEpoch(...)` lines.

Epoch 0 today is blocks (110177000, 115782882]: 16 harvests and 96,799,596,213,810,175 wei. It has ONE leaf, the
Ledger, because only 0xdEaD and the timelock hold the markets. A harvest after that block extends `--to-harvest last`.
Re-run the generator just before step 3 and use that output.

Host `epoch.json` and `manifest.json` before step 4, so the 24 h review can use them. Then check that
`cast keccak 0x$(xxd -p epochs/0/epoch.json | tr -d '\n')` equals `manifest.dataHash`.

## 3. Timelock forward (Ledger signatures 1 and 2)

```bash
AMOUNT=$(jq -r .forwardExternalRewardArguments.amount epochs/0/manifest.json)
DATA=$(cast calldata 'forwardExternalReward(bytes32,address,address,uint256)' $PAIR $RAM $DIST $AMOUNT)
SALT=$(cast keccak "peridot-ram-forward-epoch-0"); Z=0x0000000000000000000000000000000000000000000000000000000000000000
cast call $V 'forwardExternalReward(bytes32,address,address,uint256)' $PAIR $RAM $DIST $AMOUNT --from $T     # simulate as the timelock: succeeds
cast send $T 'schedule(address,uint256,bytes,bytes32,bytes32,uint256)' $V 0 $DATA $Z $SALT 3600 --from $L --ledger        # Ledger 1
cast call $T 'isOperationPending(bytes32)(bool)' $(cast call $T 'hashOperation(address,uint256,bytes,bytes32,bytes32)(bytes32)' $V 0 $DATA $Z $SALT)
# wait 3,600 s
cast send $T 'execute(address,uint256,bytes,bytes32,bytes32)' $V 0 $DATA $Z $SALT --from $L --ledger --gas-limit 1000000  # Ledger 2
cast call $RAM 'balanceOf(address)(uint256)' $DIST        # == AMOUNT
cast call $DIST 'unallocated()(uint256)'                  # == AMOUNT
cast call $V 'externalRewards(bytes32,address)(uint256)' $PAIR $RAM    # reduced by AMOUNT
```

## 4. Publish (Ledger signature 3)

```bash
A=epochs/0/manifest.json
cast call $DIST 'epochCount()(uint256)'     # == manifest.epochId (else regenerate with the right --epoch-id)
cast send $DIST 'publishEpoch(bytes32,uint256,uint64,uint64,bytes32)' $(jq -r .publishEpochArguments.root $A) $(jq -r .publishEpochArguments.total $A) \
  $(jq -r .publishEpochArguments.fromBlock $A) $(jq -r .publishEpochArguments.toBlock $A) $(jq -r .publishEpochArguments.dataHash $A) --from $L --ledger
cast call $DIST 'epochInfo(uint256)' 0      # status 1, root, total, claimOpensAt = publishedAt + 86400
cast call $DIST 'reserved()(uint256)'       # == total;  unallocated() == 0
```

**24 h challenge window.** If anything is wrong, run `cast send $DIST 'cancelEpoch(uint256)' 0 --from $L --ledger`
(an extra Ledger signature, inside the window only). The RAM stays in the distributor as unallocated. Regenerate with
the new `epochCount()` and the same range, then publish again. No new forward is needed.

## 5. Claims (no Ledger signature)

From `claimOpensAt` onwards, anyone may submit a leaf from `epochs/0/epoch.json`. The RAM goes to `account`:

```bash
cast send $DIST 'claim(uint256,address,uint256,bytes32[])' 0 <account> <amount> '[<proof...>]' --account <any gas wallet>
cast call $DIST 'isClaimed(uint256,address)(bool)' 0 <account>
```

The protocol leaf (account = the Ledger) can be submitted by any gas wallet. Claims close 180 days after publication.
After that, `sweepUnclaimed(0)` (Ledger) releases the rest to unallocated, and a later epoch commits it with
`--extra-reward <wei>` to the protocol leaf.

## Every later epoch

The order is the same:
- generate (with `--previous-manifest`);
- schedule the forward;
- wait 1 h;
- execute;
- publish;
- wait 24 h;
- claims.

That is 3 Ledger signatures per epoch.

---

## Frontend section

- **Contract:** `MerkleRewardsDistributor` at `$DIST` (journal `deployments/ram-distributor-mainnet.json`). The token is
  RAM `0x5173D45A1191eE33cBB7D8c7e65f21B04eD54802`, 18 decimals.
- **Proofs:** fetch the hosted `epoch.json` of each epoch. The URL is the operator's `manifest.uri`; check that
  `keccak256(file bytes) == epochInfo(id).dataHash`. Index `leaves[]` (`{account, amount, leaf, proof}`) by
  lower-cased `account`. Amounts are decimal strings in wei.
- **Listing epochs:** `epochCount()`, then `epochInfo(id)` for `0..count-1`. It returns
  `(root, total, claimed, publishedAt, claimOpensAt, claimDeadline, fromBlock, toBlock, dataHash, status)`, with
  status 0 None, 1 Open, 2 Cancelled, 3 Swept. Alternatively, index the events `EpochPublished`, `EpochCancelled`,
  `Claimed` and `EpochSwept`.
- **Claim call:** `claim(uint256 epochId, address account, uint256 amount, bytes32[] proof)`. Several at once:
  `claimMany((uint256,address,uint256,bytes32[])[])`, which skips already-claimed entries. Before sending, read
  `isClaimWindowOpen(id)`, `isClaimed(id, account)` and `verifyLeaf(id, account, amount, proof)`.
- **Button states:**
  - **no leaf**: "contracts, the seed and the timelock are excluded";
  - **pending**: "opens at `claimOpensAt`, 24 h review window";
  - **claimable**;
  - **claimed**;
  - **closed**: at or after `claimDeadline`;
  - **cancelled**.
- **What to show:** the amount in RAM and the epoch's L2 block range. Never show an APY or an estimate of future RAM.
- **Deposit-screen disclosure.** Show it before the deposit button is usable, not behind a tooltip:
  > **90% of RAM rewards are distributed to depositors by epoch via Merkle claims.** RAM is shared between the rpSPY and
  > rpUSDGs markets by each side's value in the vault, then by how many market shares you held and for how long. Each
  > epoch is published, then waits 24 hours before anyone can claim; you claim it yourself, and unclaimed RAM is
  > released back to the protocol 180 days after publication. The other 10%, and the part of holders that cannot be paid
  > (smart contracts, the launch seed, the timelock), goes to the protocol. RAM rewards can be zero; there is no promised
  > amount or APY.
