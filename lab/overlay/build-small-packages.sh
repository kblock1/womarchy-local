#!/bin/bash
# Build womarchy-keyring + womarchy-compat with build-all.sh (as the unprivileged
# builder user) into a scratch repo, not out/repo. Run as root in womarchy-build.
ROOT=${WOMARCHY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}  # repo root
set -euo pipefail
T=/var/tmp/womarchy-test
rm -rf "$T/repo"; install -d -o builder -g builder "$T" "$T/repo"
runuser -u builder -- env WOMARCHY_REPO="$T/repo" WOMARCHY_WORK="$T/work" \
  bash "$ROOT/linux/packages/build-all.sh" womarchy-keyring womarchy-compat
echo "--- compat contents (new files)"
bsdtar -tf "$T"/repo/womarchy-compat-0.4.0-*.pkg.tar.zst | grep -E "rollback|mesa-llvm|hooks/|keyring" 
echo "--- keyring contents"; bsdtar -tf "$T"/repo/womarchy-keyring-*.pkg.tar.zst | grep -v '^\.'
echo "--- installed on build host? $(pacman -Q womarchy-compat womarchy-keyring 2>&1 | paste -sd' ')"
