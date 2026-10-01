# womarchy WSL leaf: WSLg shared-memory share at /mnt/wslgshm (check only).
# The womarchy frame transport creates DAX-mapped files on the virtio-fs share
# tagged "wslg" that Windows opens as sections (docs/WORKLOG.md §14). The unit
# mnt-wslgshm.mount belongs to the womarchy-session package, which enables it
# statically (multi-user.target.wants; ConditionPathExists=/mnt/wslg, so it is
# skipped rather than failed without WSLg). The share root is 0777 once
# mounted, so the session user needs nothing else. Never shadow that unit here.
set -euo pipefail

# An earlier womarchy overlay wrote its own copy to /etc; it would override the
# package's unit, so remove it (only if it is ours).
if grep -qs '^# Managed by womarchy (wsl/shm-mount.sh)' /etc/systemd/system/mnt-wslgshm.mount; then
  rm -f /etc/systemd/system/mnt-wslgshm.mount /etc/systemd/system/multi-user.target.wants/mnt-wslgshm.mount
fi

if [[ ! -f /usr/lib/systemd/system/mnt-wslgshm.mount ]]; then
  echo "warning: mnt-wslgshm.mount not found; install womarchy-session for the shared-memory frame path" >&2
fi
