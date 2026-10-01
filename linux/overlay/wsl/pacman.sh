# womarchy WSL leaf: layer WSL invariants onto Omarchy's pacman.conf.
# Omarchy (post-install/pacman.sh, `omarchy refresh pacman`, channel switches)
# rewrites /etc/pacman.conf from its template, so this is idempotent and is
# re-run from the pre-refresh-pacman and post-update hooks.
#  - IgnorePkg: WSL boots Microsoft's kernel; never pull a kernel/DKMS/firmware
#    in on -Syu. (Not linux-* as a whole: linux-api-headers is a glibc dep.)
#  - [womarchy] first, so its hyprland/aquamarine/mesa builds win over Arch's.
set -euo pipefail

CONF=/etc/pacman.conf
WOMARCHY_REPO_DIR="${WOMARCHY_REPO_DIR:-/var/cache/womarchy-repo}"
IGNORE='IgnorePkg = linux linux-lts linux-zen linux-hardened linux-headers linux-omarchy linux-omarchy-headers linux-t2* linux-ptl* linux-firmware linux-firmware-* *-dkms'

[[ -f $CONF ]] || { echo "no $CONF" >&2; exit 1; }

# IgnorePkg must live in [options]; replace any previous womarchy line.
sed -i '/^# womarchy: kernels come from WSL/d; /^IgnorePkg = linux linux-lts /d' "$CONF"
sed -i "/^\[options\]/a # womarchy: kernels come from WSL; never install them here\n$IGNORE" "$CONF"

# Drop any previous [womarchy] block (header + following lines up to the next section).
awk '
  /^# womarchy repo \(managed\)/ { next }
  /^\[womarchy\][[:space:]]*$/ { skip = 1; next }
  /^\[/ { skip = 0 }
  !skip { print }
' "$CONF" >"$CONF.womarchy.tmp"

if [[ -f $WOMARCHY_REPO_DIR/womarchy.db ]]; then
  awk -v dir="$WOMARCHY_REPO_DIR" '
    !done && /^\[core\][[:space:]]*$/ {
      print "# womarchy repo (managed): must stay first so its packages win"
      print "[womarchy]"
      print "SigLevel = Optional TrustAll"
      print "Server = file://" dir
      print "# Server = https://womarchy.example/repo/$arch   (placeholder: hosted repo TBD)"
      print ""
      done = 1
    }
    { print }
  ' "$CONF.womarchy.tmp" >"$CONF.womarchy.tmp2"
  mv -f "$CONF.womarchy.tmp2" "$CONF.womarchy.tmp"
fi

install -m 0644 "$CONF.womarchy.tmp" "$CONF"
rm -f "$CONF.womarchy.tmp"

# WSL mounts /usr/lib/modules/$(uname -r) as an overlay whose upper layer is
# VM-wide: every distro in the WSL VM sees writes to it. No package here owns a
# kernel, so kmod's depmod hook could only ever rewrite WSL's shared module
# indexes for all distros. Disable it (pacman's /etc hook dir overrides by name).
install -d -m 0755 /etc/pacman.d/hooks
ln -sfn /dev/null /etc/pacman.d/hooks/60-depmod.hook
