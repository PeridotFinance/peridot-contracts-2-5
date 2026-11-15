#!/bin/bash
# usage: run-attempt.sh <logname> <forge test args...>   (writes UTC/HEAD/command header + full output + exit code into this directory)
cd /Users/joshua/Peridot/peridot-contracts-2-5/contracts
EV=/Users/joshua/Peridot/peridot-contracts-2-5/docs/deployment-handoffs/avalanche-cash-only-cycle-evidence
LOG=$EV/$1; shift
ARGS=$(printf "%q " "$@")
RPC=https://api.avax.network/ext/bc/C/rpc
CMD="AVALANCHE_MAINNET_RPC_URL=$RPC FOUNDRY_PROFILE=debt_accounting FOUNDRY_OUT=out_cycle FOUNDRY_CACHE_PATH=cache_cycle forge test --threads 1 --gas-limit 9000000000000000000 $ARGS --rpc-url $RPC --compute-units-per-second 20 --fork-retries 10 --fork-retry-backoff 1000 --skip P_OFTAdapter.sol --skip P_OFTAdapterUpgradeable.sol --skip P_OFTAdapterUpgradeable.t.sol --skip AvalancheBorrowFloorMarginFork.t.sol"
{ echo "# UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "# git HEAD: $(git rev-parse HEAD)"; echo "# command: $CMD"; echo "# ---"; } > "$LOG"
eval "$CMD" >> "$LOG" 2>&1
echo "exit=$?" >> "$LOG"
echo "# end UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
