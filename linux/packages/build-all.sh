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
# Our own makepkg config: the system one plus "no -debug split packages unless asked" (hyprland-debug
# alone is ~170 MB). Passed with --config, so the user's ~/.config/pacman/makepkg.conf is left alone.
CONF=$WORK/makepkg.conf
{
  echo 'source /etc/makepkg.conf'
  echo 'for c in /etc/makepkg.conf.d/*.conf; do [ -r "$c" ] && source "$c"; done'
  if [ "${DEBUG_PKGS:-0}" = 1 ]; then echo 'OPTIONS+=(debug)'; else echo 'OPTIONS+=(!debug)'; fi
} >"$CONF"

build() {
  local name=$1
  echo "=== $name"
  rm -rf "$WORK/$name"
  cp -r "$ROOT/linux/packages/$name" "$WORK/$name"
  cd "$WORK/$name"
  # sources are pinned by sha256 (Mesa's .sig would need its maintainers' keys imported)
  if ! nice -n 10 makepkg --config "$CONF" -sf --noconfirm --skippgpcheck --nocheck >"$WORK/$name.log" 2>&1; then
    tail -n 40 "$WORK/$name.log"
    echo "makepkg failed for $name (full log: $WORK/$name.log)"
    exit 1
  fi
  grep -E "^==> (Making|Finished|WARNING)" "$WORK/$name.log" || true
  local built=() f
  for f in *.pkg.tar.zst; do
    [[ $f == *-debug-* && ${DEBUG_PKGS:-0} != 1 ]] && continue
    # No ':' (package epochs, e.g. mesa-1:26...) in file names: GitHub release assets and Windows file
    # names can't have one. pacman downloads whatever file name the repo database records.
    if [[ $f == *:* ]]; then mv -- "$f" "${f//:/.}"; f=${f//:/.}; fi
    built+=("$f")
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
