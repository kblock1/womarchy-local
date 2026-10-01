#!/bin/bash
# Build the Omarchy-on-WSL image: out/Omarchy-<omarchy-version>-womarchy-<date>[-lite].wsl
#
# Run as root inside the womarchy-build distro (see README.md):
#   wsl -d womarchy-build -u root -e bash <repo>/linux/image/build-image.sh
# Environment:
#   LITE=1           skip Omarchy's heavy preinstalled apps (LibreOffice, Kdenlive, OBS, ...)
#   OUT=<dir>        output dir (default <repo>/out); womarchy packages are read from $OUT/repo
#   WORK=<dir>       scratch on a Linux filesystem (default /var/tmp/womarchy-image)
#   CACHE=<dir>      persistent package cache (default /var/cache/womarchy-pkg)
#   KEEP_ROOTFS=1    keep $WORK/rootfs after packing (for inspection)
#   XZ_LEVEL=6       xz preset
#
# Steps: build womarchy-compat -> stage the [womarchy] repo (lead's out/repo +
# womarchy-compat) -> trust Omarchy's signing key (pinned fingerprint) ->
# pacstrap from Omarchy's frozen stable Arch snapshot + [omarchy] with
# [womarchy] first -> womarchy-apply-system in the chroot -> WSL config ->
# scrub machine-specific state -> tar | xz.
set -euo pipefail
export TZ=UTC LC_ALL=C.UTF-8
umask 022

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUT=${OUT:-$REPO/out}
WORK=${WORK:-/var/tmp/womarchy-image}
CACHE=${CACHE:-/var/cache/womarchy-pkg}
LITE=${LITE:-0}
XZ_LEVEL=${XZ_LEVEL:-6}
ROOTFS=$WORK/rootfs
STAGE_REPO=$WORK/repo
BUILD_DATE=$(date -u +%Y%m%d)

OMARCHY_KEY=40DFB630FF42BCFFB047046CF0134EE680CAC571   # omarchy-keyring signing key (docs/research/01-omarchy.md §2.1)
ARCH_MIRROR='https://stable-mirror.omarchy.org/$repo/os/$arch'   # Omarchy's frozen Arch snapshot (stable channel)
OMARCHY_SERVERS=('https://pkgs.omarchy.org/stable/$arch' 'https://stable-mirror.omarchy.org/$repo/os/$arch')

# From install/omarchy-base.packages: hardware, networking and boot pieces WSL
# provides or does not have (research §3.1, §10.4). NetworkManager/resolved are
# replaced by WSL networking; Windows owns printers, Bluetooth, power, displays.
DROP=(asdcontrol avahi bluez bluez-tools bluez-utils bolt brightnessctl cups cups-filters
      cups-pk-helper ddcutil gnome-disk-utility gvfs-mtp kernel-modules-hook networkmanager
      nss-mdns power-profiles-daemon qemu-user-static-binfmt system-config-printer tzupdate
      wireless-regdb)
# LITE: the apps `omarchy-remove-preinstalls` drops (+ pinta's .NET runtime).
LITE_DROP=(aether cliamp libreoffice-fresh xournalpp pinta dotnet-runtime obsidian obs-studio
           kdenlive moonlight-qt lazydocker omacut omacalc omawrite)
# What the ISO/archinstall adds around the Omarchy packages, WSL flavour:
# PipeWire (archinstall audio), Mesa d3d12 + Dozen Vulkan (instead of vendor
# GPU drivers), eglinfo for GPU checks, and omarchy-other.packages' generic bits.
EXTRA=(base-devel sudo noto-fonts   # noto-fonts first, so it (not gnu-free-fonts) provides ttf-font
       pipewire pipewire-alsa pipewire-jack pipewire-pulse gst-plugin-pipewire libpulse wireplumber
       mesa vulkan-dzn vulkan-icd-loader mesa-utils xorg-xwayland
       qt6-wayland gtk4-layer-shell webp-pixbuf-loader)

log() { printf '\n\e[1;34m==> %s\e[0m\n' "$*"; }
die() { printf '\e[1;31merror:\e[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root (inside the womarchy-build distro)"
for c in pacstrap arch-chroot makepkg repo-add repo-remove bsdtar jq xz curl gpg runuser; do
  command -v "$c" >/dev/null || die "missing $c (run linux/image/setup-build-distro.sh)"
done
id builder &>/dev/null || die "missing user 'builder' (run linux/image/setup-build-distro.sh)"

unmount_rootfs() {
  local m
  for m in $(findmnt -rn -o TARGET | grep "^$ROOTFS" | sort -r); do umount -l "$m" 2>/dev/null || true; done
}
trap unmount_rootfs EXIT

mkdir -p "$WORK" "$CACHE" "$OUT"
unmount_rootfs
rm -rf "$ROOTFS" "$STAGE_REPO" "$WORK/pkg"
mkdir -p "$ROOTFS" "$STAGE_REPO" "$WORK/pkg"

# --- 1. womarchy-compat ------------------------------------------------------------
log "Building womarchy-compat"
pkgsrc=$WORK/pkg/womarchy-compat
mkdir -p "$pkgsrc"
cp "$REPO/linux/packages/womarchy-compat/PKGBUILD" "$pkgsrc/"
tar -C "$REPO/linux" --transform 's|^overlay|womarchy-overlay|' --owner=0 --group=0 \
    -czf "$pkgsrc/womarchy-overlay.tar.gz" overlay
chown -R builder: "$pkgsrc"
runuser -u builder -- env -C "$pkgsrc" PKGDEST="$pkgsrc" SRCDEST="$pkgsrc" BUILDDIR="$pkgsrc/build" \
  nice -n 10 makepkg -f --nodeps --noconfirm --noprogressbar >/dev/null
compat_pkg=$(ls "$pkgsrc"/womarchy-compat-*.pkg.tar.zst | head -n1)
[[ -f $compat_pkg ]] || die "womarchy-compat did not build"

# --- 2. [womarchy] repo: the lead's out/repo (compositor + Mesa builds) + compat ---
log "Staging the [womarchy] repo"
if [[ -f $OUT/repo/womarchy.db.tar.gz ]]; then
  cp -a "$OUT/repo/." "$STAGE_REPO/"     # cp keeps epoch file names ("mesa-1:26...")
  # Debug packages never go in the image; drop them from the staged copy only.
  mapfile -t dbg < <(bsdtar -tf "$STAGE_REPO/womarchy.db.tar.gz" | sed -n 's|^\([^/]*-debug\)-[^-/]*-[^-/]*/$|\1|p' | sort -u)
  ((${#dbg[@]})) && repo-remove -q "$STAGE_REPO/womarchy.db.tar.gz" "${dbg[@]}"
  rm -f "$STAGE_REPO"/*-debug-*.pkg.tar.*
else
  echo "no $OUT/repo: [womarchy] will carry womarchy-compat only (stock Arch hyprland/mesa)"
fi
cp "$compat_pkg" "$STAGE_REPO/"
repo-add -q "$STAGE_REPO/womarchy.db.tar.gz" "$STAGE_REPO/$(basename "$compat_pkg")"
# pacman needs the plain .db/.files names; repo-add makes symlinks, which drvfs copies may have lost
for n in db files; do
  [[ -e $STAGE_REPO/womarchy.$n ]] || ln -sf "womarchy.$n.tar.gz" "$STAGE_REPO/womarchy.$n"
done
echo "womarchy repo: $(bsdtar -tf "$STAGE_REPO/womarchy.db.tar.gz" | grep -c '/$') packages"

# --- 3. trust Omarchy's packaging key on the build host (pinned fingerprint) -------
if ! pacman-key --list-keys "$OMARCHY_KEY" &>/dev/null; then
  log "Bootstrapping omarchy-keyring on the build host"
  kr=$WORK/keyring; rm -rf "$kr"; mkdir -p "$kr"
  curl -fsSL -o "$kr/omarchy.db" "https://pkgs.omarchy.org/stable/x86_64/omarchy.db"
  desc=$(bsdtar -xOf "$kr/omarchy.db" 'omarchy-keyring-*/desc')
  file=$(awk '/^%FILENAME%$/ {getline; print}' <<<"$desc")
  sum=$(awk '/^%SHA256SUM%$/ {getline; print}' <<<"$desc")
  curl -fsSL -o "$kr/$file" "https://pkgs.omarchy.org/stable/x86_64/$file"
  echo "$sum  $kr/$file" | sha256sum -c - >/dev/null || die "omarchy-keyring checksum mismatch"
  # The package is only trusted if it carries exactly the pinned key.
  bsdtar -xOf "$kr/$file" 'usr/share/pacman/keyrings/omarchy.gpg' |
    gpg --show-keys --with-colons 2>/dev/null | grep -q "^fpr:::::::::$OMARCHY_KEY:" ||
    die "omarchy-keyring does not contain the pinned key $OMARCHY_KEY"
  pacman -U --noconfirm "$kr/$file" >/dev/null
  pacman-key --populate omarchy >/dev/null
  pacman-key --list-keys "$OMARCHY_KEY" >/dev/null || die "Omarchy key not trusted after bootstrap"
fi

# --- 4. pacstrap ---------------------------------------------------------------------
conf=$WORK/pacman.conf
{
  echo "[options]"
  echo "Architecture = auto"
  echo "SigLevel = Required DatabaseOptional"
  echo "LocalFileSigLevel = Optional"
  echo "ParallelDownloads = 5"
  echo "CacheDir = $CACHE/"
  echo
  echo "# [womarchy] first: its hyprland/aquamarine/mesa builds replace Arch's."
  echo "[womarchy]"
  echo "SigLevel = Optional TrustAll"
  echo "Server = file://$STAGE_REPO"
  for r in core extra multilib; do printf '\n[%s]\nServer = %s\n' "$r" "$ARCH_MIRROR"; done
  printf '\n[omarchy]\n'
  for s in "${OMARCHY_SERVERS[@]}"; do echo "Server = $s"; done
} >"$conf"

# Omarchy's pacman guard hook only lets `omarchy update` do system upgrades.
export OMARCHY_ALLOW_DIRECT_PACMAN=1

session=()
bsdtar -tf "$STAGE_REPO/womarchy.db.tar.gz" | grep -q '^womarchy-session-' && session=(womarchy-session)

log "pacstrap (1/2): base + Omarchy + womarchy"
nice -n 10 pacstrap -C "$conf" -c -G -M "$ROOTFS" \
  base omarchy-keyring omarchy-settings omarchy-nvim womarchy-compat omarchy "${session[@]}" "${EXTRA[@]}"

omarchy_version=$(pacman -r "$ROOTFS" -Q omarchy | awk '{print $2}')
omarchy_version=${omarchy_version%-*}
base_list=$ROOTFS/usr/share/omarchy/install/omarchy-base.packages
[[ -f $base_list ]] || die "missing $base_list"
drop=("${DROP[@]}")
(( LITE )) && drop+=("${LITE_DROP[@]}")
mapfile -t base_pkgs < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$base_list" |
  grep -vxF -f <(printf '%s\n' "${drop[@]}"))

log "pacstrap (2/2): ${#base_pkgs[@]} of Omarchy's base packages (profile: $( ((LITE)) && echo lite || echo full))"
nice -n 10 pacstrap -C "$conf" -c -G -M "$ROOTFS" --needed "${base_pkgs[@]}"

# --- 5. configure the system -----------------------------------------------------------
log "Configuring the image"
install -m 0644 "$HERE/rootfs/etc/wsl.conf" "$ROOTFS/etc/wsl.conf"
install -m 0644 "$HERE/rootfs/etc/wsl-distribution.conf" "$ROOTFS/etc/wsl-distribution.conf"
install -d "$ROOTFS/etc/womarchy"
cat >"$ROOTFS/etc/womarchy/profile" <<EOF
WOMARCHY_PROFILE=$( ((LITE)) && echo lite || echo full)
OMARCHY_VERSION=$omarchy_version
WOMARCHY_BUILD_DATE=$BUILD_DATE
EOF

# The installed system's [womarchy] repo (hosted URL to follow; see wsl/pacman.sh).
install -d "$ROOTFS/var/cache/womarchy-repo"
cp -a "$STAGE_REPO/." "$ROOTFS/var/cache/womarchy-repo/"

log "womarchy-apply-system in the chroot"
mountpoint -q "$ROOTFS" || mount --bind "$ROOTFS" "$ROOTFS"   # arch-chroot wants a mountpoint
arch-chroot "$ROOTFS" env OMARCHY_LOG_TO_STDOUT=1 OMARCHY_MIRROR=stable OMARCHY_ALLOW_DIRECT_PACMAN=1 \
  WOMARCHY_XKB_LAYOUT=us WOMARCHY_LOCALE=en_US.UTF-8 \
  womarchy-apply-system --defer-provisioning --first-install

# Sanity: the things the image must have.
grep -q '^\[womarchy\]' "$ROOTFS/etc/pacman.conf" || die "[womarchy] missing from pacman.conf"
[[ -L $ROOTFS/etc/systemd/system/NetworkManager.service || ! -f $ROOTFS/usr/lib/systemd/system/NetworkManager.service ]] ||
  die "NetworkManager not masked"
installed=$(pacman -r "$ROOTFS" -Qq)
for p in omarchy omarchy-settings womarchy-compat mesa vulkan-dzn pipewire-pulse wireplumber; do
  grep -qx "$p" <<<"$installed" || die "package $p not installed"
done
for p in limine snapper linux; do
  pacman -r "$ROOTFS" -Qi "$p" 2>/dev/null | grep -q '^Name *: '"$p"'$' && die "$p must not be installed"
done

# --- 6. scrub machine-specific state (archlinux-wsl recipe) ------------------------------
log "Scrubbing"
rm -rf "$ROOTFS/etc/pacman.d/gnupg"            # never ship a private key; OOBE runs pacman-key --init
rm -f "$ROOTFS/etc/machine-id" "$ROOTFS/var/lib/dbus/machine-id" "$ROOTFS/etc/hostname"
rm -f "$ROOTFS/etc/resolv.conf"                # WSL generates it
# Sync DBs are kept: they describe exactly the frozen Omarchy snapshot the image
# was built from (no partial-upgrade risk), and without them every pacman call
# warns "database file ... does not exist" until the first `omarchy update`.
rm -rf "$ROOTFS"/var/cache/pacman/pkg/* "$ROOTFS"/var/log/journal/*
rm -rf "$ROOTFS"/root/* "$ROOTFS"/root/.[!.]* "$ROOTFS"/tmp/* "$ROOTFS"/var/tmp/*
find "$ROOTFS/etc" -name '*.pacnew' -print

# --- 7. pack ------------------------------------------------------------------------------
suffix=$( ((LITE)) && echo -lite || true)
name="Omarchy-${omarchy_version}-womarchy-${BUILD_DATE}${suffix}.wsl"
unmount_rootfs
log "Packing $OUT/$name"
tar --numeric-owner --xattrs --xattrs-include='*' --acls --sort=name \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    -C "$ROOTFS" -c . |
  nice -n 10 xz -T0 -"$XZ_LEVEL" >"$OUT/$name.part"
mv -f "$OUT/$name.part" "$OUT/$name"
(cd "$OUT" && sha256sum "$name" >"$name.sha256")

du -sh --apparent-size "$ROOTFS" | awk '{print "rootfs: " $1}'
ls -la "$OUT/$name"
(( ${KEEP_ROOTFS:-0} )) || rm -rf "$ROOTFS"
echo "$OUT/$name"
