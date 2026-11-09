#!/usr/bin/env bash
# Regenerates patches/*.patch: the diff between each ORIGINAL engine file in contracts/contracts/margin (never modified) and its range-aware copy in
# src/engine, with the copy's import paths mapped back to the originals' relative form. `git apply --check` against the originals must pass:
#   cd <repo root> && git apply --check contracts/range-tp/patches/<name>.patch
set -eu
cd "$(dirname "$0")/.."
ROOT=$(git rev-parse --show-toplevel)
mkdir -p patches
tmp=$(mktemp -d)
for f in IsolatedMarginExecutorUpgradeable IsolatedMarginRiskEngineUpgradeable IsolatedMarginLiquidatorUpgradeable; do
  sed -E -e 's#"@peridot/PTokenInterfaces.sol"#"../PTokenInterfaces.sol"#' -e 's#"@peridot/PErc20.sol"#"../PErc20.sol"#' -e 's#"@peridot/margin/#"./#' src/engine/$f.sol > "$tmp/$f.sol"
  (cd "$ROOT" && diff -u --label a/contracts/contracts/margin/$f.sol --label b/contracts/contracts/margin/$f.sol contracts/contracts/margin/$f.sol "$tmp/$f.sol" || true) > patches/$f.patch
done
f=AvalancheMarginCloseAdapter
sed -E -e 's#"@peridot/PTokenInterfaces.sol"#"../../PTokenInterfaces.sol"#' -e 's#"@peridot/margin/IsolatedMarginTypes.sol"#"../IsolatedMarginTypes.sol"#' -e 's#"@peridot/margin/orders/#"./#' src/engine/$f.sol > "$tmp/$f.sol"
(cd "$ROOT" && diff -u --label a/contracts/contracts/margin/orders/$f.sol --label b/contracts/contracts/margin/orders/$f.sol contracts/contracts/margin/orders/$f.sol "$tmp/$f.sol" || true) > patches/$f.patch
rm -rf "$tmp"
wc -l patches/*.patch
