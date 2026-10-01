#!/bin/bash
# omarchy-test-up phase 1 (root): snapshot drift, pre-upgrade point, signed-db transition probe.
set -uo pipefail
export LC_ALL=C OMARCHY_ALLOW_DIRECT_PACMAN=1
echo "== snapshot drift: what a plain -Syu would change now"
pacman -Syup --print-format '%r %n %v %s' 2>/dev/null >/root/drift.txt; rc=$?
echo "pacman -Syup rc=$rc; $(wc -l </root/drift.txt) packages, $(awk '{s+=$4} END {printf "%.1f MiB", s/1048576}' /root/drift.txt)"
awk '{print $1}' /root/drift.txt | sort | uniq -c
head -15 /root/drift.txt

echo "== manual pre-upgrade rollback point (v0.1.0 has no hook)"
install -d /var/lib/womarchy/rollback
pacman -Q >/var/lib/womarchy/rollback/20261001T000000Z.pkgs; touch -d '-2 hours' /var/lib/womarchy/rollback/20261001T000000Z.pkgs
wc -l /var/lib/womarchy/rollback/20261001T000000Z.pkgs

echo "== transition probe: throwaway key T, signed db, the v0.1.0 SigLevel (Optional TrustAll)"
export GNUPGHOME=/root/testkey; rm -rf $GNUPGHOME; mkdir -m 700 $GNUPGHOME
gpg --batch --passphrase '' --quick-gen-key "womarchy THROWAWAY test key <test@invalid>" ed25519 sign never 2>/dev/null
K=$(gpg --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10; exit}'); echo "$K" >/root/testkey.fpr
gpg --batch --armor --export "$K" >/root/testkey.asc
rm -rf /srv/probe && mkdir -p /srv/probe && cp /var/lib/womarchy/repo/womarchy-session-*.pkg.tar.zst /srv/probe/
gpg --batch -u "$K" --detach-sign --no-armor /srv/probe/womarchy-session-*.pkg.tar.zst
( cd /srv/probe && repo-add -q -s -k "$K" womarchy.db.tar.gz *.pkg.tar.zst )
unset GNUPGHOME
mkdir -p /tmp/probe/db
cat >/tmp/probe.conf <<C
[options]
Architecture = auto
DBPath = /tmp/probe/db
[womarchy]
SigLevel = Optional TrustAll
Server = file:///srv/probe
C
echo "-- key unknown:"; pacman --config /tmp/probe.conf --noconfirm -Sy 2>&1 | tail -6; echo "rc=${PIPESTATUS[0]}"
pacman-key --add /root/testkey.asc >/dev/null 2>&1
echo "-- key present, not locally signed (what a keyserver auto-import gives):"
rm -rf /tmp/probe/db/sync; pacman --config /tmp/probe.conf --noconfirm -Sy 2>&1 | tail -3; echo "rc=${PIPESTATUS[0]}"
pacman-key --delete "$K" >/dev/null 2>&1; echo "key removed again: $(pacman-key --list-keys "$K" >/dev/null 2>&1 && echo NO || echo yes)"
