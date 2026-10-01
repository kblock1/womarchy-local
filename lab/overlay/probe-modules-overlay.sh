#!/bin/bash
# Read-only: what does the VM-wide WSL modules overlay contain, and do module lookups still resolve?
d=/usr/lib/modules/$(uname -r)
echo "distro: $WSL_DISTRO_NAME"
ls -la --time-style=+%H:%M:%S "$d" | awk '{print $6, $7}' | grep -v "^ " | paste -sd' '
[[ -e $d/vmlinuz ]] && echo "vmlinuz PRESENT ($(stat -c %y "$d/vmlinuz"))" || echo "vmlinuz absent"
modprobe --dry-run --show-depends vgem 2>&1 | head -3
modprobe --dry-run --show-depends vkms 2>&1 | head -3
