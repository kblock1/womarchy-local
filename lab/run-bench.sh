#!/usr/bin/env bash
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
cd /tmp && cc -O2 $ROOT/lab/bench-readback.c -o bench-readback -lEGL -lGLESv2 || exit 1
for d in ${DRIVERS:-d3d12 llvmpipe}; do echo "=== GALLIUM_DRIVER=$d (EGL surfaceless, no DRM node)"; GALLIUM_DRIVER=$d timeout 300 ./bench-readback 2>&1 | grep -v "^MESA"; done
