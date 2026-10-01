#!/bin/bash
# omarchy-test-up phase 4 (root): womarchy-rollback + rollback-point tests.
set -uo pipefail
export LC_ALL=C OMARCHY_ALLOW_DIRECT_PACMAN=1
D=/var/lib/womarchy/rollback
ok() { printf 'PASS  %s\n' "$*"; }; no() { printf 'FAIL  %s\n' "$*"; }
ver() { pacman -Q "$1" 2>/dev/null | awk '{print $2}'; }
age_points() { touch -d '-2 hours' $D/*.pkgs; }

echo "== list"
out=$(runuser -u omarchy -- womarchy-rollback --list 2>&1); rc=$?
[[ $rc == 0 ]] && ok "--list as a normal user (rc 0)" || no "--list rc=$rc"; echo "$out"
out=$(womarchy-rollback --to 99 --yes 2>&1); [[ $? == 1 ]] && ok "unknown point -> 1" || no "unknown point: $out"
out=$(womarchy-rollback --to 20261001T000000Z </dev/null 2>&1); rc=$?
[[ $rc == 2 && $(ver womarchy-compat) == 0.4.0-1 ]] && ok "no terminal, no --yes -> 2, nothing changed" || no "rc=$rc $out"

echo "== a) back to the pre-upgrade point: downgrade from the local repo + remove the added keyring"
age_points
out=$(womarchy-rollback --to 20261001T000000Z --yes 2>&1); rc=$?
echo "$out" | grep -E "change|remove|reinstall|Rolled|error" | head
[[ $rc == 0 && $(ver womarchy-compat) == 0.3.0-1 && -z $(ver womarchy-keyring) ]] && ok "compat 0.4.0 -> 0.3.0 (womarchy local repo), keyring removed" || no "rc=$rc compat=$(ver womarchy-compat) keyring=$(ver womarchy-keyring)"
grep -q 'womarchy local repo' <<<"$out" && ok "source: womarchy local repo" || no "source not local repo"
n=$(ls $D/*.pkgs | wc -l); [[ $n == 2 ]] && ok "the rollback's own transaction saved a point first ($n points)" || no "points: $n"
pacman -S --noconfirm womarchy-compat >/dev/null 2>&1 && [[ $(ver womarchy-compat) == 0.4.0-1 ]] && ok "back to 0.4.0 (+keyring $(ver womarchy-keyring)) from the signed hosted repo" || no "reinstall 0.4.0"

echo "== b) Arch archive download + removal of an added package"
age_points; /usr/lib/womarchy/rollback-point; P=$(ls $D | sort | tail -1); echo "point P: $P"
which_now=$(ver which)
pacman -U --noconfirm https://archive.archlinux.org/packages/w/which/which-2.21-6-x86_64.pkg.tar.zst >/dev/null 2>&1
pacman -U --noconfirm https://archive.archlinux.org/packages/s/sl/sl-5.05-6-x86_64.pkg.tar.zst >/dev/null 2>&1
echo "after changes: which $(ver which), sl $(ver sl); cache has which-$which_now: $(ls /var/cache/pacman/pkg/which-$which_now-* 2>/dev/null | wc -l)"
[[ $(ls $D | sort | tail -1) == "$P" ]] && ok "no extra point within 30 min" || no "a new point appeared"
out=$(womarchy-rollback --yes 2>&1); rc=$?
echo "$out" | grep -E "change|remove|download|MiB|archive|Rolled|error" | head
[[ $rc == 0 && $(ver which) == "$which_now" && -z $(ver sl) ]] && ok "which back to $which_now (downloaded from the Arch archive), sl removed" || no "rc=$rc which=$(ver which) sl=$(ver sl)"

echo "== c) missing packages: refuse unless --partial"
pacman -U --noconfirm /var/cache/pacman/pkg/sl-5.05-6-x86_64.pkg.tar.zst >/dev/null 2>&1
age_points
pacman -Q | grep -v '^sl ' | sed 's/^which .*/which 0.0-1/' >$D/29990101T000000Z.pkgs; echo "womarchy-nonexistent 1.0-1" >>$D/29990101T000000Z.pkgs
out=$(womarchy-rollback --yes 2>&1); rc=$?
[[ $rc == 3 && -n $(ver sl) ]] && ok "missing old packages -> 3, nothing changed" || no "rc=$rc sl=$(ver sl)"; echo "$out" | grep -A3 "not in the cache" | head -4
out=$(womarchy-rollback --yes --partial 2>&1); rc=$?
[[ $rc == 0 && -z $(ver sl) && $(ver which) == "$which_now" ]] && ok "--partial: sl removed, which and the missing ones left as they are" || no "partial rc=$rc sl=$(ver sl) which=$(ver which)"
rm -f $D/29990101T000000Z.pkgs

echo "== d) no points"
mv $D /root/rb.bak; womarchy-rollback --list >/dev/null 2>&1; rc=$?; mv /root/rb.bak $D
[[ $rc == 5 ]] && ok "no rollback points -> 5" || no "rc=$rc"
echo "== e) rollback-point: keeps 5, atomic names, fast"
age_points; for i in 1 2 3 4 5 6; do touch -d "-$((i+3)) hours" $D/*.pkgs 2>/dev/null; cp $D/$P $D/2026010${i}T000000Z.pkgs; done
age_points; t0=$(date +%s%N); /usr/lib/womarchy/rollback-point; ms=$(( ($(date +%s%N) - t0) / 1000000 ))
n=$(ls $D/*.pkgs | wc -l); [[ $n == 5 ]] && ok "pruned to the newest 5 (took ${ms} ms)" || no "points: $n"
ls -a $D | grep -q '^\.point' && no "temp file left" || ok "no temp files left"
systemctl is-system-running
