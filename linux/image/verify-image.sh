#!/bin/bash
# Verify an installed womarchy image (after OOBE). Does not start Hyprland.
#   wsl -d omarchy-test -u root -e bash <repo>/linux/image/verify-image.sh
#   wsl -d omarchy-test          -e bash <repo>/linux/image/verify-image.sh
# As root it checks the system; as a user it checks that user's session.
# Prints PASS/FAIL/WARN per check; exits non-zero if any FAIL.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/omarchy-key.env"   # OMARCHY_KEY_FPR
fails=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
warn() { printf 'WARN  %s\n' "$*"; }
check() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi; }

if (( EUID == 0 )); then
  state=$(systemctl is-system-running --wait 2>/dev/null)
  [[ $state == running ]] && pass "systemctl is-system-running = running" || fail "systemctl is-system-running = $state"
  failed=$(systemctl --failed --no-legend --plain | awk '{print $1}' | paste -sd' ')
  [[ -z $failed ]] && pass "no failed system units" || fail "failed system units: $failed"
  check "pacman -Qi omarchy" pacman -Qi omarchy
  pacman -Q omarchy 2>&1 | grep -q '^warning' && fail "pacman warns: $(pacman -Q omarchy 2>&1 | head -1)" || pass "pacman sync DBs present (no warnings)"
  v=$(omarchy-version 2>/dev/null) && pass "omarchy-version = $v" || fail "omarchy-version"
  check "womarchy-compat installed" pacman -Qi womarchy-compat
  for p in limine snapper linux; do
    pacman -Qq "$p" 2>/dev/null | grep -qx "$p" && fail "$p is installed" || pass "$p not installed"
  done
  first_repo=$(grep -m1 -E '^\[[a-z]+\]' <(grep -v '^\[options\]' /etc/pacman.conf))
  [[ $first_repo == "[womarchy]" ]] && pass "[womarchy] is the first repo" || fail "first repo is $first_repo"
  check "IgnorePkg for kernels" grep -q '^IgnorePkg = linux linux-lts' /etc/pacman.conf
  check "pacman keyring initialised (OOBE)" pacman-key --list-keys "$OMARCHY_KEY_FPR"
  # [womarchy] signatures: the pinned womarchy key, locally trusted; signed dbs required.
  check "womarchy-keyring installed" pacman -Q womarchy-keyring
  validity=$(gpg --homedir /etc/pacman.d/gnupg --no-permission-warning --batch --with-colons --list-keys "$WOMARCHY_KEY_FPR" 2>/dev/null |
    awk -F: '$1 == "pub" { print $2; exit }')
  [[ $validity == [fu] ]] && pass "womarchy key $WOMARCHY_KEY_FPR trusted in pacman's keyring" ||
    fail "womarchy key not (fully) trusted in pacman's keyring (validity '${validity:-missing}')"
  grep -qx "$WOMARCHY_KEY_FPR:4:" /usr/share/pacman/keyrings/womarchy-trusted &&
    pass "womarchy-trusted is the pinned key" || fail "womarchy-trusted: $(cat /usr/share/pacman/keyrings/womarchy-trusted 2>&1)"
  sig=$(awk '/^\[womarchy\]/{f=1;next} /^\[/{f=0} f && /^SigLevel/' /etc/pacman.conf)
  [[ $sig == "SigLevel = PackageOptional DatabaseRequired" ]] && pass "[womarchy] $sig" || fail "[womarchy] ${sig:-no SigLevel}"
  check "local repo db signature valid" pacman-key --verify /var/lib/womarchy/repo/womarchy.db.sig /var/lib/womarchy/repo/womarchy.db
  check "sync db signature valid" pacman-key --verify /var/lib/pacman/sync/womarchy.db.sig /var/lib/pacman/sync/womarchy.db
  # Rollback points and the Mesa/LLVM guard.
  for h in 00-womarchy-rollback-point 10-womarchy-mesa-llvm; do
    check "pacman hook $h" test -f /usr/share/libalpm/hooks/$h.hook
  done
  check "womarchy-rollback --list" bash -c 'womarchy-rollback --list >/dev/null || [[ $? == 5 ]]'
  # Hyprland/aquamarine carry soname deps, so pacman refuses mismatched hyprutils & co. upgrades itself.
  deps=$(pacman -Qi hyprland aquamarine 2>/dev/null | awk -F' *: ' '/^Depends On/ { print $2 }')
  grep -qE 'libhyprutils\.so=[0-9]+-64' <<<"$deps" && grep -qE 'libaquamarine\.so=[0-9]+-64' <<<"$deps" &&
    pass "hyprland/aquamarine keep soname dependencies" || fail "soname dependencies missing: $deps"
  # [womarchy]: hosted repo, then the local copy; the local copy must not be writable by users.
  repo=/var/lib/womarchy/repo
  block=$(awk '/^\[womarchy\]/{f=1;next} /^\[/{f=0} f' /etc/pacman.conf)
  hosted=$(sed -n 's/^WOMARCHY_REPO_URL=//p' /etc/womarchy/config 2>/dev/null | tail -n1)
  hosted=${hosted:-https://github.com/sytelus/womarchy/releases/download/packages}
  [[ $(grep -m1 '^Server' <<<"$block") == "Server = $hosted" ]] &&
    grep -qx "Server = file://$repo" <<<"$block" && pass "[womarchy] servers: hosted + file://$repo" ||
    fail "[womarchy] servers: $(grep Server <<<"$block" | paste -sd' ')"
  check "local repo db present" test -f $repo/womarchy.db
  bad=$(find $repo /var/lib/womarchy \( -perm /022 -o ! -user root \) ! -type l 2>/dev/null | head -5)
  [[ -z $bad ]] && pass "local repo root-owned, not group/other-writable" || fail "writable/non-root in repo: $bad"
  old=$(find $repo -name '*.old' | head -3)
  [[ -z $old ]] && pass "no *.old in the repo" || fail "*.old in repo: $old"
  [[ ! -e /var/cache/womarchy-repo ]] && pass "no repo left in /var/cache" || fail "/var/cache/womarchy-repo still exists"
  # The post-update hook's path on the live system: reassert must succeed, keep the
  # system running, and leave Omarchy's install log closed (0640, not 0666).
  if out=$(womarchy-apply-system --reassert 2>&1); then pass "womarchy-apply-system --reassert (live)"; else fail "reassert: $out"; fi
  m=$(stat -c %a /var/log/omarchy-install.log 2>/dev/null)
  [[ $m == 640 ]] && pass "omarchy-install.log mode 640 after reassert" || fail "omarchy-install.log mode ${m:-missing}"
  state=$(systemctl is-system-running 2>/dev/null)
  [[ $state == running ]] && pass "still running after reassert" || fail "after reassert: $state"
  check "settings file /etc/womarchy/config" grep -q '^WOMARCHY_DOCKER=' /etc/womarchy/config
  check "womarchy's masks are recorded" test -s /var/lib/womarchy/masked-units
  for u in NetworkManager systemd-resolved systemd-networkd sddm cups avahi-daemon power-profiles-daemon bluetooth; do
    s=$(systemctl is-enabled "$u.service" 2>/dev/null)
    [[ $s == masked || -z $s || $s == not-found ]] && pass "$u: ${s:-absent}" || fail "$u: $s"
  done
  if [[ $(sed -n 's/^WOMARCHY_DOCKER=//p' /etc/womarchy/config | tail -n1) == 0 ]]; then
    s=$(systemctl is-enabled docker.socket 2>/dev/null)
    [[ $s != enabled ]] && pass "docker.socket ${s:-absent} (WOMARCHY_DOCKER=0: Docker Desktop's WSL integration)" ||
      fail "docker.socket enabled although WOMARCHY_DOCKER=0"
  else
    check "docker.socket enabled" systemctl is-enabled docker.socket
  fi
  jq -e 'has("dns") | not' /etc/docker/daemon.json >/dev/null 2>&1 && pass "docker daemon.json has no dns key" || fail "docker daemon.json dns"
  check "binfmt drop-in" test -f /etc/systemd/system/systemd-binfmt.service.d/10-womarchy-wsl.conf
  # other distros' disks and loop devices (Docker Desktop's ISOs) are hidden from udisks,
  # so Omarchy's udiskie never prompts to automount them
  check "udev rule hiding WSL disks from udisks" test -f /usr/lib/udev/rules.d/90-womarchy-wsl-disks.rules
  shown=()
  for d in /sys/class/block/loop* /sys/class/block/sd?; do
    [[ -e $d ]] || continue
    props=$(udevadm info -q property -n "/dev/${d##*/}" 2>/dev/null)
    [[ ${d##*/} == loop* ]] || grep -qx ID_VENDOR=Msft <<<"$props" || continue
    grep -qx UDISKS_IGNORE=1 <<<"$props" || shown+=("${d##*/}")
  done
  ((${#shown[@]} == 0)) && pass "WSL loop devices and virtual disks hidden from udisks" ||
    fail "visible to udisks (udiskie would prompt to mount them): ${shown[*]}"
  if pacman -Qq womarchy-session &>/dev/null; then
    mountpoint -q /mnt/wslgshm && pass "mnt-wslgshm.mount mounted" || fail "mnt-wslgshm.mount: $(systemctl is-active mnt-wslgshm.mount)"
  else
    warn "womarchy-session not installed (no shared-memory mount)"
  fi
  gen=/usr/lib/systemd/user-environment-generators/60-womarchy-gpu
  check "GPU user environment generator" test -x $gen
  [[ ! -e /etc/environment.d/10-womarchy-gpu.conf ]] && pass "no unconditional GALLIUM_DRIVER in environment.d" ||
    fail "/etc/environment.d/10-womarchy-gpu.conf still sets GALLIUM_DRIVER unconditionally"
  with=$(env -i "$gen"); without=$(env -i WOMARCHY_DXG=/nonexistent "$gen")
  [[ $with == *GALLIUM_DRIVER=d3d12* && $without != *GALLIUM_DRIVER* && $without == *GSK_RENDERER=ngl* ]] &&
    pass "generator: d3d12 only with /dev/dxg" || fail "generator output: with dxg [$with] without [$without]"
  check "pipewire WSLg tunnel config" test -f /etc/pipewire/pipewire.conf.d/50-womarchy-wslg.conf
  if grep -q '^XKBLAYOUT=' /etc/vconsole.conf; then
    lay=$(sed -n 's/^XKBLAYOUT=//p' /etc/vconsole.conf); ok=1
    for l in ${lay//,/ }; do
      awk -v n="$l" '/^! /{s=$2;next} s=="layout" && $1==n {f=1} END{exit !f}' /usr/share/X11/xkb/rules/base.lst || ok=0
    done
    ((ok)) && pass "vconsole.conf $(grep '^XKB' /etc/vconsole.conf | paste -sd' ') (valid XKB)" || fail "vconsole.conf layout '$lay' not in base.lst"
  else
    fail "vconsole.conf has no XKBLAYOUT"
  fi
  check "locale en_US.UTF-8 generated" bash -c 'locale -a | grep -qix en_US.utf8' 
  grep -q '^\[user\]' /etc/wsl.conf && pass "wsl.conf default user: $(sed -n 's/^default=//p' /etc/wsl.conf)" || fail "wsl.conf [user]"
  check "OOBE completed" test -f /var/lib/womarchy/oobe-done
  check "appendWindowsPath=false" grep -q '^appendWindowsPath=false' /etc/wsl.conf
  check "no NM-owned resolv.conf (WSL generated)" grep -q 'generated by WSL' /etc/resolv.conf

  # Start menu: every entry WSLg would publish has an OnlyShowIn=Hyprland override.
  check "pacman hook for WSLg app overrides" test -f /usr/share/libalpm/hooks/90-womarchy-wslg-apps.hook
  visible=0 covered=0
  for f in /usr/share/applications/*.desktop; do
    awk -F= '/^\[/{g=$0;next} g!="[Desktop Entry]"{next}
      $1=="Type"&&$2!="Application"{h=1} ($1=="Hidden"||$1=="NoDisplay"||$1=="Terminal")&&tolower($2)=="true"{h=1}
      $1=="OnlyShowIn"{h=1} END{exit h}' "$f" || continue
    visible=$((visible + 1))
    grep -qs '^OnlyShowIn=Hyprland;' "/usr/local/share/applications/${f##*/}" && covered=$((covered + 1))
  done
  [[ $visible -gt 0 && $visible -eq $covered ]] && pass "WSLg-visible apps hidden from Windows: $covered/$visible" ||
    fail "WSLg-visible apps with override: $covered/$visible"

  # Never write into WSL's /usr/lib/modules/<ver>: it is a VM-wide overlay shared by all distros.
  [[ -e /usr/lib/modules/$(uname -r)/vmlinuz ]] && fail "a vmlinuz exists in WSL's shared modules overlay" ||
    pass "nothing added to WSL's shared /usr/lib/modules/$(uname -r)"
  [[ $(readlink /etc/pacman.d/hooks/60-depmod.hook) == /dev/null ]] && pass "kmod depmod pacman hook disabled" ||
    fail "kmod depmod hook active (would rewrite WSL's VM-wide module indexes)"
  warn "known: 'omarchy update' ends with 'Linux kernel has been updated. Reboot?' on WSL; answer no (see INSTALL-NOTES)"
else
  export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  echo "user $(id -un) uid $(id -u) home $HOME"
  s=$(systemctl --user is-system-running 2>/dev/null)
  [[ $s == running ]] && pass "user manager running" || fail "user manager: $s ($(systemctl --user --failed --no-legend --plain | awk '{print $1}' | paste -sd' '))"
  check "~/.config/hypr/hyprland.lua (Omarchy)" test -f ~/.config/hypr/hyprland.lua
  check "~/.config/hypr/womarchy.lua" test -f ~/.config/hypr/womarchy.lua
  check "bindings.lua requires hypr.womarchy" grep -q 'require("hypr.womarchy")' ~/.config/hypr/bindings.lua
  check "monitors.lua reads womarchy-session rules" grep -q 'womarchy/monitors.lua' ~/.config/hypr/monitors.lua
  check "uwsm env.d/10-womarchy" test -f ~/.config/uwsm/env.d/10-womarchy
  jq -e '(.disabledPlugins | index("omarchy.idle")) and ([.bar.layout[][]?.id] | index("omarchy.network") | not)' \
    ~/.config/omarchy/shell.json >/dev/null && pass "shell.json: idle off, network widget dropped" || fail "shell.json"
  perl -0pe 's{^\s*//[^\n]*(\n|$)}{}mg' ~/.config/omarchy/extensions/omarchy-menu.jsonc |
    jq -e '.["system.suspend"].when == "false" and .["system.shutdown"].action == "omarchy-system-logout"' >/dev/null &&
    pass "menu overlay: suspend hidden, shutdown -> logout" || fail "menu overlay"
  check "post-update hook" test -x ~/.config/omarchy/hooks/post-update.d/10-womarchy
  nmo=$(bash -c '. ~/.config/uwsm/env.d/10-womarchy; command -v nm-online')
  [[ $nmo == /usr/lib/womarchy/bin/nm-online ]] && timeout 5 "$nmo" -q -x -t 30 &&
    pass "session nm-online: $nmo reports online (no Wi-Fi toast)" || fail "session nm-online: ${nmo:-none}"
  check "Omarchy theme set" test -s ~/.local/state/omarchy/current/theme.name
  check "omarchy-provision-user done" test -f ~/.local/state/omarchy/done/finalize-user
  check "womarchy-provision-user done" test -f ~/.local/state/womarchy/provisioned
  if grep -qs '^WOMARCHY_PROFILE=lite' /etc/womarchy/profile; then
    check "lite: preinstalls-removed marker" test -f ~/.local/state/omarchy/preinstalls-removed
  fi
  command -v hyprctl >/dev/null && pass "hyprctl present ($(hyprctl version -j 2>/dev/null | jq -r .tag 2>/dev/null || echo 'no instance'))" || warn "hyprctl absent"

  ume=$(systemctl --user show-environment 2>/dev/null)
  [[ -e /dev/dxg ]] && grep -qx GALLIUM_DRIVER=d3d12 <<<"$ume" && grep -qx GSK_RENDERER=ngl <<<"$ume" &&
    pass "user manager env: GALLIUM_DRIVER=d3d12 GSK_RENDERER=ngl (from the generator)" ||
    fail "user manager env: $(grep -E '^(GALLIUM_DRIVER|GSK_RENDERER)=' <<<"$ume" | paste -sd' ')"
  # GPU: GALLIUM_DRIVER from the login environment (profile.d), not set by hand.
  gd=$(bash -lc 'echo "$GALLIUM_DRIVER"')
  renderer=$(bash -lc 'eglinfo -B -p surfaceless 2>&1' | grep -m1 'OpenGL core profile renderer' | sed 's/.*renderer: //')
  [[ $renderer == D3D12* ]] && pass "eglinfo surfaceless (login env GALLIUM_DRIVER=$gd): $renderer" ||
    fail "eglinfo surfaceless renderer: ${renderer:-none} (GALLIUM_DRIVER=$gd)"
  # the configured adapter is the one rendering, in login shells and in the user manager
  want=$(sed -n 's/^WOMARCHY_GPU_ADAPTER=//p' /etc/womarchy/config 2>/dev/null | tail -n1)
  if [[ -n $want && -e /dev/dxg ]]; then
    [[ ${renderer,,} == *"${want,,}"* ]] && pass "d3d12 adapter is WOMARCHY_GPU_ADAPTER=$want" ||
      fail "d3d12 adapter: $renderer, not WOMARCHY_GPU_ADAPTER=$want"
    grep -qx "MESA_D3D12_DEFAULT_ADAPTER_NAME=$want" <<<"$ume" && pass "user manager env: MESA_D3D12_DEFAULT_ADAPTER_NAME=$want" ||
      fail "user manager env lacks MESA_D3D12_DEFAULT_ADAPTER_NAME=$want"
  fi

  # Audio: straight to WSLg, and through PipeWire's tunnel.
  srv=$(PULSE_SERVER=unix:/mnt/wslg/PulseServer pactl info 2>/dev/null | sed -n 's/^Server Name: //p')
  [[ -n $srv ]] && pass "pactl -> WSLg PulseServer: $srv" || fail "pactl cannot reach /mnt/wslg/PulseServer"
  export PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native"
  pw=$(pactl info 2>/dev/null | sed -n 's/^Server Name: //p')
  [[ $pw == *PipeWire* ]] && pass "pactl -> pipewire-pulse: $pw" || fail "pipewire-pulse not reachable (${pw:-no answer})"
  for i in $(seq 1 10); do pactl list short sinks 2>/dev/null | grep -q wslg-sink && break; sleep 1; done
  if pactl list short sinks 2>/dev/null | grep -q wslg-sink; then
    pass "PipeWire tunnel sink to WSLg: $(pactl list short sinks | grep wslg-sink | awk '{print $2, $NF}'); default=$(pactl get-default-sink)"
  else
    fail "no wslg-sink in PipeWire ($(pactl list short sinks 2>&1 | paste -sd';'))"
  fi
fi

echo "---- $fails failure(s)"
exit $(( fails > 0 ))
