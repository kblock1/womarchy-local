# womarchy WSL leaf: keyboard layout + locale (the ISO's archinstall step).
# Omarchy's Hyprland input config reads XKBLAYOUT/XKBVARIANT from
# /etc/vconsole.conf. Inputs (env): WOMARCHY_XKB_LAYOUT, WOMARCHY_XKB_VARIANT,
# WOMARCHY_LOCALE. Without them an existing setting is kept, else us/en_US.
set -euo pipefail

# Value of KEY in /etc/vconsole.conf, empty when the file or key is missing.
current() { [[ -f /etc/vconsole.conf ]] || return 0; sed -n "s/^$1=//p" /etc/vconsole.conf | tr -d '"' | tail -n1; }

layout="${WOMARCHY_XKB_LAYOUT:-$(current XKBLAYOUT)}"
layout="${layout:-us}"
variant="${WOMARCHY_XKB_VARIANT-$(current XKBVARIANT)}"
[[ $layout =~ ^[a-z0-9_,()-]+$ ]] || { echo "bad XKB layout '$layout'" >&2; exit 1; }
[[ -z $variant || $variant =~ ^[A-Za-z0-9_,()-]+$ ]] || { echo "bad XKB variant '$variant'" >&2; exit 1; }

# No KEYMAP=: WSL has no virtual consoles, and an XKB name that is not also a
# console keymap would fail systemd-vconsole-setup.
{
  echo "# Managed by womarchy (wsl/keyboard-locale.sh); read by Omarchy's hypr input config"
  echo "XKBLAYOUT=$layout"
  if [[ -n $variant ]]; then echo "XKBVARIANT=$variant"; fi
} >/etc/vconsole.conf
chmod 0644 /etc/vconsole.conf

locale="${WOMARCHY_LOCALE:-}"
[[ -z $locale && -f /etc/locale.conf ]] && locale=$(sed -n 's/^LANG=//p' /etc/locale.conf | tail -n1)
[[ -z $locale || $locale == C.UTF-8 ]] && locale=en_US.UTF-8
[[ $locale =~ ^[A-Za-z_]+\.UTF-8$ ]] || { echo "bad locale '$locale'" >&2; exit 1; }
for l in en_US.UTF-8 "$locale"; do
  sed -i "s/^#\s*\(${l//./\.} UTF-8\)/\1/" /etc/locale.gen
done
locale-gen >/dev/null
echo "LANG=$locale" >/etc/locale.conf
