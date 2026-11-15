# Reference model (exact rationals) of the proposed "period exposure ledger". Not Solidity. Used only to fix the numbers
# of the named tests and to check conservation on random event sequences.
from fractions import Fraction as F
import random

class Gauge:
    def __init__(s): s.S={}; s.f={}; s.claimed={}; s.broken=False
    def owed(s,p): return s.S.get(p,0)*s.f.get(p,F(0))
    def earned(s,p): return s.owed(p)-s.claimed.get(p,0)
    def claim(s,cur):
        if s.broken: raise RuntimeError('claim reverts')
        tot=0
        for p in range(0,cur+1):
            e=s.earned(p)
            if e: s.claimed[p]=s.claimed.get(p,0)+e; tot+=e; s.paid_by_p[p]=s.paid_by_p.get(p,0)+e
        return tot
    paid_by_p={}

class Vault:
    def __init__(s,g):
        s.g=g; s.cur=0; s.bal={}; s.supply=F(0)
        s.Trec={}; s.Tt={}; s.J={}; s.Z={}; s.W={}
        s.lastP={}; s.jPaid={}
        s.funded={}; s.finalThrough=-1; s.avail=F(0); s.paid={}; s.paidTot=F(0); s.waived={}
    # --- interval recording (claim independent)
    def record(s):
        for p in range(0,s.cur+1):
            T=s.g.f.get(p,F(0)); d=T-s.Trec.get(p,F(0)); s.Trec[p]=T
            if d>0:
                s.Tt[p]=s.Tt.get(p,0)+d
                if s.supply>0: s.J[p]=s.J.get(p,0)+d/s.supply
                else: s.Z[p]=s.Z.get(p,0)+d
    def settle(s,h):
        b=s.bal.get(h,F(0)); lp=s.lastP.get(h,s.cur)
        for p in range(lp,s.cur+1):
            js=s.jPaid.get(h,F(0)) if p==lp else F(0)
            je=s.J.get(p,F(0))
            if b>0: s.W[(h,p)]=s.W.get((h,p),0)+b*(je-js)
        s.lastP[h]=s.cur; s.jPaid[h]=s.J.get(s.cur,F(0))
    def change(s,h_from,h_to,n):
        s.record()
        for h in (h_from,h_to):
            if h: s.settle(h)
        if h_from: s.bal[h_from]-=n
        else: s.supply+=n
        if h_to: s.bal[h_to]=s.bal.get(h_to,F(0))+n
        else: s.supply-=n
        # account touched first time: start at current index
        for h in (h_from,h_to):
            if h: s.lastP[h]=s.cur; s.jPaid[h]=s.J.get(s.cur,F(0))
    def deposit(s,h,n): s.change(None,h,F(n))
    def redeem(s,h,n): s.change(h,None,F(n))
    def transfer(s,a,b,n): s.change(a,b,F(n))
    # --- funding (separate from attribution)
    def harvest(s):
        s.record()
        try:
            before={p:s.g.earned(p) for p in range(0,s.cur+1)}
            got=s.g.claim(s.cur)
        except RuntimeError:
            return False
        for p,e in before.items(): s.funded[p]=s.funded.get(p,0)+e
        s.avail+=got; s.finalThrough=s.cur-1
        return True
    def advance(s): s.record(); s.cur+=1
    def final(s,p): return p<=s.finalThrough and p<s.cur
    def entitlement(s,h,p):
        if not s.final(p): return None
        Tt=s.Tt.get(p,0)
        return F(0) if Tt==0 else s.funded.get(p,0)*s.W.get((h,p),0)/Tt
    def bucket(s,p):
        Tt=s.Tt.get(p,0)
        return F(0) if Tt==0 else s.funded.get(p,0)*s.Z.get(p,0)/Tt
    def claim(s,h):
        s.record(); s.settle(h)
        tot=F(0)
        for p in range(0,s.cur):
            if s.final(p):
                e=s.entitlement(h,p); due=e-s.paid.get((h,p),0)
                if due>0: s.paid[(h,p)]=e; tot+=due
        assert tot<=s.avail; s.avail-=tot; s.paidTot+=tot
        return tot

def scenario_10_90(order):
    g=Gauge(); v=Vault(g); g.S[0]=F(100)
    v.deposit('A',1000)
    g.f[0]=F(1,10)                      # 10 units accrue while A is alone
    if order=='claim_before_B': v.harvest()
    v.deposit('B',1000)
    g.f[0]=F(1)                         # 90 more units
    if order=='claim_after_B_at_end': pass
    v.advance(); v.harvest()
    return v.claim('A'),v.claim('B'),v.bucket(0)

def scenario_late_S():
    g=Gauge(); v=Vault(g); g.S[0]=F(0)
    v.deposit('A',1000); g.f[0]=F(1,10); v.deposit('B',1000); g.f[0]=F(1)
    g.S[0]=F(100)                       # the whole period's emission is notified at the end of the period
    v.advance(); v.harvest(); return v.claim('A'),v.claim('B')

def scenario_both_fail():
    g=Gauge(); v=Vault(g); g.S[0]=F(100); g.broken=True
    v.deposit('A',1000); g.f[0]=F(1,10)
    v.deposit('B',1000)                  # entry while the reward claim reverts
    g.f[0]=F(6,10)
    v.redeem('A',1000)                   # A exits (whole position share) while the claim reverts
    g.f[0]=F(1)
    v.advance()
    assert not v.harvest()               # still failing at period end
    assert v.entitlement('A',0) is None  # quarantined: recorded, not yet payable
    g.broken=False
    assert v.harvest()
    return v.claim('A'),v.claim('B'),v.bucket(0)

def scenario_zero_supply():
    g=Gauge(); v=Vault(g); g.S[0]=F(100)
    g.f[0]=F(2,10)                       # liquidity exists, nobody holds shares (donated idle assets deployed)
    v.deposit('C',500)                   # first depositor after the empty period
    g.f[0]=F(1)
    v.advance(); v.harvest()
    return v.claim('C'),v.bucket(0)

def scenario_last_holder_then_new():
    g=Gauge(); v=Vault(g); g.S[0]=F(100)
    v.deposit('A',100); g.f[0]=F(3,10); v.redeem('A',100)
    g.f[0]=F(3,10)  # nothing accrues while supply is 0 and liquidity is gone
    v.deposit('D',100); g.f[0]=F(1)
    v.advance(); v.harvest(); return v.claim('A'),v.claim('D'),v.bucket(0)

def scenario_transfer():
    g=Gauge(); v=Vault(g); g.S[0]=F(100)
    v.deposit('A',1000); g.f[0]=F(4,10); v.transfer('A','B',500); g.f[0]=F(1)
    v.advance(); v.harvest(); return v.claim('A'),v.claim('B'),v.bucket(0)

def scenario_exited_claims_later_and_no_orphan():
    g=Gauge(); v=Vault(g); g.S[0]=F(100)
    v.deposit('A',100); g.f[0]=F(1,2); v.deposit('B',100); g.f[0]=F(1)
    v.redeem('A',100); v.redeem('B',100)   # everyone has left before ANY reward was claimed from the gauge
    v.advance(); v.advance()               # two periods pass; nobody holds shares
    v.harvest()                            # delayed claim arrives much later
    a=v.claim('A'); b=v.claim('B'); return a,b,v.bucket(0),v.supply

def fuzz(n=3000):
    random.seed(7)
    for it in range(n):
        g=Gauge(); v=Vault(g)
        accts=['A','B','C']
        for step in range(random.randint(5,40)):
            p=v.cur
            g.S.setdefault(p,F(0))
            r=random.random()
            if r<0.25: v.deposit(random.choice(accts),random.randint(1,1000))
            elif r<0.40:
                h=random.choice(accts); b=v.bal.get(h,0)
                if b>0: v.redeem(h,F(random.randint(1,int(b))))
            elif r<0.55:
                a,b2=random.sample(accts,2); bb=v.bal.get(a,0)
                if bb>0: v.transfer(a,b2,F(random.randint(1,int(bb))))
            elif r<0.75: g.f[p]=min(F(1),g.f.get(p,F(0))+F(random.randint(0,20),100))
            elif r<0.85: g.S[p]=g.S.get(p,F(0))+F(random.randint(0,100))      # late notify anywhere in the period
            elif r<0.90: v.advance(); g.f.setdefault(v.cur,F(0))
            elif r<0.95: g.broken=random.random()<0.5
            else: v.harvest()
        g.broken=False; v.advance(); v.harvest()
        v.record()
        for h in accts: v.settle(h)
        # conservation: sum of entitlements + bucket == funded for every finalised period
        for p in range(0,v.cur):
            if not v.final(p): continue
            tot=sum((v.entitlement(h,p) or 0) for h in accts)+v.bucket(p)
            assert tot<=v.funded.get(p,0)+F(1,10**9), (it,p,tot,v.funded.get(p,0))
            if v.Tt.get(p,0)>0: assert tot==v.funded.get(p,0),(it,p,tot,v.funded.get(p,0))
    return 'fuzz ok'

if __name__=='__main__':
    for o in ('claim_before_B','no_early_claim'):
        print('10-then-90',o,[str(x) for x in scenario_10_90(o)])
    print('late S',[str(x) for x in scenario_late_S()])
    print('both fail',[str(x) for x in scenario_both_fail()])
    print('zero supply',[str(x) for x in scenario_zero_supply()])
    print('last holder then new',[str(x) for x in scenario_last_holder_then_new()])
    print('transfer',[str(x) for x in scenario_transfer()])
    print('exited claims later / no orphan',[str(x) for x in scenario_exited_claims_later_and_no_orphan()])
    print(fuzz())

def scenario_all_failing_then_settle():
    """Entry, transfer, exit and whole-vault exit while the reward call reverts; funding works only after the period ended."""
    g=Gauge(); v=Vault(g); g.S[0]=F(100); g.broken=True
    v.deposit('A',1000); g.f[0]=F(1,10)
    v.deposit('B',1000)                      # ENTRY while the claim reverts
    g.f[0]=F(3,10)
    v.transfer('A','C',500)                  # TRANSFER while the claim reverts
    g.f[0]=F(5,10)
    v.redeem('A',500)                        # EXIT of one holder while the claim reverts
    g.f[0]=F(8,10)
    v.redeem('B',1000); v.redeem('C',500)    # WHOLE-VAULT EXIT while the claim reverts (liquidity removed, NFT kept, accrual stops at f=0.8)
    v.advance()
    assert not v.harvest()
    for h in 'ABC': assert v.entitlement(h,0) is None
    g.broken=False
    assert v.harvest()
    out=(v.claim('A'),v.claim('B'),v.claim('C'),v.bucket(0),v.avail,v.funded[0],v.supply)
    return out
if __name__=='__main__':
    print('all failing then settle (A,B,C,bucket,left in vault,funded,supply)',[str(x) for x in scenario_all_failing_then_settle()])
