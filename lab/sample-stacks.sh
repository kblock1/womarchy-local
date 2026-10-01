#!/usr/bin/env bash
# Poor man's profiler: sample the Hyprland main thread (and es2gears) stacks N times.
N=${1:-15}
P=$(pgrep -x Hyprland | head -1); G=$(pgrep -f es2gears_wayland | head -1)
for i in $(seq 1 $N); do
  echo "=== sample $i"
  sudo gdb -p "$P" -batch -ex "thread 1" -ex "bt 12" 2>/dev/null | grep -E "^#" | sed -E 's/^#[0-9]+ +0x[0-9a-f]+ in //; s/ \(.*//' | head -8 | tr '\n' '<' ; echo
  [ -n "$G" ] && { echo -n "   gears: "; sudo gdb -p "$G" -batch -ex "thread 1" -ex "bt 10" 2>/dev/null | grep -E "^#" | sed -E 's/^#[0-9]+ +0x[0-9a-f]+ in //; s/ \(.*//' | head -7 | tr '\n' '<'; echo; }
  sleep 0.13
done
