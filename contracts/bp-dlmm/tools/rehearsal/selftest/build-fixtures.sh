#!/usr/bin/env bash
# Compiles Fixtures.sol into <out-dir> with a throwaway forge project (solc 0.8.35 from the local svm cache; no network needed once cached).
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="${1:?usage: build-fixtures.sh <out-dir>}"; mkdir -p "$OUT"
T="$(mktemp -d "${TMPDIR:-/tmp}/bp-fixtures.XXXXXX")"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src"; cp "$HERE/Fixtures.sol" "$T/src/"
printf '[profile.default]\nsrc="src"\nout="out"\nsolc_version="0.8.35"\nevm_version="cancun"\noffline=true\n' > "$T/foundry.toml"
( cd "$T" && forge build >/dev/null 2>&1 || forge build 2>&1 | tail -5 )
[ -f "$T/out/Fixtures.sol/Thrower.json" ] || { echo "fixture build failed"; exit 1; }
rm -rf "$OUT/Fixtures.sol"; cp -R "$T/out/Fixtures.sol" "$OUT/"
echo "fixtures built in $OUT"
