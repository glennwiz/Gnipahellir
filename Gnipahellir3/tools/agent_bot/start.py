from b import *
def newgame():
    g=G()
    for i in range(40):
        r=g.st(0,53,1,1)
        if r['screen']=='play' and not r['player']['dead']: return
        g.act(30,dismiss=True)
    raise SystemExit('no play')
def p1():
    b=B(); b.st()
    trees=[x for x in range(W) if b.m[53][x]=='Wood' or b.m[52][x]=='Wood']; fl=[x for x in range(W) if b.m[53][x]=='Flower']
    wat=max([x for x in range(88) if b.m[54][x]=='Water' or b.m[55][x]=='Water'],default=0)
    log(trees,fl,'water',wat)
    tw=sorted([q for q in trees if q<88],reverse=True)  # past the pond too: sparse seeds have nothing nearer
    for x in tw:
        if b.count('Wood_Log')>=16 or (b.count('Wood_Log')>=7 and abs(x-b.pos()[0])>45): break
        for f in [q for q in fl if x<q<b.pos()[0]]: b.walkx(f,limit=40)
        b.chop(x,x+2)
    for f in (84,):
        pass
    if b.count('Wood_Log')<7: raise Exception('logs')
    b.st()
    stuck=0; lastx=None
    for i in range(40):
        if b.walkx(95,limit=60): break
        # Run 7: 30 s jumping at a trunk at x 88, which p1 never chopped (it only cuts x<88).
        # No progress twice: cut the trunk in the way, else give up loudly.
        x=round(b.p['x'],1); stuck=stuck+1 if x==lastx else 0; lastx=x
        if stuck>=2:
            nc=int(b.p['x']+.4)+1; fy=b.pos()[1]
            if any(b.t(nc,y)=='Wood' for y in (fy-1,fy)): b.chop(nc,nc-1); stuck=0; continue
            raise Exception('p1: stuck walking to the shaft at x %s'%x)
        b.a(1,jump=True,move='right'); b.a(15,move='right')
    b.a(2,move='left')
    b.sel('Wood_Log'); b.a(2,place=[96,58]); assert b.t(96,58)=='Wood'
    b.walkx(96,limit=20); b.waitland(); b.a(10); b.st()
    b.a(1,select=-1); b.dig(96,58,tries=30); b.waitland(); b.a(15); b.walkx(96,limit=3); b.st()
    assert b.count('Pickaxe')==1
    b.sel('Pickaxe')
    for c in((95,60),(95,61)): b.dig(*c)
    b.walkx(97,limit=6); b.sel('Pickaxe')
    for c in((98,60),(98,61)): b.dig(*c)
    b.a(3); b.st()
    b.a(2,craft='Plank'); b.craft('Crafting_Bench'); b.sel('Crafting_Bench')
    # run 8: (98,61) had no floor in one world ("It needs solid ground under it"): try the cells round the feet
    fx,fy=b.pos()
    for c in [(98,61),(fx+1,fy),(fx-1,fy),(fx+2,fy),(fx-2,fy)]:
        if not b.solid(*c) and b.solid(c[0],c[1]+1):
            b.a(3,place=list(c))
            if b.t(*c)=='Crafting_Bench': break
    assert b.count('Crafting_Bench')==0,('bench not placed',b.r['notes'][-1:])
    b.a(2); b.craft('Fire_Wand'); b.craft('Potion_Health'); b.a(2,craft='Plank'); b.st()
    assert b.count('Fire_Wand')==1
    b.a(2,craft='Plank'); b.a(2,craft='Plank'); b.craft('Tree_Grower',3); b.st()
if __name__=='__main__':
    newgame(); p1()
