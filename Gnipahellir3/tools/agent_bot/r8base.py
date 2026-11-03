# run 8: surface-band tunnel base east of the shaft: bench, smelter, golem
from r8 import *
b=B(); b.sparebuilder=True
b.sel('Pickaxe')
log(b.goto(127,56,maxrepl=10),b.pos())
b.noguard=True
b.quarry(40,d=1,cols=12); b.st()
x,y=b.pos(); log(b.goto(x-8,y,maxrepl=6),b.pos())
x,y=b.pos()
b.a(2,craft='Plank'); b.sel('Crafting_Bench'); b.a(3,place=[x-1,y]); log('bench',b.t(x-1,y),b.r['notes'][-1:])
b.a(2); b.craft('Smelter'); b.sel('Smelter'); b.a(3,place=[x+1,y]); log('smelter',b.t(x+1,y),b.r['notes'][-1:])
n=b.count('Iron_Ore'); b.a(3,use=[x+1,y]); b.a(3,feed=b.slot('Iron_Ore')); b.a(3,feed=b.slot('Wood_Log'),count=2*n); b.a(2)
for i in range(6): b.a(2,craft='Clay')
b.a(200*n+30); b.a(3,use=[x+1,y]); b.a(3,collect=True); b.a(2)
log(b.craft('Command_Wand'), b.craft('Clay_Golem'))
b.sel('Clay_Golem'); b.a(3,place=[x+2,y-1])
b.sel('Command_Wand'); b.a(3,place=[x+3,y]); log(b.r['notes'][-2:]); cshow(b); b.st()
log('BASE',x,y)
