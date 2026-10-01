#!/bin/bash
# omarchy-test-up phase 5 (root): Mesa/LLVM guard.
set -uo pipefail
export LC_ALL=C OMARCHY_ALLOW_DIRECT_PACMAN=1
G=/usr/lib/womarchy/mesa-llvm-guard
ok() { printf 'PASS  %s\n' "$*"; }; no() { printf 'FAIL  %s\n' "$*"; }
echo "mesa $(pacman -Q mesa | awk '{print $2}'), llvm-libs $(pacman -Q llvm-libs | awk '{print $2}'); libgallium needs: $(grep -aohE 'libLLVM\.so\.[0-9]+(\.[0-9]+)?' /usr/lib/libgallium-*.so | sort -u | paste -sd' '); libLLVM files: $(ls /usr/lib/libLLVM* | paste -sd' ')"
# fake pacman front-end for the direct tests
F=/tmp/fakebin; mkdir -p $F
cat >$F/pacman <<'P'
#!/bin/bash
case "$*" in
  "-Q mesa") echo "mesa ${FAKE_MESA_Q:-1:26.2.3-2.1}" ;;
  "-Si llvm-libs") printf 'Repository      : extra\nName            : llvm-libs\nVersion         : %s\n' "${FAKE_LLVM:-22.1.8-2}" ;;
  "-Si mesa") printf 'Repository      : %s\nName            : mesa\nVersion         : %s\n' "${FAKE_MESA_REPO:-womarchy}" "${FAKE_MESA_SI:-1:26.2.3-2.1}" ;;
  *) exec /usr/bin/pacman "$@" ;;
esac
P
chmod +x $F/pacman
g() { env PATH=$F:$PATH "$@" bash $G </dev/null >/tmp/g.out 2>&1; echo $?; }
[[ $(g FAKE_LLVM=22.1.9-1) == 0 ]] && ok "same soname (22.1.8 -> 22.1.9): allowed" || no "$(cat /tmp/g.out)"
[[ $(g FAKE_LLVM=23.1.0-1) == 1 ]] && ok "soname bump (-> 23.1), no newer womarchy mesa: ABORT" || no "$(cat /tmp/g.out)"
sed -n 2,4p /tmp/g.out
[[ $(g FAKE_LLVM=23.1.0-1 FAKE_MESA_SI=1:26.2.4-1.1) == 0 ]] && ok "soname bump + newer womarchy mesa offered: allowed" || no "$(cat /tmp/g.out)"
[[ $(g FAKE_LLVM=23.1.0-1 FAKE_MESA_REPO=extra FAKE_MESA_SI=1:26.3.0-1) == 1 ]] && ok "newer mesa only from extra: still abort" || no "$(cat /tmp/g.out)"
[[ $(g FAKE_LLVM=23.1.0-1 FAKE_MESA_Q=1:26.2.3-1) == 0 ]] && ok "stock Arch mesa (pkgrel without '.'): allowed" || no "$(cat /tmp/g.out)"

echo "== the real hook: dummy llvm-libs 99.1.0 in a temporary first repo"
B=/tmp/fakellvm; rm -rf $B; mkdir -p $B/repo; chown -R omarchy: $B
cat >$B/PKGBUILD <<'P'
pkgname=llvm-libs
pkgver=99.1.0
pkgrel=1
pkgdesc='DUMMY for the womarchy Mesa/LLVM guard test'
arch=(x86_64)
license=(MIT)
package() { install -Dm644 /dev/null "$pkgdir/usr/share/doc/llvm-libs-dummy"; }
P
chown omarchy: $B/PKGBUILD
runuser -u omarchy -- env -C $B makepkg -f --nodeps >/dev/null 2>&1 && cp $B/llvm-libs-99*.pkg.tar.zst $B/repo/ && (cd $B/repo && repo-add -q fakellvm.db.tar.gz *.pkg.tar.zst)
cp /etc/pacman.conf /root/pacman.conf.bak
sed -i "0,/^# womarchy repo (managed/s||[fakellvm]\nSigLevel = Optional TrustAll\nServer = file://$B/repo\n\n&|" /etc/pacman.conf
before=$(pacman -Q llvm-libs)
pacman -Sy --noconfirm llvm-libs >/tmp/hook.out 2>&1; rc=$?
after=$(pacman -Q llvm-libs)
cp /root/pacman.conf.bak /etc/pacman.conf; pacman -Sy >/dev/null 2>&1
[[ $rc != 0 && $before == "$after" ]] && ok "pacman -S llvm-libs 99.1 aborted by the hook (rc=$rc), $after unchanged" || no "rc=$rc before=$before after=$after"
grep -E "womarchy stopped|would be upgraded|failed to commit|hook" /tmp/hook.out | head -5

echo "== hyprland/aquamarine soname dependencies (pacman refuses mismatched upgrades itself)"
pacman -Qi hyprland aquamarine | awk -F' *: ' '/^Name/ {n=$2} /^Depends On/ {print n ": " $2}' | grep -oE '^[a-z]+:|lib(hypr[a-z]+|aquamarine)\.so=[0-9]+-64' | paste -sd' '
systemctl is-system-running
