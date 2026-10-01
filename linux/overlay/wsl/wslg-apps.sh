# womarchy WSL leaf: hide the distro's desktop apps from the Windows Start menu
# (WSLg shortcuts). The desktop is the product; single apps in WSLg windows
# outside Hyprland confuse. Kept current by the 90-womarchy-wslg-apps pacman hook.
set -euo pipefail
/usr/lib/womarchy/wslg-hide-apps
