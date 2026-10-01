#!/bin/bash
# fetch-signed-db.sh: bring a local [womarchy] repo directory (default out/repo) in
# line with the signed release, and prove it is consistent.
#
#   fetch-signed-db.sh [--fetch-packages] [--prune] [REPO_DIR]   download the signed db + .sig files
#   fetch-signed-db.sh --verify-only [REPO_DIR]                  check REPO_DIR as it is
#
# Download mode fetches womarchy.db, womarchy.files (+ their .tar.gz copies when
# published) with their .sig files, and the .sig of every package the db lists,
# into a staging directory. With --fetch-packages it also downloads package files
# that are missing locally or differ. Both modes then require:
#   - each db file has a valid signature by a key in womarchy-trusted (and the key
#     file contains exactly those keys);
#   - the db lists exactly the package files in REPO_DIR: same names, same sha256,
#     each with a valid signature; no unlisted package files.
# Only after that does download mode move the new files into REPO_DIR.
# Exit 0 = consistent and signed; anything else = the image must not be built.
#
# Environment: WOMARCHY_REPO_URL (default the `packages` release), WOMARCHY_KEY_DIR
# (default <this dir>/womarchy-keyring: womarchy.asc, womarchy-trusted).
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
URL=${WOMARCHY_REPO_URL:-https://github.com/sytelus/womarchy/releases/download/packages}
KEY_DIR=${WOMARCHY_KEY_DIR:-$HERE/womarchy-keyring}

usage() {
  cat <<'USAGE'
Usage: fetch-signed-db.sh [--fetch-packages] [--prune] [REPO_DIR]
       fetch-signed-db.sh --verify-only [REPO_DIR]
REPO_DIR defaults to out/repo. Exit 0 only when the db is validly signed by the
womarchy key and lists exactly the (signed) package files in REPO_DIR.
--fetch-packages downloads missing or differing package files; --prune deletes
local package files the db does not list.
USAGE
}

verify_only=0 fetch_packages=0 prune=0 repo=""
while (($#)); do
  case "$1" in
    --verify-only) verify_only=1; shift ;;
    --fetch-packages) fetch_packages=1; shift ;;
    --prune) prune=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) repo=$1; shift ;;
  esac
done
repo=${repo:-$ROOT/out/repo}

die() { echo "fetch-signed-db.sh: $*" >&2; exit 1; }
[[ -d $repo ]] || die "no repo directory $repo"
for c in gpg curl bsdtar sha256sum; do command -v "$c" >/dev/null || die "missing $c"; done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
gnupg=$tmp/gnupg stage=$tmp/stage
mkdir -m 0700 "$gnupg"
mkdir "$stage" "$stage/pkgs"

# --- the accepted signers -------------------------------------------------------------
[[ -f $KEY_DIR/womarchy.asc && -f $KEY_DIR/womarchy-trusted ]] || die "keyring files missing in $KEY_DIR"
gpg --homedir "$gnupg" --batch --quiet --import "$KEY_DIR/womarchy.asc" 2>/dev/null || die "cannot import $KEY_DIR/womarchy.asc"
trusted=$(sed -e 's/#.*//' "$KEY_DIR/womarchy-trusted" | cut -d: -f1 | grep -E '^[0-9A-F]{40}$' | sort -u || true)
[[ -n $trusted ]] || die "no fingerprints in $KEY_DIR/womarchy-trusted"
in_key=$(gpg --homedir "$gnupg" --batch --with-colons --list-keys 2>/dev/null |
  awk -F: '$1 == "pub" { want = 1; next } want && $1 == "fpr" { print $10; want = 0 }' | sort -u)
[[ $in_key == "$trusted" ]] || die "womarchy.asc holds {${in_key//$'\n'/,}}, womarchy-trusted lists {${trusted//$'\n'/,}}"

# good_sig FILE SIG: a valid signature made by one of the trusted primary keys.
good_sig() {
  local status primary
  [[ -f $1 && -f $2 ]] || return 1
  status=$(gpg --homedir "$gnupg" --batch --status-fd 1 --verify "$2" "$1" 2>/dev/null) || return 1
  primary=$(awk '$2 == "VALIDSIG" { print $NF }' <<<"$status")
  [[ -n $primary ]] && grep -qxF "$primary" <<<"$trusted"
}

# --- download (unless --verify-only) ------------------------------------------------------
dbdir=$repo
if (( ! verify_only )); then
  dbdir=$stage
  for f in womarchy.db womarchy.db.sig womarchy.files womarchy.files.sig; do
    curl -fsSL --retry 3 -o "$stage/$f" "$URL/$f" || die "cannot download $URL/$f"
  done
  for f in womarchy.db.tar.gz womarchy.files.tar.gz; do   # optional copies under repo-add's names
    if curl -fsSL --retry 3 -o "$stage/$f" "$URL/$f" 2>/dev/null; then
      curl -fsSL --retry 3 -o "$stage/$f.sig" "$URL/$f.sig" || die "$URL/$f has no signature"
    else
      rm -f "$stage/$f"
    fi
  done
fi

# --- the db files are signed by the womarchy key ---------------------------------------------
for f in womarchy.db womarchy.files womarchy.db.tar.gz womarchy.files.tar.gz; do
  if [[ ! -e $dbdir/$f ]]; then
    [[ $f == *.tar.gz ]] && continue
    die "$dbdir/$f is missing"
  fi
  good_sig "$dbdir/$f" "$dbdir/$f.sig" || die "$f: no valid signature by the womarchy key ($dbdir/$f.sig)"
done
for n in db files; do
  if [[ -e $dbdir/womarchy.$n.tar.gz ]]; then
    cmp -s "$dbdir/womarchy.$n" "$dbdir/womarchy.$n.tar.gz" || die "womarchy.$n and womarchy.$n.tar.gz differ"
  fi
done

# --- the db lists exactly the package files we have --------------------------------------------
listed=$(bsdtar -xOf "$dbdir/womarchy.db" '*/desc' |
  awk '/^%FILENAME%$/ { getline; f = $0 } /^%SHA256SUM%$/ { getline; print f "\t" $0 }' | sort)
[[ -n $listed ]] || die "the womarchy db lists no packages"
while IFS=$'\t' read -r file sum; do
  [[ $file =~ ^[A-Za-z0-9@._+-]+\.pkg\.tar\.(zst|xz|gz)$ ]] || die "odd package file name in the db: '$file'"
  if (( ! verify_only )); then
    curl -fsSL --retry 3 -o "$stage/pkgs/$file.sig" "$URL/$file.sig" || die "cannot download $URL/$file.sig"
    if (( fetch_packages )) && ! { [[ -f $repo/$file ]] && sha256sum "$repo/$file" | grep -q "^$sum "; }; then
      curl -fsSL --retry 3 -o "$stage/pkgs/$file" "$URL/$file" || die "cannot download $URL/$file"
    fi
  fi
  pkg=$repo/$file sig=$repo/$file.sig
  [[ -f $stage/pkgs/$file ]] && pkg=$stage/pkgs/$file
  [[ -f $stage/pkgs/$file.sig ]] && sig=$stage/pkgs/$file.sig
  [[ -f $pkg ]] || die "$file is listed in the db but not in $repo (use --fetch-packages)"
  sha256sum "$pkg" | grep -q "^$sum " || die "$file: sha256 differs from the db's (use --fetch-packages)"
  good_sig "$pkg" "$sig" || die "$file: no valid signature by the womarchy key"
done <<<"$listed"

extra=()
for f in "$repo"/*.pkg.tar.*; do
  [[ -f $f && $f != *.sig ]] || continue
  awk -F'\t' -v f="${f##*/}" '$1 == f { found = 1 } END { exit !found }' <<<"$listed" || extra+=("${f##*/}")
done
if ((${#extra[@]})); then
  (( prune && ! verify_only )) || die "package files in $repo that the db does not list: ${extra[*]} (use --prune)"
  for f in "${extra[@]}"; do rm -f "$repo/$f" "$repo/$f.sig"; echo "pruned $f"; done
fi

# --- install the verified files ----------------------------------------------------------------
if (( ! verify_only )); then
  for f in "$stage"/womarchy.* "$stage"/pkgs/*; do
    [[ -f $f ]] || continue
    rm -f "$repo/${f##*/}"   # may be a repo-add symlink
    mv -f "$f" "$repo/"
  done
fi
echo "womarchy repo in $repo: $(wc -l <<<"$listed") packages, db and packages signed by the womarchy key"
