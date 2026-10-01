#!/usr/bin/env bash
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
cd /tmp && cc -O2 $ROOT/lab/gbmtest.c -o gbmtest -lgbm -lEGL -lGLESv2 -ldrm $(pkg-config --cflags libdrm) || exit 1
for node in ${NODES:-/dev/dri/card0}; do
for d in ${DRIVERS:-llvmpipe d3d12}; do
  echo "===== GALLIUM_DRIVER=$d $node"
  GALLIUM_DRIVER=$d ./gbmtest $node 2>&1; echo "exit=$?"
done; done
