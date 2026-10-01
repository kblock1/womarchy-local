#!/bin/bash

# womarchy first-run setup (WSL OOBE). WSL runs this as root, attached to the
# terminal, the first time the distro's default shell is opened after
# `wsl --install --from-file Omarchy*.wsl` (/etc/wsl-distribution.conf [oobe]).
# omarchy.exe also runs it (wsl --exec) when the session reports that setup is
# needed. Exit 0 = done (WSL then makes UID 1000 the default user and never runs
# it again); non-zero = WSL closes the shell and runs this again next launch.
#
#   /usr/lib/womarchy/oobe.sh [--defaults]
#
# Unattended use (installers; pass the variables through WSLENV from Windows):
#   WOMARCHY_OOBE_USER + WOMARCHY_OOBE_PASSWORD   (both required without a terminal)
#   WOMARCHY_OOBE_FULLNAME, WOMARCHY_OOBE_EMAIL, WOMARCHY_XKB_LAYOUT,
#   WOMARCHY_XKB_VARIANT, WOMARCHY_OOBE_NOPASSWD=1 (passwordless sudo),
#   WOMARCHY_OOBE_SKIP_PROVISION=1
# TESTS ONLY: --defaults / WOMARCHY_OOBE_DEFAULTS=1 creates user "omarchy" with
#   the well-known password "omarchy" and sudo rights. Never use it for a real
#   install (test-image.ps1 uses it on throwaway omarchy-test* distros).

set -uo pipefail

UID_DEFAULT=1000   # must match [oobe] defaultUid in /etc/wsl-distribution.conf
DONE=/var/lib/womarchy/oobe-done
LOG=/var/log/womarchy-oobe.log
REG=/mnt/c/Windows/System32/reg.exe
CMD=/mnt/c/Windows/System32/cmd.exe
export OMARCHY_PATH=/usr/share/omarchy
export PATH="$OMARCHY_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"

defaults="${WOMARCHY_OOBE_DEFAULTS:-0}"
[[ ${1:-} == --defaults ]] && defaults=1
tty=0
[[ -t 0 ]] && tty=1

say() { printf '\e[1;32m::\e[0m %s\n' "$*"; }
err() { printf '\e[1;31merror:\e[0m %s\n' "$*" >&2; }
ask() { # ask VAR "prompt" default
  local __v
  if (( defaults || ! tty )); then printf -v "$1" '%s' "$3"; return; fi
  read -r -p "$2 [$3]: " __v || true
  printf -v "$1" '%s' "${__v:-$3}"
}

touch "$LOG" && chmod 0600 "$LOG"
exec > >(tee -a "$LOG") 2>&1

# Already set up (e.g. OOBE was run by omarchy.exe, or a retry after success):
# let WSL record completion and switch to the default user.
if [[ -f $DONE ]] && getent passwd "$UID_DEFAULT" >/dev/null; then
  exit 0
fi

existing=$(getent passwd "$UID_DEFAULT" | cut -d: -f1)
if (( ! defaults && ! tty )) && [[ -z $existing ]] &&
   [[ -z ${WOMARCHY_OOBE_USER:-} || -z ${WOMARCHY_OOBE_PASSWORD:-} ]]; then
  err "no terminal: set WOMARCHY_OOBE_USER and WOMARCHY_OOBE_PASSWORD for unattended setup"
  exit 1
fi

cat <<'EOF'

   Omarchy for WSL (womarchy) - first-run setup
   Omarchy 4 on Arch Linux, with the Hyprland desktop on your GPU.

EOF
if (( defaults )); then
  say "TEST DEFAULTS: user 'omarchy' with password 'omarchy' and sudo. Not for real use."
fi

# --- pacman keyring: never shipped in the image (it would carry a private key)
keyrings=()
for k in archlinux omarchy womarchy; do
  [[ -f /usr/share/pacman/keyrings/$k.gpg ]] && keyrings+=("$k")
done
if [[ ! -s /etc/pacman.d/gnupg/trustdb.gpg ]]; then
  say "Initialising the pacman keyring (${keyrings[*]})"
  pacman-key --init >/dev/null 2>&1 && pacman-key --populate "${keyrings[@]}" >/dev/null 2>&1 ||
    err "pacman keyring setup failed; run: sudo pacman-key --init && sudo pacman-key --populate ${keyrings[*]}"
fi
# With the womarchy key now trusted, [womarchy] can require signed databases.
bash /usr/lib/womarchy/wsl/pacman.sh || err "pacman.conf setup failed; run: sudo womarchy-apply-system --reassert"

# --- Windows hints (not with --defaults): user name and keyboard layouts -------
win_user="" win_klids=()
if (( ! defaults )) && [[ -x $REG && -x $CMD ]]; then
  win_user=$(cd /mnt/c && timeout 5 "$CMD" /d /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' | tail -n1)
  # Read-only: the Windows user's keyboard layouts in order (Preload\1, \2, ...).
  mapfile -t preload < <(cd /mnt/c && timeout 5 "$REG" query 'HKCU\Keyboard Layout\Preload' 2>/dev/null |
    tr -d '\r' | awk '$2 == "REG_SZ" && $1 ~ /^[0-9]+$/ { print $1, tolower($3) }' | sort -n | awk '{ print $2 }')
  for klid in "${preload[@]}"; do
    if [[ $klid == d* ]]; then # substitute layouts (e.g. US-International)
      sub=$(cd /mnt/c && timeout 5 "$REG" query 'HKCU\Keyboard Layout\Substitutes' /v "$klid" 2>/dev/null |
        tr -d '\r' | awk '$2 == "REG_SZ" { print tolower($3) }')
      [[ -n $sub ]] && klid=$sub
    fi
    win_klids+=("$klid")
  done
fi

# Windows keyboard layout id (KLID) -> XKB "layout[:variant]"; empty when unknown.
klid_to_xkb() {
  case "${1,,}" in
    00000409) echo us ;;           00020409) echo us:intl ;;      00010409) echo us:dvorak ;;
    00000809) echo gb ;;           00001809) echo ie ;;           00001009) echo ca:multix ;;
    00000c0c) echo ca:fr-legacy ;; 00000407) echo de ;;           00000807) echo ch ;;
    0000100c) echo ch:fr ;;        0000040c) echo fr ;;           0000080c) echo be ;;
    00000410) echo it ;;           0000040a) echo es ;;           0000080a) echo latam ;;
    00000816) echo pt ;;           00000416) echo br ;;           00010416) echo br ;;
    00000413) echo nl ;;           00000406) echo dk ;;
    00000414) echo no ;;           0000041d) echo se ;;           0000040b) echo fi ;;
    0000040f) echo is ;;           00000415) echo pl ;;           00000405) echo cz ;;
    0000041b) echo sk ;;           0000040e) echo hu ;;           00000418) echo ro ;;
    00000424) echo si ;;           0000041a) echo hr ;;           00000419) echo ru ;;
    00000422) echo ua ;;           00000408) echo gr ;;           0000041f) echo tr ;;
    0000040d) echo il ;;           00000401) echo ara ;;          00000411) echo jp ;;
    00000412) echo kr ;;           00000804) echo cn ;;           00000404) echo tw ;;
    00000439) echo in ;;           00000425) echo ee ;;           00000426) echo lv ;;
    00000427) echo lt ;;           00000402) echo bg ;;           00000c1a) echo rs ;;
    *) ;;
  esac
}

# --- user -------------------------------------------------------------------
default_user=$(printf '%s' "${WOMARCHY_OOBE_USER:-${win_user:-omarchy}}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
[[ $default_user =~ ^[a-z_] ]] || default_user=omarchy
(( defaults )) && default_user="${WOMARCHY_OOBE_USER:-omarchy}"

# Remove a half-created account so the next OOBE run starts clean.
abort_user() { err "$1"; userdel -r "$user" >/dev/null 2>&1; exit 1; }

user=$existing
if [[ -n $user ]]; then
  say "Using existing user '$user' (UID $UID_DEFAULT)"
else
  for attempt in 1 2 3; do
    ask user "Linux user name" "$default_user"
    if [[ ! $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      err "'$user' is not a valid user name (lowercase letters, digits, - and _)"
    elif getent passwd "$user" >/dev/null; then
      err "user '$user' already exists"
    elif getent group "$user" >/dev/null; then
      # useradd -U would fail: a group of that name exists (docker, video, git, ...).
      err "'$user' is already a group name on this system; choose another user name"
    else
      break
    fi
    (( defaults || ! tty || attempt == 3 )) && exit 1
  done
  ask fullname "Full name (for git and XCompose; optional)" "${WOMARCHY_OOBE_FULLNAME:-}"
  ask email "Email (for git and XCompose; optional)" "${WOMARCHY_OOBE_EMAIL:-}"

  say "Creating user '$user' (UID $UID_DEFAULT, groups: wheel)"
  useradd -m -u "$UID_DEFAULT" -U -G wheel -s /bin/bash -c "${fullname:-$user}" "$user" || { err "useradd failed"; exit 1; }

  if (( defaults )) || [[ -n ${WOMARCHY_OOBE_PASSWORD:-} ]]; then
    printf '%s:%s\n' "$user" "${WOMARCHY_OOBE_PASSWORD:-omarchy}" | chpasswd ||
      abort_user "setting the password failed (chpasswd)"
  else
    pw_ok=0
    for attempt in 1 2 3; do
      if passwd "$user"; then pw_ok=1; break; fi
      err "password not set (attempt $attempt of 3)"
    done
    (( pw_ok )) || abort_user "no password set; the setup will start again next time"
  fi
fi
fullname="${fullname:-$(getent passwd "$user" | cut -d: -f5 | cut -d, -f1)}"
email="${email:-${WOMARCHY_OOBE_EMAIL:-}}"

# wheel may sudo; passwordless only on request.
install -d -m 0750 /etc/sudoers.d
if [[ ${WOMARCHY_OOBE_NOPASSWD:-0} == 1 ]]; then
  echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' >/etc/sudoers.d/10-womarchy-wheel
else
  echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-womarchy-wheel
fi
chmod 0440 /etc/sudoers.d/10-womarchy-wheel

# Default user for `wsl -d <distro>` (WSL also records defaultUid after OOBE).
if grep -q '^\[user\]' /etc/wsl.conf 2>/dev/null; then
  sed -i "/^\[user\]/,/^\[/{s/^default=.*/default=$user/}" /etc/wsl.conf
  grep -q "^default=$user" /etc/wsl.conf || sed -i "/^\[user\]/a default=$user" /etc/wsl.conf
else
  printf '\n[user]\ndefault=%s\n' "$user" >>/etc/wsl.conf
fi

# --- keyboard layouts ---------------------------------------------------------------
# Spec "layout[:variant],layout[:variant]..." from all Windows layouts (unknown ones
# dropped, duplicates removed); keyboard-locale.sh validates it and, with more than
# one layout, adds the Alt+Shift layout toggle.
spec="" seen=","
for klid in "${win_klids[@]}"; do
  x=$(klid_to_xkb "$klid")
  [[ -n $x && $seen != *",$x,"* ]] || continue
  spec+="${spec:+,}$x" seen+="$x,"
done
spec=${spec:-us}

apply_keyboard() { # spec -> WOMARCHY_XKB_LAYOUT/VARIANT for keyboard-locale.sh
  local item layouts="" variants="" any_variant=0
  IFS=, read -r -a items <<<"$1"
  for item in "${items[@]}"; do
    layouts+="${layouts:+,}${item%%:*}"
    if [[ $item == *:* ]]; then variants+=",${item#*:}"; any_variant=1; else variants+=","; fi
  done
  (( any_variant )) || variants=","
  WOMARCHY_XKB_LAYOUT="$layouts" WOMARCHY_XKB_VARIANT="${variants#,}" \
    bash /usr/lib/womarchy/wsl/keyboard-locale.sh
}

if [[ -n ${WOMARCHY_XKB_LAYOUT:-} ]]; then
  say "Keyboard layout: $WOMARCHY_XKB_LAYOUT ${WOMARCHY_XKB_VARIANT:+($WOMARCHY_XKB_VARIANT)}"
  bash /usr/lib/womarchy/wsl/keyboard-locale.sh || err "keyboard/locale setup failed"
else
  for attempt in 1 2 3; do
    ask xkb "Keyboard layout(s) (XKB layout[:variant], comma-separated; Alt+Shift switches)" "$spec"
    say "Keyboard layout: $xkb"
    apply_keyboard "$xkb" && break
    if (( defaults || ! tty || attempt == 3 )); then
      err "keyboard layout '$xkb' rejected; using us"
      apply_keyboard us || err "keyboard/locale setup failed"
      break
    fi
  done
fi

# --- Omarchy user provisioning ---------------------------------------------------
if [[ ${WOMARCHY_OOBE_SKIP_PROVISION:-0} != 1 ]]; then
  say "Setting up Omarchy for $user (themes, apps, dev tools; needs network, a few minutes)"
  home=$(getent passwd "$user" | cut -d: -f6)
  if ! runuser -u "$user" -- env -i HOME="$home" USER="$user" LOGNAME="$user" SHELL=/bin/bash \
      PATH="$PATH" LANG="$(sed -n 's/^LANG=//p' /etc/locale.conf)" TERM="${TERM:-xterm-256color}" \
      OMARCHY_USER_NAME="$fullname" OMARCHY_USER_EMAIL="$email" \
      womarchy-provision-user --force; then
    err "Omarchy user setup did not finish. Run it again later with: womarchy-provision-user --force"
  fi
fi

mkdir -p "$(dirname "$DONE")"
date -Is >"$DONE"

cat <<EOF

   Done. You are '$user'.
   Start the Omarchy desktop from Windows: run "omarchy" in cmd or PowerShell,
   or use the Omarchy entry in the Start menu.
   Keys Windows reserves moved: layout toggle = Super+Alt+L, close all = Super+Ctrl+Alt+Backspace.

EOF
exit 0
