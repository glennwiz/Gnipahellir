# Late game, kept from run 3. Assumes the sky base, chamber altars and Jade Ring.
# Run one phase: python3 late.py rebless | cave3 | strafe | vstrafe | perch X Y
from fast import *

def rebless(b):
    """Top up flight at the sky swirl: hop left into it until flight is above 15 s."""
    assert b.r["level"]==3,"rebless: not in the sky"; b.flightf=b.r["frame"]-int((20-b.r["flight_s"])*60)
    for i in range(8):
        b.a(1,jump=True,move='left'); b.a(10,move='left'); b.a(3)
        if b.r['flight_s']>15: break
        b.waitland()
    b.flyto(92,76,tmax=19.8); b.a(3); b.flightf=b.r['frame']; log('flight',b.r['flight_s'])

def cave3(b):
    """Sky to cave 3 on one blessing: drop, then 8-way airline, arrives with about 11 s."""
    b.leave_sky_to(0,0); b.fly(144,93); b.a(2); b.a(3,interact=True); b.a(1); b.scan(); assert b.level==1,b.level
    b.noguard=True
    if not b.flyall(b.airline(180,101)): return False
    b.a(1)
    for i in range(6):
        if b.p['y']+.9>=102: break
        b.a(1,down=True)
    b.a(3,interact=True); b.a(1); b.scan(); assert b.level==2,b.level
    log('L2',b.r['flight_s'],b.garm()); return True

def to_garm(b,y=87):
    g=b.garm(); return b.flyall(b.airline(int(g['x']),y))

if __name__=='__main__':
    b=B(); b.a(1); b.lasthp=b.p['hp']; c=sys.argv[1]
    if c=='rebless': rebless(b)
    elif c=='cave3': log(cave3(b))
    elif c=='strafe':
        if cave3(b) and to_garm(b): log(b.strafe(),b.garm(),b.p)
    elif c=='vstrafe':
        if cave3(b) and b.flyall(b.airline(165,80)): log(b.vstrafe(),b.garm(),b.p)
    elif c=='perch':
        if cave3(b) and b.flyall(b.airline(int(sys.argv[2]),int(sys.argv[3]))):
            b.waitland(); b.a(1); b.scan(); log(b.garmloop(maxf=1800,nolos_stop=420,closeat=0),b.garm(),b.p)
