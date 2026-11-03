# run 8 life 6: wood and flowers in the west, then dash down the shaft for the pickaxe past the grave guard
from r8 import *
b=B(); b.noguard=True
trees=sorted([x for x in range(W) if (b.m[53][x]=='Wood' or b.m[52][x]=='Wood') and x<88],reverse=True)
fl=[x for x in range(W) if b.m[53][x]=='Flower' and x<92]
log('trees',trees,'fl',fl)
for x in trees:
    if b.count('Wood_Log')>=14: break
    for f in [q for q in fl if x<q<b.pos()[0]]: b.walkx(f,limit=40)
    b.chop(x,x+2)
for f in sorted(fl,reverse=True):
    if b.count('Flower')>=3: break
    b.walkj(f,limit=60)
b.st()
b.walkj(86,limit=60)
def u(): return [(round(e['x'],1),round(e['y'],1)) for e in b.r['enemies'] if e['kind']=='Undead']
for i in range(40):
    if b.p['x']>=95.6: break
    b.a(6,move='right',jump=(i%3==0))
for i in range(20):
    b.a(6,move='right' if b.p['x']<96 else 'none')
    if b.p['grounded'] and b.p['y']>58: break
log('landed',b.pos(),'hp',b.p['hp'],u())
b.walkx(96,limit=4); log('pick',b.count('Pickaxe'))
b.sel('Pickaxe')
for i in range(6):
    b.a(17,mine=[96,62])
    if not b.solid(96,62): break
b.a(40); b.waitland(); log('below',b.pos(),'hp',b.p['hp'],u()); b.st()
