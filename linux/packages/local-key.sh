#!/usr/bin/env bash
# Give this checkout its own [womarchy] repository key, and point the image at its own repo.
#
# Run as the builder user in the womarchy-build distro (tools/local-setup.ps1 does):
#   bash linux/packages/local-key.sh
# Safe to run again. It:
#  - creates an ed25519 signing key in $WOMARCHY_GNUPGHOME (default ~/.womarchy-gnupg) unless one
#    exists there; the private key never leaves the build distro;
#  - writes the public key into linux/packages/womarchy-keyring (womarchy.asc, womarchy-trusted) and
#    pins its fingerprint in linux/image/omarchy-key.env (build-image.sh and verify-image.sh check it);
#    when the key changes, womarchy-keyring's pkgver becomes today's date;
#  - sets WOMARCHY_REPO_URL in the image's /etc/womarchy/config to this checkout's out/repo, which
#    installed systems read on `omarchy update` (through WSL's /mnt/<drive> mount).
# These are local edits to tracked files: commit them on your own branch, or keep them uncommitted.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
KEYRING=$HERE/womarchy-keyring
KEY_ENV=$ROOT/linux/image/omarchy-key.env
CONFIG=$ROOT/linux/image/rootfs/etc/womarchy/config
export GNUPGHOME=${WOMARCHY_GNUPGHOME:-$HOME/.womarchy-gnupg}

die() { echo "local-key.sh: $*" >&2; exit 1; }
# sed -i on /mnt/c (drvfs) warns that it can't copy the file's ownership; rewrite in place instead
subst() { # FILE SED-ARGS...
  local f=$1 out; shift
  out=$(sed "$@" "$f") && printf '%s\n' "$out" >"$f"
}
(( EUID != 0 )) || die "run as the builder user, not root"
command -v gpg >/dev/null || die "gpg is missing (run linux/image/setup-build-distro.sh)"

# the same check womarchy-apply-system and wsl/pacman.sh apply to WOMARCHY_REPO_URL
repo_url="file://$ROOT/out/repo"
[[ $repo_url =~ ^file:///[A-Za-z0-9._~/%+-]*$ ]] ||
  die "WOMARCHY_REPO_URL can't hold this checkout's path ($ROOT): clone it to a path with only letters, digits and . _ - (no spaces), e.g. C:\\dev\\womarchy-local"

install -d -m 700 "$GNUPGHOME"
secret_fprs() { gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^sec:/ {p=1; next} p && /^fpr:/ {print $10; p=0}'; }
if [[ -z $(secret_fprs) ]]; then
  gpg --batch --passphrase '' --quick-gen-key "womarchy local builds <womarchy@localhost>" ed25519 sign never
fi
mapfile -t fprs < <(secret_fprs)
(( ${#fprs[@]} == 1 )) || die "$GNUPGHOME holds ${#fprs[@]} secret keys; expected exactly one"
FPR=${fprs[0]}

old=$(sed -n 's/^WOMARCHY_KEY_FPR=//p' "$KEY_ENV")
if [[ $old != "$FPR" ]]; then
  gpg --batch --armor --export "$FPR" >"$KEYRING/womarchy.asc"
  echo "$FPR:4:" >"$KEYRING/womarchy-trusted"
  subst "$KEY_ENV" "s/^WOMARCHY_KEY_FPR=.*/WOMARCHY_KEY_FPR=$FPR/"
  subst "$KEYRING/PKGBUILD" -e "s/^pkgver=.*/pkgver=$(date +%Y%m%d)/" -e "s/^pkgrel=.*/pkgrel=1/"
  echo "womarchy repo key: $FPR (was ${old:-unset}); womarchy-keyring $(sed -n 's/^pkgver=//p' "$KEYRING/PKGBUILD")"
else
  echo "womarchy repo key: $FPR (unchanged)"
fi

subst "$CONFIG" "s|^WOMARCHY_REPO_URL=.*|WOMARCHY_REPO_URL=$repo_url|"
grep -qx "WOMARCHY_REPO_URL=$repo_url" "$CONFIG" || die "could not set WOMARCHY_REPO_URL in $CONFIG"
echo "image's WOMARCHY_REPO_URL: $repo_url"
