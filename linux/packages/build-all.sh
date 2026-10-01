#!/usr/bin/env bash
# Build the womarchy packages into a local pacman repo (out/repo, repo name "womarchy").
# Run inside an Arch (WSL) build distro as a regular user with passwordless sudo.
#   build-all.sh [pkg...]      default: aquamarine hyprland mesa-womarchy womarchy-session
# Packages keep Arch's names; list [womarchy] first in pacman.conf so they take precedence.
set -euo pipefail
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}  # repo root (as seen from the build distro)
REPO=${WOMARCHY_REPO:-$ROOT/out/repo}
WORK=${WOMARCHY_WORK:-$HOME/pkgbuild}
PKGS=("${@:-aquamarine hyprland mesa-womarchy womarchy-session}")
read -r -a PKGS <<<"${PKGS[*]}"

sudo pacman -S --needed --noconfirm base-devel git >/dev/null
mkdir -p "$REPO" "$WORK"
# no -debug split packages unless asked (hyprland-debug alone is ~170 MB); user makepkg.conf is read after /etc's
if [ "${DEBUG_PKGS:-0}" = 1 ]; then OPT='OPTIONS+=(debug)'; else OPT='OPTIONS+=(!debug)'; fi
mkdir -p "$HOME/.config/pacman" && echo "$OPT" >"$HOME/.config/pacman/makepkg.conf"

build() {
  local name=$1
  echo "=== $name"
  rm -rf "$WORK/$name"
  cp -r "$ROOT/linux/packages/$name" "$WORK/$name"
  cd "$WORK/$name"
  # sources are pinned by sha256 (Mesa's .sig would need its maintainers' keys imported)
  nice -n 10 makepkg -sf --noconfirm --skippgpcheck --nocheck 2>&1 | grep -E "==>|error|ERROR" | grep -v "^  ->" || true
  local built=() f
  for f in *.pkg.tar.zst; do
    [[ $f == *-debug-* && ${DEBUG_PKGS:-0} != 1 ]] || built+=("$f")
  done
  [ -e "${built[0]}" ] || { echo "no package produced for $name"; exit 1; }
  cp -f "${built[@]}" "$REPO/"
  (cd "$REPO" && repo-add -q -R womarchy.db.tar.gz "${built[@]}")
  # later packages build against these (hyprland needs our aquamarine headers)
  sudo pacman -U --noconfirm --needed "${built[@]}" >/dev/null
  echo "built: ${built[*]}"
}

for p in "${PKGS[@]}"; do build "$p"; done
rm -f "$REPO"/*.old
ls -la "$REPO"
