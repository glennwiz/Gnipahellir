import sys,heapq,time,os,json,atexit
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from g import G,show,brief
from tiles import SOLID,MINE,HAZ
class Dead(Exception): pass
LOG=open(os.path.dirname(os.path.abspath(__file__))+'/play.log','a')
def log(*a):
    s=' '.join(str(x) for x in a); print(s,flush=True); LOG.write(time.strftime('%H:%M:%S ')+s+'\n'); LOG.flush()
W,H=192,108
NAT={'Stone','Dirt','Grass','Sand','Mossy_Stone','Cloud','Cloud_Ore','Aether_Ore','Iron_Ore','Silver_Ore','Gold_Ore','Gold_Rare_Ore','Jade_Ore','Emerald_Ore','Diamond_Ore','Hel_Gem_Ore','Runic_Sky_Ore','Clay','Wood','Leaves','Green_Cave_Mushroom'}
class B:
    def __init__(s):
        s.maxfall=5; s.safeonly=True; s.flightf=0; s.vp=set(); s.g=G(); s.r=None; s.m=[['Void']*W for _ in range(H)]; s.level=None; s.noguard=False; s.deaths=0
        s.items={}; s.planned=False
        s.scan()
        atexit.register(s.endplan)
    def ingest(s,r):
        if not r.get('ok'):
            log('ERR',r); return
        s.r=r; v=r['view']; L=v['legend']
        for j,row in enumerate(v['rows']):
            for i,c in enumerate(row):
                s.m[v['y']+j][v['x']+i]=L[c]
        if 'solid' in v:  # the game says which legend chars block: trust it over tiles.py
            for c,name in L.items():
                (SOLID.add if c in v['solid'] else SOLID.discard)(name)
        s.items_view=r['items']
        if r['screen']=='dead' and not getattr(s,'allowdead',False): raise Dead()
    def scan(s):
        s.ingest(s.g.st(0,0,W,H)); s.level=s.r['level']
        s.items={(i['x'],i['y']):(i['item'],i['count']) for i in s.r['items']}
        return s.r
    @property
    def p(s): return s.r['player']
    def pos(s):
        p=s.p; return (int(p['x']+0.4), int(p['y']+1.75))  # feet cell
    def t(s,x,y):
        if 0<=x<W and 0<=y<H: return s.m[y][x]
        return 'Stone'
    def solid(s,x,y): return s.t(x,y) in SOLID
    def slot(s,item):
        for i in s.r['inventory']:
            if i['item']==item: return i['slot']
        return None
    def count(s,item): return sum(i['count'] for i in s.r['inventory'] if i['item']==item)
    def a(s,frames=1,**k):
        s.ingest(s.g.act(frames,**k))
        if s.r['level']!=s.level: s.scan()
        for it in s.r['items']: s.items[(it['x'],it['y'])]=(it['item'],it['count'])
        if not s.noguard: s.guard()
        return s.r
    def inhaz(s):
        p=s.p
        if s.r.get('in_tile') in HAZ: return True
        return any(s.t(x,y) in HAZ for x in {int(p['x']),int(p['x']+.79)} for y in {int(p['y']),int(p['y']+.9),int(p['y']+1.79)})
    def flee(s):
        s.noguard=True; log('FLEE',s.p,s.pos())
        for _ in range(8):
            if not s.inhaz(): break
            s.ingest(s.g.st(int(s.p['x'])-20,int(s.p['y'])-12,41,25))
            col,y=s.pos(); best=None
            for d in (1,-1,2,-2,3,-3,4,-4,6,-6,8,-8):
                if s.t(col+d,y) not in HAZ and s.t(col+d,y-1) not in HAZ and not s.solid(col+d,y) and not s.solid(col+d,y-1) and all(not s.solid(col+q*(1 if d>0 else -1),y-1) and not s.solid(col+q*(1 if d>0 else -1),y) for q in range(1,abs(d))): best=d;break
            if best is None:
                for c in((col+1,y),(col+1,y-1),(col-1,y),(col-1,y-1)):
                    pass
                s.a(1,jump=True); s.a(8); continue
            s.a(min(30,abs(best)*8),move='right' if best>0 else 'left')
        s.noguard=False
    def los(s,x0,y0,x1,y1):
        n=int(max(abs(x1-x0),abs(y1-y0))*3)+1
        for i in range(n+1):
            x=x0+(x1-x0)*i/n; y=y0+(y1-y0)*i/n
            if s.solid(int(x),int(y)): return False
        return True
    def guard(s):
        r=s.r
        if r['screen']!='play':
            s.noguard=True; s.a(2,dismiss=True); s.noguard=False; return
        p=s.p
        hp0=getattr(s,'lasthp',p['hp']); s.lasthp=p['hp']
        if s.inhaz() or (p['hp']<hp0 and s.nearhaz(*s.pos(),r=2)): s.flee()
        p=s.p
        if p['hp']<=5 and s.slot('Potion_Health') is not None:
            log('drink',p['hp']); s.noguard=True; s.a(2,equip=s.slot('Potion_Health')); s.noguard=False
        if s.slot('Fire_Wand') is None and s.slot('Sword') is None: return
        cx,cy=p['x']+.4,p['y']+.9
        ene=[]
        for e in r['enemies']:
            if e['kind']=='Garm': continue
            ex,ey=e['x']+.4,e['y']+.9; d=max(abs(ex-cx),abs(ey-cy))
            if d<=2.6 or (d<=8 and s.slot('Fire_Wand') is not None and p['mana']>=4 and s.los(cx,cy,ex,ey)): ene.append((d,e['slot'],e))
        if not ene: return
        ene.sort(key=lambda q:q[:2]); s.fight(ene[0][2])
    def fight(s,e):
        s.noguard=True
        sel=s.r['selected']; hp0=s.p['hp']; log('fight',e['kind'],e['x'],e['y'],'hp',s.p['hp'])
        miss=0; last=e['hp']
        for n in range(50):
            cur=[x for x in s.r['enemies'] if x['slot']==e['slot']]
            if not cur: log('killed',e['kind'],'hp',s.p['hp']); break
            c=cur[0]
            if c['hp']<last: miss=0; last=c['hp']
            cx,cy=s.p['x']+.4,s.p['y']+.9; ex,ey=c['x']+.4,c['y']+.9
            d=max(abs(ex-cx),abs(ey-cy))
            if d>9.5: break
            if s.p['hp']<=5 and s.slot('Potion_Health') is not None:
                s.a(2,equip=s.slot('Potion_Health'))
            tile=[int(ex),int(ey)]
            sw=next((q for q in('Gold_Sword','Silver_Sword','Sword') if s.slot(q) is not None),None)
            if sw and d<=2.6:
                s.a(1,select=s.slot(sw)); s.a(21,mine=tile); continue
            if s.slot('Fire_Wand') is None or s.p['mana']<4:
                if sw: s.a(1,select=s.slot(sw)); s.a(10); continue
                break
            if miss>=2:
                k=int(max(abs(ex-cx),abs(ey-cy))*3)+1; dug=False
                for i in range(1,k):
                    q=(int(cx+(ex-cx)*i/k),int(cy+(ey-cy)*i/k))
                    if s.solid(*q) and s.t(*q) in MINE and s.reach(*q):
                        s.a(1,select=s.slot('Pickaxe')); s.a(17,mine=list(q)); dug=True; break
                miss=0
                if dug: continue
            s.a(1,select=s.slot('Fire_Wand')); s.a(12,mine=tile); miss+=1
        s.a(1,select=sel); s.noguard=False
    def sel(s,item):
        i=s.slot(item)
        if i is None: return False
        if s.r['selected']!=i: s.a(1,select=i)
        return True
    def dig(s,x,y,tries=60):
        for _ in range(tries):
            if not s.solid(x,y): return True
            if s.t(x,y) not in MINE: return False
            wand=s.slot('Mine_Wand') is not None and s.cheb(x,y)<=3
            if s.reach(x,y) and not (wand and s.p['mana']>=45):
                if not s.sel('Pickaxe'): s.a(1,select=-1)
                s.a(17,mine=[x,y]); continue
            if not wand: log('noreach',(x,y),'from',s.p['x'],s.p['y']); return False
            if s.p['mana']<6: s.a(30); continue   # out of pick reach: wait for mana, never chip what is under the cursor's nearest
            s.sel('Mine_Wand'); s.a(16,mine=[x,y])
        return not s.solid(x,y)
    def reach(s,x,y):
        p=s.p; col=int(p['x']+.4); top=int(p['y']); bot=int(p['y']+1.799)
        return abs(x-col)<=1 and top-1<=y<=bot+1
    def cheb(s,x,y):
        fx,fy=s.pos(); return max(abs(fx-x),abs(fy-1-y))
    def placeblock(s,x,y,item=None):
        for it in ([item] if item else ['Stone_Block','Mossy_Stone','Dirt','Grass_Turf']):
            if s.slot(it) is not None:
                s.sel(it); s.a(2,place=[x,y]); return s.solid(x,y)
        return False
    def walkx(s,tx,limit=200,tol=0.25):
        # walk until body centre in target tile
        lv=s.r['level']
        for _ in range(limit):
            if s.r['level']!=lv: return False
            c=s.p['x']+.4; d=tx+.5-c
            if abs(d)<tol: return True
            f=max(1,min(30,int(abs(d)*60/8)))
            s.a(f,move='left' if d<0 else 'right')
            if s.p['vx']==0 and abs(s.p['x']+.4-c)<0.01:
                return False
        return False
    def waitland(s,maxf=120):
        for _ in range(maxf):
            if s.p['grounded']: return
            s.a(3)
    def think(s,*acts,sec=20):
        """Last call before a think: what the player does meanwhile. Plays at 15 ticks/s and
        is blind, so give it only moves that are safe from where it starts."""
        acts=list(acts) or s.safeacts(sec)
        r=s.g.plan(*acts); s.planned=True
        log('plan sent',r,len(acts),'steps, left',s.g.st(0,0,1,1).get('plan_left')); return r
    def safeacts(s,sec=20):
        """mine rock beside the body if any is clear of the floor and of hazards, else hold still.
        Worth a free stone while thinking; the cells are checked now, not when they play."""
        if s.r['screen']!='play' or s.p['dead'] or s.r.get('flight_s',0)>0 or s.slot('Pickaxe') is None: return [{'frames':min(600,sec*15)}]
        x,y=s.pos(); cells=[(c,r) for c in(x-1,x+1) for r in(y-1,y) if s.t(c,r)=='Stone' and s.reach(c,r) and not s.nearhaz(c,r,2)]
        acts=[{'select':s.slot('Pickaxe'),'frames':1}]+[{'mine':list(c),'frames':24} for c in cells]
        left=sec*15-24*len(cells)
        if left>0: acts.append({'frames':min(600,left)})
        return acts
    def endplan(s):
        # every script ends in a think, so a forgotten plan must not leave him standing idle
        if s.planned: return
        try: s.think()
        except Exception as e: print('endplan failed',e,flush=True)
    # ---- pathing
    def free(s,x,y):
        t=s.t(x,y); return t not in SOLID and t not in HAZ and t!='Water'
    def cost(s,x,y,digok):
        """cost to clear a cell; None if impossible"""
        t=s.t(x,y)
        if t in HAZ or t=='Water': return None
        if t in SOLID:
            if not digok or t not in NAT: return None
            # no digging beside lava
            for dx,dy in((1,0),(-1,0),(0,-1),(0,1),(2,0),(-2,0),(0,-2),(1,-1),(-1,-1)):
                if s.t(x+dx,y+dy) in HAZ: return None
            return 3
        return 0
    def neigh(s,x,y,digok,blocks):
        out=[]
        for dx in(-1,1):
            nx=x+dx
            a=s.cost(nx,y,digok); b=s.cost(nx,y-1,digok)
            if a is not None and b is not None:
                fy=None; f=y
                if s.solid(nx,y+1): fy=y
                else:
                    while f-y<s.maxfall:
                        if s.cost(nx,f+1,False) is None: f=-1;break
                        f+=1
                        if s.solid(nx,f+1): fy=f;break
                    if a or b: fy=y if fy==y else None
                if fy is not None: out.append((1+a+b+(fy-y)*.3,nx,fy,'walk'))
                if blocks and not s.solid(nx,y+1) and s.t(nx,y+1) not in HAZ and s.t(nx,y+1)!='Water':
                    out.append((3.2+a+b,nx,y,'bridge'))
            # step up one tile
            a=s.cost(nx,y-1,digok); b=s.cost(nx,y-2,digok); c=s.cost(x,y-2,digok)
            if None not in(a,b,c) and s.solid(nx,y):
                out.append((1.5+a+b+c,nx,y-1,'up'))
        if blocks:
            a=s.cost(x,y-2,digok); b=s.cost(x,y-3,digok)
            if a is not None and b is not None and s.t(x,y) in('Air','Void'):  # a mushroom cell refuses the block
                out.append((2.6+a+b,x,y-1,'Pillar'))
        if s.solid(x,y+1):
            a=s.cost(x,y+1,digok)
            if a is not None and s.t(x,y+1) in MINE:
                f=y+1; fy=None
                while f-y<=s.maxfall:
                    if s.solid(x,f+1): fy=f;break
                    if s.cost(x,f+1,False) is None: break
                    f+=1
                if fy is not None: out.append((1+a,x,fy,'down'))
        return out
    def fl(s,x,y): return s.solid(x,y) or (x,y) in s.vp
    def safe(s,x,y):
        return any(s.solid(x,y+i) for i in range(1,7))
    def path(s,tx,ty,digok=True,blocks=False,near=0,maxn=250000):
        st=s.pos(); s.vp=set()
        q=[(0,0,st,None)]; seen={}; n=0; parent={st:None}; best={st:0}
        while q and n<maxn:
            f,gc,cur,_=heapq.heappop(q); n+=1
            if abs(cur[0]-tx)<=near and abs(cur[1]-ty)<=near:
                pth=[]
                while parent[cur]:
                    pc,mv=parent[cur]; pth.append((cur,mv,pc)); cur=pc
                return pth[::-1]
            if gc>best.get(cur,1e9): continue
            for c,nx,ny,mv in s.neigh(cur[0],cur[1],digok,blocks):
                if not(1<=nx<W-1 and 1<=ny<H-1): continue
                g2=gc+c
                if g2<best.get((nx,ny),1e9):
                    best[(nx,ny)]=g2; parent[(nx,ny)]=(cur,mv)
                    heapq.heappush(q,(g2+1.6*max(abs(nx-tx),abs(ny-ty)),g2,(nx,ny),None))
        return None
    def center(s,col):
        for _ in range(30):
            x=s.p['x']
            if col+.01<=x<=col+.19: s.a(1); 
            if col+.01<=s.p['x']<=col+.19 and s.p['vx']==0: return True
            d=col+.1-s.p['x']
            if abs(d)>.25: s.walkx(col,limit=6,tol=.2)
            else: s.a(1,move='left' if d<0 else 'right'); s.a(1)
        return False
    def stack(s):
        if s.slot('Stone_Block') is not None: return 'Stone_Block'
        for it in('Mossy_Stone','Dirt','Grass_Turf','Sand'):
            if s.slot(it) is not None: return it
        return None
    def pillar(s,n=1):
        col,y=s.pos()
        it=s.stack()
        if it is None or s.count(it)<n: log('no blocks'); return False
        for r in range(y-2,y-3-n,-1):
            if s.solid(col,r) and not s.dig(col,r): log('pillar head',col,r,s.t(col,r)); return False
        if s.solid(col,y-3-n): n=1 if not s.solid(col,y-3) else 0
        if n==0: log('pillar blocked'); return False
        if not s.center(col): log('no center',s.p); return False
        if not s.p['grounded']: s.waitland()
        s.sel(it); y0=s.p['y']
        s.a(1,jump=True)
        for _ in range(26):
            if y0-s.p['y']>=n+.04: break
            s.a(1)
        for k in range(n):
            s.a(1,place=[col,y-k])
        s.waitland(); s.a(1)
        return s.pos()==(col,y-n)
    def step(s,cur,mv,dst):
        x,y=cur; nx,ny=dst; d=1 if nx>x else -1
        if mv=='walk':
            for c in((nx,y),(nx,y-1)):
                if not s.dig(*c): return False
            r=s.walkx(nx); s.waitland(); return r
        if mv=='bridge':
            for c in((nx,y),(nx,y-1)):
                if not s.dig(*c): return False
            if not s.solid(nx,y+1):
                it=s.stack()
                if it is None: log('no blocks'); return False
                s.sel(it); s.a(2,place=[nx,y+1])
                if not s.solid(nx,y+1): log('bridge fail',nx,y+1,s.p); return False
            return s.walkx(nx)
        if mv=='Pillar':
            return s.pillar(1)
        if mv=='up':
            for c in((x,y-2),(nx,y-1),(nx,y-2)):
                if not s.dig(*c): return False
            s.walkx(nx); s.waitland(); return True
        if mv=='down':
            if not s.dig(x,y+1): return False
            s.walkx(x,limit=10); s.waitland(); return True
    def goto(s,tx,ty,digok=True,blocks=True,near=0,maxrepl=25):
        fails={}
        for _ in range(maxrepl):
            if abs(s.pos()[0]-tx)<=near and abs(s.pos()[1]-ty)<=near: return True
            pth=s.path(tx,ty,digok,blocks,near)
            if pth is None:
                log('nopath',s.pos(),(tx,ty)); return False
            key=(s.pos(),pth[0][0],pth[0][1]); fails[key]=fails.get(key,0)+1
            if fails[key]>2: log('same step failed',key); return False
            ok=True
            log('plan',s.pos(),'->',(tx,ty),len(pth),''.join(m[0] for _,m,_ in pth)[:90],'blocks',sum(m in('bridge','Pillar') for _,m,_ in pth),'have',s.count('Stone_Block'))
            i=0
            while i<len(pth):
                dst,mv,cur=pth[i]
                if s.pos()!=cur:
                    log('offpath',s.pos(),cur,mv,s.p['x'],s.p['y'],s.p['grounded']); ok=False;break
                if s.r['level']!=s.level: return True
                if mv=='Pillar' and i+1<len(pth) and pth[i+1][1]=='Pillar':
                    if s.pillar(2) and s.pos()==pth[i+1][0]: i+=2; continue
                    ok=False;break
                if not s.step(cur,mv,dst): ok=False;log('stepfail',mv,cur,dst,s.pos());break
                i+=1
            if not ok: s.a(2); s.waitland()
        return False
    def quarry(s,want,d=1,cols=80):
        x,y=s.pos()
        for i in range(cols):
            if s.count('Stone_Block')>=want: return True
            nx=x+d
            if s.t(nx,y) in HAZ or s.t(nx,y-1) in HAZ or s.t(nx,y)=='Water' or s.t(nx,y-1)=='Water': log('quarry haz',nx,y); return False
            ok=s.step((x,y),'bridge' if not s.solid(nx,y+1) else 'walk',(nx,y))
            if s.pos()!=(nx,y): log('quarry stop',s.pos(),(nx,y)); return False
            for c in((nx,y-2),):
                if s.t(*c) in('Stone',) and s.reach(*c) and s.t(c[0],c[1]-1) not in HAZ: s.dig(*c,tries=4)
            x=nx
        return s.count('Stone_Block')>=want
    def craft(s,name,n=1):
        for _ in range(n):
            before=s.count(name); s.a(3,craft=name)
            if s.count(name)<=before:
                log('craft fail',name,s.r.get('craftable')); return False
        return True
    def inv(s): return {i['item']:s.count(i['item']) for i in s.r['inventory']}
    def st(s): log('frame',s.r['frame'],'L',s.r['level'],'pos',s.pos(),'hp',s.p['hp'],'mana',s.p['mana'],s.inv(),'en',[(e['kind'],int(e['x']),int(e['y'])) for e in s.r['enemies']])
    def harvest(s,want,box,maxsec=240):
        """want: {tile:targetcount}"""
        t0=time.time(); drop={'Wood':'Wood_Log','Cloud':'Cloud_Stone','Cloud_Ore':'Cloud_Stone','Stone':'Stone_Block','Jade_Ore':'Jade','Emerald_Ore':'Emerald','Diamond_Ore':'Diamond'}
        bad=set()
        while time.time()-t0<maxsec:
            names=[n for n,c in want.items() if s.count(drop.get(n,n))<c]
            if not names: return True
            x0,y0,x1,y1=box; px,py=s.pos(); c=[]
            for y in range(y0,y1+1):
                for x in range(x0,x1+1):
                    if s.m[y][x] in names and (x,y) not in bad and not s.nearhaz(x,y,2) and not (136<=x<=151 and 92<=y<=97):
                        c.append((max(abs(x-px),abs(y-py))+abs(y-py),x,y))
            if not c: log('no ore',names); return False
            c.sort(); _,x,y=c[0]
            nm=s.m[y][x]; before=s.count(drop.get(nm,nm))
            ok=False
            for ty in (y,y+1):
                if s.path(x,ty,True,True) is not None:
                    ok=s.goto(x,ty,maxrepl=6); break
            if not ok or s.t(x,y)==nm or (nm not in('Cloud',) and s.count(drop.get(nm,nm))<=before):
                # dropped item might be above: try once
                bad.add((x,y)); log('harvest miss',nm,(x,y),s.pos())
            s.st()
        return False
    def nearhaz(s,x,y,r=3):
        return any(s.t(x+i,y+j) in HAZ for i in range(-r,r+1) for j in range(-r,r+1))
    def sweep(s,xs,y,want):
        """tunnel along row y (feet in row y), floor y+1 must stay. xs in order"""
        for x in xs:
            if s.count('Cloud_Stone')>=want: return True
            if s.solid(x,y): 
                if not s.dig(x,y): log('sweep stuck',x,y,s.pos()); 
            s.walkx(x,limit=12); s.a(1)
        return s.count('Cloud_Stone')>=want
    def fly(s,tx,ty,maxit=80):
        lv=s.r['level']
        for _ in range(maxit):
            if s.r['level']!=lv: return False
            dx=tx+.1-s.p['x']; dy=ty+.1-s.p['y']
            if abs(dx)<.2 and abs(dy)<.2: return True
            f=max(1,min(10,int(max(abs(dx),abs(dy))/.233)))
            k={}
            if dx<-.15: k['move']='left'
            elif dx>.15: k['move']='right'
            if dy<-.15: k['jump']=True
            elif dy>.15: k['down']=True
            ox,oy,hp0=s.p['x'],s.p['y'],s.p['hp']
            s.a(f,**k)
            # run 3 died here: a conjured wall stopped the flight and this loop kept
            # pushing in rising lava with noguard on, ring and potion unused
            if s.r.get('in_tile') in HAZ or s.p['hp']<hp0:
                if s.warpout('fly hurt at %s'%(s.pos(),)): return False
                if s.r.get('in_tile') in HAZ: s.flee(); return False
            if abs(s.p['x']-ox)+abs(s.p['y']-oy)<.01:
                stuck=getattr(s,'_st',0)+1; s._st=stuck
                if stuck>4: s._st=0; return False
                fy=s.p['y']%1; fx=s.p['x']%1
                if fy>.6: s.a(2,down=True)
                elif fy>.03 and fy<=.6 and 'jump' not in k and 'down' not in k: s.a(1,jump=True)
                if fx>.21 and fx<.6: s.a(1,move='left')
                elif fx>=.6: s.a(1,move='right')
        return False
    def flyall(s,w):
        """fly a waypoint list; stop at the first leg that fails"""
        for x,y in w[1:]:
            if not s.fly(x,y): return False
        return True
    def bless(s):
        """walk to swirl; returns frame"""
        s.goto(92,77); s.a(3); s.flightf=s.r['frame']; log('blessed at',s.r['frame'],s.pos()); return s.flightf
    def ftime(s): return (s.r['frame']-s.flightf)/60
    def tunnel(s,xs,top,want,tmax=17):
        for x in xs:
            if s.ftime()>tmax or s.count('Cloud_Stone')>=want or s.r['level']!=3: return
            for y in(top,top+1):
                if s.solid(x,y): s.dig(x,y,tries=6)
            if not s.fly(x,top): log('flystuck',x,top,s.p['x'],s.p['y'])
    def segs(s):
        out=[]
        for T in(76,64,52,40):
            x=1
            while x<W-1:
                if s.m[T][x] in('Cloud','Cloud_Ore','Aether_Ore'):
                    x0=x
                    while s.m[T][x] in('Cloud','Cloud_Ore','Aether_Ore','Air') and x<W-1 and any(s.m[T][q] in('Cloud','Cloud_Ore') for q in range(x,min(x+3,W-1))): x+=1
                    n=sum(1 for q in range(x0,x) for r in(T,T+1) if s.m[r][q] in('Cloud','Cloud_Ore'))
                    o=sum(1 for q in range(x0,x) if s.m[T][q]=='Cloud_Ore')
                    if n>=4 and not (T==76 and 86<=x0<=108): out.append((T,x0,x-1,n,o))
                else: x+=1
        return out
    def safecol(s,x,y):
        return all(s.m[r][x] not in SOLID for r in range(y+2,86))
    def bail(s):
        """fly to the nearest column with free fall to the exit and drop"""
        px,py=s.pos(); py=py-1
        for d in range(0,60):
            for x in(px+d,px-d):
                if 2<x<W-2 and s.safecol(x,py) and all(not s.solid(q,py) and not s.solid(q,py+1) for q in range(min(x,px),max(x,px)+1)):
                    log('bail col',x,'from',px,py,'t',s.ftime()); s.fly(x,py); 
                    for _ in range(90):
                        if s.r['level']!=3: return True
                        s.a(10)
                    return s.r['level']!=3
        log('no bail',px,py); return False
    def cloudrun(s,want,tmax=14.5):
        while s.ftime()<tmax and s.count('Cloud_Stone')<want:
            seg=[q for q in s.segs()]
            px=s.p['x'];py=s.p['y']
            seg.sort(key=lambda q:(abs(q[1]-px)+abs(q[0]-py)*1.0-q[4]*6))
            if not seg: break
            T,x0,x1,n,o=seg[0]
            xs=list(range(x0,x1+1)) if abs(x0-px)<=abs(x1-px) else list(range(x1,x0-1,-1))
            # approach from outside
            st=xs[0]
            log('seg',T,x0,x1,n,o,'t',s.ftime())
            ok=s.fly(st-(1 if xs[0]==x0 else -1),T)
            s.tunnel(xs,T,want,tmax=tmax)
    def walkj(s,x,limit=60):
        for _ in range(12):
            if s.walkx(x,limit=limit): return True
            d='right' if x+.5>s.p['x']+.4 else 'left'
            s.a(1,jump=True,move=d); s.a(16,move=d)
        return False
    def chop(s,x,fromx):
        d=1 if fromx>x else -1
        s.walkj(x+d)
        s.a(1,select=-1) if s.slot('Pickaxe') is None else s.sel('Pickaxe')
        n=s.count('Wood_Log')
        y=next((r for r in (53,52,51) if s.t(x,r)=='Wood'),None)
        if y is None or not s.reach(x,y) or not s.dig(x,y,tries=30): log('chop fail',x,s.p,y); return False
        s.a(70)
        for q in (x,x-d,x): s.walkj(q)
        s.a(2); log('chop',x,'logs',n,'->',s.count('Wood_Log'))
        return True
    def flyland(s):
        """nearest standable spot by air, from any point in flight"""
        from collections import deque
        s.scan()
        px,py=int(s.p['x']+.4),int(s.p['y']+.1)
        def ok(x,y): return 1<=x<W-1 and 1<=y<H-2 and not s.solid(x,y) and not s.solid(x,y+1) and s.t(x,y) not in HAZ and s.t(x,y+1) not in HAZ
        q=deque([(px,py)]); par={(px,py):None}
        while q:
            c=q.popleft()
            if s.solid(c[0],c[1]+2):
                out=[]
                while c: out.append(c); c=par[c]
                out=out[::-1]; log('flyland',out[-1],len(out),'t',s.ftime())
                for w in out[1:]: s.fly(*w)
                return True
            for dx,dy in((0,1),(1,0),(-1,0),(0,-1)):
                n=(c[0]+dx,c[1]+dy)
                if n not in par and ok(*n): par[n]=c; q.append(n)
        return False
    def airpath(s,tx,ty):
        """BFS through free 2-high 1-wide space, for flight"""
        from collections import deque
        px,py=int(s.p['x']+.4),int(s.p['y']+.1)
        def ok(x,y): return 1<=x<W-1 and 1<=y<H-2 and not s.solid(x,y) and not s.solid(x,y+1)
        q=deque([(px,py)]); par={(px,py):None}
        while q:
            c=q.popleft()
            if c==(tx,ty):
                out=[]
                while c: out.append(c); c=par[c]
                return out[::-1]
            for dx,dy in((1,0),(-1,0),(0,1),(0,-1)):
                n=(c[0]+dx,c[1]+dy)
                if n not in par and ok(*n): par[n]=c; q.append(n)
        return None
    def flyhome(s):
        s.scan(); p=s.airpath(92,76)
        if p is None: log('no air path'); return False
        # compress to turning points
        wp=[p[i] for i in range(0,len(p),1) if i==len(p)-1 or i==0 or (p[i+1][0]-p[i][0],p[i+1][1]-p[i][1])!=(p[i][0]-p[i-1][0],p[i][1]-p[i-1][1])]
        for x,y in wp[1:]:
            if not s.fly(x,y): log('fly stuck',x,y,s.p['x'],s.p['y'])
        s.fly(92,76); s.flightf=s.r['frame']; log('home',s.pos()); return True
    def flypath(s,tx,ty,digc=6):
        """dijkstra on 2-tall body cells, digging allowed"""
        px,py=int(s.p['x']+.4),int(s.p['y']+.1)
        def cc(x,y):
            t=s.t(x,y)
            if t in HAZ or t=='Water': return None
            if t in SOLID: return digc if t in MINE else None
            return 0
        q=[(0,px,py)]; best={(px,py):0}; par={(px,py):None}
        while q:
            d,x,y=heapq.heappop(q)
            if (x,y)==(tx,ty):
                out=[];c=(x,y)
                while c: out.append(c); c=par[c]
                return out[::-1]
            if d>best[(x,y)]: continue
            for dx,dy in((1,0),(-1,0),(0,1),(0,-1)):
                nx,ny=x+dx,y+dy
                if not(1<=nx<W-1 and 1<=ny<H-2): continue
                a=cc(nx,ny); b=cc(nx,ny+1)
                if a is None or b is None: continue
                nd=d+1+a+b
                if nd<best.get((nx,ny),1e9):
                    best[(nx,ny)]=nd; par[(nx,ny)]=(x,y); heapq.heappush(q,(nd,nx,ny))
        return None
    def flyto(s,tx,ty,tmax=18.0):
        s.scan(); p=s.flypath(tx,ty)
        if p is None: log('no flypath',tx,ty); return False
        log('flyto',(tx,ty),len(p),'t',s.ftime())
        i=1
        while i<len(p):
            if s.ftime()>tmax:
                log('flight out',s.pos()); s.flyland(); return False
            x,y=p[i]
            # run straight free segment
            j=i
            while j+1<len(p) and not s.solid(p[j+1][0],p[j+1][1]) and not s.solid(p[j+1][0],p[j+1][1]+1) and (p[j+1][0]==p[i][0] or p[j+1][1]==p[i][1]): j+=1
            for c in((p[i][0],p[i][1]),(p[i][0],p[i][1]+1)):
                if s.solid(*c): s.dig(*c,tries=8)
            if not s.fly(p[j][0],p[j][1]):
                log('fly stuck',p[j],s.p['x'],s.p['y'])
                return s.flyto(tx,ty,tmax) if s.ftime()<tmax else False
            i=j+1
        return True
    def cloudrun2(s,want,tmax=12.5):
        while s.ftime()<tmax and s.count('Cloud_Stone')<want:
            s.scan(); seg=s.segs()
            px=s.p['x'];py=s.p['y']
            seg.sort(key=lambda q:(abs(q[1]-px)+abs(q[0]-py)-q[4]*6))
            if not seg: break
            T,x0,x1,n,o=seg[0]
            near0=abs(x0-px)<=abs(x1-px)
            xs=list(range(x0,x1+1)) if near0 else list(range(x1,x0-1,-1))
            log('seg',T,x0,x1,n,o,'t',s.ftime())
            s.flyto(xs[0]-(1 if near0 else -1),T,tmax=tmax)
            s.tunnel(xs,T,want,tmax=tmax)
    def skychop(s):
        s.scan()
        for gx,by in((94,78),(104,76),(107,76)):
            if s.t(gx,by)=='Wood':
                s.flyto(gx+1,by-1,tmax=19); s.dig(gx,by,tries=8); s.a(62)
                s.fly(gx,by-1); s.fly(gx-1,by-1); s.fly(gx+1,by-1)
        log('logs',s.count('Wood_Log'))
    def smeltcollect(s):
        s.flyto(96,77,tmax=19.5) if s.ftime()<19 else None
        s.a(3,use=[97,79]); s.a(3,collect=True); s.a(2); s.st()
    def rebless(s):
        s.flyto(92,76,tmax=19.8); s.a(4); s.flightf=s.r['frame']
    def leave_sky_to(s,tx,ty):
        """from the swirl: portal -> chamber -> cave gate, still flying"""
        s.flyto(95,77,tmax=19.8); s.a(2,move='right'); s.a(7,down=True); s.a(2); log('at',s.p); s.a(3,interact=True); s.a(2)
        assert s.r['level']==0, s.p
        log('in L0 flying t',s.ftime(),s.p)
    def land(s):
        for _ in range(40):
            if s.ftime()>20.5 and s.p['grounded']: break
            oy=s.p['y']; s.a(6,down=True)
            if abs(s.p['y']-oy)<.01: 
                if s.ftime()>20.2: break
                s.a(10)
    def grab(s,names=('Cloud_Stone','Wood_Log'),x0=88,x1=112):
        """jump-collect floating drops above the sky floor"""
        for _ in range(30):
            its=[i for i in s.r['items'] if i['item'] in names and x0<=i['x']<=x1 and i['y']>=75 and i['y']<=79]
            if not its: return
            its.sort(key=lambda i:abs(i['x']-s.p['x']))
            it=its[0]; n=s.count(it['item'])
            s.walkj(it['x'],limit=30)
            s.a(1,jump=True); s.a(30); s.waitland(); s.a(2)
            if not any(i['x']==it['x'] and i['y']==it['y'] for i in s.r['items']): continue
            log('grab miss',it); s.a(1,jump=True); s.a(14,move='left'); s.a(14,move='right'); s.waitland()
            if any(i['x']==it['x'] and i['y']==it['y'] for i in s.r['items']): break
    def cloudsat(s,want):
        s.sel('Mine_Wand'); c=[]
        for y in range(74,79):
            for x in range(90,125):
                if s.t(x,y) in('Cloud','Cloud_Ore') and s.cheb(x,y)<=3: c.append((s.cheb(x,y),x,y))
        c.sort()
        for _,x,y in c:
            if s.p['mana']<6: s.a(60)
            s.a(16,mine=[x,y])
        return len(c)
    def flydeep(s,tx,ty,n=45):
        """best standable spot within n air steps (8-way) toward target"""
        from collections import deque
        s.scan(); px,py=int(s.p['x']+.4),int(s.p['y']+.2)
        def ok(x,y): return 1<=x<W-1 and 1<=y<H-2 and not s.solid(x,y) and not s.solid(x,y+1) and s.t(x,y) not in HAZ and s.t(x,y+1) not in HAZ and s.t(x,y)!='Water' and s.t(x,y+1)!='Water'
        q=deque([(px,py,0)]); par={(px,py):None}; best=None
        while q:
            x,y,d=q.popleft()
            if s.solid(x,y+2) and s.t(x,y+2) not in HAZ:
                sc=max(abs(x-tx),abs(y-ty))
                if best is None or sc<best[0]: best=(sc,x,y)
            if d>=n: continue
            for dx,dy in((1,1),(-1,1),(1,-1),(-1,-1),(0,1),(1,0),(-1,0),(0,-1)):
                nx,ny=x+dx,y+dy
                if (nx,ny) in par or not ok(nx,ny): continue
                if dx and dy and not(ok(x+dx,y) and ok(x,y+dy)): continue
                par[(nx,ny)]=(x,y); q.append((nx,ny,d+1))
        if not best: return False
        c=(best[1],best[2]); out=[]
        while c: out.append(c); c=par[c]
        out=out[::-1]; log('flydeep',best,len(out),'t',s.ftime())
        i=0
        while i<len(out)-1:
            j=min(i+6,len(out)-1)
            s.fly(*out[j]); i=j
        log('at',s.pos(),'t',s.ftime()); return True
    def skyfarm(s,want,x0=100,x1=112):
        if s.level!=3 or s.pos()[1]!=79: log('skyfarm: not on row 79',s.level,s.pos()); return False
        """stone bridge along row 80, shoot the cloud roof above it, then jump straight
        up under each floating drop.  Never leaves the bridge, so it cannot fall off."""
        for x in range(x0,x1+1):
            if s.count('Cloud_Stone')>=want: break
            if not s.solid(x+1,80): s.placeblock(x+1,80)
            for y in (79,78):
                if s.solid(x+1,y): s.dig(x+1,y,tries=8)
            s.walkx(x+1,limit=8)
            if s.pos()!=(x+1,79): log('skyfarm stuck',x,s.p); break
            c=[(s.cheb(q,y),q,y) for y in range(73,80) for q in range(x-2,x+5) if s.t(q,y) in('Cloud','Cloud_Ore') and s.cheb(q,y)<=3]
            for _,q,y in sorted(c):
                if s.p['mana']<6: s.a(60)
                s.sel('Mine_Wand'); s.a(16,mine=[q,y])
            s.pickup(x0,x+1)
        return s.count('Cloud_Stone')>=want
    def pickup(s,x0,x1,names=('Cloud_Stone','Wood_Log')):
        for _ in range(12):
            its=[i for i in s.r['items'] if i['item'] in names and x0<=i['x']<=x1 and 72<=i['y']<=79]
            if not its: return
            it=min(its,key=lambda i:abs(i['x']-s.p['x'])); n=s.count(it['item'])
            s.walkx(it['x'],limit=12); s.a(1,jump=True); s.a(28); s.waitland(); s.a(2)
            if s.count(it['item'])<=n: log('pickup miss',it,s.p['x']); return
    def hoverchop(s,gx):
        """cut the tree on grower gx from the side, in flight; drops float, so sweep them up"""
        ys=[y for y in range(70,79) if s.t(gx,y) in('Wood','Leaves')]
        if not ys: return 0
        top=min(y for y in ys if s.t(gx,y)=='Wood') if any(s.t(gx,y)=='Wood' for y in ys) else 78
        s.flyto(gx+1,top-1,tmax=19.5) 
        for y in range(top,79):
            if s.t(gx,y)=='Wood':
                s.fly(gx+1,y-1); s.sel('Pickaxe'); s.dig(gx,y,tries=8)
        return 1
    def sweep_items(s,names=('Wood_Log',),x0=86,x1=112,y0=70,y1=80):
        for _ in range(14):
            its=[i for i in s.r['items'] if i['item'] in names and x0<=i['x']<=x1 and y0<=i['y']<=y1]
            if not its or s.ftime()>17: return
            it=min(its,key=lambda i:abs(i['x']-s.p['x'])+abs(i['y']-s.p['y'])); n=s.count(it['item'])
            s.flyto(it['x'],it['y'],tmax=18)
            s.a(3)
            if s.count(it['item'])<=n:
                s.flyto(it['x'],it['y']-1,tmax=18); s.a(3)
                if s.count(it['item'])<=n: log('sweep miss',it); return
    def trench(s,want,xs,row):
        """walk a cloud row with a stone floor laid under it: dig the next cell, floor it,
        step in. Cloud drops float in the cell, so you must stand in them; a body in a
        one-wide gap falls through the sky, hence the floor first."""
        for x in xs:
            if s.count('Cloud_Stone')>=want: return True
            d=1 if x>s.pos()[0] else -1
            if not s.solid(x,row+1):
                s.sel('Stone_Block'); s.a(2,place=[x,row+1])
                if not s.solid(x,row+1): log('trench no floor',x,s.r['notes'][-1:]); return False
            for c in ((x,row),(x,row-1)):
                if s.solid(*c) and not s.dig(*c,tries=8): log('trench dig',c); return False
            s.walkx(x,limit=10); s.waitland(); s.a(2)
        return s.count('Cloud_Stone')>=want
    # ---- Garm: orbs fly 48 tiles, his fireball reaches 12, the ring warps out of anything
    def garm(s): return next((e for e in s.r['enemies'] if e['kind']=='Garm'),None)
    def airline(s,tx,ty):
        """8-way free-air path as turning points; None if out of air"""
        from collections import deque
        px,py=int(s.p['x']+.4),int(s.p['y']+.2)
        def ok(x,y): return 1<=x<W-1 and 1<=y<H-2 and not s.solid(x,y) and not s.solid(x,y+1) and s.t(x,y) not in HAZ and s.t(x,y+1) not in HAZ
        q=deque([(px,py)]); par={(px,py):None}
        while q:
            c=q.popleft()
            if c==(tx,ty):
                out=[]
                while c: out.append(c); c=par[c]
                out=out[::-1]
                return [out[i] for i in range(len(out)) if i in(0,len(out)-1) or (out[i+1][0]-out[i][0],out[i+1][1]-out[i][1])!=(out[i][0]-out[i-1][0],out[i][1]-out[i-1][1])]
            for dx,dy in((1,1),(-1,1),(1,-1),(-1,-1),(0,1),(1,0),(-1,0),(0,-1)):
                n=(c[0]+dx,c[1]+dy)
                if n in par or not ok(*n): continue
                if dx and dy and not(ok(c[0]+dx,c[1]) and ok(c[0],c[1]+dy)): continue
                par[n]=c; q.append(n)
        return None
    def warpout(s,why):
        # a worn ring leaves the inventory and is not in state: try, a refusal has ok:false and no player
        log('WARP',why,s.p,s.r['frame']); r=s.g.act(3,warp=True)
        if 'player' not in r: log('no warp',r); return None
        s.ingest(r); s.a(2); s.scan(); log('now L',s.level,s.pos())
        return 'warp'
    def garmloop(s,maxf=3000,nolos_stop=240,closeat=3.6):
        s.noguard=True; f0=s.r['frame']; nolos=0; last=None; hurt=0
        if s.r['inventory'][s.r['selected']]['item']!='Fire_Wand' if False else True: s.sel('Fire_Wand')
        while s.r['frame']-f0<maxf:
            q=s.p; s.ingest(s.g.st(max(0,int(q['x'])-60),max(0,int(q['y'])-35),121,71))  # enemies are listed only inside the view
            g=s.garm(); p=s.p
            if g is None:
                log('NO GARM',s.r['notes'][-3:]); return 'gone'
            if p['dead'] or s.r['screen']=='dead': return 'dead'
            cx,cy=p['x']+.4,p['y']+.9; gx,gy=g['x']+.8,g['y']+.9
            d=((gx-cx)**2+(gy-cy)**2)**.5
            cheb=max(abs(gx-cx),abs(gy-cy))
            if s.r.get('in_tile') in HAZ: return s.warpout('hazard')
            if p['hp']<=6:  # a bite is 6, a fireball 5
                if s.slot('Potion_Health') is not None: s.a(2,equip=s.slot('Potion_Health')); log('drink',s.p['hp'],s.count('Potion_Health')); continue
                return s.warpout('hp')
            if cheb<=closeat: return s.warpout('close')
            vx=0 if last is None else (gx-last)/6.0  # tiles per frame over the last step
            last=gx
            t=d/16; ax=gx+vx*60*t; ay=gy
            lo=s.los(cx,cy,ax,ay)
            if lo and p['mana']>=4:
                nolos=0; s.a(6,mine=[int(ax),int(ay)])
            else:
                nolos+=6; s.a(6)
                if nolos>=nolos_stop: log('no shot for',nolos,'frames',g,p); return 'nolos'
            if (s.r['frame']-f0)%60<6: log('t',s.r['frame']-f0,'G',g['x'],g['y'],g['hp'],'P',round(p['x'],1),round(p['y'],1),p['hp'],'m',round(p['mana']),'d',round(d,1),'los',lo,s.r['notes'][-1:])
        return 'time'
    def strafe(s,y=87,minflight=0.7,span=7):
        """hover on row y and sweep past him, firing down: out of fireball range, and moving
        out of each cage before it closes.  Warp before the blessing runs out."""
        s.noguard=True; s.sel('Fire_Wand'); d=1
        while s.r['flight_s']>minflight:
            q=s.p; s.ingest(s.g.st(max(0,int(q['x'])-40),max(0,int(q['y'])-25),81,51))
            g=s.garm(); p=s.p
            if g is None: log('NO GARM',s.r['notes'][-3:]); return 'gone'
            cx,cy=p['x']+.4,p['y']+.9; gx,gy=g['x']+.8,g['y']+.9
            if p['hp']<=6 and s.slot('Potion_Health') is not None: s.a(2,equip=s.slot('Potion_Health')); continue
            if p['hp']<=5: return s.warpout('hp')
            if gx-cx>span: d=1
            elif cx-gx>span: d=-1
            lo=s.los(cx,cy,gx,gy); k={'move':'right' if d>0 else 'left'}
            if p['mana']>=4: k['mine']=[int(gx),int(gy)]
            ox=p['x']; s.a(6,**k)
            if abs(s.p['x']-ox)<.05: d=-d
            if (s.r['frame']%30)<6: log('G',g['x'],g['y'],g['hp'],'P',round(p['x'],1),round(p['y'],1),p['hp'],'m',round(p['mana']),'fl',s.r['flight_s'],'los',lo)
        g=s.garm(); log('flight low',g); return s.warpout('flight low')
    def vstrafe(s,yhi=74,ylo=88,minflight=0.6):
        """climb and dive on the column with a clear line to him: a cage closes round a
        hovering player in under a second, and one that is left is abandoned."""
        s.noguard=True; s.sel('Fire_Wand'); up=False
        while s.r['flight_s']>minflight:
            q=s.p; s.ingest(s.g.st(max(0,int(q['x'])-40),max(0,int(q['y'])-30),81,61))
            g=s.garm(); p=s.p
            if g is None: log('NO GARM',s.r['notes'][-3:]); return 'gone'
            cx,cy=p['x']+.4,p['y']+.9; gx,gy=g['x']+.8,g['y']+.9
            if p['hp']<=6 and s.slot('Potion_Health') is not None: s.a(2,equip=s.slot('Potion_Health')); continue
            if p['hp']<=5: return s.warpout('hp')
            if p['y']<=yhi+.5: up=False
            elif p['y']>=ylo-.5: up=True
            best=min(range(int(gx)-5,int(gx)+6),key=lambda x:(not s.los(x+.5,cy,gx,gy),abs(x+.5-cx)))
            k={'jump':True} if up else {'down':True}
            if best+.5-cx>.3: k['move']='right'
            elif best+.5-cx<-.3: k['move']='left'
            lo=s.los(cx,cy,gx,gy)
            if p['mana']>=4: k['mine']=[int(gx),int(gy)]
            ox=p['y']; s.a(6,**k)
            if abs(s.p['y']-ox)<.05: up=not up
            if (s.r['frame']%30)<6: log('G',g['x'],g['y'],g['hp'],'P',round(p['x'],1),round(p['y'],1),p['hp'],'m',round(p['mana']),'fl',s.r['flight_s'],'los',lo)
        log('flight low',s.garm()); return s.warpout('flight low')
