#!/usr/bin/env python3
"""DAX spike v2 (run as root in the lab): create a file on WSLg's section-backed virtio-fs share
the way WSLg's Weston does (O_CREAT|O_EXCL + fallocate + mmap MAP_SHARED), keep it open, and wait
so a Windows process can open it as a named section. Also measures write throughput.
usage: dax-spike2.py <seconds-to-hold>
"""
import ctypes, ctypes.util, mmap, os, subprocess, sys, time

MNT = "/mnt/wslgshm"
os.makedirs(MNT, exist_ok=True)
if subprocess.run(["mountpoint", "-q", MNT]).returncode != 0:
    r = subprocess.run(["mount", "-t", "virtiofs", "wslg", MNT, "-o", "dax"], capture_output=True, text=True)
    print("mount:", r.returncode, r.stderr.strip())
print(subprocess.run(["findmnt", MNT], capture_output=True, text=True).stdout.strip())

libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
name = "womarchy-spike-%d" % os.getpid()
path = f"{MNT}/{name}"
size = 64 << 20
fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
rc = libc.fallocate(fd, 0, ctypes.c_long(0), ctypes.c_long(size))
print("fallocate rc", rc, os.strerror(ctypes.get_errno()) if rc else "")
st = os.fstat(fd)
print("st_size", st.st_size)
m = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
blob = bytes(range(256)) * (size // 256)
t = time.perf_counter()
m[:] = blob
dt = time.perf_counter() - t
m[0:16] = b"WOMARCHY-DAX-OK!"
m[size - 16:size] = b"END-OF-64MB-FILE"
print(f"Linux write into DAX mapping (first touch): {size / dt / 1e9:.2f} GB/s")
for i in range(3):
    t = time.perf_counter(); m[:] = blob; dt = time.perf_counter() - t
    print(f"Linux write into DAX mapping (pass {i+2}): {size / dt / 1e9:.2f} GB/s")
t = time.perf_counter(); _ = m[:]; dt = time.perf_counter() - t
print(f"Linux read from DAX mapping: {size / dt / 1e9:.2f} GB/s")
print("NAME=" + name, flush=True)
hold = float(sys.argv[1]) if len(sys.argv) > 1 else 20
deadline = time.time() + hold
while time.time() < deadline:
    if m[0:16] == b"WINDOWS-WROTE-IT":
        print("Linux sees the Windows write: coherent both ways", flush=True)
        break
    time.sleep(0.2)
else:
    print("Linux did not see a Windows write; head =", m[0:16], flush=True)
m.close()
os.close(fd)
print("exists after close:", os.path.exists(path))
try:
    os.unlink(path)
except FileNotFoundError:
    print("unlink: already gone")
print("cleaned up", flush=True)
