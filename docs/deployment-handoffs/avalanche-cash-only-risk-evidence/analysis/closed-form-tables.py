LI=1.08
print("| CF | W: max AVAX fall survived, util 99% | util 90% | util 70% | U: max AVAX rise survived, util 99% | util 90% | util 70% |")
print("|---|---|---|---|---|---|---|")
for cf in (30,40,45,50,55,60,65,70,75,80,85,90):
    c=cf/100
    row=[]
    for u in (.99,.9,.7):
        f=max(0,1-c*u*LI) if c*u*LI<1 else 0  # bad if rho=(1-f)/(c u) < LI -> f > 1 - c u LI
        row.append("%.0f%%"%(100*f) if c*u*LI<1 else "0% (never safe)")
    row2=[]
    for u in (.99,.9,.7):
        g=1/(c*u*LI)-1
        row2.append("+%.0f%%"%(100*g) if g>0 else "none")
    print(f"| {cf}% | "+" | ".join("-"+x if not x.startswith('0') else x for x in row)+" | "+" | ".join(row2)+" |")
print()
print("CF* (largest CF with zero bad debt) per shock, util 99, by LI")
for li in (1.05,1.08,1.10,1.15):
    w=[(f, min(.9,(1-f)/(.99*li))) for f in (.2,.3,.4,.5,.6,.7)]
    u=[(g, min(.9,1/(.99*li*(1+g)))) for g in (.25,.5,.75,1,1.5,2)]
    print(li,'W',' '.join('-%d%%:%.1f%%'%(f*100,c*100) for f,c in w))
    print(li,'U',' '.join('+%d%%:%.1f%%'%(g*100,c*100) for g,c in u))
print("CF* at util 90 and 70 LI 1.08")
for uu in (.9,.7):
    w=[(f, min(.9,(1-f)/(uu*1.08))) for f in (.2,.3,.4,.5,.6,.7)]
    u=[(g, min(.9,1/(uu*1.08*(1+g)))) for g in (.25,.5,.75,1,1.5,2)]
    print(uu,'W',' '.join('-%d%%:%.1f%%'%(f*100,c*100) for f,c in w))
    print(uu,'U',' '.join('+%d%%:%.1f%%'%(g*100,c*100) for g,c in u))
# bad fraction table at u=.99 LI 1.08
print("bad fraction of debt at util 99, LI1.08: W rows CF, cols fall")
for cf in (30,40,50,60,70,75,80,90):
    c=cf/100
    print(cf,'W',' '.join('-%d%%:%.1f%%'%(f*100,100*max(0,1-((1-f)/(c*.99))/1.08)) for f in (.2,.3,.4,.5,.6,.7)),'| U',' '.join('+%d%%:%.1f%%'%(g*100,100*max(0,1-(1/(c*.99*(1+g)))/1.08)) for g in (.25,.5,.75,1,1.5,2)))
