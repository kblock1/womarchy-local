#!/usr/bin/env bash
# Build Mesa (matching the system version) with womarchy patches into /opt/womarchy-mesa (lab only).
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
set -euo pipefail
VER=${MESA_VER:-26.2.3}
sudo pacman -S --noconfirm --needed meson ninja directx-headers python-mako python-packaging python-yaml glslang libdrm wayland wayland-protocols libx11 libxext libxfixes libxshmfence libxxf86vm libxrandr libxcb libglvnd byacc flex bison >/dev/null
mkdir -p ~/src && cd ~/src
[ -f mesa-$VER.tar.xz ] || curl -sLo mesa-$VER.tar.xz https://archive.mesa3d.org/mesa-$VER.tar.xz
if [ "${CLEAN:-0}" = 1 ] || [ ! -f mesa-$VER/.womarchy-patched ]; then
  rm -rf mesa-$VER && tar xJf mesa-$VER.tar.xz
  cd mesa-$VER
  for p in $ROOT/patches/mesa/*.patch; do echo "applying $p"; patch -p1 -s < "$p"; done
  touch .womarchy-patched
else
  cd mesa-$VER
fi
[ -d build ] || meson setup build --prefix=/opt/womarchy-mesa --buildtype=release \
  -Dgallium-drivers=d3d12,softpipe -Dvulkan-drivers= -Dplatforms=wayland,x11 \
  -Degl=enabled -Dgles2=enabled -Dgbm=enabled -Dglx=dri -Dllvm=disabled -Dglvnd=enabled \
  -Dgallium-va=disabled -Dvideo-codecs= -Dmicrosoft-clc=disabled -Dspirv-to-dxil=false \
  -Dvalgrind=disabled -Dlibunwind=disabled -Dbuild-tests=false >/dev/null
nice -n 10 ninja -C build 2>&1 | tail -1
sudo ninja -C build install >/dev/null && echo "installed to /opt/womarchy-mesa"
