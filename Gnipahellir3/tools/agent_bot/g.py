import socket, json, os, time, sys
HERE=os.path.dirname(os.path.abspath(__file__))
class G:
    def __init__(s):
        s.c=socket.create_connection(('127.0.0.1',7778)); s.f=s.c.makefile('rb')
    def raw(s,o):
        s.c.sendall((json.dumps(o)+'\n').encode()); r=s.f.readline()
        return json.loads(r)
    def st(s,x=None,y=None,w=None,h=None):
        o={'cmd':'state'}
        for k,v in (('x',x),('y',y),('w',w),('h',h)):
            if v is not None:o[k]=v
        return s.raw(o)
    def act(s,frames=1,**k):
        return s.raw({'cmd':'act','frames':frames,**k})
    def plan(s,*acts):
        # What the player does while you think. Send it last, about 15 ticks per second of thinking.
        return s.raw({'cmd':'plan','acts':list(acts)})
    def goal(s,goal=None,step=None,failed=False):
        o={'cmd':'objective'}
        if goal is not None: o['goal']=goal
        if step is not None: o['step']=step
        if failed: o['result']='failed'
        return s.raw(o)
def show(r):
    v=r['view']; print('v',v['x'],v['y'],v['w'],v['h'],v['legend'])
    for i,row in enumerate(v['rows']): print('%3d %s'%(v['y']+i,row))
def brief(r):
    p=r['player']; print('f',r['frame'],r['screen'],'L',r['level'],'p',p['x'],p['y'],'hp',p['hp'],p['hp_max'],'gnd',p['grounded'],'sel',r['selected'],[ (i['slot'],i['item'],i['count']) for i in r['inventory']],'craft',r['craftable'],'en',r['enemies'][:6],'items',r['items'][:8])
