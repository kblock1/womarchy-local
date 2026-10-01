#!/usr/bin/env bash
# Reproduce the headless first-frame hang and symbolize the main thread's libgallium frames offline.
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
L=$ROOT/lab/hyprctl-lab.sh
export DEBUGINFOD_URLS=https://debuginfod.archlinux.org
LIB=$(ls /usr/lib/libgallium-*.so)
DBG=$(debuginfod-find debuginfo "$LIB" 2>/dev/null); echo "debug file: $DBG"
bash $L start >/dev/null 2>&1
sleep 3
P=$(pgrep -x Hyprland); echo "pid=$P"
BASE=$(sudo grep -m1 "$(basename $LIB)" /proc/$P/maps | cut -d- -f1)
sudo gdb -p $P -batch -ex "thread 1" -ex "bt 20" 2>/dev/null | grep -E "^#" | grep libgallium \
 | sed -E 's/^#([0-9]+) +0x([0-9a-f]+).*/\1 \2/' | while read n a; do
   off=$(printf "0x%x" $((0x$a - 0x$BASE)))
   echo "#$n $off $(addr2line -f -C -i -e "${DBG:-$LIB}" $off | paste -sd' ' | cut -c1-200)"
 done
bash $L stop >/dev/null 2>&1
