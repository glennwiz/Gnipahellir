#!/usr/bin/env python3
# Holds the one game connection; serves local clients over a unix socket, one line in, one line out.
import socket, socketserver, threading, os, sys, time
HERE=os.path.dirname(os.path.abspath(__file__)); PORT=7778
for _ in range(120):
    try:
        g=socket.create_connection(('127.0.0.1',7777)); break
    except OSError: time.sleep(1)
else: sys.exit('no game')
g.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY,1)
gf=g.makefile('rb'); lock=threading.Lock()
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
