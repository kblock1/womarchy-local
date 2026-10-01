#!/bin/bash
# Unit tests for the womarchy WSL leaves, run INSIDE a kept image rootfs (throwaway copy):
#   arch-chroot /var/tmp/womarchy-image/rootfs bash /root/t.sh
set -u
W=/usr/lib/womarchy/wsl
ok() { printf 'PASS  %s\n' "$*"; }; no() { printf 'FAIL  %s\n' "$*"; }
t() { local d=$1; shift; if "$@"; then ok "$d"; else no "$d"; fi; }

echo "== apply-system plan (loud parser)"
t "--list works on the 4.0.4 tree" bash -c 'womarchy-apply-system --list >/dev/null'
mkdir -p /tmp/inst/config /tmp/inst/post-install
printf 'run_logged "$OMARCHY_INSTALL/config/a.sh"\nsource "$OMARCHY_INSTALL/config/b.sh"\n' >/tmp/inst/config/all.sh
out=$(OMARCHY_INSTALL=/tmp/inst womarchy-apply-system --list 2>&1); rc=$?
t "unknown all.sh line fails loudly (rc=$rc)" test $rc -ne 0
grep -q 'cannot classify' <<<"$out" && ok "message: $(grep -m1 cannot <<<"$out")" || no "no message: $out"

echo "== keyboard-locale"
kl() { env "$@" bash $W/keyboard-locale.sh; }
kl WOMARCHY_XKB_LAYOUT=us,ru WOMARCHY_XKB_VARIANT= WOMARCHY_LOCALE=en_US.UTF-8 >/dev/null 2>&1
t "us,ru -> toggle option" grep -qx 'XKBOPTIONS=grp:alt_shift_toggle' /etc/vconsole.conf
t "us,ru -> XKBLAYOUT" grep -qx 'XKBLAYOUT=us,ru' /etc/vconsole.conf
kl WOMARCHY_XKB_LAYOUT=us,ru WOMARCHY_XKB_VARIANT=,phonetic WOMARCHY_LOCALE=en_US.UTF-8 >/dev/null 2>&1
t "variant ,phonetic kept" grep -qx 'XKBVARIANT=,phonetic' /etc/vconsole.conf
before=$(cat /etc/vconsole.conf)
kl WOMARCHY_XKB_LAYOUT=xx WOMARCHY_LOCALE='"de_DE.UTF-8"' 2>/tmp/kl.err; rc=$?
t "invalid layout -> non-zero (rc=$rc)" test $rc -ne 0
t "invalid layout leaves vconsole.conf unchanged" test "$before" == "$(cat /etc/vconsole.conf)"
t "...but locale step still ran (quoted LANG accepted)" grep -qx 'LANG=de_DE.UTF-8' /etc/locale.conf
t "de_DE generated" bash -c 'locale -a | grep -qix de_DE.utf8'
kl WOMARCHY_XKB_LAYOUT=us WOMARCHY_LOCALE=sr_RS.UTF-8@latin >/dev/null 2>&1; rc=$?
t "@modifier locale sr_RS.UTF-8@latin (rc=$rc)" grep -qx 'LANG=sr_RS.UTF-8@latin' /etc/locale.conf
t "sr_RS@latin generated" bash -c 'locale -a | grep -qix sr_RS@latin'
kl WOMARCHY_XKB_LAYOUT=us WOMARCHY_XKB_VARIANT=bogus 2>/dev/null; t "bad variant rejected" test $? -ne 0
kl WOMARCHY_XKB_LAYOUT=us WOMARCHY_XKB_OPTIONS=grp:nonsense 2>/dev/null; t "bad option rejected" test $? -ne 0
kl WOMARCHY_XKB_LAYOUT=us WOMARCHY_LOCALE=en_US.UTF-8 >/dev/null 2>&1
t "single layout -> no XKBOPTIONS" bash -c '! grep -q XKBOPTIONS /etc/vconsole.conf'

echo "== pacman.sh"
R=/var/lib/womarchy/repo
chmod 0777 $R/womarchy.db.tar.gz; chown 1234 $R/womarchy.db.tar.gz; touch $R/x.old
bash $W/pacman.sh
t "perms repaired" test -z "$(find $R \( -perm /022 -o ! -user root \) ! -type l)"
t "*.old removed" test ! -e $R/x.old
t "[womarchy] first with hosted + file servers" bash -c "awk '/^\[womarchy\]/{f=1;next} /^\[/{f=0} f' /etc/pacman.conf | grep -c '^Server' | grep -qx 2"
cp /etc/pacman.conf /tmp/pc; sed -i '/^\[core\]/,+1d' /etc/pacman.conf
out=$(bash $W/pacman.sh 2>&1); rc=$?; cp /tmp/pc /etc/pacman.conf
t "no [core] -> loud failure (rc=$rc: $out)" test $rc -ne 0
mv $R /tmp/repo.bak; out=$(bash $W/pacman.sh 2>&1); rc=$?; mv /tmp/repo.bak $R
t "missing local db -> loud failure (rc=$rc)" test $rc -ne 0
echo "   $out"
mv $R /var/cache/womarchy-repo; chmod -R 0777 /var/cache/womarchy-repo
bash $W/pacman.sh; t "migration from /var/cache (perms fixed, old dir gone)" test -f $R/womarchy.db -a ! -e /var/cache/womarchy-repo -a -z "$(find $R -perm /022 ! -type l)"
bash $W/pacman.sh; bash $W/pacman.sh
t "idempotent: one [womarchy] section" test "$(grep -c '^\[womarchy\]' /etc/pacman.conf)" == 1
t "idempotent: one IgnorePkg line" test "$(grep -c '^IgnorePkg = linux linux-lts' /etc/pacman.conf)" == 1

echo "== settings + masks"
womarchy-apply-system --reassert >/dev/null 2>&1
t "log mode 640 after reassert" test "$(stat -c %a /var/log/omarchy-install.log)" == 640
WOMARCHY_DOCKER=0 womarchy-apply-system --reassert >/dev/null 2>&1
t "WOMARCHY_DOCKER=0 persisted" grep -qx 'WOMARCHY_DOCKER=0' /etc/womarchy/config
t "docker.socket disabled" bash -c '! systemctl is-enabled docker.socket >/dev/null 2>&1'
womarchy-apply-system --reassert >/dev/null 2>&1
t "plain reassert keeps the saved 0" bash -c '! systemctl is-enabled docker.socket >/dev/null 2>&1'
WOMARCHY_DOCKER=1 womarchy-apply-system --reassert >/dev/null 2>&1
t "WOMARCHY_DOCKER=1 re-enables" systemctl is-enabled docker.socket
rm -f /etc/systemd/system/cups.service   # the user unmasks cups
womarchy-apply-system --reassert >/dev/null 2>&1
t "user-unmasked cups.service stays unmasked" test ! -e /etc/systemd/system/cups.service
t "...and is recorded as released" grep -qx cups.service /var/lib/womarchy/released-units
t "NetworkManager still masked" test "$(readlink /etc/systemd/system/NetworkManager.service)" == /dev/null
WOMARCHY_FIREWALL=1 womarchy-apply-system --reassert >/dev/null 2>&1
t "firewall=1 lifts womarchy's ufw mask" test ! -e /etc/systemd/system/ufw.service
WOMARCHY_FIREWALL=0 womarchy-apply-system --reassert >/dev/null 2>&1
t "firewall=0 masks ufw again" test "$(readlink /etc/systemd/system/ufw.service)" == /dev/null
t "WOMARCHY_FIREWALL=x rejected" bash -c '! WOMARCHY_FIREWALL=x womarchy-apply-system --reassert >/dev/null 2>&1'

echo "== GPU generator"
g=/usr/lib/systemd/user-environment-generators/60-womarchy-gpu
t "with dxg: d3d12" bash -c "WOMARCHY_DXG=/etc/hostname-not $g | grep -q GALLIUM || true; touch /tmp/dxg; env -i WOMARCHY_DXG=/tmp/dxg $g | grep -qx GALLIUM_DRIVER=d3d12"
t "without dxg: no GALLIUM_DRIVER" bash -c "! env -i WOMARCHY_DXG=/nonexistent $g | grep -q GALLIUM"
t "caller's value wins" bash -c "! env -i GALLIUM_DRIVER=llvmpipe WOMARCHY_DXG=/tmp/dxg $g | grep -q GALLIUM"
t "old environment.d file removed" test ! -e /etc/environment.d/10-womarchy-gpu.conf
