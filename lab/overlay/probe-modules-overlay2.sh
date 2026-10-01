#!/bin/bash
# Read-only: module index sanity in the shared WSL modules overlay.
d=/usr/lib/modules/$(uname -r)
n=$(find $d/kernel -name '*.ko*' | wc -l); echo "module files: $n; modules.dep entries: $(wc -l < $d/modules.dep)"
for m in $(find $d/kernel -name '*.ko*' | head -400 | xargs -n1 basename | sed 's/\.ko.*//' | shuf -n 5 --random-source=/dev/zero); do
  modprobe --dry-run --show-depends "$m" >/dev/null 2>&1 && echo "ok   $m" || echo "FAIL $m"
done
modinfo -F filename "$(find $d/kernel -name '*.ko*' | head -1 | xargs basename | sed 's/\.ko.*//')"
