"""Windows side of the DAX shared-memory spike: open the section WSLg's virtio-fs share exposes
for a file created by Linux, verify contents, measure read throughput, and write a marker back.
usage: python dax_spike_win.py <VMID> <file-name>
"""
import ctypes
import sys
import time
from ctypes import wintypes

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
k32.OpenFileMappingW.restype = wintypes.HANDLE
k32.OpenFileMappingW.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.LPCWSTR]
k32.MapViewOfFile.restype = ctypes.c_void_p
k32.MapViewOfFile.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, ctypes.c_size_t]
k32.UnmapViewOfFile.argtypes = [ctypes.c_void_p]
k32.CloseHandle.argtypes = [wintypes.HANDLE]
FILE_MAP_READ, FILE_MAP_WRITE = 0x0004, 0x0002

vmid, name = sys.argv[1], sys.argv[2]
size = 64 << 20
for prefix in ("", "Local\\", "Global\\"):
    section = f"{prefix}WSL\\{vmid}\\wslg\\{name}"
    h = k32.OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, False, section)
    print(f"OpenFileMappingW({section!r}) -> {'OK' if h else 'FAIL err=%d' % ctypes.get_last_error()}")
    if h:
        break
if not h:
    sys.exit(1)
p = k32.MapViewOfFile(h, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, size)
if not p:
    print("MapViewOfFile failed", ctypes.get_last_error())
    sys.exit(1)
head = ctypes.string_at(p, 16)
tail = ctypes.string_at(p + size - 16, 16)
print("windows sees head:", head, "tail:", tail)
buf = (ctypes.c_char * size)()
t = time.perf_counter()
for _ in range(5):
    ctypes.memmove(buf, p, size)
dt = (time.perf_counter() - t) / 5
print(f"Windows read throughput from section: {size/dt/1e9:.2f} GB/s")
ok = bytes(buf[256:512]) == bytes(range(256))
print("content pattern matches:", ok)
ctypes.memmove(p, b"WINDOWS-WROTE-IT", 16)
k32.UnmapViewOfFile(p)
k32.CloseHandle(h)
