# womarchy WSL leaf: GPU environment (replaces hardware/vulkan.sh + nvidia.sh).
# WSL exposes the host GPU as /dev/dxg; Mesa's d3d12 Gallium driver and the
# Dozen Vulkan driver (vulkan-dzn) use it through /usr/lib/wsl/lib, which WSL
# adds to the loader path itself (/etc/ld.so.conf.d/ld.wsl.conf). Arch's Mesa
# does not auto-select d3d12 (it picks llvmpipe), and does not fall back when
# GALLIUM_DRIVER=d3d12 is set without a GPU, so it is set only when /dev/dxg
# exists, at the time the environment is built:
#  - user manager: /usr/lib/systemd/user-environment-generators/60-womarchy-gpu
#    (shipped by womarchy-compat);
#  - login shells: /etc/profile.d/womarchy-gpu.sh (written here).
# MESA_D3D12_DEFAULT_ADAPTER_NAME is deliberately left unset (first adapter).
set -euo pipefail

# Earlier images set it unconditionally through environment.d.
if grep -qs '^# Managed by womarchy' /etc/environment.d/10-womarchy-gpu.conf; then
  rm -f /etc/environment.d/10-womarchy-gpu.conf
fi
[[ -x /usr/lib/systemd/user-environment-generators/60-womarchy-gpu ]] ||
  echo "warning: the 60-womarchy-gpu user environment generator is missing (womarchy-compat)" >&2

cat >/etc/profile.d/womarchy-gpu.sh <<'CONF'
# Managed by womarchy (wsl/gpu.sh). Respect values set by the caller.
# Mesa's d3d12 driver only when WSL exposes the host GPU (it does not fall back).
if [ -z "${GALLIUM_DRIVER+x}" ] && [ -e /dev/dxg ]; then
  export GALLIUM_DRIVER=d3d12
fi
export GSK_RENDERER="${GSK_RENDERER:-ngl}"
CONF
chmod 0644 /etc/profile.d/womarchy-gpu.sh
