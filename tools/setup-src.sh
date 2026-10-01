#!/usr/bin/env bash
# Recreate the working forks in src/ from the pinned upstream tags plus our patch series, on a branch
# named "womarchy" with one commit per patch (so `linux/packages/refresh-patches.sh` round-trips).
#   tools/setup-src.sh            # clones what is missing
#   FORCE=1 tools/setup-src.sh    # re-create from scratch (discards local changes in src/)
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
. patches/versions.sh
mkdir -p src

fork() { # <dir> <repo url> <tag> <patch dir>
  local dir=src/$1
  if [ -d "$dir" ] && [ "${FORCE:-0}" != 1 ]; then
    echo "$dir exists (FORCE=1 to re-create)"
    return
  fi
  rm -rf "$dir"
  git clone --quiet --branch "$3" --depth 1 "$2" "$dir"
  git -C "$dir" switch --quiet -c womarchy
  git -C "$dir" -c user.name=womarchy -c user.email=womarchy@localhost am --quiet --committer-date-is-author-date "$ROOT/$4"/0*.patch
  echo "$dir: $3 + $(ls "$ROOT/$4"/0*.patch | wc -l) patches"
}
fork aquamarine "$AQUAMARINE_REPO" "$AQUAMARINE_TAG" patches/aquamarine
fork Hyprland "$HYPRLAND_REPO" "$HYPRLAND_TAG" patches/hyprland
