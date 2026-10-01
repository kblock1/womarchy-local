#!/usr/bin/env bash
# Probe which Mesa driver backs EGL's GBM platform on a vgem render node.
# Requires: sudo modprobe vgem (creates /dev/dri/card0 + renderD128).
for cfg in \
  "" \
  "MESA_LOADER_DRIVER_OVERRIDE=kms_swrast" \
  "MESA_LOADER_DRIVER_OVERRIDE=kms_swrast GALLIUM_DRIVER=d3d12" \
  "MESA_LOADER_DRIVER_OVERRIDE=d3d12" \
  "GALLIUM_DRIVER=d3d12" \
  "MESA_LOADER_DRIVER_OVERRIDE=zink"; do
  echo "=== [$cfg]"
  env $cfg eglinfo -p gbm -B 2>&1 | grep -E "renderer|failed|error|MESA" | head -4
done
