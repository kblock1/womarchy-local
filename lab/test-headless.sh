#!/usr/bin/env bash
# E1: Hyprland headless on a vgem node, GPU rendering via Mesa kms_swrast + d3d12
# (needs patched aquamarine in /opt/womarchy). Captures a frame with grim.
# Env knobs: NODE, GALLIUM_DRIVER, CLIENT_ENV (prefix for GL clients), RES, TAG, OVERLAY=1
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
set -u
OUT=$ROOT/lab/out; mkdir -p $OUT
TAG=${TAG:-${GALLIUM_DRIVER:-d3d12}}
RES=${RES:-1920x1080}
sudo modprobe vgem; sudo chmod 666 /dev/dri/card0 /dev/dri/renderD128
mkdir -p ~/.config/hypr
cat > ~/.config/hypr/hyprland.conf <<CONF
monitor = , ${RES}@60, 0x0, 1
misc {
    disable_hyprland_logo = true
    disable_splash_rendering = true
}
debug {
    disable_logs = false
    enable_stdout_logs = true
    overlay = ${OVERLAY:-0}
}
decoration {
    rounding = 10
    blur {
        enabled = true
        size = 8
        passes = 3
    }
}
general {
    col.active_border = rgb(ff0000) rgb(00ff00) 45deg
    border_size = 4
}
CONF
unset WAYLAND_DISPLAY DISPLAY
export LD_LIBRARY_PATH=/opt/womarchy/lib AQ_HEADLESS_RENDER_NODE=${NODE:-/dev/dri/card0} \
       GALLIUM_DRIVER=${GALLIUM_DRIVER:-d3d12} LIBSEAT_BACKEND=noop
cd /tmp; rm -f /tmp/hypr.log /tmp/client-*.log
setsid Hyprland > /tmp/hypr.log 2>&1 < /dev/null &
HP=$!
sleep 4
export HYPRLAND_INSTANCE_SIGNATURE=$(ls -t $XDG_RUNTIME_DIR/hypr | head -1)
WD=$(ls $XDG_RUNTIME_DIR | grep -E '^wayland-[0-9]+$' | head -1); echo "socket=$WD"
hyprctl monitors | grep -q HEADLESS- || { hyprctl output create headless >/dev/null; sleep 1; }
hyprctl monitors | grep -E "^Monitor|@" | head -4
run_client() { # name cmd...
  local n=$1; shift
  (cd /tmp; WAYLAND_DISPLAY=$WD timeout 20 env ${CLIENT_ENV:-} "$@" > /tmp/client-$n.log 2>&1 < /dev/null; echo "exit=$?" >> /tmp/client-$n.log) &
}
run_client gears es2gears_wayland
run_client foot foot
run_client vkcube vkcube --wsi wayland
sleep 6
WAYLAND_DISPLAY=$WD timeout 10 grim $OUT/headless-$TAG.png && echo "grim ok"
magick $OUT/headless-$TAG.png -format "%wx%h mean=%[fx:mean] colors=%k\n" info: 2>/dev/null
hyprctl clients | grep -E "^Window|class:" | head -10
for f in /tmp/client-*.log; do echo "--- $f"; tail -4 $f; done
kill $HP 2>/dev/null; sleep 2; kill -9 -$HP 2>/dev/null; pkill -9 -f es2gears_wayland; pkill -9 foot; pkill -9 vkcube
echo "--- hyprland errors"
grep -vE "XCursor|Supports Format|with modifier|Supported extensions" /tmp/hypr.log | grep -E "ERR|CRIT|Renderer:|Using: OpenGL" | grep -viE "xwayland|hyprcursor|drm: |DRM Backend|Wayland backend|wayland\) could not|Implementation wayland" | sort | uniq -c | sort -rn | head -20
exit 0
