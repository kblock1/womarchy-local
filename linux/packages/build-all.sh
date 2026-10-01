#!/usr/bin/env bash
# Build the womarchy packages into a local pacman repo (out/repo, repo name "womarchy").
# Run inside an Arch (WSL) build distro as a regular user with passwordless sudo.
#   build-all.sh [pkg...]      default: aquamarine hyprland mesa-womarchy womarchy-session
#                                       womarchy-keyring womarchy-compat
# A package directory may contain prepare-sources.sh, run in the build copy as
# `prepare-sources.sh <repo root>` before makepkg (womarchy-compat packs linux/overlay).
# arch=(any) packages compile nothing: they build with --nodeps and are not installed
# on the build host; compiled ones are installed after building (hyprland builds
# against our aquamarine).
# Packages keep Arch's names; list [womarchy] first in pacman.conf so they take precedence.
set -euo pipefail
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}  # repo root (as seen from the build distro)
REPO=${WOMARCHY_REPO:-$ROOT/out/repo}
WORK=${WOMARCHY_WORK:-$HOME/pkgbuild}
PKGS=("${@:-aquamarine hyprland mesa-womarchy womarchy-session womarchy-keyring womarchy-compat}")
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
  [[ -f $ROOT/linux/packages/$name/PKGBUILD ]] || { echo "no PKGBUILD for $name in $ROOT/linux/packages"; exit 1; }
  cp -r "$ROOT/linux/packages/$name" "$WORK/$name"
  cd "$WORK/$name"
  if [[ -f prepare-sources.sh ]]; then
    bash prepare-sources.sh "$ROOT" || { echo "prepare-sources.sh failed for $name"; exit 1; }
  fi
  local any=0 deps=(-s)
  if grep -qE '^arch=\(any\)' PKGBUILD; then any=1; deps=(--nodeps); fi
  # sources are pinned by sha256 (Mesa's .sig would need its maintainers' keys imported)
  if ! nice -n 10 makepkg --config "$CONF" "${deps[@]}" -f --noconfirm --skippgpcheck --nocheck >"$WORK/$name.log" 2>&1; then
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
  # later packages build against these (hyprland needs our aquamarine headers);
  # arch=any packages (session, keyring, compat: units and pacman hooks) stay off the build host
  if (( ! any )); then sudo pacman -U --noconfirm --needed "${built[@]}" >/dev/null; fi
  echo "built: ${built[*]}"
}

for p in "${PKGS[@]}"; do build "$p"; done
rm -f "$REPO"/*.old
ls -la "$REPO"
