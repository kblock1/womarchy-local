# womarchy WSL leaf: replaces install/config/enable-services.sh.
# WSL owns networking (eth0, /etc/resolv.conf, DNS tunnelling) and there is no
# seat, printer, Bluetooth adapter, battery or display manager to serve. Masks
# follow Microsoft's custom-distro guidance and the archlinux-wsl image.
set -euo pipefail

# Kept from upstream. docker.socket is socket-activated (costs nothing until
# used); set WOMARCHY_DOCKER=0 when Docker Desktop's WSL integration is used.
if [[ ${WOMARCHY_DOCKER:-1} == 1 ]] && [[ -f /usr/lib/systemd/system/docker.socket ]]; then
  systemctl enable docker.socket
fi
# systemd-oomd needs PSI + cgroup v2, both present in the WSL kernel.
systemctl enable systemd-oomd.service 2>/dev/null || true

# Services that fight WSL or have nothing to manage. Masked (not just disabled)
# so Omarchy migrations re-enabling them cannot start them.
mask=(
  NetworkManager.service NetworkManager-wait-online.service NetworkManager-dispatcher.service
  systemd-resolved.service
  systemd-networkd.service systemd-networkd.socket systemd-networkd-wait-online.service
  iwd.service wpa_supplicant.service
  sddm.service plymouth-start.service plymouth-quit.service plymouth-quit-wait.service
  cups.service cups.socket cups.path cups-browsed.service
  avahi-daemon.service avahi-daemon.socket
  power-profiles-daemon.service bluetooth.service
  linux-modules-cleanup.service
  snapper-timeline.timer snapper-cleanup.timer limine-snapper-sync.service
  ufw.service
  # Same as the official Arch WSL image (WSL provides the consoles and first boot).
  # tmpfiles/tmp.mount stay enabled there and work, so they stay enabled here.
  console-getty.service systemd-firstboot.service
)
[[ ${WOMARCHY_FIREWALL:-0} == 1 ]] && mask=("${mask[@]/ufw.service}")

for unit in "${mask[@]}"; do
  [[ -n $unit ]] || continue
  # `systemctl mask` refuses units that have a real file in /etc; those are ours to keep.
  [[ -e /etc/systemd/system/$unit && ! -L /etc/systemd/system/$unit ]] && continue
  ln -sfn /dev/null "/etc/systemd/system/$unit"
done

# Shared Hyper-V consoles: getty templates fail in WSL (microsoft/WSL#13595).
ln -sfn /dev/null /etc/systemd/system/getty@.service
ln -sfn /dev/null /etc/systemd/system/serial-getty@.service
