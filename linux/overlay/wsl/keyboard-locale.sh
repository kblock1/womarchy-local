# womarchy WSL leaf: keyboard layouts + locale (the ISO's archinstall step).
# Omarchy's Hyprland input config reads XKBLAYOUT/XKBVARIANT from
# /etc/vconsole.conf; womarchy's ~/.config/hypr/womarchy.lua adds XKBOPTIONS
# (e.g. the layout toggle) to Omarchy's kb_options.
# Inputs (env):
#   WOMARCHY_XKB_LAYOUT   comma list, e.g. "us,ru"
#   WOMARCHY_XKB_VARIANT  comma list aligned with the layouts, e.g. ",phonetic"
#   WOMARCHY_XKB_OPTIONS  default: grp:alt_shift_toggle with more than one layout
#   WOMARCHY_LOCALE       e.g. en_US.UTF-8, "de_DE.UTF-8", sr_RS.UTF-8@latin
# Without them the current settings are kept, else us / en_US.UTF-8. Names are
# checked against /usr/share/X11/xkb/rules/base.lst. The two steps are
# independent: a keyboard problem never skips locale-gen. Non-zero if either failed.
set +e
set -uo pipefail

warn() { echo "womarchy (wsl/keyboard-locale.sh): $*" >&2; }

# Value of KEY in /etc/vconsole.conf, empty when the file or key is missing.
current() {
  [[ -f /etc/vconsole.conf ]] || return 0
  sed -n "s/^$1=//p" /etc/vconsole.conf | tr -d "\"'" | tail -n1
}

LST=/usr/share/X11/xkb/rules/base.lst
# xkb_known layout NAME | variant NAME LAYOUT | option NAME
xkb_known() {
  [[ -r $LST ]] || return 0
  awk -v kind="$1" -v name="$2" -v lay="${3:-}" '
    /^! / { sect = $2; next }
    sect != kind { next }
    kind == "variant" { if ($1 == name && $2 == lay ":") found = 1; next }
    $1 == name { found = 1 }
    END { exit !found }
  ' "$LST"
}

keyboard() {
  local layouts variants options i
  if [[ -n ${WOMARCHY_XKB_LAYOUT:-} ]]; then
    layouts=$WOMARCHY_XKB_LAYOUT
    variants=${WOMARCHY_XKB_VARIANT:-}
  else
    layouts=$(current XKBLAYOUT)
    variants=${WOMARCHY_XKB_VARIANT-$(current XKBVARIANT)}
  fi
  layouts=${layouts:-us}
  local -a L V O
  IFS=, read -r -a L <<<"$layouts"
  IFS=, read -r -a V <<<"$variants"
  if [[ -n ${WOMARCHY_XKB_OPTIONS+x} ]]; then
    options=$WOMARCHY_XKB_OPTIONS
  elif [[ -n ${WOMARCHY_XKB_LAYOUT:-} ]]; then
    options=""
    ((${#L[@]} > 1)) && options=grp:alt_shift_toggle
  else
    options=$(current XKBOPTIONS)
  fi
  IFS=, read -r -a O <<<"$options"

  [[ -r $LST ]] || warn "$LST not found; layout names not validated"
  ((${#V[@]} <= ${#L[@]})) || { warn "more variants ($variants) than layouts ($layouts)"; return 1; }
  for i in "${!L[@]}"; do
    [[ ${L[i]} =~ ^[a-z0-9_]+$ ]] && xkb_known layout "${L[i]}" ||
      { warn "unknown XKB layout '${L[i]}'"; return 1; }
    if [[ -n ${V[i]:-} ]]; then
      [[ ${V[i]} =~ ^[A-Za-z0-9_-]+$ ]] && xkb_known variant "${V[i]}" "${L[i]}" ||
        { warn "unknown XKB variant '${V[i]}' for layout '${L[i]}'"; return 1; }
    fi
  done
  for i in "${!O[@]}"; do
    [[ ${O[i]} =~ ^[a-z0-9_]+:[A-Za-z0-9_+-]+$ ]] && xkb_known option "${O[i]}" ||
      { warn "unknown XKB option '${O[i]}'"; return 1; }
  done

  # No KEYMAP=: WSL has no virtual consoles, and an XKB name that is not also a
  # console keymap would fail systemd-vconsole-setup.
  {
    echo "# Managed by womarchy (wsl/keyboard-locale.sh); read by Omarchy's and womarchy's hypr input config"
    echo "XKBLAYOUT=$layouts"
    [[ ${variants//,/} ]] && echo "XKBVARIANT=$variants"
    [[ $options ]] && echo "XKBOPTIONS=$options"
    true
  } >/etc/vconsole.conf.womarchy && chmod 0644 /etc/vconsole.conf.womarchy &&
    mv -f /etc/vconsole.conf.womarchy /etc/vconsole.conf
}

locale_setup() {
  local loc=${WOMARCHY_LOCALE:-} base mod entry found=0
  if [[ -z $loc && -f /etc/locale.conf ]]; then
    loc=$(sed -n 's/^LANG=//p' /etc/locale.conf | tail -n1)
  fi
  loc=${loc//\"/}
  loc=${loc//\'/}
  [[ -z $loc || $loc =~ ^(C|POSIX|C\.UTF-8|C\.utf8)$ ]] && loc=en_US.UTF-8
  # language[_TERRITORY].UTF-8[@modifier]; any spelling of the codeset is normalised.
  if [[ $loc =~ ^([a-z]{2,3}(_[A-Z]{2})?)\.([Uu][Tt][Ff]-?8)(@[A-Za-z0-9]+)?$ ]]; then
    base=${BASH_REMATCH[1]} mod=${BASH_REMATCH[4]}
  else
    warn "unsupported locale '$loc' (expected e.g. en_US.UTF-8 or sr_RS.UTF-8@latin)"
    return 1
  fi
  loc=$base.UTF-8$mod
  # locale.gen spells modifier locales without the codeset ("sr_RS@latin UTF-8").
  for entry in en_US.UTF-8 "$base.UTF-8$mod" "$base$mod"; do
    if grep -qE "^#?[[:space:]]*${entry//./\\.}[[:space:]]+UTF-8[[:space:]]*$" /etc/locale.gen; then
      sed -i -E "s/^#[[:space:]]*(${entry//./\\.}[[:space:]]+UTF-8)[[:space:]]*$/\1/" /etc/locale.gen
      [[ $entry != en_US.UTF-8 || $loc == en_US.UTF-8 ]] && found=1
    fi
  done
  ((found)) || { warn "locale '$loc' is not in /etc/locale.gen"; return 1; }
  locale-gen >/dev/null || { warn "locale-gen failed"; return 1; }
  echo "LANG=$loc" >/etc/locale.conf
}

status=0
keyboard || status=1
locale_setup || status=1
exit "$status"
