# womarchy WSL leaf: GPU environment (replaces hardware/vulkan.sh + nvidia.sh).
# WSL exposes the host GPU as /dev/dxg; Mesa's d3d12 Gallium driver and the
# Dozen Vulkan driver (vulkan-dzn) use it through /usr/lib/wsl/lib, which WSL
# adds to the loader path itself (/etc/ld.so.conf.d/ld.wsl.conf). Arch's Mesa
# does not auto-select d3d12 and falls back to llvmpipe, so select it here.
# MESA_D3D12_DEFAULT_ADAPTER_NAME is deliberately left unset (first adapter).
set -euo pipefail

# systemd user manager (and so uwsm, Hyprland and every user service).
install -d -m 0755 /etc/environment.d
cat >/etc/environment.d/10-womarchy-gpu.conf <<'CONF'
# Managed by womarchy (wsl/gpu.sh)
GALLIUM_DRIVER=d3d12
# GTK4's Vulkan renderer runs on the non-conformant Dozen driver; use GL.
GSK_RENDERER=ngl
CONF

# Login shells (wsl -d <distro>) and anything started from them.
cat >/etc/profile.d/womarchy-gpu.sh <<'CONF'
# Managed by womarchy (wsl/gpu.sh). Respect values set by the caller.
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-d3d12}"
export GSK_RENDERER="${GSK_RENDERER:-ngl}"
CONF
chmod 0644 /etc/environment.d/10-womarchy-gpu.conf /etc/profile.d/womarchy-gpu.sh
