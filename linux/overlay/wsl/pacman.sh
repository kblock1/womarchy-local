# womarchy WSL leaf: layer WSL invariants onto Omarchy's pacman.conf.
# Omarchy (post-install/pacman.sh, `omarchy refresh pacman`, channel switches)
# rewrites /etc/pacman.conf from its template, so this is idempotent and is
# re-run from the pre-refresh-pacman and post-update hooks.
#  - IgnorePkg: WSL boots Microsoft's kernel; never pull a kernel/DKMS/firmware
#    in on -Syu. (Not linux-* as a whole: linux-api-headers is a glibc dep.)
#  - [womarchy] before [core], so its hyprland/aquamarine/mesa builds win over
#    Arch's: the hosted repo first (updates), the image's local copy as the
#    offline fallback. Fails (non-zero, message) rather than leave it out.
#  - Signatures: `SigLevel = PackageOptional DatabaseRequired` (CI signs the db
#    and every package with the womarchy key), written only after checking that
#    every key in womarchy-keyring's womarchy-trusted is in pacman's keyring and
#    locally trusted (populated first if needed). Otherwise the pre-signing
#    `Optional TrustAll` stays, with a loud warning: a system must never be left
#    unable to update.
#  - The local repo is trusted, so it must be root-owned and not
#    group/other-writable; permissions are repaired on every run.
set -euo pipefail

CONF=/etc/pacman.conf
REPO_DIR=/var/lib/womarchy/repo
OLD_REPO_DIR=/var/cache/womarchy-repo   # images built before 2026-10: moved out of /var/cache
# The hosted repo: WOMARCHY_REPO_URL from womarchy-apply-system, or from
# /etc/womarchy/config when run on its own (pre-refresh-pacman hook, OOBE).
if [[ -z ${WOMARCHY_REPO_URL:-} && -f /etc/womarchy/config ]]; then
  WOMARCHY_REPO_URL=$(sed -n 's/^WOMARCHY_REPO_URL=//p' /etc/womarchy/config | tail -n1)
fi
HOSTED=${WOMARCHY_REPO_URL:-https://github.com/sytelus/womarchy/releases/download/packages}
[[ $HOSTED =~ ^(https://[A-Za-z0-9.-]+|file://)/[A-Za-z0-9._~/%+-]*$ ]] || { echo "womarchy (wsl/pacman.sh): invalid WOMARCHY_REPO_URL '$HOSTED'" >&2; exit 1; }
IGNORE='IgnorePkg = linux linux-lts linux-zen linux-hardened linux-headers linux-omarchy linux-omarchy-headers linux-t2* linux-ptl* linux-firmware linux-firmware-* *-dkms'

SIGNED_SIGLEVEL='PackageOptional DatabaseRequired'
LEGACY_SIGLEVEL='Optional TrustAll'
TRUSTED=/usr/share/pacman/keyrings/womarchy-trusted

fail() { echo "womarchy (wsl/pacman.sh): $*" >&2; exit 1; }

# Every womarchy key (womarchy-trusted) is in pacman's keyring with full trust.
womarchy_keys_trusted() {
  local fpr validity n=0
  [[ -s $TRUSTED ]] && pacman-key -l >/dev/null 2>&1 || return 1
  while IFS=: read -r fpr _; do
    [[ $fpr =~ ^[0-9A-F]{40}$ ]] || continue
    n=$((n + 1))
    validity=$(gpg --homedir /etc/pacman.d/gnupg --no-permission-warning --batch --with-colons       --list-keys "$fpr" 2>/dev/null | awk -F: '$1 == "pub" { print $2; exit }')
    [[ $validity == [fu] ]] || return 1
  done <"$TRUSTED"
  ((n > 0))
}
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

# --- signature level ----------------------------------------------------------------------
if womarchy_keys_trusted ||
   { [[ -f /usr/share/pacman/keyrings/womarchy.gpg ]] && pacman-key -l >/dev/null 2>&1 &&
     pacman-key --populate womarchy >/dev/null 2>&1 && womarchy_keys_trusted; }; then
  siglevel=$SIGNED_SIGLEVEL
else
  siglevel=$LEGACY_SIGLEVEL
  if systemd-detect-virt -q --chroot; then
    echo "note: image build (no pacman keyring yet): [womarchy] uses 'SigLevel = $siglevel' until the first-run setup" >&2
  else
    cat >&2 <<WARN
================================================================================
WARNING (womarchy): the womarchy signing key is not in pacman's keyring, or not
trusted there, so [womarchy] keeps 'SigLevel = $siglevel' (signatures are not
enforced). To fix: sudo pacman -S womarchy-keyring && sudo pacman-key --populate womarchy
                   && sudo womarchy-apply-system --reassert
================================================================================
WARN
  fi
fi

# --- [womarchy] block, rebuilt before [core] ---------------------------------------------
tmp=$(mktemp "$CONF.womarchy.XXXXXX")
trap 'rm -f "$tmp"' EXIT
awk -v hosted="$HOSTED" -v local_dir="$REPO_DIR" -v siglevel="$siglevel" '
  /^# womarchy repo \(managed/ { next }
  /^\[womarchy\][[:space:]]*$/ { skip = 1; next }   # previous block, up to the next section
  /^\[/ { skip = 0 }
  skip { next }
  !placed && /^\[core\][[:space:]]*$/ {
    print "# womarchy repo (managed by womarchy-compat): must stay before [core] so its packages win"
    print "[womarchy]"
    print "SigLevel = " siglevel
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
