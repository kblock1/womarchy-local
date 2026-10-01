#!/usr/bin/env bash
# Helper for interactive lab sessions.
#   hyprctl-lab.sh start          -> start headless Hyprland (detached), create output
#   hyprctl-lab.sh run <cmd...>   -> run a client inside it (detached)
#   hyprctl-lab.sh shot <name>    -> grim screenshot into lab/out/<name>.png
#   hyprctl-lab.sh ctl <args...>  -> hyprctl passthrough
#   hyprctl-lab.sh stop
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
OUT=$ROOT/lab/out; mkdir -p $OUT
sig() { ls -t $XDG_RUNTIME_DIR/hypr 2>/dev/null | head -1; }
wd() { ls -t $XDG_RUNTIME_DIR | grep -E '^wayland-[0-9]+$' | head -1; }
export HYPRLAND_INSTANCE_SIGNATURE=$(sig)
case "$1" in
start)
  sudo modprobe vgem; sudo chmod 666 /dev/dri/card0 /dev/dri/renderD128
  pkill -9 Hyprland; sleep 0.5
  rm -rf $XDG_RUNTIME_DIR/hypr $XDG_RUNTIME_DIR/wayland-[0-9]*
  cd /tmp
  env -u WAYLAND_DISPLAY -u DISPLAY LD_LIBRARY_PATH=/opt/womarchy/lib \
      AQ_HEADLESS_RENDER_NODE=${NODE:-/dev/dri/card0} GALLIUM_DRIVER=${GALLIUM_DRIVER:-d3d12} \
      LIBSEAT_BACKEND=noop ${HYPR_ENV:-} setsid -f Hyprland > /tmp/hypr.log 2>&1 < /dev/null
  sleep 4
  export HYPRLAND_INSTANCE_SIGNATURE=$(sig)
  hyprctl monitors | grep -q HEADLESS- || hyprctl output create headless
  sleep 1; hyprctl monitors | grep -E "^Monitor|@"; echo "WAYLAND_DISPLAY=$(wd)"
  ;;
run)
  shift; cd /tmp
  WAYLAND_DISPLAY=$(wd) LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=d3d12 ${CLIENT_ENV:-} setsid -f "$@" > /tmp/client-$(basename $1).log 2>&1 < /dev/null
  ;;
shot)
  WAYLAND_DISPLAY=$(wd) timeout 10 grim $OUT/$2.png; echo "grim exit=$?"
  magick $OUT/$2.png -format "%wx%h mean=%[fx:mean] colors=%k\n" info: 2>/dev/null
  ;;
ctl) shift; hyprctl "$@" ;;
stop) pkill Hyprland; sleep 1; pkill -9 Hyprland; echo stopped ;;
esac
