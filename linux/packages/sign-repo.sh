#!/usr/bin/env bash
# Sign a locally built [womarchy] repo (default out/repo) with your own repo key, the way
# upstream's CI publish job (.github/workflows/packages.yml) does: every package gets a detached .sig,
# womarchy.db / womarchy.files become real copies of repo-add's .tar.gz files (pacman fetches them by
# those names), and all four db files are signed. Ends with fetch-signed-db.sh --verify-only, the same
# check build-image.sh runs.
#
# Run as the builder user in the womarchy-build distro, after linux/packages/build-all.sh:
#   bash linux/packages/sign-repo.sh [REPO_DIR]
# The private key lives in $WOMARCHY_GNUPGHOME (default ~/.womarchy-gnupg) and nowhere else; it is
# created by linux/packages/local-key.sh (tools/local-setup.ps1). See LOCAL-BUILD.md.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
REPO_DIR=${1:-$ROOT/out/repo}
export GNUPGHOME=${WOMARCHY_GNUPGHOME:-$HOME/.womarchy-gnupg}
source "$ROOT/linux/image/omarchy-key.env"   # WOMARCHY_KEY_FPR

die() { echo "sign-repo.sh: $*" >&2; exit 1; }
[[ -f $REPO_DIR/womarchy.db.tar.gz ]] || die "no $REPO_DIR/womarchy.db.tar.gz (run linux/packages/build-all.sh first)"
gpg --batch --list-secret-keys "$WOMARCHY_KEY_FPR" >/dev/null 2>&1 ||
  die "the signing key $WOMARCHY_KEY_FPR is not in $GNUPGHOME (run tools/local-setup.ps1 first)"

sign() { gpg --batch --yes --pinentry-mode loopback --passphrase '' --local-user "$WOMARCHY_KEY_FPR" --detach-sign "$1"; }

cd "$REPO_DIR"
shopt -s nullglob
rm -f -- *.old
for f in *.pkg.tar.zst; do sign "$f"; done
# signatures of packages repo-add -R has since removed
for s in *.pkg.tar.zst.sig; do [[ -f ${s%.sig} ]] || rm -f -- "$s"; done
for n in db files; do
  rm -f "womarchy.$n"
  cp "womarchy.$n.tar.gz" "womarchy.$n"
done
for f in womarchy.db womarchy.db.tar.gz womarchy.files womarchy.files.tar.gz; do sign "$f"; done

bash "$HERE/fetch-signed-db.sh" --verify-only "$REPO_DIR"
