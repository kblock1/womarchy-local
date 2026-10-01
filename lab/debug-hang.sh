#!/usr/bin/env bash
# Start headless Hyprland, create output, then dump all thread stacks to find hangs.
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
L=$ROOT/lab/hyprctl-lab.sh
sudo pacman -S --noconfirm --needed gdb debuginfod >/dev/null 2>&1
bash $L start
sleep 3
P=$(pgrep -x Hyprland); echo "pid=$P"
ps -o pid,stat,pcpu,etime,wchan:30,comm -p $P
sudo DEBUGINFOD_URLS=https://debuginfod.archlinux.org gdb -p $P -batch -ex "set debuginfod enabled on" -ex "set pagination off" -ex "thread apply all bt 20" 2>/dev/null | grep -E "^#|^Thread" | grep -vE "libc.so|libstdc|in ?? () from /usr/lib/wsl" | cut -c1-240 | head -90
bash $L stop
