#!/bin/bash
export XDG_RUNTIME_DIR=/run/user/$(id -u)
ls -la $XDG_RUNTIME_DIR $XDG_RUNTIME_DIR/pulse 2>&1
findmnt -rn | grep -E "run/user|wslg" 
systemctl --user status pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service --no-pager 2>&1 | grep -E "●|Active|Listen|error|Error" 
systemctl --user list-units --all 'wslg*' --no-pager 2>&1 | head; ls /usr/lib/systemd/user | grep -i wsl
env | grep -E "PULSE|XDG_RUNTIME|WAYLAND"
