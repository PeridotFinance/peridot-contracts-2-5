#!/bin/bash

while true; do
  echo "Running LiquidationBot script..."
  forge script script/LiquidationBot.s.sol --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
  echo "Run finished. Waiting 30 seconds..."
  sleep 30
done 