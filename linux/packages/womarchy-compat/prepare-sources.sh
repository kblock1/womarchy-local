#!/bin/bash
# Pack linux/overlay into womarchy-overlay.tar.gz in the current directory: the
# local source of this PKGBUILD. build-all.sh runs it before makepkg.
#   prepare-sources.sh <womarchy repo root>
set -euo pipefail
root=${1:?usage: prepare-sources.sh <womarchy repo root>}
[[ -d $root/linux/overlay ]] || { echo "prepare-sources.sh: no $root/linux/overlay" >&2; exit 1; }
# Owner, order and mode come from here, not from the checkout (a Windows checkout
# marks every file executable; the PKGBUILD sets modes explicitly anyway).
tar -C "$root/linux" --transform 's|^overlay|womarchy-overlay|' --sort=name \
    --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' \
    -czf womarchy-overlay.tar.gz overlay
echo "packed $(tar -tzf womarchy-overlay.tar.gz | grep -vc '/$') overlay files"
