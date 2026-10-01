#!/bin/bash
# Query Omarchy stable repo metadata with a throwaway pacman DB (no host changes).
set -euo pipefail
W=/var/tmp/womarchy-probe
mkdir -p $W/db
cat > $W/pacman.conf <<'C'
[options]
Architecture = auto
SigLevel = Never
DBPath = /var/tmp/womarchy-probe/db
[core]
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
[extra]
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
[multilib]
Server = https://stable-mirror.omarchy.org/$repo/os/$arch
[omarchy]
Server = https://pkgs.omarchy.org/stable/$arch
C
pacman --config $W/pacman.conf --dbpath $W/db -Sy >/dev/null
for p in omarchy omarchy-settings omarchy-keyring omarchy-nvim quickshell hyprland mesa owe limine-mkinitcpio-hook limine-snapper-sync; do
  echo "=== $p"; pacman --config $W/pacman.conf --dbpath $W/db -Si $p 2>&1 | grep -E "^(Repository|Version|Depends On|Provides|Conflicts With)" || true
done
