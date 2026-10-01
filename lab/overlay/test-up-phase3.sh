#!/bin/bash
# omarchy-test-up phase 3 (root): publish a signed "next" [womarchy] repo at /srv/hosted
# (throwaway key T from phase 1 stands in for the womarchy key; the key is pre-added
# UNTRUSTED, as a keyserver auto-import would add it), point the hosted URL there,
# then run a plain `omarchy update -y` as the user.
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}  # repo root
set -uo pipefail
export LC_ALL=C
P=${1:?usage: test-up-phase3.sh DIR-WITH-NEW-PACKAGES}   # the freshly built compat/keyring/session packages
K=$(cat /root/testkey.fpr)
L=/var/lib/womarchy/repo H=/srv/hosted
# 1. the image's local fallback repo, unsigned as in v0.1.0 (only its original packages)
rm -f $L/womarchy-compat-0.4.0-* $L/womarchy-keyring-* $L/*.sig $L/womarchy.db* $L/womarchy.files*
( cd $L && repo-add -q womarchy.db.tar.gz *.pkg.tar.zst && for n in db files; do rm -f womarchy.$n; cp womarchy.$n.tar.gz womarchy.$n; done )
# 2. keyring package for T, built exactly like linux/packages/womarchy-keyring
B=/tmp/kr; rm -rf $B; mkdir -p $B
cp "$ROOT"/linux/packages/womarchy-keyring/{PKGBUILD,womarchy-keyring.install,womarchy-revoked} $B/
GNUPGHOME=/root/testkey gpg --batch --armor --export "$K" >$B/womarchy.asc; echo "$K:4:" >$B/womarchy-trusted
chown -R omarchy: $B; runuser -u omarchy -- env -C $B makepkg -f --nodeps >/dev/null 2>&1 || { echo "keyring build failed"; exit 1; }
# 3. the hosted repo: image packages (old compat 0.3.0 file kept, like CI) + compat 0.4.0 + keyring(T); all signed by T
rm -rf $H; mkdir -p $H
cp $L/*.pkg.tar.zst $P/womarchy-compat-0.4.0-*.pkg.tar.zst $B/womarchy-keyring-*.pkg.tar.zst $H/
export GNUPGHOME=/root/testkey
for p in $H/*.pkg.tar.zst; do gpg --batch --yes -u "$K" --detach-sign --no-armor "$p"; done
( cd $H && repo-add -q -s -k "$K" womarchy.db.tar.gz $(ls *.pkg.tar.zst | grep -v 'compat-0.3.0') )
for n in db files; do rm -f $H/womarchy.$n $H/womarchy.$n.sig; cp $H/womarchy.$n.tar.gz $H/womarchy.$n; cp $H/womarchy.$n.tar.gz.sig $H/womarchy.$n.sig; done
unset GNUPGHOME
echo "hosted: $(bsdtar -tf $H/womarchy.db | grep -c '/$') packages: $(bsdtar -tf $H/womarchy.db | grep -oE '^womarchy-(compat|keyring)-[^/]*' | paste -sd' ')"
# 4. hosted URL -> /srv/hosted (pacman.conf by hand for v0.1.0; config for the new pacman.sh)
sed -i "s|^Server = https://github.com/sytelus/womarchy/releases/download/repo$|Server = file://$H|" /etc/pacman.conf
grep -q '^WOMARCHY_REPO_URL=' /etc/womarchy/config && sed -i "s|^WOMARCHY_REPO_URL=.*|WOMARCHY_REPO_URL=file://$H|" /etc/womarchy/config || echo "WOMARCHY_REPO_URL=file://$H" >>/etc/womarchy/config
pacman-key --list-keys "$K" >/dev/null 2>&1 || pacman-key --add /root/testkey.asc >/dev/null 2>&1
echo "T key before: $(gpg --homedir /etc/pacman.d/gnupg --batch --with-colons --list-keys "$K" 2>/dev/null | awk -F: '$1=="pub"{print "present, validity " $2}')"

echo "== omarchy update -y (as omarchy, plain)"
( while sleep 2; do pgrep -x gum >/dev/null && { echo "[watcher: dismissed: $(ps -o args= -C gum | head -1)]"; pkill -x gum; }; done ) &
watcher=$!
runuser -u omarchy -- bash -lc 'cd ~ && omarchy update -y' </dev/null >/root/update.out 2>&1; rc=$?
kill $watcher 2>/dev/null
echo "omarchy update rc=$rc"
tr -d '\033' </root/update.out | sed 's/\[J//g' | grep -aE "Packages \(|upgrading|installing|womarchy|error|warning|conflict|went wrong|WARNING|Reboot|populat|key" | grep -avE "downloading|^\]3008" | cut -c1-150 | head -30
echo "== after"
pacman -Q womarchy-compat womarchy-keyring
awk '/^\[womarchy\]/{f=1} f&&/^(SigLevel|Server)/{print} /^\[core\]/{f=0}' /etc/pacman.conf
echo "T key after: $(gpg --homedir /etc/pacman.d/gnupg --batch --with-colons --list-keys "$K" 2>/dev/null | awk -F: '$1=="pub"{print "validity " $2}')"
echo "rollback points: $(ls /var/lib/womarchy/rollback | paste -sd' ')"
echo "system: $(systemctl is-system-running)"
pacman -Syy >/dev/null 2>&1 && echo "pacman -Syy with the new SigLevel: ok" || echo "pacman -Syy FAILED"
pacman-key --verify /var/lib/pacman/sync/womarchy.db.sig /var/lib/pacman/sync/womarchy.db >/dev/null 2>&1 && echo "sync db .sig kept by pacman and valid" || echo "no valid sync db .sig"
