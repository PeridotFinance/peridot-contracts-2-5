import sys
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse import parse
rows=parse(sys.argv[1:2])
gap=[r for r in rows if r['_kind']=='CELL' and r['mode']=='gap']
def frac(r):
    if r['repaidUnits']==0: return 0
    if r['dir']=='W': d0=r['debt0Usd']
    else:
        ps=r['repaidUsd']*1e20/r['repaidUnits']; pin=ps/(r['shock']/1e4); d0=r['debt0Usd']*1e20/pin
    return r['repaidUnits']/d0
for d in 'WU':
    shocks=sorted({r['shock'] for r in gap if r['dir']==d}, reverse=(d=='W'))
    print('dir',d,'inventory as fraction of INITIAL debt (debt-asset units), util 99, LI 1.08, close .5')
    for cf in (3000,4000,5000,6000,7000,7500,8000,9000):
        out=[]
        for sh in shocks:
            q=[r for r in gap if r['dir']==d and r['cf']==cf and r['util']==99 and r['li']==10800 and r['close']==5000 and r['shock']==sh]
            if q: out.append('%d:%.2f/%dtx'%(sh,frac(q[0]),q[0]['txs']))
        print(cf,' '.join(out))
    # all cells
    allv=[(frac(r),r) for r in gap if r['dir']==d]
    print('max over grid', max(v for v,_ in allv))
    # first-round only budget = close factor? check minimal txs
print('close factor effect on txs (W cf60 util99 shock5000 li1.08)')
for c in (2500,5000,9000):
    r=[r for r in gap if r['dir']=='W' and r['cf']==6000 and r['util']==99 and r['shock']==5000 and r['li']==10800 and r['close']==c][0]
    print(c,r['txs'],r['maxr'],r['badShock'],r['repaidUsd'])
for c in (2500,5000,9000):
    r=[r for r in gap if r['dir']=='W' and r['cf']==5000 and r['util']==99 and r['shock']==6000 and r['li']==10800 and r['close']==c][0]
    print('safe case',c,r['txs'],r['maxr'],r['badShock'],r['repaidUsd'])
# gas total = txs*avg
print('worst txs per cell', max(r['txs'] for r in gap), 'max rounds', max(r['maxr'] for r in gap))
