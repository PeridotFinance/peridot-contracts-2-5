import json,sys,os,hashlib
src=sys.argv[1]; name=sys.argv[2]; out=sys.argv[3]
d=json.load(open(src))
r=d['result'][0]
meta={k:v for k,v in r.items() if k!='SourceCode'}
sc=r['SourceCode']
os.makedirs(out,exist_ok=True)
if sc.startswith('{{'):
    j=json.loads(sc[1:-1]); files=j['sources']; settings=j.get('settings')
elif sc.startswith('{'):
    j=json.loads(sc); files=j.get('sources',j); settings=j.get('settings')
else:
    files={r['ContractName']+'.sol':{'content':sc}}; settings=None
print(name, json.dumps(meta)[:900])
if settings: print('settings',json.dumps(settings)[:400])
for p,c in files.items():
    fp=os.path.join(out,p.lstrip('/'))
    os.makedirs(os.path.dirname(fp),exist_ok=True)
    open(fp,'w').write(c['content'])
    print(hashlib.sha256(c['content'].encode()).hexdigest()[:16], len(c['content'].splitlines()), p)
json.dump(meta,open(out+'/_meta.json','w'),indent=1)
