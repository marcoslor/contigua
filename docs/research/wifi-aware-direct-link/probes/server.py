# Test server: mode byte 'E' = echo 64-byte frames, 'D' = discard until EOF then reply byte count.
import socket, threading, sys, time
def handle(c, a):
    try:
        m = c.recv(1)
        if m == b'E':
            while True:
                b = c.recv(64)
                if not b: break
                c.sendall(b)
        elif m == b'D':
            n, t0 = 0, time.time()
            while True:
                b = c.recv(1 << 16)
                if not b: break
                n += len(b)
            c.sendall(str(n).encode())
            print(f"discard from {a[0]}: {n} B in {time.time()-t0:.2f}s", flush=True)
    finally:
        c.close()
s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.setsockopt(socket.SOL_SOCKET, 0x1104, 1)  # SO_RECV_ANYIF: accept on restricted P2P interfaces
s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
s.bind(("::", 48111)); s.listen(8)
print("listening :48111", flush=True)
while True:
    c, a = s.accept()
    print("conn", a[0], a[3] if len(a) > 3 else "", flush=True)
    threading.Thread(target=handle, args=(c, a), daemon=True).start()
