#!/bin/bash
# Read-only probe of WSL facts relevant to the image (run in womarchy-build).
echo "--- virtiofs tags"; for d in /sys/fs/virtiofs/*; do [[ -e $d/tag ]] && echo "$d: $(cat $d/tag)"; done; ls /sys/fs/virtiofs 2>&1 | head
echo "--- /mnt/wslg"; ls -la /mnt/wslg | head -20
echo "--- mounts"; grep -E "wslg|virtiofs|/usr/lib/modules|/usr/lib/wsl" /proc/mounts
echo "--- ld.so.conf.d"; ls -la /etc/ld.so.conf.d/; cat /etc/ld.so.conf.d/*wsl* 2>/dev/null
echo "--- virt"; systemd-detect-virt; systemd-detect-virt --vm; systemd-detect-virt --container
echo "--- uname"; uname -r; ls /usr/lib/modules 2>&1
echo "--- system state"; systemctl is-system-running; systemctl --failed --no-legend
echo "--- env"; env | grep -E "PULSE|WAYLAND|DISPLAY|XDG|WSL" | sort
echo "--- masked"; ls -la /etc/systemd/system | grep null
echo "--- wsl.conf"; cat /etc/wsl.conf; cat /etc/wsl-distribution.conf
