#!/usr/bin/env bash
# Sample blocking syscalls of the running Hyprland main thread for a few seconds.
P=$(pgrep -x Hyprland | head -1)
[ -z "$P" ] && { echo "no Hyprland"; exit 1; }
sudo timeout ${1:-3} strace -tt -T -p "$P" -e trace=ioctl,epoll_wait,poll,ppoll,futex,read,write,sendto,recvfrom 2>&1 \
  | awk -F'<' '{ t=$NF; sub(/>.*/, "", t); if (t+0 > 0.02) print }' | head -40
echo "--- syscall summary"
sudo timeout 2 strace -c -p "$P" 2>&1 | head -25
