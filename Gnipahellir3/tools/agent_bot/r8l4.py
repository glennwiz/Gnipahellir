# run 8 life 4: the grave guard sits by the shaft, so arm up in the west first
from r8 import *
b=B(); b.sparebuilder=True; b.noguard=True
trees=sorted([x for x in range(W) if (b.m[53][x]=='Wood' or b.m[52][x]=='Wood') and x<76],reverse=True)
fl=[x for x in range(W) if b.m[53][x]=='Flower' and x<76]
log('trees',trees,'fl',fl)
for x in trees:
    if b.count('Wood_Log')>=8: break
    for f in [q for q in fl if x<q<b.pos()[0]]: b.walkx(f,limit=40)
    b.chop(x,x+2)
for f in fl:
    if b.count('Flower')>=3: break
    b.walkj(f,limit=40)
b.st()
x,y=b.pos()
b.a(1,select=-1)
for c in ((x+1,y+1),(x+1,y+2)):
    b.dig(*c,tries=40)
b.a(30); b.walkx(x+1,limit=5); b.a(20); b.st()
b.a(2,craft='Plank'); b.a(2,craft='Plank'); b.craft('Crafting_Bench'); b.sel('Crafting_Bench')
fx,fy=b.pos()
for c in [(fx+1,fy),(fx-1,fy),(fx+2,fy),(fx-2,fy)]:
    if not b.solid(*c) and b.solid(c[0],c[1]+1):
        b.a(3,place=list(c))
        if b.t(*c)=='Crafting_Bench': break
b.a(2); b.craft('Fire_Wand'); b.craft('Potion_Health'); b.st()
