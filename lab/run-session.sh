#!/usr/bin/env bash
# Dev stand-in for /usr/bin/womarchy-session (lab): print the handshake for omarchy.exe, mount the
# shared-memory share, and run the patched Hyprland with the wsl backend on patched Mesa.
# Env from omarchy.exe (via WSLENV): WOMARCHY_TOKEN, WOMARCHY_VSOCK_PORT, WOMARCHY_MONITORS.
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
set -u
VMID=$(wslinfo --vm-id)
echo "WOMARCHY_VMID=$VMID"

if ! mountpoint -q /mnt/wslgshm; then
  sudo mkdir -p /mnt/wslgshm && sudo mount -t virtiofs wslg /mnt/wslgshm -o dax
fi

export WOMARCHY_VM_ID=$VMID
export WOMARCHY_SHM_DIR=${WOMARCHY_SHM_DIR-/mnt/wslgshm}
export HYPRLAND_BACKEND=wsl
export WOMARCHY_TRACE=${WOMARCHY_TRACE-0}
export GALLIUM_DRIVER=d3d12
if [ -d /opt/womarchy-mesa/lib ]; then
  export LD_LIBRARY_PATH=/opt/womarchy-mesa/lib:/opt/womarchy/lib
  export __EGL_VENDOR_LIBRARY_FILENAMES=/opt/womarchy-mesa/share/glvnd/egl_vendor.d/50_mesa.json
else
  export LD_LIBRARY_PATH=/opt/womarchy/lib
fi
unset WAYLAND_DISPLAY DISPLAY
CONF=${WOMARCHY_HYPR_CONF:-$ROOT/lab/hypr-test.conf}
cd ~; mkdir -p ~/.cache/womarchy
echo "[session] starting Hyprland (log: $HOME/.cache/womarchy/hypr-session.log)" >&2
/opt/womarchy/bin/Hyprland --config "$CONF" >$HOME/.cache/womarchy/hypr-session.log 2>&1
rc=$?
cp "$(ls -td $XDG_RUNTIME_DIR/hypr/*/ 2>/dev/null | head -1)hyprland.log" $HOME/.cache/womarchy/hypr-last.log 2>/dev/null
echo "[session] Hyprland exited with $rc" >&2
exit $rc
