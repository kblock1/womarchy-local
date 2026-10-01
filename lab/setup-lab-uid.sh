#!/usr/bin/env bash
# Move the lab user off UID 1000 so its systemd user slice (user-<uid>.slice) never collides
# with other systemd distros' users on WSL <= 2.7 (shared cgroup tree). Run as root with the
# lab user logged out.
set -euo pipefail
NEWUID=${NEWUID:-1789}
U=lab
OLD=$(id -u $U)
[ "$OLD" = "$NEWUID" ] && { echo "already $NEWUID"; exit 0; }
pkill -9 -u $U || true
sleep 1
groupmod -g $NEWUID $U
usermod -u $NEWUID -g $NEWUID $U
find / -xdev \( -uid $OLD -o -gid $OLD \) -not -path "/proc/*" -print0 2>/dev/null \
  | xargs -0 -r chown -h --from=$OLD:$OLD $NEWUID:$NEWUID 2>/dev/null || true
find / -xdev -uid $OLD -not -path "/proc/*" -print0 2>/dev/null | xargs -0 -r chown -h $NEWUID 2>/dev/null || true
id $U
