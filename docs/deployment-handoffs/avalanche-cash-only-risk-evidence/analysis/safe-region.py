import sys, collections
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse import parse
rows=parse(sys.argv[1:2])
cells=[r for r in rows if r['_kind']=='CELL']
gap=[r for r in cells if r['mode']=='gap']
print(len(gap), 'gap cells', len([r for r in cells if r['mode'].startswith('path')]), 'path cells')
TOL=50000  # 5 cents absolute (3 borrowers)
# safe map at LI 10800 close 5000
def D(r): return r['debt0Usd']*(r['shock']/1e4 if r['dir']=='U' else 1)
for d in 'WU':
    print('=== dir',d,'LI 1.08 close .5: max tested CF with bad debt <=5c, by util x shock')
    shocks=sorted({r['shock'] for r in gap if r['dir']==d}, reverse=(d=='W'))
    for u in (70,90,99):
        line=[]
        for sh in shocks:
            ok=[r['cf'] for r in gap if r['dir']==d and r['li']==10800 and r['close']==5000 and r['util']==u and r['shock']==sh and r['badShock']<=TOL]
            line.append(f"{sh}:{max(ok) if ok else 'none'}")
        print('util',u,' '.join(line))
# LI sensitivity at util 99
for d in 'WU':
  for li in (10500,10800,11000,11500):
    shocks=sorted({r['shock'] for r in gap if r['dir']==d}, reverse=(d=='W'))
    line=[]
    for sh in shocks:
        ok=[r['cf'] for r in gap if r['dir']==d and r['li']==li and r['close']==5000 and r['util']==99 and r['shock']==sh and r['badShock']<=TOL]
        line.append(f"{sh}:{max(ok) if ok else 'none'}")
    print(d,'LI',li,'util99',' '.join(line))
# bad fraction at CF60W / CF75U
for d,cf in (('W',6000),('U',7500),('W',5000),('U',5000)):
    for u in (70,90,99):
        print(d,cf,u,[ (r['shock'], round(100*r['badShock']/D(r),1)) for r in sorted(gap,key=lambda r:r['shock']) if r['dir']==d and r['cf']==cf and r['util']==u and r['li']==10800 and r['close']==5000])
