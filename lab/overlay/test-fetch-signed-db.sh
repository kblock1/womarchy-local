#!/bin/bash
# Tests for linux/packages/fetch-signed-db.sh with a THROWAWAY key (temp GNUPGHOME,
# deleted at the end). A fake "release" directory is served via file://.
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}  # repo root
set -uo pipefail
F=$ROOT/linux/packages/fetch-signed-db.sh
SRC=/var/tmp/womarchy-test/repo          # the freshly built keyring + compat packages
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GNUPGHOME=$T/gnupg; mkdir -m 700 $GNUPGHOME
ok() { printf 'PASS  %s\n' "$*"; }; no() { printf 'FAIL  %s\n' "$*"; }
newkey() { gpg --batch --passphrase '' --quick-gen-key "$1 <test@invalid>" ed25519 sign never 2>/dev/null
  gpg --batch --with-colons --list-keys "$1" | awk -F: '$1=="fpr"{print $10; exit}'; }
K=$(newkey "womarchy throwaway test key"); O=$(newkey "some other key")
mkdir -p $T/keys $T/rel $T/local
gpg --batch --armor --export "$K" >$T/keys/womarchy.asc; echo "$K:4:" >$T/keys/womarchy-trusted
# a signed release: packages + .sig, db signed (repo-add -s), plain names like the GitHub release
cp -L $SRC/*.pkg.tar.zst $T/rel/
for p in $T/rel/*.pkg.tar.zst; do gpg --batch -u "$K" --detach-sign --no-armor "$p"; done
( cd $T/rel && repo-add -q -s -k "$K" womarchy.db.tar.gz *.pkg.tar.zst )
for n in db files; do rm -f $T/rel/womarchy.$n $T/rel/womarchy.$n.sig
  cp $T/rel/womarchy.$n.tar.gz $T/rel/womarchy.$n; cp $T/rel/womarchy.$n.tar.gz.sig $T/rel/womarchy.$n.sig; done
export WOMARCHY_REPO_URL=file://$T/rel WOMARCHY_KEY_DIR=$T/keys
run() { bash $F "$@" >$T/out 2>&1; echo $?; }

[[ $(run $T/local) != 0 ]] && grep -q 'not in' $T/out && ok "empty local repo -> refuses (packages missing)" || no "$(cat $T/out)"
[[ $(run --fetch-packages $T/local) == 0 ]] && ok "--fetch-packages: $(tail -1 $T/out)" || no "fetch: $(cat $T/out)"
[[ $(run --verify-only $T/local) == 0 ]] && ok "--verify-only on the result" || no "verify: $(cat $T/out)"
ls $T/local/womarchy.db.sig $T/local/womarchy-compat-*.pkg.tar.zst.sig >/dev/null 2>&1 && ok "db + package .sig files in place" || no "sigs missing"
cp $T/local/womarchy-keyring-*.pkg.tar.zst $T/k.bak; echo x >>$T/local/womarchy-keyring-*.pkg.tar.zst
[[ $(run --verify-only $T/local) != 0 ]] && grep -q sha256 $T/out && ok "tampered package -> $(cat $T/out)" || no "tamper: $(cat $T/out)"
[[ $(run --fetch-packages $T/local) == 0 ]] && ok "--fetch-packages repairs the tampered file" || no "repair: $(cat $T/out)"
touch $T/local/stray-1.0-1-any.pkg.tar.zst
[[ $(run --verify-only $T/local) != 0 ]] && grep -q 'does not list' $T/out && ok "unlisted package file -> refused" || no "extra: $(cat $T/out)"
[[ $(run --prune $T/local) == 0 ]] && [[ ! -e $T/local/stray-1.0-1-any.pkg.tar.zst ]] && ok "--prune removes it" || no "prune: $(cat $T/out)"
gpg --batch -u "$O" --detach-sign --no-armor -o $T/local/womarchy.db.sig --yes $T/local/womarchy.db
[[ $(run --verify-only $T/local) != 0 ]] && grep -q 'no valid signature' $T/out && ok "db signed by another key -> $(cat $T/out)" || no "other key: $(cat $T/out)"
rm $T/rel/womarchy.db.sig
[[ $(run $T/local) != 0 ]] && ok "release without db .sig -> download refused" || no "nosig: $(cat $T/out)"
gpg --batch --armor --export "$K" "$O" >$T/keys/womarchy.asc
[[ $(run --verify-only $T/local) != 0 ]] && grep -q 'holds' $T/out && ok "key file with an extra key -> refused" || no "extrakey: $(cat $T/out)"
