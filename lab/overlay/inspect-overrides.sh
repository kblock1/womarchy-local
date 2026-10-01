#!/bin/bash
# Inspect wslg-hide-apps output in a kept image rootfs (KEEP_ROOTFS=1).
R=${1:-/var/tmp/womarchy-image/rootfs}
echo "system entries: $(ls $R/usr/share/applications/*.desktop | wc -l); overrides: $(grep -l '^# womarchy-generated' $R/usr/local/share/applications/*.desktop | wc -l)"
ls $R/usr/local/share/applications/ | paste -sd' '
echo "--- foot override head"; head -8 $R/usr/local/share/applications/foot.desktop
echo "--- entries not overridden (WSLg already skips them):"
for f in $R/usr/share/applications/*.desktop; do [[ -f $R/usr/local/share/applications/${f##*/} ]] || printf '%s ' "${f##*/}"; done; echo
echo "--- desktop-file-validate foot override"; desktop-file-validate $R/usr/local/share/applications/foot.desktop 2>&1 | head -5 || true
