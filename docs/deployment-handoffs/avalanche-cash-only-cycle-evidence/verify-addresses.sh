#!/bin/bash
# Independent on-chain verification of every venue address at the pin (block 99,200,000) with cast. Read-only, no keys.
R=https://api.avax.network/ext/bc/C/rpc; B=99200000
W=0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7; U=0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E
c(){ cast call --rpc-url $R --block $B "$@" 2>&1 | head -4 | tr '\n' ' '; echo; sleep 0.25; }
cs(){ echo -n "codesize $1 = "; cast codesize --rpc-url $R --block $B $1 2>&1 | tail -1; sleep 0.25; }
echo "# tokens"; cs $W; cs $U
echo "# routers -> factory pointers"
for r in 0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE 0x8E4638eefee96732C56291fBF48bBB98725c6b31 0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506 0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106 0x60aE616a2155Ee3d9A68541Ba4544862310933d4; do
  cs $r; echo -n " factory(): "; c $r "factory()(address)"; echo -n " WETH9()/WAVAX()/WETH(): "; c $r "WETH9()(address)"; c $r "WAVAX()(address)"; c $r "WETH()(address)"; done
cs 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c; echo -n " Pharaoh router WETH9(): "; c 0xc8B8fCbDb5C019D7802fFb0b39603395D7d3915c "WETH9()(address)"
LB=0x18556DA13313f3532c54711497A8FedAC273220E; cs $LB
for f in getFactory getV1Factory getLegacyFactory getFactoryV2_1 getWNATIVE; do echo -n " LBRouter.$f(): "; c $LB "$f()(address)"; done
echo "# factory lookups"
echo "Uniswap V3 factory getPool:"; for f in 100 500 3000 10000; do c 0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD "getPool(address,address,uint24)(address)" $W $U $f; done
echo "Sushi V3 factory getPool:"; for f in 100 500 3000 10000; do c 0x3e603C14aF37EBdaD31709C4f848Fc6aD5BEc715 "getPool(address,address,uint24)(address)" $W $U $f; done
echo "Pharaoh CL factory getPool (ts 1,5,10,50,100,200,2000):"; for t in 1 5 10 50 100 200 2000; do c 0xAE6E5c62328ade73ceefD42228528b70c8157D0d "getPool(address,address,int24)(address)" $W $U $t; done
echo "V2 factories getPair: UniV2, Pangolin, Sushi V2, LFJ V1:"
c 0x9e5A52f57b3038F1B8EeE45F28b3C1967e22799C "getPair(address,address)(address)" $W $U
c 0xefa94DE7a4656D787667C749f7E1223D71E9FD88 "getPair(address,address)(address)" $W $U
c 0xc35DADB65012eC5796536bD9864eD8773aBc74C4 "getPair(address,address)(address)" $W $U
c 0x9Ad6C38BE94206cA50bb0d90783181662f0Cfa10 "getPair(address,address)(address)" $W $U
echo "LFJ LB factories getAllLBPairs (V2.2, V2.1, V2.0):"
for f in 0xb43120c4745967fa9b93E79C149E66B0f2D6Fe0c 0x8e42f2F4101563bF679975178e880FD87d3eFd4e 0x6E77932A92582f504FF6c4BdbCef7Da6c198aEEf; do cs $f; c $f "getAllLBPairs(address,address)((uint16,address,bool,bool)[])" $W $U; done
echo "# pools: token0/token1/fee/liquidity/slot0 (V3-style)"
for p in 0x1951BD56E82cC1eDFEc8546c3202eCBcC5B74A29 0xfAe3f424a0a47706811521E3ee268f00cFb5c45E 0x0E663593657B064e1baE76d28625Df5D0eBd4421 0xd18384F4398BF5415902aD5d87eAA96549Fd4f1E 0x0bA96F2F9E56BBB75e5bb0Bd951B07adea3D2072 0x4A5c0E100F830A1F6B76A42e6bb4Be2A7fE0d61B 0xD937a05dF90918f584A17a168026cc06f9cB099D 0x8EAf84001447da898054D06EdF6e4Ebc010f33a1 0xf01449C0bA930B6e2CaCA3DEF3CCBd7a3E589534 0x1Abbf74e863e19940ED364C6EE1Ffb782e204d20 0xb1E1Db50a98D49eC8eA9a1CCBBD4Af56842C43c1 0x2eB24B12177B7DF1c85fAC74d06675cbEadeD3d7; do
 echo "pool $p"; cs $p; echo -n " token0 "; c $p "token0()(address)"; echo -n " token1 "; c $p "token1()(address)"; echo -n " fee "; c $p "fee()(uint24)"; echo -n " liquidity "; c $p "liquidity()(uint128)"; echo -n " tickSpacing "; c $p "tickSpacing()(int24)"; done
echo "# LB pairs: tokenX/tokenY/binStep/activeId/total reserves"
for p in 0x864d4e5Ee7318e97483DB7EB0912E09F161516EA 0xE52BeDE8CFd7C5C8894c8616E49Fb25811c97367 0x411E7f9e9F0584804bA23DF1182c28d28df0d69C 0xE4379C25faaB825cF19cDd57b52187BDcF056729 0x55a50aDBa067530b96d30225f9de86640431e86f 0xD446eb1660F766d533BeCeEf890Df7A69d26f7d1 0xe3a7045112cA6Bcc7f9A80B61c3fBA6EaD3d7124 0x79925795dF91424DB1d7d427859FFF709d731c8e 0x75577CA07649B4824A0B24e78d5b8CeA54243699; do
 echo "pair $p"; echo -n " X "; c $p "getTokenX()(address)"; echo -n " Y "; c $p "getTokenY()(address)"; echo -n " binStep "; c $p "getBinStep()(uint16)"; echo -n " activeId "; c $p "getActiveId()(uint24)"; echo -n " reserves(X,Y) "; c $p "getReserves()(uint128,uint128)"; done
echo "# V2-style pairs: token0/token1/factory()/reserves"
for p in 0x6239aE4D661379b71A90c4c79f0a95297342e391 0x0e0100Ab771E9288e0Aa97e11557E6654C3a9665 0x6539bF462F73fF9497054bA261C195DA8639ED61 0xf4003F4efBE8691B60249E6afbD307aBE7758adb; do
 echo "pair $p"; echo -n " token0 "; c $p "token0()(address)"; echo -n " token1 "; c $p "token1()(address)"; echo -n " factory "; c $p "factory()(address)"; echo -n " reserves "; c $p "getReserves()(uint112,uint112,uint32)"; done
echo "# Uniswap V4 PoolManager 0x06380C0e0912312B5150364B9DC4542BA0DbBc85 (from Uniswap/contracts deployments/43114.md): pool (WAVAX,USDC,fee 500,ts 10,no hooks) liquidity slot via extsload"
python3 - <<'PY'
import subprocess
W="0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7";U="0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E"
PM="0x06380C0e0912312B5150364B9DC4542BA0DbBc85";R="https://api.avax.network/ext/bc/C/rpc"
sh=lambda *a: subprocess.run(a,capture_output=True,text=True).stdout.strip()
for fee,ts in [(100,1),(500,10),(3000,60),(10000,200)]:
    pid=sh("cast","keccak",sh("cast","abi-encode","f(address,address,uint24,int24,address)",W,U,str(fee),str(ts),"0x"+"00"*20))
    slot=sh("cast","keccak",sh("cast","abi-encode","f(bytes32,uint256)",pid,"6"))
    v=int(sh("cast","call","--rpc-url",R,"--block","99200000",PM,"extsload(bytes32)(bytes32)",slot),16)
    if v==0: print(fee,ts,"not initialised"); continue
    sq=v&((1<<160)-1); l=int(sh("cast","call","--rpc-url",R,"--block","99200000",PM,"extsload(bytes32)(bytes32)","0x%064x"%(int(slot,16)+3)),16)
    print(fee,ts,"poolId",pid,"sqrtPriceX96",sq,"price USD/AVAX",(sq/2**96)**2*1e12,"liquidity",l,"virtual USDC in range",l*sq/2**96/1e6)
PY
