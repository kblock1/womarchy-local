#!/bin/bash
# OOBE negative tests inside a throwaway image rootfs (no terminal: stdin=/dev/null).
O=/usr/lib/womarchy/oobe.sh
ok() { printf 'PASS  %s\n' "$*"; }; no() { printf 'FAIL  %s\n' "$*"; }
rm -f /var/lib/womarchy/oobe-done
out=$(WOMARCHY_OOBE_USER=alice timeout 20 bash $O </dev/null 2>&1); rc=$?
[[ $rc == 1 ]] && grep -q 'WOMARCHY_OOBE_PASSWORD' <<<"$out" && ! id alice &>/dev/null &&
  ok "user without password, no tty: exits 1 at once, no account (rc=$rc)" || no "rc=$rc: $out"
out=$(WOMARCHY_OOBE_USER=docker WOMARCHY_OOBE_PASSWORD=x WOMARCHY_OOBE_SKIP_PROVISION=1 timeout 20 bash $O </dev/null 2>&1); rc=$?
[[ $rc == 1 ]] && grep -q 'already a group name' <<<"$out" && ! getent passwd docker >/dev/null &&
  ok "user name = existing group (docker): refused clearly (rc=$rc)" || no "rc=$rc: $(tail -3 <<<"$out")"
out=$(WOMARCHY_OOBE_USER=bob WOMARCHY_OOBE_PASSWORD=pw WOMARCHY_XKB_LAYOUT=us,de WOMARCHY_OOBE_SKIP_PROVISION=1 timeout 60 bash $O </dev/null 2>&1); rc=$?
[[ $rc == 0 ]] && id -u bob | grep -qx 1000 && grep -qx 'XKBOPTIONS=grp:alt_shift_toggle' /etc/vconsole.conf &&
  ok "unattended user+password: created, 2 layouts + toggle (rc=$rc)" || no "rc=$rc: $(tail -5 <<<"$out")"
grep -q 'run "omarchy" in cmd or PowerShell' <<<"$out" && ok "final message points to omarchy on Windows" || no "final message"
grep -q 'womarchy-session' <<<"$out" && no "message still mentions womarchy-session" || true
[[ $(stat -c %a /var/log/womarchy-oobe.log) == 600 ]] && ok "OOBE log mode 600" || no "log mode $(stat -c %a /var/log/womarchy-oobe.log)"
out=$(timeout 10 bash $O </dev/null 2>&1); rc=$?
[[ $rc == 0 ]] && ok "rerun after success exits 0 (idempotent)" || no "rerun rc=$rc"
userdel -r bob >/dev/null 2>&1; rm -f /var/lib/womarchy/oobe-done

echo "== Preload parsing (simulated reg.exe output)"
fake=$'\r\nHKEY_CURRENT_USER\Keyboard Layout\Preload\r\n    2    REG_SZ    00000419\r\n    1    REG_SZ    00000409\r\n    3    REG_SZ    d0010409\r\n\r\n'
mapfile -t preload < <(printf '%s' "$fake" | tr -d '\r' | awk '$2 == "REG_SZ" && $1 ~ /^[0-9]+$/ { print $1, tolower($3) }' | sort -n | awk '{ print $2 }')
[[ "${preload[*]}" == "00000409 00000419 d0010409" ]] && ok "Preload order: ${preload[*]}" || no "Preload: ${preload[*]}"
source <(sed -n '/^klid_to_xkb()/,/^}/p' $O)
spec="" seen=","
for klid in 00000409 00000419 00020409 00000409 deadbeef; do
  x=$(klid_to_xkb "$klid"); [[ -n $x && $seen != *",$x,"* ]] || continue; spec+="${spec:+,}$x" seen+="$x,"
done
[[ $spec == "us,ru,us:intl" ]] && ok "KLIDs -> spec '$spec' (unknown dropped, duplicates removed)" || no "spec '$spec'"
