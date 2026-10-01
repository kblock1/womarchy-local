#!/bin/bash
# Scan a kept image rootfs (KEEP_ROOTFS=1 build) for anything identifying the build machine or its owner.
#   privacy-scan.sh [ROOTFS] [PATTERN...]
# Searched for, in every file (binaries too): this machine's host name, the Windows user name, the git
# author emails of this checkout, Windows drive paths as WSL sees them (/mnt/<letter>/), and any extra
# PATTERNs (e.g. your real name).
R=${1:-/var/tmp/womarchy-image/rootfs}
shift || true
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
patterns=("$@")
patterns+=("$(cat /proc/sys/kernel/hostname)")
win_user=$(cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')
[[ -n $win_user && $win_user != '%USERNAME%' ]] && patterns+=("$win_user")
for email in $(git -C "$here" config user.email) $(git -C "$here" config --global user.email); do patterns+=("$email"); done
cd "$R" || exit 1
echo "== identity strings"
for pat in "${patterns[@]}"; do
  [[ -n $pat ]] || continue
  hits=$(nice -n 10 grep -rIlaiF --exclude-dir={proc,sys,dev,run} -- "$pat" . 2>/dev/null | head -20)
  printf '%-14s %s\n' "$pat:" "${hits:-none}" | paste -sd' '
done
hits=$(nice -n 10 grep -rIlaE --exclude-dir={proc,sys,dev,run} -- '/mnt/[a-z]/' . 2>/dev/null | head -20)
echo "/mnt/<drive>/:  ${hits:-none}" | paste -sd' '
echo "== machine-id: etc=$(test -e etc/machine-id && echo "present:'$(cat etc/machine-id)'" || echo absent) dbus=$(test -e var/lib/dbus/machine-id && echo present || echo absent)"
echo "== hostname: $(test -e etc/hostname && cat etc/hostname || echo absent); hosts:"; cat etc/hosts
echo "== /var/log:"; find var/log -type f -printf '%p %s\n'; echo "journal entries: $(find var/log/journal -mindepth 1 | wc -l)"
echo "== /root:"; ls -la root; echo "== /home:"; ls -la home
echo "== secrets/history anywhere:"; find . -xdev \( -name '.bash_history' -o -name '.zsh_history' -o -name '.lesshst' -o -name '.viminfo' -o -name '.gitconfig' -o -name 'id_rsa*' -o -name 'id_ed25519*' -o -name 'ssh_host_*key*' -o -name 'private-keys-v1.d' -o -name 'secring.gpg' -o -name '.python_history' -o -name '.wget-hsts' \) -print
echo "== pacman gnupg: $(test -e etc/pacman.d/gnupg && echo PRESENT || echo absent)"
echo "== users with uid>=1000:"; awk -F: '$3>=1000 && $3<65534' etc/passwd
echo "== packagers:"; grep -h -A1 '^%PACKAGER%' var/lib/pacman/local/*/desc | grep -v '^%PACKAGER%\|^--' | sort | uniq -c | sort -rn | head
echo "== pacman.log lines with /mnt or /home:"; grep -c -E '/mnt/|/home/' var/log/pacman.log; grep -m3 -E '/mnt/|/home/' var/log/pacman.log
echo "== plocate db paths outside the image tree:"; plocate -d var/lib/plocate/plocate.db '/mnt/' 2>/dev/null | head -5; echo "(end)"
echo "== /etc/womarchy:"; head -20 etc/womarchy/profile
