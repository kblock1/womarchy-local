# womarchy WSL leaf: Docker DNS without systemd-resolved.
# omarchy-settings ships /etc/docker/daemon.json with "dns": ["172.17.0.1"],
# which relies on resolved's DNSStubListenerExtra on the docker bridge. WSL
# keeps resolved off (masked), so containers would lose DNS: drop the key and
# let dockerd use /etc/resolv.conf (WSL-generated). Re-run by the post-update
# hook because the package may restore the file.
set -euo pipefail

f=/etc/docker/daemon.json
[[ -f $f ]] || exit 0

resolved=0
if systemctl is-enabled --quiet systemd-resolved.service 2>/dev/null; then resolved=1; fi
# In a chroot (image build) systemctl "ignores" is-active and returns 0: skip it there.
if ! systemd-detect-virt -q --chroot && [[ -d /run/systemd/system ]] &&
   systemctl is-active --quiet systemd-resolved.service; then resolved=1; fi
(( resolved )) && exit 0

if jq -e 'has("dns")' "$f" >/dev/null 2>&1; then
  tmp=$(mktemp)
  jq 'del(.dns)' "$f" >"$tmp"
  install -m 0644 "$tmp" "$f"
  rm -f "$tmp"
fi
