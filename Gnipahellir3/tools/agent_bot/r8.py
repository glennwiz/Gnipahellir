# run 8: crew helpers
from b import *
def crew(b):
    c=b.r.get('crew',{}); return c
def cshow(b,tag=''):
    c=crew(b); log(tag,'f',b.r['frame'],'zone',c.get('zone'),'mon',c.get('monument'),[(g['slot'],g['status'],round(g['x'],1),round(g['y'],1),g['hp'],g['mode'],g['job']) for g in c.get('golems',[])])
def say(b,t): b.g.raw({'cmd':'say','text':t[:96]})
def look(b,x,y,w,h):
    r=b.g.st(x,y,w,h); b.ingest(r); show(r); return r
def items_all(b):
    r=b.g.st(0,0,W,H); b.ingest(r)
    tot={}
    for i in r['items']: tot[i['item']]=tot.get(i['item'],0)+i['count']
    return tot,r['items']
def zcount(b,z):
    x0,y0,x1,y1=z; c={}
    for y in range(y0,y1+1):
        for x in range(x0,x1+1): c[b.m[y][x]]=c.get(b.m[y][x],0)+1
    return c
def watchc(b,frames,step=60,z=None,every=1,tag=''):
    n=0; hist=[]
    while n<frames:
        b.a(step); n+=step
        if (n//step)%every==0:
            if z: b.ingest(b.g.st(z[0]-6,z[1]-6,z[2]-z[0]+13,z[3]-z[1]+13))
            g=[(q['slot'],q['status'][0],round(q['x'],1),round(q['y'],1),q['hp'],q['mode'][0],q['job']) for q in crew(b).get('golems',[])]
            log(tag,'f',b.r['frame'],'p',b.pos(),'hp',b.p['hp'],g, zcount(b,z) if z else '', 'en',[(e['kind'],int(e['x']),int(e['y'])) for e in b.r['enemies']][:4])
            hist.append((b.r['frame'],g))
    return hist
