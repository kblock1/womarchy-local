# womarchy WSL leaf: PipeWire audio through WSLg's PulseAudio server.
# WSL has no ALSA devices; WSLg exposes PulseAudio at unix:/mnt/wslg/PulseServer
# (RDP audio to Windows). Keep Omarchy's PipeWire + WirePlumber stack and give
# it a pulse-tunnel sink and source to that server, so pactl/wpctl/pamixer, the
# Quickshell audio panel and every app share one graph whose output is Windows.
# Inside the Hyprland session PULSE_SERVER must point at pipewire-pulse, not at
# WSLg directly (the user overlay's uwsm env does that).
set -euo pipefail

install -d -m 0755 /etc/pipewire/pipewire.conf.d
cat >/etc/pipewire/pipewire.conf.d/50-womarchy-wslg.conf <<'CONF'
# Managed by womarchy (wsl/audio.sh): tunnel to WSLg's PulseAudio server.
# nofail: without WSLg (guiApplications=false) PipeWire still starts; the
# tunnels retry every 5 s and appear when the server does.
context.modules = [
  { name = libpipewire-module-pulse-tunnel
    args = {
      tunnel.mode = sink
      pulse.server.address = "unix:/mnt/wslg/PulseServer"
      reconnect.interval.ms = 5000
      stream.props = {
        node.name = "wslg-sink"
        node.description = "Windows audio (WSLg)"
        priority.session = 2000
      }
    }
    flags = [ nofail ]
  }
  { name = libpipewire-module-pulse-tunnel
    args = {
      tunnel.mode = source
      pulse.server.address = "unix:/mnt/wslg/PulseServer"
      reconnect.interval.ms = 5000
      stream.props = {
        node.name = "wslg-source"
        node.description = "Windows microphone (WSLg)"
        priority.session = 2000
      }
    }
    flags = [ nofail ]
  }
]
CONF
chmod 0644 /etc/pipewire/pipewire.conf.d/50-womarchy-wslg.conf

# WSL's user generator adds wslg-session.service to every user manager when
# WSLg is on. It symlinks $XDG_RUNTIME_DIR/pulse/native to WSLg's server, which
# replaces pipewire-pulse's socket (pactl then bypasses PipeWire). Keep its
# Wayland links (WSLg apps started from a plain shell need them), drop the pulse
# ones. /etc/systemd/user outranks generator output, so the drop-in applies.
install -d -m 0755 /etc/systemd/user/wslg-session.service.d
cat >/etc/systemd/user/wslg-session.service.d/10-womarchy-pipewire.conf <<'CONF'
# Managed by womarchy (wsl/audio.sh): leave $XDG_RUNTIME_DIR/pulse to pipewire-pulse.
[Service]
ExecStart=
ExecStart=/bin/sh -c 'ln -sf "$WSLG_RUNTIME_DIR/wayland-0" "$XDG_RUNTIME_DIR/wayland-0"'
ExecStart=/bin/sh -c 'ln -sf "$WSLG_RUNTIME_DIR/wayland-0.lock" "$XDG_RUNTIME_DIR/wayland-0.lock"'
CONF
chmod 0644 /etc/systemd/user/wslg-session.service.d/10-womarchy-pipewire.conf

# PipeWire, pipewire-pulse and WirePlumber are socket/dependency activated per
# user by their packages' global presets; make sure they stay enabled.
systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
