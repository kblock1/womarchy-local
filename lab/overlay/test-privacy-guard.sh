#!/bin/bash
# Exercise build-image.sh's privacy_leaks() on a fake tree.
eval "$(sed -n '/^privacy_leaks() {/,/^}/p' $(dirname "$0")/../../linux/image/build-image.sh)"
d=$(mktemp -d); mkdir -p $d/{root,home,var/log/journal,etc/ssh,etc/pacman.d}
[[ -z $(privacy_leaks $d) ]] && echo "PASS clean tree: no leaks" || echo "FAIL clean tree: $(privacy_leaks $d)"
touch $d/etc/machine-id $d/root/.bash_history $d/etc/ssh/ssh_host_ed25519_key; mkdir $d/home/x $d/etc/pacman.d/gnupg
n=$(privacy_leaks $d | wc -l); [[ $n == 5 ]] && echo "PASS dirty tree: $n leaks found" || echo "FAIL dirty tree: $(privacy_leaks $d)"
rm -rf $d
