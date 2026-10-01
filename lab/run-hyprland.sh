#!/usr/bin/env bash
# Launch Hyprland in the lab with WSL-specific env, capture filtered logs.
# Usage: run-hyprland.sh [seconds] [extra env assignments...]
secs=${1:-20}; shift || true
cd /tmp
export GALLIUM_DRIVER=${GALLIUM_DRIVER:-d3d12}
env "$@" timeout "$secs" Hyprland 2>&1 \
  | grep -vE "^\s*$|YY|UU|xx|rr|vv|zz|cc|nn" \
  | grep -E "aquamarine|Backend|backend|drm|DRM|gbm|GBM|EGL|egl|dmabuf|llocator|render|Render|monitor|Monitor|output|terminate|what|CRIT|ERR|WARN" \
  | head -${LINES_MAX:-80}
