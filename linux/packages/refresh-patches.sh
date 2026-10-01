#!/usr/bin/env bash
# Export the forks in src/ (one commit per logical change, on top of the upstream tag) as patch
# series in patches/, and copy all series into the package directories.
#   edit in src/<repo>, commit (or `git commit --fixup=<commit>` + autosquash), then run this
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
. patches/versions.sh

export_series() { # <fork> <upstream tag> <patch dir>
  [ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ] || { echo "$1 has uncommitted changes" >&2; exit 1; }
  rm -f "$3"/0*.patch
  git -C "$1" format-patch --quiet --zero-commit --no-signature -o "$ROOT/$3" "$2..HEAD"
}
export_series src/aquamarine "$AQUAMARINE_TAG" patches/aquamarine
export_series src/Hyprland "$HYPRLAND_TAG" patches/hyprland

for pkg in aquamarine hyprland; do
  rm -f linux/packages/$pkg/0*.patch
  cp patches/$pkg/0*.patch linux/packages/$pkg/
done
rm -f linux/packages/mesa-womarchy/0*.patch
cp patches/mesa/0*.patch linux/packages/mesa-womarchy/
ls patches/*/0*.patch
