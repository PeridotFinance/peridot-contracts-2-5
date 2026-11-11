# Freeze the Pharaoh CL USDC/USDt vault: deposit cap = current balance (Safe transaction, Ledger)

Status: **PREPARED, NOT SENT** (11 Nov 2026). Dry-run with `eth_call` from the Ledger: returns `true`. Decision (operator, 11 Nov 2026): the deep Pharaoh USDC/USDT liquidity is in the DLMM pool `0x16888EE58E706C253b821EAA637ae9b2cFeA255C` (about USD 3.7M), not in the CL pool this vault uses (TVL about USD 1.3k, 1% depth USD 174 on the USDt side, see `avalanche-blackhole-pairs-evaluation.md`). The CL USDC/USDt vault takes no new deposits.

## What it does
`setDepositCap(39820353)` on the USDC vault proxy `0x855bF832f26a294d28500db59eE941dE3d654129`, through the Safe `0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12` (1-of-1, owner = the Ledger `0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD`). `39,820,353` is the vault's `totalAssets()` at the time of preparation (39.820353 USDC; was cap 200,000,000). The vault's `maxDeposit` is `cap - totalAssets()` when positive, else 0 (`PharaohLiquidityVaultR3.sol:255`): with the cap at the balance it is 0 and **grows only if `totalAssets()` later falls below the cap** (a loss or a position-value dip refills at most that gap, a few cents). Withdrawals and redemptions are unaffected. The **stricter** alternative is the closed sentinel `setDepositCap(1)` (calldata `0x866512030000000000000000000000000000000000000000000000000000000000000001`): `maxDeposit` is 0 whatever the balance does. Pick one; the commands below are for the cap-at-balance version the operator asked for.

## The transaction (one Ledger confirmation; Safe `execTransaction`, caller = the owner)
```
export ETH_RPC_URL=https://api.avax.network/ext/bc/C/rpc
LEDGER=0x064eFE76812F5f18Bd1aA9708739Fb33C810B2dD ; SAFE=0x80f4207e0810EA2C39B6C8387E5ffC6FF34dfB12
V=0x855bF832f26a294d28500db59eE941dE3d654129 ; Z=0x0000000000000000000000000000000000000000
SIG=0x000000000000000000000000064efe76812f5f18bd1aa9708739fb33c810b2dd000000000000000000000000000000000000000000000000000000000000000001
cast send $SAFE 'execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)' $V 0 0x8665120300000000000000000000000000000000000000000000000000000000025f9c41 0 0 0 0 $Z $Z $SIG --ledger --from $LEDGER
```
Safe nonce before: **18** (so 19 after). Gas about 74k.

## Read-backs (read-only)
```
cast call $V 'depositCap()(uint256)'                 # = 39820353
cast call $V 'maxDeposit(address)(uint256)' $LEDGER   # = 0 (or a few cents if totalAssets() dipped)
cast call $V 'totalAssets()(uint256)'                # compare with the cap
cast call $SAFE 'nonce()(uint256)'                   # = 19
```

## Re-open or change
Same form with another argument: `cast calldata 'setDepositCap(uint256)' <units>` (USDC has 6 decimals). Closed sentinel: argument `1`.
