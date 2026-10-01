#!/bin/bash
# Parser/termination tests for linux/overlay/bin/nm-online (needs ip + a default route).
s=$(dirname "$0")/../../linux/overlay/bin/nm-online
for args in "-t" "-q -t" "-qt" "-qx -t 5" "--timeout=abc -x" "-q -s -t 30" "-x -t" "-q -x -t 30" "--timeout"; do
  start=$(date +%s%N); timeout 5 bash $s $args; rc=$?; ms=$(( ($(date +%s%N) - start) / 1000000 ))
  printf '%-18s rc=%s %sms\n' "$args" "$rc" "$ms"
done
