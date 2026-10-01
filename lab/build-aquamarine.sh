#!/usr/bin/env bash
# Build patched aquamarine (matching the system version) into /opt/womarchy for LD_LIBRARY_PATH testing.
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
set -euo pipefail
VER=${AQ_VER:-v0.15.1}
sudo pacman -S --noconfirm --needed cmake ninja hyprwayland-scanner hyprutils libdisplay-info libinput seatd pixman hwdata wayland-protocols >/dev/null
mkdir -p ~/src && cd ~/src
[ -d aquamarine ] || git clone -q --branch "$VER" --depth 1 https://github.com/hyprwm/aquamarine.git
cd aquamarine
git checkout -q -- . 
for p in $ROOT/patches/aquamarine/*.patch; do echo "applying $p"; git apply "$p"; done
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=/opt/womarchy >/dev/null
cmake --build build -j"$(nproc)" 2>&1 | tail -3
sudo cmake --install build >/dev/null && ls /opt/womarchy/lib*/libaquamarine*
