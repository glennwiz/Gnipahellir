# After fast.py: from the Scroll B chest in cave 2, to 10 Gold Bars in the bag.
# 2 ore and 2 logs a bar, in the spare smelter fast.py leaves in the bag.
from b import *

ORE_PER_BAR=2; FUEL_PER_BAR=2; GOAL=10
BATCH=4  # bars a feed: smelt ticks are slow, so a short wait per batch keeps the bot near

def spot(b):
    """An Air tile beside the body, on solid ground, for the smelter."""
    x,y=b.pos()
    for dx in (2,-2,3,-3,1,-1):
        if b.t(x+dx,y)=='Air' and b.solid(x+dx,y+1): return x+dx,y
    raise Exception('no spot')

def gold(b):
    assert b.count('Smelter')>=1
    assert b.harvest({'Gold_Ore':GOAL*ORE_PER_BAR,'Wood':GOAL*FUEL_PER_BAR},(0,60,W-1,H-1),maxsec=600); b.st()
    t=spot(b); b.sel('Smelter'); b.a(3,place=list(t)); assert b.t(*t)=='Smelter',b.r['notes']
    for i in range(GOAL*4):
        if b.count('Gold_Bar')>=GOAL: break
        b.a(3,use=list(t))
        if b.slot('Gold_Ore') is not None: b.a(3,feed=b.slot('Gold_Ore'),count=BATCH*ORE_PER_BAR)
        if b.slot('Wood_Log') is not None: b.a(3,use=list(t)); b.a(3,feed=b.slot('Wood_Log'),count=BATCH*FUEL_PER_BAR)
        b.a(600); b.a(3,use=list(t)); b.a(3,collect=True); b.a(2); b.st()
        log('bars',b.count('Gold_Bar'))
    assert b.count('Gold_Bar')>=GOAL
    log('PHASE gold',b.r['frame'])

if __name__=='__main__':
    b=B(); b.st(); gold(b)
