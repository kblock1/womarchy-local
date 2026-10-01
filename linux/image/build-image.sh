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
#   ALLOW_STOCK_PACKAGES=1  build even if $OUT/repo lacks womarchy-session, aquamarine,
#                    hyprland or mesa (the image then gets stock Arch builds; not a product image)
#
# Steps: build womarchy-compat -> stage the [womarchy] repo ($OUT/repo +
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
ALLOW_STOCK_PACKAGES=${ALLOW_STOCK_PACKAGES:-0}
ROOTFS=$WORK/rootfs
STAGE_REPO=$WORK/repo
IMAGE_REPO=/var/lib/womarchy/repo   # the installed system's local [womarchy] repo (see wsl/pacman.sh)
BUILD_DATE=$(date -u +%Y%m%d)

source "$HERE/omarchy-key.env"      # OMARCHY_KEY_FPR (pinned omarchy-keyring key)
ARCH_MIRROR='https://stable-mirror.omarchy.org/$repo/os/$arch'   # Omarchy's frozen Arch snapshot (stable channel)
OMARCHY_SERVERS=('https://pkgs.omarchy.org/stable/$arch' 'https://stable-mirror.omarchy.org/$repo/os/$arch')
# Packages that must come from $OUT/repo (DRM-free compositor, patched Mesa, session).
REQUIRED_WOMARCHY=(womarchy-session aquamarine hyprland mesa)

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
for c in pacstrap arch-chroot makepkg repo-add repo-remove bsdtar jq xz curl gpg runuser findmnt; do
  command -v "$c" >/dev/null || die "missing $c (run linux/image/setup-build-distro.sh)"
done
id builder &>/dev/null || die "missing user 'builder' (run linux/image/setup-build-distro.sh)"
[[ $ROOTFS == /*/* && $ROOTFS != *..* ]] || die "refusing odd ROOTFS path '$ROOTFS'"

# Mounts at or below $ROOTFS (pacstrap/arch-chroot bind /dev, /proc, /sys, /run there).
rootfs_mounts() { findmnt -rn -o TARGET | awk -v r="$ROOTFS" '$0 == r || index($0, r "/") == 1'; }
unmount_rootfs() {
  local m
  for m in $(rootfs_mounts | sort -r); do umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true; done
}
# A /dev bind left under $ROOTFS would make `rm -rf` delete the device nodes every
# distro in the WSL VM shares: never delete while anything is still mounted there.
remove_rootfs() {
  unmount_rootfs
  local left
  left=$(rootfs_mounts)
  [[ -z $left ]] || die "still mounted under $ROOTFS, not deleting: $(paste -sd' ' <<<"$left")"
  rm -rf --one-file-system "$ROOTFS"
}
trap unmount_rootfs EXIT

# Owned by root, no group/other write: the [womarchy] repo is trusted (TrustAll)
# and comes first, so a writable copy would let any user plant packages for root.
lock_down() {
  chown -R root:root "$1"
  chmod -R u=rwX,go=rX "$1"
  rm -f "$1"/*.old
}

mkdir -p "$WORK" "$CACHE" "$OUT"
remove_rootfs
rm -rf --one-file-system "$STAGE_REPO" "$WORK/pkg"
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
compat_pkgs=("$pkgsrc"/womarchy-compat-*.pkg.tar.zst)
[[ -f ${compat_pkgs[0]} ]] || die "womarchy-compat did not build"
compat_pkg=${compat_pkgs[0]}

# --- 2. [womarchy] repo: $OUT/repo (compositor + Mesa builds + session) + compat ---
log "Staging the [womarchy] repo"
if [[ -f $OUT/repo/womarchy.db.tar.gz ]]; then
  # --no-preserve: a drvfs (/mnt/d) copy would otherwise carry 0777 modes.
  cp -r --no-preserve=mode,ownership "$OUT/repo/." "$STAGE_REPO/"
  # Debug packages never go in the image; drop them from the staged copy only.
  # Packages are identified by name in the db and their files by the db's
  # %FILENAME% (file names need not follow name-version: epochs are renamed).
  mapfile -t dbg < <(bsdtar -tf "$STAGE_REPO/womarchy.db.tar.gz" | sed -n 's|^\([^/]*-debug\)-[^-/]*-[^-/]*/$|\1|p' | sort -u)
  if ((${#dbg[@]})); then
    mapfile -t dbg_files < <(bsdtar -xOf "$STAGE_REPO/womarchy.db.tar.gz" '*-debug-*/desc' | awk '/^%FILENAME%$/ { getline; print }')
    repo-remove -q "$STAGE_REPO/womarchy.db.tar.gz" "${dbg[@]}"
    for f in "${dbg_files[@]}"; do rm -f "$STAGE_REPO/$f" "$STAGE_REPO/$f.sig"; done
  fi
else
  echo "no $OUT/repo/womarchy.db.tar.gz"
fi
cp "$compat_pkg" "$STAGE_REPO/"
repo-add -q "$STAGE_REPO/womarchy.db.tar.gz" "$STAGE_REPO/$(basename "$compat_pkg")"
# pacman needs the plain .db/.files names; repo-add makes symlinks, which drvfs copies may have lost
for n in db files; do
  [[ -e $STAGE_REPO/womarchy.$n ]] || ln -sf "womarchy.$n.tar.gz" "$STAGE_REPO/womarchy.$n"
done
lock_down "$STAGE_REPO"

# Repo contents, read once into a variable (no `| grep -q` under pipefail: an early
# grep exit SIGPIPEs the producer and the test silently fails).
repo_listing=$(bsdtar -tf "$STAGE_REPO/womarchy.db.tar.gz")
repo_version() { sed -n "s|^$1-\([^-/]*-[^-/]*\)/\$|\1|p" <<<"$repo_listing"; }
echo "womarchy repo: $(grep -c '/$' <<<"$repo_listing") packages"
# Every package the db lists must have its file (%FILENAME%) in the repo.
repo_files=$(bsdtar -xOf "$STAGE_REPO/womarchy.db.tar.gz" '*/desc' | awk '/^%FILENAME%$/ { getline; print }')
while IFS= read -r f; do
  [[ -z $f || -f $STAGE_REPO/$f ]] || die "the womarchy db lists $f, but the file is not in the repo"
done <<<"$repo_files"
missing=()
for p in "${REQUIRED_WOMARCHY[@]}"; do [[ -n $(repo_version "$p") ]] || missing+=("$p"); done
if ((${#missing[@]})); then
  (( ALLOW_STOCK_PACKAGES )) || die "$OUT/repo lacks ${missing[*]} (set ALLOW_STOCK_PACKAGES=1 to build with stock Arch packages)"
  echo "warning: building without womarchy ${missing[*]} (ALLOW_STOCK_PACKAGES=1)" >&2
fi

# --- 3. trust Omarchy's packaging key on the build host (pinned fingerprint) -------
if ! pacman-key --list-keys "$OMARCHY_KEY_FPR" &>/dev/null; then
  log "Bootstrapping omarchy-keyring on the build host"
  kr=$WORK/keyring; rm -rf --one-file-system "$kr"; mkdir -p "$kr"
  curl -fsSL -o "$kr/omarchy.db" "https://pkgs.omarchy.org/stable/x86_64/omarchy.db"
  desc=$(bsdtar -xOf "$kr/omarchy.db" 'omarchy-keyring-*/desc')
  file=$(awk '/^%FILENAME%$/ {getline; print}' <<<"$desc")
  sum=$(awk '/^%SHA256SUM%$/ {getline; print}' <<<"$desc")
  curl -fsSL -o "$kr/$file" "https://pkgs.omarchy.org/stable/x86_64/$file"
  echo "$sum  $kr/$file" | sha256sum -c - >/dev/null || die "omarchy-keyring checksum mismatch"
  # Trust the package only if it carries exactly the pinned key: the set of
  # primary-key fingerprints in omarchy.gpg and the set in omarchy-trusted must
  # both equal {OMARCHY_KEY_FPR} (no extra keys that `--populate` would lsign).
  bsdtar -xOf "$kr/$file" 'usr/share/pacman/keyrings/omarchy.gpg' >"$kr/omarchy.gpg"
  bsdtar -xOf "$kr/$file" 'usr/share/pacman/keyrings/omarchy-trusted' >"$kr/omarchy-trusted"
  primaries=$(gpg --show-keys --with-colons "$kr/omarchy.gpg" 2>/dev/null |
    awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }' | sort -u)
  trusted=$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$kr/omarchy-trusted" | cut -d: -f1 | sort -u)
  [[ $primaries == "$OMARCHY_KEY_FPR" ]] || die "omarchy.gpg keys are {${primaries//$'\n'/,}}, expected exactly $OMARCHY_KEY_FPR"
  [[ $trusted == "$OMARCHY_KEY_FPR" ]] || die "omarchy-trusted lists {${trusted//$'\n'/,}}, expected exactly $OMARCHY_KEY_FPR"
  pacman -U --noconfirm "$kr/$file" >/dev/null
  pacman-key --populate omarchy >/dev/null
  pacman-key --list-keys "$OMARCHY_KEY_FPR" >/dev/null || die "Omarchy key not trusted after bootstrap"
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
[[ -n $(repo_version womarchy-session) ]] && session=(womarchy-session)

log "pacstrap (1/2): base + Omarchy + womarchy"
nice -n 10 pacstrap -C "$conf" -c -G -M "$ROOTFS" \
  base omarchy-keyring omarchy-settings omarchy-nvim womarchy-compat omarchy "${session[@]}" "${EXTRA[@]}"

omarchy_version=$(pacman -r "$ROOTFS" -Q omarchy | awk '{print $2}')
omarchy_version=${omarchy_version%-*}
base_list=$ROOTFS/usr/share/omarchy/install/omarchy-base.packages
[[ -f $base_list ]] || die "missing $base_list"
drop=("${DROP[@]}")
if (( LITE )); then drop+=("${LITE_DROP[@]}"); fi
mapfile -t base_pkgs < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$base_list" |
  grep -vxF -f <(printf '%s\n' "${drop[@]}"))

log "pacstrap (2/2): ${#base_pkgs[@]} of Omarchy's base packages (profile: $( ((LITE)) && echo lite || echo full))"
nice -n 10 pacstrap -C "$conf" -c -G -M "$ROOTFS" --needed "${base_pkgs[@]}"

# The womarchy builds must be what got installed (repo order is what decides).
for p in "${REQUIRED_WOMARCHY[@]}"; do
  want=$(repo_version "$p")
  [[ -n $want ]] || continue
  have=$(pacman -r "$ROOTFS" -Q "$p" 2>/dev/null | awk '{print $2}')
  [[ $have == "$want" ]] || die "$p: installed '${have:-none}', expected womarchy's $want"
done

# --- 5. configure the system -----------------------------------------------------------
log "Configuring the image"
install -m 0644 "$HERE/rootfs/etc/wsl.conf" "$ROOTFS/etc/wsl.conf"
install -m 0644 "$HERE/rootfs/etc/wsl-distribution.conf" "$ROOTFS/etc/wsl-distribution.conf"
install -d -m 0755 "$ROOTFS/etc/womarchy"
cat >"$ROOTFS/etc/womarchy/profile" <<EOF
WOMARCHY_PROFILE=$( ((LITE)) && echo lite || echo full)
OMARCHY_VERSION=$omarchy_version
WOMARCHY_BUILD_DATE=$BUILD_DATE
EOF
install -m 0644 "$HERE/rootfs/etc/womarchy/config" "$ROOTFS/etc/womarchy/config"

# The installed system's local [womarchy] repo (offline fallback behind the
# hosted one; see wsl/pacman.sh). /var/lib, not /var/cache: cache cleaners must
# not be able to remove a configured repo.
install -d -m 0755 "$ROOTFS/var/lib/womarchy" "$ROOTFS$IMAGE_REPO"
cp -r --no-preserve=mode,ownership "$STAGE_REPO/." "$ROOTFS$IMAGE_REPO/"
lock_down "$ROOTFS$IMAGE_REPO"

log "womarchy-apply-system in the chroot"
mountpoint -q "$ROOTFS" || mount --bind "$ROOTFS" "$ROOTFS"   # arch-chroot wants a mountpoint
arch-chroot "$ROOTFS" env OMARCHY_LOG_TO_STDOUT=1 OMARCHY_MIRROR=stable OMARCHY_ALLOW_DIRECT_PACMAN=1 \
  WOMARCHY_XKB_LAYOUT=us WOMARCHY_LOCALE=en_US.UTF-8 \
  womarchy-apply-system --defer-provisioning --first-install

# Sanity: the things the image must have.
first_repo=$(grep -m1 -E '^\[[A-Za-z0-9_-]+\]' <(grep -v '^\[options\]' "$ROOTFS/etc/pacman.conf"))
[[ $first_repo == "[womarchy]" ]] || die "first pacman repo is '$first_repo', not [womarchy]"
[[ -L $ROOTFS/etc/systemd/system/NetworkManager.service || ! -f $ROOTFS/usr/lib/systemd/system/NetworkManager.service ]] ||
  die "NetworkManager not masked"
installed=$(pacman -r "$ROOTFS" -Qq)
for p in omarchy omarchy-settings womarchy-compat mesa vulkan-dzn pipewire-pulse wireplumber; do
  grep -qx "$p" <<<"$installed" || die "package $p not installed"
done
for p in limine snapper linux; do
  if grep -qx "$p" <<<"$installed"; then die "$p must not be installed"; fi
done
writable=$(find "$ROOTFS$IMAGE_REPO" \( -perm /022 -o ! -user root \) ! -type l)
[[ -z $writable ]] || die "group/other-writable or non-root files in $IMAGE_REPO: $writable"

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
# Backup files (repo-add's *.old, pacman's *.pacsave/*.pacnew) have no place in
# an image; a package-owned file of that name is reported, not deleted.
while IFS= read -r -d '' f; do
  if pacman -r "$ROOTFS" -Qqo "${f#"$ROOTFS"}" &>/dev/null; then
    echo "note: keeping package-owned ${f#"$ROOTFS"}"
  else
    echo "removing ${f#"$ROOTFS"}"; rm -f "$f"
  fi
done < <(find "$ROOTFS/etc" "$ROOTFS/var" -xdev \( -name '*.old' -o -name '*.pacnew' -o -name '*.pacsave' \) -print0)

# Nothing machine- or owner-specific may ship (lab/overlay/privacy-scan.sh does the
# full string scan for releases). machine-id stays absent: systemd creates it at first boot.
privacy_leaks() {
  local r=$1 p
  for p in etc/machine-id var/lib/dbus/machine-id etc/hostname etc/pacman.d/gnupg; do
    [[ -e $r/$p ]] && echo "$p"
  done
  find "$r/root" "$r/home" "$r/var/log/journal" -mindepth 1 -maxdepth 1 2>/dev/null
  find "$r/etc/ssh" -name 'ssh_host_*key*' 2>/dev/null
  true
}
leaks=$(privacy_leaks "$ROOTFS")
[[ -z $leaks ]] || die "machine-specific files left in the image: $(paste -sd' ' <<<"$leaks")"

# --- 7. pack ------------------------------------------------------------------------------
suffix=$( ((LITE)) && echo -lite || true)
name="Omarchy-${omarchy_version}-womarchy-${BUILD_DATE}${suffix}.wsl"
unmount_rootfs
[[ -z $(rootfs_mounts) ]] || die "still mounted under $ROOTFS: $(rootfs_mounts | paste -sd' ')"
log "Packing $OUT/$name"
tar --numeric-owner --xattrs --xattrs-include='*' --acls --sort=name \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' --exclude='./run/*' \
    -C "$ROOTFS" -c . |
  nice -n 10 xz -T0 -"$XZ_LEVEL" >"$OUT/$name.part"
mv -f "$OUT/$name.part" "$OUT/$name"
(cd "$OUT" && sha256sum "$name" >"$name.sha256")

du -sh --apparent-size "$ROOTFS" | awk '{print "rootfs: " $1}'
ls -la "$OUT/$name"
for p in womarchy-compat "${REQUIRED_WOMARCHY[@]}"; do printf '%s ' "$(pacman -r "$ROOTFS" -Q "$p" 2>/dev/null || echo "$p:none")"; done; echo
(( ${KEEP_ROOTFS:-0} )) || remove_rootfs
echo "$OUT/$name"
