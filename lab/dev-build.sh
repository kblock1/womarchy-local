#!/usr/bin/env bash
# Dev build of the patched aquamarine + Hyprland (src/ trees on the Windows side) into /opt/womarchy
# inside the lab distro. Niced so it yields CPU to anything else running on the machine.
#   dev-build.sh [aquamarine|hyprland|all] [--clean]
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}  # repo root
set -euo pipefail
PREFIX=/opt/womarchy
JOBS=${JOBS:-$(nproc)}
WHAT=${1:-all}
SRC=$ROOT/src

if [ ! -f ~/.womarchy-deps ]; then
  sudo pacman -S --needed --noconfirm cmake ninja meson rsync glaze hyprland-protocols hyprwayland-scanner xorgproto \
    glslang lua muparser re2 tomlplusplus hyprwire hyprcursor hyprgraphics hyprlang hyprutils libinput libxkbcommon \
    pango cairo pixman lcms2 xcb-util-errors xcb-util-wm xcb-util-renderutil xcb-util-image xcb-util-keysyms \
    libxcomposite libxcursor libdisplay-info seatd hwdata >/dev/null
  touch ~/.womarchy-deps
fi

sync_src() { mkdir -p ~/dev/$1; rsync -a --delete --exclude build "$SRC/$1/" ~/dev/$1/; }

build_aquamarine() {
  sync_src aquamarine
  cd ~/dev/aquamarine
  [ "${CLEAN:-0}" = 1 ] && rm -rf build
  [ -f build/build.ninja ] || cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=$PREFIX >/dev/null
  nice -n 10 cmake --build build -j"$JOBS" 2>&1 | grep -E "error|warning: unused|FAILED|Linking" | grep -v "^\s*$" || true
  sudo cmake --install build >/dev/null
  echo "aquamarine installed: $(ls $PREFIX/lib/libaquamarine.so.* | head -1)"
}

build_hyprland() {
  sync_src Hyprland
  cd ~/dev/Hyprland
  [ "${CLEAN:-0}" = 1 ] && rm -rf build
  [ -f build/build.ninja ] || PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig cmake -S . -B build -G Ninja \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_RPATH=$PREFIX/lib \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON -DNO_TESTS=ON -DBUILD_TESTING=OFF >/dev/null
  nice -n 10 cmake --build build -j"$JOBS" 2>&1 | grep -E "error|FAILED" -A3 | head -80 || true
  sudo cmake --install build >/dev/null
  echo "Hyprland installed: $($PREFIX/bin/Hyprland --version 2>/dev/null | head -1)"
}

[ "${2:-}" = "--clean" ] && CLEAN=1
case "$WHAT" in
  aquamarine) build_aquamarine ;;
  hyprland) build_hyprland ;;
  all) build_aquamarine; build_hyprland ;;
esac
