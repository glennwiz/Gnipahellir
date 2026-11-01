import sys,heapq,time,os,json
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
        s.items={}
        s.scan()
    def ingest(s,r):
        if not r.get('ok'):
            log('ERR',r); return
        s.r=r; v=r['view']; L=v['legend']
        for j,row in enumerate(v['rows']):
            for i,c in enumerate(row):
                s.m[v['y']+j][v['x']+i]=L[c]
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
        if s.inhaz(): s.flee()
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
            if not s.reach(x,y) and not (s.slot('Mine_Wand') is not None and s.p['mana']>=45 and s.cheb(x,y)<=3): 
                log('noreach',(x,y),'from',s.p['x'],s.p['y']); return False
            mw=None
            if s.slot('Mine_Wand') is not None and s.p['mana']>=45 and s.cheb(x,y)<=3:
                s.sel('Mine_Wand'); s.a(16,mine=[x,y])
            else:
                if not s.sel('Pickaxe'): s.a(1,select=-1)
                s.a(17,mine=[x,y])
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
            if a is not None and b is not None:
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
        for _ in range(maxrepl):
            if abs(s.pos()[0]-tx)<=near and abs(s.pos()[1]-ty)<=near: return True
            pth=s.path(tx,ty,digok,blocks,near)
            if pth is None:
                log('nopath',s.pos(),(tx,ty)); return False
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
        t0=time.time(); drop={'Cloud':'Cloud_Stone','Cloud_Ore':'Cloud_Stone','Stone':'Stone_Block'}
        bad=set()
        while time.time()-t0<maxsec:
            names=[n for n,c in want.items() if s.count(drop.get(n,n))<c]
            if not names: return True
            x0,y0,x1,y1=box; px,py=s.pos(); c=[]
            for y in range(y0,y1+1):
                for x in range(x0,x1+1):
                    if s.m[y][x] in names and (x,y) not in bad and not s.nearhaz(x,y) and not (136<=x<=151 and 92<=y<=97):
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
            ox,oy=s.p['x'],s.p['y']
            s.a(f,**k)
            if abs(s.p['x']-ox)+abs(s.p['y']-oy)<.01:
                stuck=getattr(s,'_st',0)+1; s._st=stuck
                if stuck>4: s._st=0; return False
                fy=s.p['y']%1; fx=s.p['x']%1
                if fy>.6: s.a(2,down=True)
                elif fy>.03 and fy<=.6 and 'jump' not in k and 'down' not in k: s.a(1,jump=True)
                if fx>.21 and fx<.6: s.a(1,move='left')
                elif fx>=.6: s.a(1,move='right')
        return False
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
