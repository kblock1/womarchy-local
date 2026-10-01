#!/usr/bin/env python3
"""Reproduce the frame/ack pattern outside Hyprland.
Linux (server): sends a ~150 byte FRAME, waits for a 32 byte ACK (non-blocking + select), then
                sends the next FRAME immediately. Reports ack latency percentiles.
Windows (client): recv FRAME -> send ACK, like omarchy.exe's render thread.

  Linux:   python3 hvsock_framepace.py serve PORT [N]
  Windows: python hvsock_framepace.py client VMID PORT [--sndbuf BYTES]
"""
import select, socket, statistics, struct, sys, time

FRAME = 150
ACK = 32


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError
        b += c
    return b


def serve(port, n):
    ls = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    ls.bind((socket.VMADDR_CID_ANY, port))
    ls.listen(1)
    print("listening", flush=True)
    s, _ = ls.accept()
    s.setblocking(False)
    lat = []
    for i in range(n):
        t = time.perf_counter()
        s.send(struct.pack("<I", i) + bytes(FRAME - 4))
        got = b""
        while len(got) < ACK:
            select.select([s], [], [], 1.0)
            try:
                got += s.recv(ACK - len(got))
            except BlockingIOError:
                pass
        lat.append((time.perf_counter() - t) * 1e3)
    lat.sort()
    slow = sum(1 for x in lat if x > 20)
    print(f"ack latency ms: median {statistics.median(lat):.2f} p90 {lat[int(n*0.9)]:.2f} max {lat[-1]:.1f}; >20ms: {slow}/{n}", flush=True)
    s.close()


def client(vmid, port, sndbuf):
    s = socket.socket(socket.AF_HYPERV, socket.SOCK_STREAM, socket.HV_PROTOCOL_RAW)
    if sndbuf is not None:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, sndbuf)
    s.connect((vmid, "%08X-FACB-11E6-BD58-64006A7986D3" % port))
    try:
        while True:
            recv_exact(s, FRAME)
            s.sendall(bytes(ACK))
    except (ConnectionError, OSError):
        pass


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(int(sys.argv[2]), int(sys.argv[3]) if len(sys.argv) > 3 else 200)
    else:
        sb = None
        if "--sndbuf" in sys.argv:
            sb = int(sys.argv[sys.argv.index("--sndbuf") + 1])
        client(sys.argv[2], int(sys.argv[3]), sb)
