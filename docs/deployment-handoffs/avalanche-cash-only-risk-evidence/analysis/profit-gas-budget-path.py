import sys, collections, statistics as st
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse import parse
rows=parse(sys.argv[1:2])
cells=[r for r in rows if r['_kind']=='CELL']
gap=[r for r in cells if r['mode']=='gap']
path=[r for r in cells if r['mode'].startswith('path')]
def D(r): return r['debt0Usd']*(r['shock']/1e4 if r['dir']=='U' else 1)
print("== profit bp by LI (cells with repaid>0)")
for li in (10500,10800,11000,11500):
    v=[r['profitBp'] for r in gap if r['li']==li and r['repaidUsd']>0]
    print(li, min(v), max(v), len(v))
print("== gas per liquidation (mocked, in-test) min/avg/max")
v=[r['gasMax'] for r in cells if r['txs']>0]; print(min(v), st.mean(v), max(v))
print("== txs per cell/ max rounds on one account by close factor")
for c in (2500,5000,9000):
    v=[r['maxr'] for r in gap if r['close']==c and r['txs']>0]; print(c, 'maxr', max(v), 'median', st.median(v), 'txs max', max(r['txs'] for r in gap if r['close']==c))
print("== liquidator budget (repaid debt units / initial debt units) ; in gap cells with liquidations")
# repaidUnits vs debt0: need debt0 units; compute from debt0Usd/ price? use repaidUsd / D(r) (value at shock)
for d in 'WU':
    for u in (70,90,99):
        v=[r['repaidUsd']/D(r) for r in gap if r['dir']==d and r['util']==u and r['li']==10800 and r['close']==5000 and r['repaidUsd']>0]
        print(d,u,'repaid/debt@shock min %.2f max %.2f'%(min(v),max(v)))
# inventory in debt-asset units relative to initial debt units: need debt0 units; repaidUnits and badUnits+... debt0units = ? derive: for W units=usd; for U units: debt0Usd at pin /pin price -> use repaidUnits vs debt0 via shock: repaidUnits/(debt0Usd*1e12*1e8/avaxPin)
PIN=None
print("== worst budget for the placeholder CFs, per USD 1M of aggregate borrow at pin")
for d,cf in (('W',6000),('U',7500)):
    for u in (99,):
        for sh in sorted({r['shock'] for r in gap if r['dir']==d}):
            r=[x for x in gap if x['dir']==d and x['cf']==cf and x['util']==u and x['shock']==sh and x['li']==10800 and x['close']==5000][0]
            if d=='W': inv=r['repaidUsd']/r['debt0Usd']
            else: inv=r['repaidUsd']/r['debt0Usd']  # USD at shock price of WAVAX needed vs USD at pin
            print(d,cf,u,sh,'repaidUsd/debt0Usd=%.3f bad%%=%.1f short=%d txs=%d maxr=%d'%(inv,100*r['badShock']/D(r),r['short'],r['txs'],r['maxr']))
print("== path summary: bad debt (frac of debt) / backlog / steps for CF, util 99, LI 1.08")
for d in 'WU':
    print('dir',d)
    for cf in sorted({r['cf'] for r in path if r['dir']==d}):
        out=[]
        for r in path:
            if r['dir']==d and r['cf']==cf and r['util']==99 and r['li']==10800:
                out.append((r['mode'], round(100*r['badShock']/ (r['debt0Usd'] if d=='W' else r['debt0Usd']*r['shock']/1e4),1), r['backlogSteps'], r['firstShortStep'], r['steps'], r['residShort'], round(r['peakStepUsd']/r['debt0Usd'],2), round(r['repaidUsd']/r['debt0Usd'],2)))
        print(cf, out)
print("== path LI sens (util99 middle step k1)")
for d in 'WU':
    for cf in (6000,7500,9000):
        for li in (10500,10800,11500):
            for r in path:
                if r['dir']==d and r['cf']==cf and r['util']==99 and r['li']==li and r['mode'].endswith('step1000') and d=='W' or (r['dir']==d and r['cf']==cf and r['util']==99 and r['li']==li and r['mode'].endswith('step2500') and d=='U' and r['mode'].startswith('path-k1')):
                    print(d,cf,li,r['mode'],'bad%%=%.1f'%(100*r['badShock']/(r['debt0Usd'] if d=='W' else r['debt0Usd']*r['shock']/1e4)))
