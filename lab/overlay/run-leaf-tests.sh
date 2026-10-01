#!/bin/bash
# Runs test-leaves-in-chroot.sh inside the kept image rootfs (KEEP_ROOTFS=1 build).
R=/var/tmp/womarchy-image/rootfs
[[ -d $R/usr/lib/womarchy ]] || { echo "no kept rootfs"; exit 1; }
cp "$(dirname "$0")/test-leaves-in-chroot.sh" $R/root/t.sh
mountpoint -q $R || mount --bind $R $R
arch-chroot $R bash /root/t.sh 2>&1 | grep -v "not a mountpoint"
rm -f $R/root/t.sh
umount $R 2>/dev/null; true
