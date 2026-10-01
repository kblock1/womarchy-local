#!/usr/bin/env bash
# P0.5: can a user distro use WSLg's section-backed virtio-fs share (tag "wslg", DAX) as
# zero-copy shared memory with a Windows process? Run as root in the lab distro.
#   dax-spike.sh mount   -> mount at /mnt/wslgshm, create + fill a test file
#   dax-spike.sh check   -> print first/last bytes as Linux sees them (after Windows wrote)
#   dax-spike.sh clean   -> remove test file, unmount
set -u
MNT=/mnt/wslgshm
F=$MNT/womarchy-spike-$(cat /proc/sys/kernel/random/boot_id | cut -c1-8)
case "$1" in
mount)
  mkdir -p $MNT
  mountpoint -q $MNT || mount -t virtiofs wslg $MNT -o dax || { echo "MOUNT FAILED"; exit 1; }
  findmnt $MNT
  ls -la $MNT | head
  python3 - "$F" <<'EOF'
import mmap, os, sys, time
f = sys.argv[1]
size = 64 << 20
fd = os.open(f, os.O_RDWR | os.O_CREAT, 0o666)
os.ftruncate(fd, size)
m = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)
m[0:16] = b"WOMARCHY-DAX-OK!"
m[size-16:size] = b"END-OF-64MB-FILE"
t = time.perf_counter()
blob = bytes(range(256)) * (size // 256)
m[:] = blob
m[0:16] = b"WOMARCHY-DAX-OK!"
m[size-16:size] = b"END-OF-64MB-FILE"
dt = time.perf_counter() - t
print(f"created {f} ({size>>20} MB); Linux write throughput into DAX mapping: {size/dt/1e9:.2f} GB/s")
m.flush(); m.close(); os.close(fd)
EOF
  echo "NAME=$(basename $F)"
  ;;
check)
  python3 - "$F" <<'EOF'
import mmap, os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
m = mmap.mmap(fd, 0, mmap.MAP_SHARED, mmap.PROT_READ)
print("linux sees head:", m[0:16], "tail:", m[len(m)-16:])
EOF
  ;;
clean)
  rm -f $MNT/womarchy-spike-*
  umount $MNT && echo unmounted
  ;;
esac
