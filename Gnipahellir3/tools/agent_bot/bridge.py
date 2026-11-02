#!/usr/bin/env python3
# Holds the one game connection; serves local clients over local TCP on 7778, one line in, one line out.
import socket, socketserver, threading, os, sys, time
HERE=os.path.dirname(os.path.abspath(__file__))
PORT=int(os.environ.get('GNIPA_BRIDGE_PORT',7778)); GAME_PORT=int(os.environ.get('GNIPA_AGENT_PORT',7777))
for _ in range(120):
    try:
        g=socket.create_connection(('127.0.0.1',GAME_PORT)); break
    except OSError: time.sleep(1)
else: sys.exit('no game')
g.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY,1)
gf=g.makefile('rb'); lock=threading.Lock()
if os.environ.get('GNIPA_AGENT_TURBO'):
    # A harness run: ticks between acts follow wall time, so there must be none.
    g.sendall(b'{"cmd":"idle","on":false}\n'); gf.readline()
print('connected',flush=True)
stop=threading.Event()
class H(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            if line.strip()==b'__quit__':
                self.wfile.write(b'bye\n'); self.wfile.flush(); stop.set(); return
            with lock:
                g.sendall(line if line.endswith(b'\n') else line+b'\n')
                r=gf.readline()
            if not r:
                print('game closed',flush=True); os._exit(1)
            self.wfile.write(r); self.wfile.flush()
class S(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads=True; allow_reuse_address=True
s=S(('127.0.0.1',PORT),H); threading.Thread(target=s.serve_forever,daemon=True).start()
stop.wait(); time.sleep(.2); g.close(); print('closed',flush=True); os._exit(0)
