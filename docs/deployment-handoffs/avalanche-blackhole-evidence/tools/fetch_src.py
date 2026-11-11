import sys,json,urllib.request,os
addr=sys.argv[1]; out=sys.argv[2]
u=f"https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api?module=contract&action=getsourcecode&address={addr}"
d=json.load(urllib.request.urlopen(u,timeout=40))
r=d['result'][0]
os.makedirs(out,exist_ok=True)
sc=r.get('SourceCode','')
print(r.get('ContractName'),r.get('CompilerVersion'),len(sc),'proxy',r.get('Proxy'),r.get('Implementation'))
if sc.startswith('{{'): sc=sc[1:-1]
try:
  j=json.loads(sc); srcs=j.get('sources',j)
  for k,v in srcs.items():
    p=os.path.join(out,k.lstrip('/')); os.makedirs(os.path.dirname(p),exist_ok=True); open(p,'w').write(v['content'])
  print(len(srcs),'files')
except Exception as e:
  open(os.path.join(out,(r.get('ContractName') or 'c')+'.sol'),'w').write(sc); print('single',e)
