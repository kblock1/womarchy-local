#!/bin/bash
# One-time setup of the womarchy-build distro (official Arch WSL image), run as root:
#   wsl -d womarchy-build -u root -e bash <repo>/linux/image/setup-build-distro.sh
# Idempotent. Creates the unprivileged "builder" user (UID 1790) that makepkg needs.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# The Arch image's OOBE (pacman-key init) is skipped by `--no-launch`.
if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg && ! -s /etc/pacman.d/gnupg/pubring.kbx ]]; then
  pacman-key --init
  pacman-key --populate archlinux
fi

# WSL 3.0.1: systemd-binfmt exits 1 ("Failed to flush binfmt_misc rules") and the
# distro boots "degraded". Ignore its exit status (same fix the image ships).
install -d /etc/systemd/system/systemd-binfmt.service.d
cat >/etc/systemd/system/systemd-binfmt.service.d/10-womarchy-wsl.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/lib/systemd/systemd-binfmt
EOF

nice -n 10 pacman -Syu --noconfirm --needed \
  arch-install-scripts base-devel git jq xz zstd python devtools

# makepkg refuses to run as root; UID 1790 avoids colliding with any other distro's users.
if ! id builder &>/dev/null; then
  useradd -m -u 1790 -U -s /bin/bash builder
fi
echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/10-builder
chmod 440 /etc/sudoers.d/10-builder

sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen >/dev/null
echo "womarchy-build ready: $(pacman -Q pacman arch-install-scripts | tr '\n' ' ')"
