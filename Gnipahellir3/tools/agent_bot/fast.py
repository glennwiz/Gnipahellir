from b import *
from start import newgame,p1
import sys
def plant(b,xs,row=54):
    """Tree farm: growers set into the grass, so the walk stays flat. 2 planks + 4 leaves
    each, and a tree only needs clear Air above, so the surface works; caves are Void."""
    for x in xs:
        b.walkj(x-1,limit=30); b.waitland()
        b.sel('Pickaxe'); b.dig(x,row,tries=20); b.a(3)
        b.sel('Tree_Grower'); b.a(3,place=[x,row]); log('grower',x,b.t(x,row),b.r.get('refused'),b.r['notes'][-1:])
def farm(b,xs,row=54):
    """cut every grown trunk at its base and walk through the drops"""
    for x in xs:
        if b.t(x,row-1)!='Wood': continue
        b.walkj(x-1,limit=30); b.waitland(); b.sel('Pickaxe'); b.dig(x,row-1,tries=30)
    b.a(60)
    for x in xs: b.walkj(x,limit=30); b.a(2)
    log('logs',b.count('Wood_Log'))
ph=sys.argv[1:] or ['1','2','3','4','5']
def p2(b):
    if b.count('Stone_Block')<20: b.quarry(22,d=-1); b.st()
    if b.pos()[1]>53: b.goto(100,53,maxrepl=12)  # from under ground: a jump loop only works beside the shaft lip
    assert b.pos()[1]<=53
    trees=[x for x in range(W) if (b.m[53][x]=='Wood' or b.m[52][x]=='Wood') and 99<x<170]; fl=[x for x in range(W) if b.m[53][x]=='Flower' and 99<x<170]
    xs=[x for x in range(102,150,6) if all(abs(x-t)>2 for t in trees) and all(b.t(x,y)=='Air' for y in range(47,54))][:6]
    log('farm at',xs)
    for x in sorted(trees+xs):
        for f in [q for q in fl if b.pos()[0]<q<x]: b.walkj(f,limit=40)
        if x in xs: plant(b,[x])
        else: b.chop(x,x-2)
    b.st()
    assert b.goto(147,92,maxrepl=30,near=3); b.st()
    b.harvest({'Iron_Ore':10,'Silver_Ore':14},(100,70,175,104),maxsec=200); b.st()
    b.quarry(55,d=1 if b.pos()[0]<140 else -1); b.quarry(55,d=-1 if b.pos()[0]<140 else 1); b.st()
    assert b.goto(145,94,maxrepl=30); b.st(); assert b.pos()==(145,94)
    b.waitland(); b.sel('Stone_Block')
    for x in [146,147,148,149,144,143,142,141,140,139,138]:
        if not b.solid(x,95): b.a(2,place=[x,95])
    for i in range(4): b.a(2,craft='Plank')
    b.craft('Crafting_Bench'); b.sel('Crafting_Bench'); b.a(3,place=[142,94]); assert b.t(142,94)=='Crafting_Bench'
    b.a(2)
    for i in range(3): b.a(2,craft='Plank')
    b.craft('Potion_Health')
    b.craft('Sky_Altar',2); b.craft('Smelter',2); b.craft('Mine_Wand'); b.craft('Tree_Grower',3); b.craft('Crafting_Bench'); b.st()
    for x in(146,147,148): b.sel('Wood_Log'); b.a(3,place=[x,94])
    b.sel('Sky_Altar'); b.a(3,place=[147,93]); assert b.t(147,93)=='Sky_Altar'; b.a(2)
    b.walkx(142,limit=30); b.a(3,use=[141,94]); b.a(3,take=5); b.a(2); assert b.count('Rune_Scroll_A')==1
    b.goto(149,94); b.a(3,interact=True); b.a(5); b.scan(); b.st(); assert b.r['level']==3
    log('PHASE sky at',b.r['frame'])
def p3(b):
    b.scan(); b.walkx(94)
    for x in range(89,94): b.sel('Stone_Block'); b.a(2,place=[x,79])
    b.a(2,move='right')
    for x in (90,91,92): b.sel('Wood_Log'); b.a(2,place=[x,78])
    b.sel('Sky_Altar'); b.a(3,place=[91,77]); assert b.t(91,77)=='Sky_Altar'
    b.walkx(96); b.sel('Tree_Grower'); b.a(3,place=[94,79]); b.a(2,move='left')
    b.sel('Smelter'); b.a(3,place=[97,79]); assert b.t(97,79)=='Smelter'
    b.sel('Smelter'); b.a(3,place=[98,79]); log('second smelter',b.t(98,79),b.r.get('refused'))
    b.walkj(100,limit=20); b.sel('Tree_Grower')
    for c in((102,79),(104,79)): b.a(3,place=list(c)); log(c,b.t(*c))
    b.walkj(96,limit=20)
    b.a(2,craft='Plank'); b.a(2,craft='Plank'); b.st()
    b.a(3,use=[97,79]); b.a(3,feed=b.slot('Silver_Ore')); b.a(3,feed=b.slot('Wood_Log')); b.a(2); b.st()
    # cloud drops float, so stand in them: a stone bridge along row 80 and the roof above it
    b.walkj(98,limit=20); b.waitland(); assert b.pos()[1]==81,b.pos()
    b.sel('Stone_Block')
    for nx in range(b.pos()[0]+1,106):
        if not b.solid(nx,82): b.a(2,place=[nx,82])
        b.step((nx-1,81),'walk',(nx,81)); assert b.pos()==(nx,81),b.pos()
    assert b.pillar(1) and b.pillar(1) and b.pos()==(105,79),b.pos()
    b.skyfarm(9,105,122); b.st()
    assert b.count('Cloud_Stone')>=8
    assert b.goto(93,78,maxrepl=8); b.st()
    b.a(3,interact=True); b.a(130); b.a(3); b.st(); b.flightf=b.r['frame']
    log('PHASE ritual A',b.r['frame'],b.count('Cloud_Stone'))
def skychop2(b):
    b.scan()
    for gx in (94,102,104):
        if b.t(gx,78)=='Wood' and b.ftime()<16:
            b.flyto(gx+1,77,tmax=18); 
            b.sel('Pickaxe')
            for y in (78,77,76):
                b.dig(gx,y,tries=10) if b.t(gx,y)=='Wood' and b.reach(gx,y) else None
            b.fly(gx,77); b.a(10); b.fly(gx,76); b.a(4); b.fly(gx+1,76); 
    log('logs',b.count('Wood_Log'))
def p4(b):
    b.flightf=b.r['frame']-80; b.rebless(); b.st()
    t0=time.time()
    while b.count('Cloud_Stone')<33 and time.time()-t0<170 and b.r['level']==3:
        b.cloudrun2(33,tmax=12.5)
        if not b.flyhome(): break
        b.st()
    skychop2(b); b.rebless()
    b.flyto(96,77,tmax=18); b.a(3,use=[97,79]); b.a(3,collect=True); b.a(2)
    b.a(3,use=[98,79]); b.a(3,feed=b.slot('Iron_Ore'))
    if b.slot('Wood_Log') is not None: b.a(3,use=[98,79]); b.a(3,feed=b.slot('Wood_Log'))
    b.a(2); b.st(); b.rebless()
    log('PHASE clouds',b.r['frame'],b.ftime())
def p5(b):
    b.flightf=b.r['frame']; b.leave_sky_to(0,0)
    print(b.fly(144,93),b.p); b.a(2); b.a(3,interact=True); b.a(2); b.scan(); b.st(); assert b.r['level']==1
    t=b.ftime(); log('in cave2 t',t)
    b.flydeep(13,100,int((18.6-t)*11)); b.a(6); b.waitland(); b.st()
    if b.count('Stone_Block')<20:
        x,y=b.pos(); b.harvest({'Stone':25},(x-14,y-8,x+14,y+12),maxsec=40); b.st()
    assert b.goto(12,104,maxrepl=40); b.st()
    b.a(3,use=[12,101]); b.a(3,take=5); b.a(2); b.st(); assert b.count('Rune_Scroll_B')==1
    log('PHASE scroll B',b.r['frame'])
if __name__=='__main__':
    if '1' in ph: newgame(); 
    if '1' in ph: p1()
    b=B(); b.st()
    for n,f in (('2',p2),('3',p3),('4',p4),('5',p5)):
        if n in ph: f(b)
