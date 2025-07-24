#!/bin/bash

# Navigate to the correct directory
cd "$(dirname "$0")"

# Stop any running replica to ensure a clean start
dfx stop

# Start the local replica in the background
dfx start --clean --background

# Deploy the EVM RPC canister first
dfx deploy evm_rpc

# Build the peridot_monitor canister
cargo build --release --target wasm32-unknown-unknown --package peridot_monitor

# Create the peridot_monitor canister
dfx canister create --with-cycles 10_000_000_000_000 peridot_monitor

# Install the WASM code into the peridot_monitor canister
dfx canister install --wasm target/wasm32-unknown-unknown/release/peridot_monitor.wasm peridot_monitor --argument-file initArgument.did --mode reinstall

# Sleep for 3 seconds to allow the EVM address to be generated
sleep 3

# Display the canister's EVM address
dfx canister call peridot_monitor get_evm_address 