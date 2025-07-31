#!/bin/bash

# Configuration
# These are the known market addresses from your LiquidationBot.s.sol
PUSDC_ADDRESS="0xA72b43Bd60E5a9a13B99d0bDbEd36a9041269246"
PUSDT_ADDRESS="0xa568bD70068A940910d04117c36Ab1A0225FD140"

# IMPORTANT: Set your RPC_URL environment variable
if [ -z "$RPC_URL" ]; then
  echo "Error: RPC_URL environment variable is not set."
  echo "Please set it e.g. export RPC_URL=https://your_rpc_provider_url"
  exit 1
fi

# IMPORTANT: For best results, set this to the block number when your protocol was deployed.
START_BLOCK=${START_BLOCK:-0}

echo "Using RPC_URL: $RPC_URL"
echo "Searching from block: $START_BLOCK"

# Basic PToken events that contain user addresses
# event Mint(address minter, uint mintAmount, uint mintTokens);
# event Borrow(address borrower, uint borrowAmount, uint accountBorrows, uint totalBorrows);
# event Redeem(address redeemer, uint redeemAmount, uint redeemTokens);
# event RepayBorrow(address payer, address borrower, uint repayAmount, uint accountBorrows, uint totalBorrows);

MINT_EVENT="0x4c209b5fc8ad50758f13e2e1088ba56a560dff690a1c6fef26394f4c03821c4f"
BORROW_EVENT="0x13ed6866d4e1ee6da46f845c46d7e6c4ffba00dc3fc6a6c7e0b87f1b0e9b1c9c"
REDEEM_EVENT="0xe5b754fb1abb7f01b499791d0b820ae3b6af3424ac1c59768edb53f4ec31a929"
REPAY_EVENT="0x1a2a22cb034d26d1854bdc6666a5b91fe25efbbb5dcad3b0355478d6f5c362a1"

# Temporary file to store all unique addresses
TEMP_ADDRESSES=$(mktemp)

# Function to fetch events from a contract
fetch_events_from_contract() {
    local contract_address=$1
    local contract_name=$2
    
    echo "Fetching events from $contract_name ($contract_address)..."
    
    # Try to fetch each event type, but don't fail if one doesn't exist
    for event_topic in $MINT_EVENT $BORROW_EVENT $REDEEM_EVENT $REPAY_EVENT; do
        echo "  Fetching event topic: $event_topic"
        cast logs --from-block "$START_BLOCK" --rpc-url "$RPC_URL" --address "$contract_address" "$event_topic" 2>/dev/null | \
        awk '{if (NF >= 4) print "0x" substr($4, 27)}' >> "$TEMP_ADDRESSES" || true
    done
}

# Fetch events from known markets
fetch_events_from_contract "$PUSDC_ADDRESS" "pUSDC"
fetch_events_from_contract "$PUSDT_ADDRESS" "pUSDT"

# Also try to get accounts from any liquidation events on these markets
# event LiquidateBorrow(address liquidator, address borrower, uint repayAmount, address pTokenCollateral, uint seizeTokens);
LIQUIDATE_EVENT="0x298637f684da70674f26509b10f07ec2fbc77a335ab1e7d6215a4b2484d8bb52"

echo "Fetching liquidation events..."
for market in "$PUSDC_ADDRESS" "$PUSDT_ADDRESS"; do
    cast logs --from-block "$START_BLOCK" --rpc-url "$RPC_URL" --address "$market" "$LIQUIDATE_EVENT" 2>/dev/null | \
    awk '{if (NF >= 5) {print "0x" substr($4, 27); print "0x" substr($5, 27)}}' >> "$TEMP_ADDRESSES" || true
done

# Remove duplicates and save to accounts.txt
sort -u "$TEMP_ADDRESSES" | grep -E "^0x[0-9a-fA-F]{40}$" > accounts.txt

# Cleanup
rm "$TEMP_ADDRESSES"

# Show results
ACCOUNT_COUNT=$(wc -l < accounts.txt)
echo "Done. Found $ACCOUNT_COUNT unique accounts."

if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    echo "Warning: No accounts found. This could mean:"
    echo "1. The protocol has no activity yet"
    echo "2. The event topics are incorrect"
    echo "3. The contract addresses are wrong"
    echo "4. The RPC endpoint is having issues"
    echo ""
    echo "Adding a placeholder address to accounts.txt so the bot doesn't crash."
    echo "0x0000000000000000000000000000000000000000" > accounts.txt
else
    echo "The list of accounts has been saved to accounts.txt"
    echo "First 5 accounts:"
    head -5 accounts.txt
fi 