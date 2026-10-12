# Fuji margin: higher-leverage rehearsal and disposable test wallet

This package contains local-fork tests and a **fixed-scope Fuji mock runner**.
It is not mainnet approval. The new runner has not been authorized or executed on
public Fuji. It does not change deployed contracts, transfer admin ownership,
loosen configured slippage, or change risk parameters.

## Rehearsal on the deployed stack

`test/FujiCollateralMarginLiveFork.t.sol` forks Fuji block **59336291**, after the
four requested-2x round trips and both pToken withdrawals. It uses the existing
executor `0xA1398d06Cf8d0bE8673A46C67e462718FD99Bf9C`, existing liquidity, debt
accounting, insurance, fee distribution and original collateral markets.

Only inside the local VM, the test impersonates the mock-feed owner, transfers
existing pTokens to a separate non-admin trader and changes mock prices. It does
not fabricate pToken balances or impersonate anyone on the public network.

Five test functions passed with no skips:

- Twelve round trips: requested3x/4x/5x, both collateral pools, long and short.
  Each uses $25 mock-equivalent margin from a $60 pool budget, at most $0.25
  opening/closing fee and $2 voluntary-close collateral sale. The swap minimum
  remains99% of the quote. Collateral retention, zero final debt, closed status,
  cleared approvals and pToken-only withdrawal with unchanged supply are checked.
- Four partial-liquidation scenarios:50% repayment improves health, leaves some
  debt, then restored $10 mock pricing permits full voluntary close.
- Four full-liquidation scenarios at negative equity: insurance is used, bounded
  by100 mockUSD or10 mockAVAX per scenario, with no account/aggregate debt left.
  Liquidation may consume the entire position collateral; the voluntary-close
  sale cap does **not** limit liquidation loss. These losses occur only locally.
- Both long and short5x requests remain non-liquidatable after a simulated day of
  interest at unchanged prices, accrue positive debt interest and close successfully.
- A non-admin trader cannot update the existing mock feeds, and a keeper cannot
  liquidate a healthy position.

The boundary search checks adjacent price points at1bp distance resolution. With
mock AVAX initially$10, results were:

| Collateral | Side | Requested | Actual entry leverage | First liquidatable AVAX price | Adverse distance |
| --- | --- | --- | --- | --- | --- |
| USD vault | Long |3x|2.95x|$7.301|26.99%|
| USD vault | Long |4x|3.89x|$8.229|17.71%|
| USD vault | Long |5x|4.82x|$8.786|12.14%|
| USD vault | Short |3x|2.92x|$12.209|22.09%|
| USD vault | Short |4x|3.85x|$11.452|14.52%|
| USD vault | Short |5x|4.77x|$10.998|9.98%|
| AVAX vault | Long |3x|2.95x|$8.066|19.34%|
| AVAX vault | Long |4x|3.89x|$8.641|13.59%|
| AVAX vault | Long |5x|4.82x|$9.027|9.73%|
| AVAX vault | Short |3x|2.92x|$13.260|32.60%|
| AVAX vault | Short |4x|3.85x|$11.928|19.28%|
| AVAX vault | Short |5x|4.77x|$11.250|12.50%|

These are snapshot-specific **mock** results, not production liquidation-price
guarantees. AVAX collateral changes value with AVAX: it amplifies losses for longs
and offsets part of the adverse move for shorts. Borrow interest, fees, collateral
NAV, execution costs and production risk weights also affect the threshold.

Run from `contracts/` (RPC reads only):

```sh
CP_FUJI_RPC_URL=https://api.avax-test.network/ext/bc/C/rpc \
FOUNDRY_PROFILE=debt_accounting forge test \
  --match-contract FujiCollateralMarginLiveForkTest \
  --fork-url https://api.avax-test.network/ext/bc/C/rpc \
  --fork-block-number 59336291 --threads 1 -vv \
  --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol
```

Without `CP_FUJI_RPC_URL`, these fork tests explicitly skip; that is not a pass.
The separate50-test Fuji deployment/operator suite also requires `--threads 1`
because its environment-variable fixtures are process-global.

## Disposable wallet

The user approved a disposable local key for capped Fuji test batches. Created:

`0x7Eb84484a3e05F611De42c8954D786100917E726`

`tools/fuji-test-wallet.cjs` creates a cryptographically random wallet and prints
only public metadata. The credential is stored in root
`private-keys/fuji-margin-runner.json`, an existing git-ignored path, with0600 file
and0700 directory permissions. It refuses overwriting an existing wallet,
symlinks, insecure permissions and tracked paths. Four Node tests pass.

The key is **unencrypted local test material**, as explicitly approved. Filesystem
permissions do not protect it from other processes running as the same OS user.
EVM keys are not intrinsically chain-restricted: never send mainnet assets to this
address or grant it ownership/admin roles. The metadata chain ID is not itself a
signing restriction. The separate runner enforces chain43113 and its own limits.
No signing or broadcast command exists in the wallet-creation utility itself.

```sh
node tools/fuji-test-wallet.cjs address
node --test tools/fuji-test-wallet.test.cjs
```

Never print, commit, paste, or pass the private key on a command line. The existing
deployer keystore is unchanged. No key backup or recovery phrase is provided;
this wallet is disposable. Do not rerun `create` to try to rotate it silently.

## Gas funding and next live-test gates

Verified gas allocation: **0.25 test AVAX**, not real AVAX (block59337843,
2026-10-12T11:59:55Z, latest/pending nonce0). This is funding,
not authority for arbitrary transactions. The intended first live batch will be
restricted to12 round trips (3x–5x, both pools/sides), $25 margin per position,
$60 original pToken funding per pool, at most$0.25 fee per action and$2 voluntary
close collateral sale. `tools/fuji-margin-runner.cjs` reserves the entire batch's
worst-case gas cost against a cumulative **0.20 test AVAX** ceiling before signing,
restricts the chain and exact targets, stops on unexpected state or failure,
records receipts, and refuses replay. No public-Fuji runner batch has been executed.

The following gas-only funding command was already completed; **do not repeat it**:

```sh
cast send 0x7Eb84484a3e05F611De42c8954D786100917E726 \
  --value 0.25ether --chain 43113 \
  --rpc-url https://api.avax-test.network/ext/bc/C/rpc \
  --from 0x94696d767e65a75581145646960FA0eC886cE5d2 \
  --account robinhood-deployer
```

Enter the existing keystore password only locally. `ether` here is the CLI's
18-decimal unit; with chain43113 it sends **test AVAX**. No funding was broadcast
by the agent. Check the receipt and destination before proceeding.

Funding alone is insufficient for the live tests:

1. The wallet also needs bounded transfers of existing mock pTokens from the owner:
   300000000000raw USD-vault shares and30000000000raw AVAX-vault shares. No transfer
   is included in the gas command above. Do not sweep the owner's streamed rewards.
2. Existing mock feeds are owner-only and expire after1200seconds. Funding does
   not delegate feed permissions. Fresh $1/$10 updates require the existing owner.
3. Liquidation requires intentionally adverse mock-price updates and explicit
   loss/insurance budgets. Keep those tests local until a separate owner-signed
   lifecycle batch is reviewed, including restoration of the$10 price.
4. Publish/review the runner changes and approve its complete scope once.
   No need to seek approval per transaction
   within that exact scope; stop for new authority or a material change.

Do not transfer feed ownership or any other admin role merely to enable automation.
Do not rerun the first-use smoke scripts on the now-completed position history.

## Fixed-scope runner and owner preparation

`script/PrepareFujiMarginRunner.s.sol` prepares exactly four owner transactions:
transfer300000000000raw existing USD-vault pTokens to the runner, transfer
30000000000raw existing AVAX-vault pTokens, then refresh mockUSD/mockAVAX at the
unchanged$1/$10 values. It refuses already-funded wallets and changed history or
prices, and validates the resulting checkpoint. **Separate owner approval and
local keystore signing are required.** No minting, redemption, admin grant or
owner reward sweep is included. Do this only when the reviewed runner is ready,
because the feeds expire after20minutes.

`script/ExerciseFujiMarginRunner.s.sol` simulates **34 runner transactions**:

- Four market accruals.
- Exact approve/deposit/clear for$60-equivalent USD-vault pTokens.
- Six round trips using$25 margin:3x long/short,4x long/short,5x long/short.
- Exact approve/deposit/clear for$60-equivalent AVAX-vault pTokens.
- The same six round trips for that pool.

There are no withdrawals, feed updates, liquidations, governance actions, native
transfers or direct insurance calls. Each position is fully closed before the
next is opened. Position IDs must be5–16; runner nonces must be0–33. The final
check requires zero account/aggregate debt, no locked shares or deposit approvals,
and at least90% of each original share budget free in the margin vault. Mock-price
stress and insurance-funded liquidation tests remain local-only.

The Node runner first generates a fresh **unsigned** simulation and independently
validates every call, target, sender, nonce, chain, value, amount, leverage, fee cap,
sale cap and route bytes. It never forwards transaction fields from an arbitrary
artifact directly to the signer. Immediately before a trade it refreshes only its
price minimum: the protocol quote for opens,99% of current quoted trade output
for closes. One-hour deadlines originate in that fresh simulation, are not
extended during execution, and must have at least five minutes remaining.
Feeds must remain at$1/$10 and less than15minutes old during the batch.

The initial fee is125% of the RPC gas-price suggestion and stays fixed. Worst-case
gas is reserved for all34 calls using16million gas per open,6million per close,
600000 per deposit,100000 per approval and150000 per accrual. If the total exceeds
0.20 test AVAX or the available balance, **nothing is signed**. No automatic gas
top-up, fee bump or replacement is permitted. These limits may deliberately refuse
a batch during expensive network conditions.

Only `run` reads the existing signing credential, after read-only preflight. It
creates a0600 exclusive journal in the ignored private-keys directory, records
intent before signing and the deterministic transaction hash before submission,
then checks receipt success, canonical block and position state. The journal is
never automatically deleted, reset or reused. No raw signed transaction or key is
logged. A signing/RPC exception is printed generically because provider errors can
contain signed data. `check` does not load the credential or submit transactions:

```sh
node tools/fuji-margin-runner.cjs check
```

After **separate complete-batch approval** and verified owner preparation only:

```sh
CONFIRM_FUJI_RUNNER_BATCH_V1=true node tools/fuji-margin-runner.cjs run
```

These are sequential transactions, **not an atomic batch**. If a close, oracle
check, gas estimate or RPC request fails after an open, a position can remain open.
Stop and reconcile receipts and live state before requesting recovery authority;
do not remove the journal or retry blindly. pTokens remain in margin after success;
any later withdrawal must use fresh balances and separately agreed scope.

## Runner verification

`test/FujiMarginRunnerFork.t.sol` tests owner preparation plus all12 consecutive
round trips on the actual pinned deployment and rejects wrong chain, missing
confirmation, duplicate preparation, stale prices and missing funding. Tests
require the same fork flags above, replacing the match contract with
`FujiMarginRunnerForkTest`; use `--threads 1`.

```sh
node --test tools/fuji-margin-runner.test.cjs tools/fuji-test-wallet.test.cjs
```

The local integration test also validates Foundry's real generated calldata and
the RPC guards, estimates, mined receipts and final state for all34 transactions.
Start a **fresh disposable local** Anvil in one terminal:

```sh
anvil --fork-url https://api.avax-test.network/ext/bc/C/rpc \
  --fork-block-number 59336291 --chain-id 43113 --port 18547 \
  --auto-impersonate --silent
```

Then, from `contracts/`, run:

```sh
FUJI_RUNNER_LOCAL_TEST=true node --test tools/fuji-margin-runner.local.test.cjs
```

It pins127.0.0.1:18547, checks Anvil and the initial block, uses VM-only account
impersonation and never reads the local signing key. Stop the disposable node
afterward. Its Foundry files under ignored `broadcast/` are **local-fork artifacts,
not public-Fuji receipt evidence**. Without opt-in this integration explicitly
skips; that is not a pass.
