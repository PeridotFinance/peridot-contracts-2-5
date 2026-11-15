#!/usr/bin/env bash
# Storage layout check for the R3 upgrade: the R3 base and the R3 extension must have EXACTLY the storage layout of the deployed ones (nothing added,
# removed, retyped or moved; the existing proxies keep their storage). Compares `forge inspect <contract> storage-layout` of the original (byte-identical
# to the deployed code, see tools/check-reproduction.sh) with the R3 contract (AST ids in type names are ignored). Exit 1 on any difference.
# Also prints the runtime sizes against the EIP-170 limit.
set -euo pipefail
cd "$(dirname "$0")/.."
forge build >/dev/null 2>&1
NORM='import json,re,sys
d=json.load(sys.stdin)
for s in d["storage"]:
    print(s["label"], s["slot"], s["offset"], re.sub(r"\)\d+", ")", s["type"]))'
fail=0
for pair in "src/orig/PharaohLiquidityVault.sol:PharaohLiquidityVault src/r3/PharaohLiquidityVaultR3.sol:PharaohLiquidityVaultR3" "src/orig/PharaohRewardExtension.sol:PharaohRewardExtension src/r3/PharaohRewardExtensionR3.sol:PharaohRewardExtensionR3"; do
  set -- $pair
  a=$(forge inspect "$1" storage-layout --json 2>/dev/null | python3 -c "$NORM"); b=$(forge inspect "$2" storage-layout --json 2>/dev/null | python3 -c "$NORM")
  n=$(printf '%s\n' "$a" | grep -c . || true)
  if [ "$a" = "$b" ]; then echo "layout identical: $1 == $2 ($n linear slots)"; else echo "LAYOUT DIFFERS: $1 vs $2"; diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") || true; fail=1; fi
done
for c in PharaohLiquidityVault PharaohLiquidityVaultR3 PharaohRewardExtension PharaohRewardExtensionR3; do
  f="out/$c.sol/$c.json"
  python3 - "$f" "$c" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); o=j["deployedBytecode"]["object"]; print("runtime size %-28s %d bytes (limit 24576)" % (sys.argv[2], (len(o)-2)//2))
PY
done
exit $fail
