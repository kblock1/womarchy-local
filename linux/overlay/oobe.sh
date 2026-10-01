#!/bin/bash

# womarchy first-run setup (WSL OOBE). WSL runs this as root, attached to the
# terminal, the first time the distro's default shell is opened after
# `wsl --install --from-file Omarchy*.wsl` (/etc/wsl-distribution.conf [oobe]).
# Exit 0 = done (WSL then makes UID 1000 the default user and never runs it
# again); non-zero = WSL closes the shell and runs this again next launch.
#
#   /usr/lib/womarchy/oobe.sh [--defaults]
#
# Unattended use (tests, installers; pass through WSLENV from Windows):
#   WOMARCHY_OOBE_DEFAULTS=1   user "omarchy", password "omarchy", layout us
#   WOMARCHY_OOBE_USER, WOMARCHY_OOBE_PASSWORD, WOMARCHY_OOBE_FULLNAME,
#   WOMARCHY_OOBE_EMAIL, WOMARCHY_XKB_LAYOUT, WOMARCHY_XKB_VARIANT,
#   WOMARCHY_OOBE_NOPASSWD=1 (passwordless sudo), WOMARCHY_OOBE_SKIP_PROVISION=1

set -uo pipefail

UID_DEFAULT=1000   # must match [oobe] defaultUid in /etc/wsl-distribution.conf
DONE=/var/lib/womarchy/oobe-done
LOG=/var/log/womarchy-oobe.log
export OMARCHY_PATH=/usr/share/omarchy
export PATH="$OMARCHY_PATH/bin:/usr/local/sbin:/usr/local/bin:/usr/bin"

defaults="${WOMARCHY_OOBE_DEFAULTS:-0}"
[[ ${1:-} == --defaults ]] && defaults=1

say() { printf '\e[1;32m::\e[0m %s\n' "$*"; }
err() { printf '\e[1;31merror:\e[0m %s\n' "$*" >&2; }
ask() { # ask VAR "prompt" default
  local __v
  if (( defaults )) || [[ ! -t 0 ]]; then printf -v "$1" '%s' "$3"; return; fi
  read -r -p "$2 [$3]: " __v || true
  printf -v "$1" '%s' "${__v:-$3}"
}

exec > >(tee -a "$LOG") 2>&1

# Already set up (e.g. OOBE was run by hand, or a retry after success): let
# WSL record completion and switch to the default user.
if [[ -f $DONE ]] && getent passwd "$UID_DEFAULT" >/dev/null; then
  exit 0
fi

if (( ! defaults )) && [[ ! -t 0 ]] && [[ -z ${WOMARCHY_OOBE_USER:-} ]]; then
  err "no terminal: set WOMARCHY_OOBE_DEFAULTS=1 or WOMARCHY_OOBE_USER/PASSWORD for unattended setup"
  exit 1
fi

cat <<'EOF'

   Omarchy for WSL (womarchy) - first-run setup
   Omarchy 4 on Arch Linux, with the Hyprland desktop on your GPU.

EOF

# --- pacman keyring: never shipped in the image (it would carry a private key)
if [[ ! -s /etc/pacman.d/gnupg/trustdb.gpg ]]; then
  say "Initialising the pacman keyring"
  pacman-key --init >/dev/null 2>&1 && pacman-key --populate archlinux omarchy >/dev/null 2>&1 ||
    err "pacman keyring setup failed; run: sudo pacman-key --init && sudo pacman-key --populate archlinux omarchy"
fi

# --- Windows hints (skipped with defaults): user name and keyboard layout -----
win_user="" win_klid=""
if (( ! defaults )) && [[ -x /mnt/c/Windows/System32/cmd.exe ]]; then
  win_user=$(cd /mnt/c && timeout 5 /mnt/c/Windows/System32/cmd.exe /d /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r' | tail -n1)
  # Read-only: first keyboard layout of the Windows user (e.g. 00000409).
  win_klid=$(cd /mnt/c && timeout 5 /mnt/c/Windows/System32/reg.exe query 'HKCU\Keyboard Layout\Preload' /v 1 2>/dev/null |
    tr -d '\r' | awk '/REG_SZ/ {print tolower($3)}')
  if [[ $win_klid == d* ]]; then # substitute layouts (e.g. US-International)
    win_klid=$(cd /mnt/c && timeout 5 /mnt/c/Windows/System32/reg.exe query 'HKCU\Keyboard Layout\Substitutes' /v "$win_klid" 2>/dev/null |
      tr -d '\r' | awk '/REG_SZ/ {print tolower($3)}')
  fi
fi

# Windows keyboard layout id (KLID) -> XKB "layout[:variant]". Unknown -> us.
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
    *) echo us ;;
  esac
}

# --- user -------------------------------------------------------------------
default_user=$(printf '%s' "${WOMARCHY_OOBE_USER:-${win_user:-omarchy}}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
[[ $default_user =~ ^[a-z_] ]] || default_user=omarchy
(( defaults )) && default_user="${WOMARCHY_OOBE_USER:-omarchy}"

user=$(getent passwd "$UID_DEFAULT" | cut -d: -f1)
if [[ -n $user ]]; then
  say "Using existing user '$user' (UID $UID_DEFAULT)"
else
  while :; do
    ask user "Linux user name" "$default_user"
    if [[ $user =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && ! getent passwd "$user" >/dev/null; then break; fi
    err "'$user' is not a valid, unused user name (lowercase letters, digits, - and _)"
    (( defaults )) || [[ ! -t 0 ]] && exit 1
  done
  ask fullname "Full name (for git and XCompose; optional)" "${WOMARCHY_OOBE_FULLNAME:-}"
  ask email "Email (for git and XCompose; optional)" "${WOMARCHY_OOBE_EMAIL:-}"

  say "Creating user '$user' (UID $UID_DEFAULT, groups: wheel)"
  useradd -m -u "$UID_DEFAULT" -U -G wheel -s /bin/bash -c "${fullname:-$user}" "$user" || { err "useradd failed"; exit 1; }

  if (( defaults )) || [[ -n ${WOMARCHY_OOBE_PASSWORD:-} ]]; then
    printf '%s:%s\n' "$user" "${WOMARCHY_OOBE_PASSWORD:-omarchy}" | chpasswd
  else
    until passwd "$user"; do err "try again"; done
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

# --- keyboard layout -----------------------------------------------------------
xkb="${WOMARCHY_XKB_LAYOUT:-}"
if [[ -z $xkb ]]; then
  xkb=$(klid_to_xkb "${win_klid:-00000409}")
  ask xkb "Keyboard layout (XKB layout[:variant])" "$xkb"
fi
say "Keyboard layout: $xkb"
WOMARCHY_XKB_LAYOUT="${xkb%%:*}" WOMARCHY_XKB_VARIANT="${WOMARCHY_XKB_VARIANT:-$( [[ $xkb == *:* ]] && echo "${xkb#*:}")}" \
  bash /usr/lib/womarchy/wsl/keyboard-locale.sh || err "keyboard/locale setup failed"

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

   Done. You are '$user'. Start the desktop from Windows with: omarchy
   (or inside this shell: womarchy-session, once the womarchy session is installed).
   Keys Windows reserves moved: layout toggle = Super+Alt+L, close all = Super+Ctrl+Alt+Backspace.

EOF
exit 0
