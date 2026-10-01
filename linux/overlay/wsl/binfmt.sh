# womarchy WSL leaf: ignore systemd-binfmt's exit status.
# On WSL 3.0.1 systemd-binfmt fails with "Failed to flush binfmt_misc rules:
# Read-only file system" and the distro boots "degraded", although interop and
# the registered entries work. Keep the unit, drop only the failure.
set -euo pipefail

install -d -m 0755 /etc/systemd/system/systemd-binfmt.service.d
cat >/etc/systemd/system/systemd-binfmt.service.d/10-womarchy-wsl.conf <<'CONF'
# Managed by womarchy (womarchy-apply-system: wsl/binfmt.sh)
[Service]
ExecStart=
ExecStart=-/usr/lib/systemd/systemd-binfmt
CONF
