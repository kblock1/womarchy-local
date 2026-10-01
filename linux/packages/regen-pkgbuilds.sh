#!/usr/bin/env bash
# Regenerate the package directories from Arch's PKGBUILDs (ref/) plus our patches (patches/ and src/ clones).
# Bump a package's revision below whenever its patches change, so installs upgrade (pkgrel <arch>.<rev>).
set -euo pipefail
cd "$(dirname "$0")"
AQUAMARINE_REL=7 # 2: orphan timeout; 3-5: output resize on display changes; 6: page-aligned shm files; 7: patch series, synced wdp.h
HYPRLAND_REL=3 # 2: output state event logging; 3: screen capture without dmabuf
MESA_REL=1
PY=$(command -v python3 >/dev/null && python3 -c 'print(1)' >/dev/null 2>&1 && echo python3 || echo python)

bash refresh-patches.sh
$PY derive-pkgbuild.py ref/aquamarine.PKGBUILD aquamarine/PKGBUILD 'aquamarine-$pkgver' --rel $AQUAMARINE_REL \
  -- aquamarine/0*.patch
$PY derive-pkgbuild.py ref/hyprland.PKGBUILD hyprland/PKGBUILD hyprland-source --rel $HYPRLAND_REL --only hyprland \
  -- hyprland/0*.patch
$PY mesa-womarchy/make-pkgbuild.py --rel $MESA_REL ref/mesa.PKGBUILD mesa-womarchy/PKGBUILD mesa-womarchy/0*.patch
