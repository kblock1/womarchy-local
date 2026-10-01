#!/bin/bash
# In-session recorder for lab/demo-gif.ps1 (run as the desktop user): once the Omarchy session is up,
# take a grim screenshot of the desktop every ~100 ms into /tmp/womarchy-demo/frame-<unix ms>.png,
# until /tmp/womarchy-demo/stop exists (or 4 minutes pass).
#
# Recording inside the session shows exactly what the compositor drew, and keeps working when Windows
# isn't showing it (a locked screen, monitors asleep).
set -u
out=/tmp/womarchy-demo
rm -rf "$out"
mkdir -p "$out"

# wait for this desktop's compositor (not WSLg's wayland-0)
for _ in $(seq 1 240); do
  eval "$(systemctl --user show-environment | grep -E '^(WAYLAND_DISPLAY|XDG_RUNTIME_DIR)=' | sed 's/^/export /')"
  [[ ${WAYLAND_DISPLAY:-} == wayland-[1-9]* ]] && break
  sleep 0.5
done
[[ ${WAYLAND_DISPLAY:-} == wayland-[1-9]* ]] || { echo "no Omarchy session appeared" >&2; exit 1; }

deadline=$((SECONDS + 240))
while [[ ! -e $out/stop ]] && ((SECONDS < deadline)); do
  grim -l 1 "$out/frame-$(date +%s%3N).png" 2>/dev/null
  sleep 0.1
done
echo "recorded $(ls "$out" | grep -c '^frame-') frames"
