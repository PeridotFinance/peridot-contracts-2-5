#!/usr/bin/env bash
# Thin wrapper: counts RPC calls and reads the endpoint ONLY from the environment (AVALANCHE_RPC). Never prints it.
# usage: rpc.sh <cast subcommand args...>   e.g. rpc.sh call <addr> "fn()(type)" [--block N]
CNT="${RPC_COUNT_FILE:-/tmp/bh_rpc_count}"
echo 1 >> "$CNT"
cast "$@" --rpc-url "$AVALANCHE_RPC"
