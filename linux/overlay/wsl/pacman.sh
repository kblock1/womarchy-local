# womarchy WSL leaf: layer WSL invariants onto Omarchy's pacman.conf.
# Omarchy (post-install/pacman.sh, `omarchy refresh pacman`, channel switches)
# rewrites /etc/pacman.conf from its template, so this is idempotent and is
# re-run from the pre-refresh-pacman and post-update hooks.
#  - IgnorePkg: WSL boots Microsoft's kernel; never pull a kernel/DKMS/firmware
#    in on -Syu. (Not linux-* as a whole: linux-api-headers is a glibc dep.)
#  - [womarchy] before [core], so its hyprland/aquamarine/mesa builds win over
#    Arch's: the hosted repo first (updates), the image's local copy as the
#    offline fallback. Fails (non-zero, message) rather than leave it out.
#  - The local repo is trusted (SigLevel TrustAll), so it must be root-owned and
#    not group/other-writable; permissions are repaired on every run.
set -euo pipefail

CONF=/etc/pacman.conf
REPO_DIR=/var/lib/womarchy/repo
OLD_REPO_DIR=/var/cache/womarchy-repo   # images built before 2026-10: moved out of /var/cache
HOSTED=https://github.com/sytelus/womarchy/releases/download/repo
IGNORE='IgnorePkg = linux linux-lts linux-zen linux-hardened linux-headers linux-omarchy linux-omarchy-headers linux-t2* linux-ptl* linux-firmware linux-firmware-* *-dkms'

fail() { echo "womarchy (wsl/pacman.sh): $*" >&2; exit 1; }
[[ -f $CONF ]] || fail "no $CONF"

# --- local repo: location and permissions -------------------------------------------
if [[ -f $OLD_REPO_DIR/womarchy.db && ! -e $REPO_DIR ]]; then
  install -d -m 0755 "${REPO_DIR%/*}"
  mv "$OLD_REPO_DIR" "$REPO_DIR"
fi
if [[ -d $OLD_REPO_DIR ]]; then
  rm -rf --one-file-system "$OLD_REPO_DIR"   # stale copy (old images left it world-writable)
fi
[[ -f $REPO_DIR/womarchy.db ]] ||
  fail "the local [womarchy] repo is missing ($REPO_DIR/womarchy.db); reinstall the image or restore that directory"
install -d -m 0755 -o root -g root "${REPO_DIR%/*}"
chown -R root:root "$REPO_DIR"
chmod -R u=rwX,go=rX "$REPO_DIR"
rm -f "$REPO_DIR"/*.old

# --- IgnorePkg (must live in [options]); replace any previous womarchy line ----------
sed -i '/^# womarchy: kernels come from WSL/d; /^IgnorePkg = linux linux-lts /d' "$CONF"
sed -i "/^\[options\]/a # womarchy: kernels come from WSL; never install them here\n$IGNORE" "$CONF"

# --- [womarchy] block, rebuilt before [core] ---------------------------------------------
tmp=$(mktemp "$CONF.womarchy.XXXXXX")
trap 'rm -f "$tmp"' EXIT
awk -v hosted="$HOSTED" -v local_dir="$REPO_DIR" '
  /^# womarchy repo \(managed/ { next }
  /^\[womarchy\][[:space:]]*$/ { skip = 1; next }   # previous block, up to the next section
  /^\[/ { skip = 0 }
  skip { next }
  !placed && /^\[core\][[:space:]]*$/ {
    print "# womarchy repo (managed by womarchy-compat): must stay before [core] so its packages win"
    print "[womarchy]"
    print "SigLevel = Optional TrustAll"
    print "Server = " hosted
    print "Server = file://" local_dir
    print ""
    placed = 1
  }
  { print }
  END { exit !placed }
' "$CONF" >"$tmp" || fail "no [core] section in $CONF: cannot place [womarchy] before it"

first=$(grep -v '^\[options\]' "$tmp" | grep -m1 -E '^\[[A-Za-z0-9_-]+\]' || true)
[[ $first == "[womarchy]" ]] || fail "[womarchy] would not be the first repository (first is '$first')"
install -m 0644 "$tmp" "$CONF"

# WSL mounts /usr/lib/modules/$(uname -r) as an overlay whose upper layer is
# VM-wide: every distro in the WSL VM sees writes to it. No package here owns a
# kernel, so kmod's depmod hook could only ever rewrite WSL's shared module
# indexes for all distros. Disable it (pacman's /etc hook dir overrides by name).
install -d -m 0755 /etc/pacman.d/hooks
ln -sfn /dev/null /etc/pacman.d/hooks/60-depmod.hook
