#!/usr/bin/env python3
"""hvsocket (AF_VSOCK <-> AF_HYPERV) benchmark between a WSL2 distro and a Windows process.

Linux (server):   python3 hvsock_bench.py serve [port]
Windows (client): python hvsock_bench.py connect <vm-id> [port]

Measures: WSL->Windows bulk throughput (frame-sized writes), Windows->WSL throughput,
and 64-byte request/response round-trip latency (input-event-sized messages).
"""
import socket
import statistics
import struct
import sys
import time

PORT = 50001
FRAME = 3840 * 2160 * 4          # one 4K BGRA frame
TOTAL = 64 * FRAME               # ~2.1 GB per direction
CHUNK = 1 << 20


def recv_exact(s, n, buf=None):
    view = memoryview(buf) if buf is not None else None
    got = 0
    while got < n:
        if view is not None:
            k = s.recv_into(view[got:n] if n - got < len(view) else view, min(n - got, len(view)))
        else:
            k = len(s.recv(min(n - got, CHUNK)))
        if k == 0:
            raise ConnectionError("peer closed")
        got += k
    return got


def serve(port):
    ls = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    ls.bind((socket.VMADDR_CID_ANY, port))
    ls.listen(1)
    print(f"listening on vsock port {port}", flush=True)
    s, addr = ls.accept()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
    payload = bytes(CHUNK)
    # 1) Linux -> Windows bulk
    sent = 0
    while sent < TOTAL:
        sent += s.send(payload)
    # 2) Windows -> Linux bulk
    buf = bytearray(CHUNK)
    got = 0
    while got < TOTAL:
        k = s.recv_into(buf)
        if k == 0:
            break
        got += k
    # 3) echo 64-byte messages
    msg = bytearray(64)
    while True:
        try:
            recv_exact(s, 64, msg)
        except ConnectionError:
            break
        s.sendall(msg)
    print("server done", flush=True)


def connect(vmid, port):
    service = "%08X-FACB-11E6-BD58-64006A7986D3" % port
    s = socket.socket(socket.AF_HYPERV, socket.SOCK_STREAM, socket.HV_PROTOCOL_RAW)
    s.connect((vmid, service))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    buf = bytearray(CHUNK)
    t0 = time.perf_counter()
    got = 0
    while got < TOTAL:
        k = s.recv_into(buf)
        if k == 0:
            raise ConnectionError("closed early")
        got += k
    dt = time.perf_counter() - t0
    print(f"WSL->Windows: {got/dt/1e9:.2f} GB/s  (= {got/FRAME/dt:.0f} full 4K frames/s, {got/(FRAME/4)/dt:.0f} full 1080p frames/s)")
    payload = bytes(CHUNK)
    t0 = time.perf_counter()
    sent = 0
    while sent < TOTAL:
        sent += s.send(payload)
    dt = time.perf_counter() - t0
    print(f"Windows->WSL: {sent/dt/1e9:.2f} GB/s")
    lat = []
    msg = bytes(64)
    rbuf = bytearray(64)
    for i in range(5000):
        t = time.perf_counter()
        s.sendall(msg)
        recv_exact(s, 64, rbuf)
        lat.append((time.perf_counter() - t) * 1e6)
    lat.sort()
    print(f"64B round trip: median {statistics.median(lat):.0f} us, p99 {lat[int(len(lat)*0.99)]:.0f} us")
    s.close()


if __name__ == "__main__":
    if sys.argv[1] == "serve":
        serve(int(sys.argv[2]) if len(sys.argv) > 2 else PORT)
    else:
        connect(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else PORT)
