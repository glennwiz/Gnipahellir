# run 8: p1, then iron, a flat tunnel base at row 58 with bench, smelter, and one golem deployed
from r8 import *
from start import newgame,p1
newgame(); p1()
b=B(); b.sparebuilder=True
say(b,'life 3: setup again - iron, tunnel base at row 58, one golem')
b.sel('Pickaxe')
b.harvest({"Iron_Ore":6},(86,58,125,66),maxsec=200); b.st()
b.noguard=True
log(b.goto(99,58,maxrepl=12),b.pos())
b.quarry(50,d=1,cols=20); b.st()
log(b.goto(101,58,maxrepl=8),b.pos())
b.a(2,craft='Plank'); b.craft('Crafting_Bench'); b.sel('Crafting_Bench'); b.a(3,place=[100,58]); log('bench',b.t(100,58),b.r['notes'][-1:])
b.a(2); b.craft('Smelter'); b.sel('Smelter'); b.a(3,place=[102,58]); log('smelter',b.t(102,58),b.r['notes'][-1:])
n=b.count('Iron_Ore'); b.a(3,use=[102,58]); b.a(3,feed=b.slot('Iron_Ore')); b.a(3,feed=b.slot('Wood_Log'),count=min(2*n,b.count('Wood_Log')-1)); b.a(2)
for i in range(8): b.a(2,craft='Clay')
b.a(20*n*3+30); b.a(3,use=[102,58]); b.a(3,collect=True); b.a(2)
log(b.craft('Command_Wand'), b.craft('Clay_Golem'))
b.sel('Clay_Golem'); b.a(3,place=[103,57])
b.sel('Command_Wand'); b.a(3,place=[104,58]); log(b.r['notes'][-2:]); cshow(b); b.st()
