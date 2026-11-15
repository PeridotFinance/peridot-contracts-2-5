import sys
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parse import parse
rows=parse(sys.argv[1:2])
for r in rows:
    if r['_kind']=='EXIT': print({k:r[k] for k in r if k not in('_kind',)})
print()
for r in rows:
    if r['_kind'] in ('RESFIRST','EQV','GAS'): print(r)
print()
for r in rows:
    if r['_kind']=='ACCR': print(r)
print()
for r in rows:
    if r['_kind']=='IRM' and r['rfBp']==1000: print(r)
