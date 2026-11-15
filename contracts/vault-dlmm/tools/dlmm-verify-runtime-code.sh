#!/usr/bin/env bash
# READ-ONLY: proves that the code on chain IS the build output. For the implementation, its validator (CREATE(implementation, 1)), the proxy and the ProxyAdmin
# it fetches the runtime code (eth_getCode) and compares it byte for byte with `out/<Contract>.json` deployedBytecode, masking only the IMMUTABLE slots the compiler
# lists (immutableReferences), and prints the immutable values so they can be read: the implementation's DEPOSIT_CAP_CEILING (200000000) and VALIDATOR
# (= CREATE(implementation, 1)), the proxy's admin (= CREATE(proxy, 1)).
#   usage: tools/dlmm-verify-runtime-code.sh <vault proxy>       needs: forge build done in this folder (out/), cast, node >= 18, ETH_RPC_URL (environment only)
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?vault proxy}"; : "${ETH_RPC_URL:?ETH_RPC_URL must be set in the environment (read-only)}"
IMPL="$(cast implementation "$V")"; ADMIN="$(cast admin "$V")"
VALIDATOR="$(cast compute-address "$IMPL" --nonce 1 | awk '{print $NF}')"
PADMIN_CHECK="$(cast compute-address "$V" --nonce 1 | awk '{print $NF}')"
echo "proxy $V   implementation $IMPL   validator(CREATE(impl,1)) $VALIDATOR   ProxyAdmin $ADMIN (CREATE(proxy,1) = $PADMIN_CHECK)"
[ "$(echo "$ADMIN" | tr A-Z a-z)" = "$(echo "$PADMIN_CHECK" | tr A-Z a-z)" ] || { echo "the ProxyAdmin is not CREATE(proxy, 1)" >&2; exit 1; }
check() { # name artifact-dir address expected-immutable-word-or-empty
  local code; code="$(cast code "$3")"
  node -e '
const fs=require("fs");const [name,art,code,imm]=process.argv.slice(1);
const j=JSON.parse(fs.readFileSync(`out/${art}.sol/${name}.json`,"utf8"));
const want=j.deployedBytecode.object.replace(/^0x/,"").toLowerCase();const got=code.replace(/^0x/,"").toLowerCase();
if(want.length!==got.length){console.log(`${name}: LENGTH DIFFERS build ${want.length/2} bytes, chain ${got.length/2} bytes`);process.exit(1);}
const refs=Object.values(j.deployedBytecode.immutableReferences||{}).flat();
const masked=new Array(want.length).fill(false);const vals=[];
for(const r of refs){for(let i=0;i<r.length*2;i++)masked[r.start*2+i]=true;vals.push(got.slice(r.start*2,(r.start+r.length)*2));}
for(let i=0;i<want.length;i++){if(!masked[i]&&want[i]!==got[i]){console.log(`${name}: MISMATCH at byte ${Math.floor(i/2)}`);process.exit(1);}}
console.log(`${name}: runtime code equals the build output (${got.length/2} bytes; ${refs.length} immutable slot(s) masked: ${[...new Set(vals)].map(v=>"0x"+v.replace(/^0+/,"")).join(", ")||"none"})`);
' "$1" "$2" "$code"
}
check PharaohDlmmVault PharaohDlmmVault "$IMPL"
check PharaohDlmmPairValidator PharaohDlmmPairValidator "$VALIDATOR"
check TransparentUpgradeableProxy TransparentUpgradeableProxy "$V"
check ProxyAdmin ProxyAdmin "$ADMIN"
echo "expected immutables: implementation 0xbebc200 (=200000000, leading zeros stripped) and the validator address $(echo "$VALIDATOR" | tr A-Z a-z | sed 's/^0x//'); proxy: the ProxyAdmin address $(echo "$ADMIN" | tr A-Z a-z | sed 's/^0x//')"
