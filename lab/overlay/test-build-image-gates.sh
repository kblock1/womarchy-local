#!/bin/bash
# build-image.sh's early gates (no pacstrap): an unsigned repo and a repo without compat/keyring.
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}  # repo root
T=/var/tmp/wtest; rm -rf $T; mkdir -p $T/repo
cp -rL "$ROOT/out/repo/." $T/repo/
B=$ROOT/linux/image/build-image.sh
OUT=$T WORK=$T/work bash $B >$T/a.log 2>&1; echo "unsigned repo -> rc=$?: $(grep -E 'error|fetch-signed' $T/a.log | tail -2 | paste -sd' ')"
OUT=$T WORK=$T/work ALLOW_UNSIGNED_REPO=1 bash $B >$T/b.log 2>&1; echo "ALLOW_UNSIGNED_REPO, no compat -> rc=$?: $(grep -E 'error' $T/b.log | tail -1)"
grep -c "pacstrap" $T/a.log $T/b.log
rm -rf $T
