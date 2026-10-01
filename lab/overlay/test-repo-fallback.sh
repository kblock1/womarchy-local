#!/bin/bash
# pacman with the image's [womarchy] servers (hosted first, local second): does -Sy fall back?
R=/var/tmp/womarchy-image/rootfs
d=$(mktemp -d)
awk '/^\[womarchy\]/{f=1} /^\[core\]/{f=0} f' $R/etc/pacman.conf | sed "s|file:///var/lib/womarchy/repo|file://$R/var/lib/womarchy/repo|" >$d/repo.conf
printf '[options]\nArchitecture = auto\nDBPath = %s/db\n' "$d" | cat - $d/repo.conf >$d/pacman.conf
mkdir -p $d/db; cat $d/pacman.conf
pacman --config $d/pacman.conf -Sy 2>&1; echo "pacman -Sy rc=$?"
pacman --config $d/pacman.conf -Sl womarchy | head -3
rm -rf $d
