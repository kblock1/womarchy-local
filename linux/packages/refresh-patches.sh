#!/usr/bin/env bash
# Re-export our changes in the src/ clones as patch series (patches/) and copy them into the package dirs.
# Each patch is one logical change (grouped by file), so humans can take them upstream one at a time.
# New files must be known to git first: `git -C src/<repo> add -N <file>`.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

series() { # <repo dir> <out dir> <name> <paths...>
  local repo=$1 out=$2 name=$3
  shift 3
  git -C "$repo" diff HEAD -- "$@" >"$out/$name"
  [ -s "$out/$name" ] || { echo "empty patch: $name" >&2; exit 1; }
}

rm -f patches/aquamarine/0*.patch patches/hyprland/0*.patch
series src/aquamarine patches/aquamarine 0001-allocator-shm-allocator-for-drm-free-backends.patch \
  include/aquamarine/allocator/Allocator.hpp include/aquamarine/allocator/Shm.hpp src/allocator/Shm.cpp src/allocator/Swapchain.cpp
series src/aquamarine patches/aquamarine 0002-backend-wsl-remote-viewer-backend.patch \
  include/aquamarine/backend/Backend.hpp include/aquamarine/backend/Wsl.hpp src/backend/Backend.cpp src/backend/Wsl.cpp src/backend/wsl/wdp.h

series src/Hyprland patches/hyprland 0001-render-drm-free-mode-surfaceless-egl-and-shm-outputs.patch \
  src/render/OpenGL.cpp src/render/OpenGL.hpp src/render/Renderbuffer.cpp src/render/Renderbuffer.hpp \
  src/render/gl/GLRenderbuffer.cpp src/render/gl/GLRenderbuffer.hpp src/render/GLRenderer.cpp src/output/Monitor.cpp
series src/Hyprland patches/hyprland 0002-compositor-select-the-aquamarine-wsl-backend.patch \
  src/Compositor.cpp src/debug/HyprCtl.cpp src/helpers/SystemInfo.cpp
series src/Hyprland patches/hyprland 0003-pointer-cpu-cursor-buffers-without-dmabuf.patch \
  src/pointer/PointerManager.cpp
series src/Hyprland patches/hyprland 0004-protocols-screen-capture-without-linux-dmabuf.patch \
  src/protocols/ImageCopyCapture.cpp src/protocols/Screencopy.cpp

# nothing left out of the series
for r in aquamarine:src/aquamarine hyprland:src/Hyprland; do
  name=${r%%:*} repo=${r#*:}
  total=$(git -C "$repo" diff HEAD --stat | tail -1)
  covered=$(cat patches/"$name"/0*.patch | grep -c '^diff --git')
  files=$(git -C "$repo" diff HEAD --name-only | wc -l)
  [ "$covered" = "$files" ] || { echo "$name: $files changed files but $covered in the series" >&2; exit 1; }
  echo "$name: $total"
done

rm -f linux/packages/aquamarine/0*.patch linux/packages/hyprland/0*.patch
cp patches/aquamarine/0*.patch linux/packages/aquamarine/
cp patches/hyprland/0*.patch linux/packages/hyprland/
cp patches/mesa/0*.patch linux/packages/mesa-womarchy/
ls patches/aquamarine/0*.patch patches/hyprland/0*.patch patches/mesa/0*.patch
