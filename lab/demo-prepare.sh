#!/bin/bash
# Prepares a throwaway distro for lab/demo-gif.ps1 (run as the desktop user). The GIF is public, so:
# fastfetch gets a user config based on Omarchy's own, without the disk module (it lists the
# Windows drives and their sizes) and with "Windows 11 + WSL <version>" instead of the distro's name.
set -euo pipefail
mkdir -p ~/.config/fastfetch
jq --arg host 'echo "Windows 11 + WSL $(wslinfo --wsl-version 2>/dev/null)"' '
  .modules |= map(
    if type == "object" and .type == "disk" then empty
    elif type == "object" and .type == "host" then {type: "command", key: .key, keyColor: .keyColor, text: $host}
    else . end)' /etc/fastfetch/config.jsonc > ~/.config/fastfetch/config.jsonc
for tool in es2gears_wayland vkcube glxinfo grim; do
  command -v "$tool" >/dev/null || { echo "missing $tool (pacman -S mesa-utils vulkan-tools)" >&2; exit 1; }
done
