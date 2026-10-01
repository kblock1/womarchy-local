#!/bin/bash
R=/var/tmp/womarchy-image/rootfs
cp "$(dirname "$0")/test-oobe-in-chroot.sh" $R/root/t.sh
mountpoint -q $R || mount --bind $R $R
arch-chroot $R bash /root/t.sh 2>&1 | grep -v "not a mountpoint"
rm -f $R/root/t.sh; umount $R 2>/dev/null; true
